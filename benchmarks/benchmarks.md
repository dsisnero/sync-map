# Concurrent Map Benchmarks

Crystal 1.20.2, macOS aarch64 (Apple Silicon), `--release`.

Three backends share the same concurrent-map contract:

- `Sync::Map` — `Sync::RWLock(:unchecked)` + stdlib `Hash`
- `Sync::HashTrieMap` — lock-free reads over a hash trie
- `Sync::XMap` — CLHT (cache-line hash table)

## Harness Notes

- `benchmarks/bench_harness.cr` pre-fills each map before timing.
- Each benchmark runs 5 times, discards the first run, and averages the last 4.
- Dead-code elimination is blocked with a sink count that must match `ITERS`.
- The MT build now uses real concurrent workers instead of just MT compile flags.
- Worker count defaults to `1` for ST and `8` for MT, and can be
  overridden with `BENCH_WORKERS`.
- `BENCH_SIZE`, `BENCH_RUNS`, and `BENCH_ITERS` can override the default workload.
- `BENCH_MODE=read|mixed` selects between the original read-only benchmark and
  an `87.5%` read / `12.5%` write hot-set workload.
- For micro-optimization work, prefer a longer run such as
  `BENCH_ITERS=5000000 BENCH_RUNS=6` so each timed average lands well
  above the 10-20ms noise floor.

## Commands

```bash
# Single-thread
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache crystal build --release -o bin/bench benchmarks/bench_harness.cr
./bin/bench

# Multi-thread
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache crystal build --release -Dpreview_mt -Dexecution_context -o bin/bench_mt benchmarks/bench_harness.cr
./bin/bench_mt

# Size sweep (read + mixed, both binaries)
for s in 100 1000 10000 100000; do
  for m in read mixed; do
    BENCH_SIZE=$s BENCH_MODE=$m ./bin/bench
    BENCH_SIZE=$s BENCH_MODE=$m ./bin/bench_mt
  done
done
```

## Results — Size Sweep

Measured 2026-06-23. `iters=500000`, `runs=5` (first discarded, last 4
averaged), `Int32 => Int32` keys. Throughput in millions of ops/s (M).

### ST — 100% reads (`workers=1`)

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 38.4 | 80.9 | 70.6 |
| 1k   | 34.7 | 52.2 | 40.8 |
| 10k  | 33.7 | 26.7 | 4.78 |
| 100k | 18.8 | 5.18 | 0.16 |

### ST — 87.5% read / 12.5% write (`workers=1`)

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 34.8 | 36.2 | 64.6 |
| 1k   | 34.6 | 22.3 | 37.2 |
| 10k  | 36.6 | 10.8 | 4.11 |
| 100k | 18.5 | 3.31 | 0.15 |

### MT — 100% reads (`workers=8`)

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 34.9 | 45.4 | 47.2 |
| 1k   | 34.0 | 34.9 | 26.0 |
| 10k  | 23.9 | 20.3 | 4.32 |
| 100k | 16.4 | 5.19 | 0.14 |

### MT — 87.5% read / 12.5% write (`workers=8`)

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 31.4 | 22.6 | 39.3 |
| 1k   | 21.0 | 17.4 | 24.1 |
| 10k  | 34.6 | 9.92 | 3.51 |
| 100k | 11.7 | 3.09 | 0.13 |

## What the Numbers Say

- **`Sync::Map` is the most size-robust backend.** It stays ~33-38M ops/s
  up to 10k entries and remains the clear winner at 100k (ST 18.8M,
  MT 16.4M) — orders of magnitude ahead of the others on large maps.
- **At small sizes (≤ ~1k) the lock-free backends win.** `HashTrieMap`
  leads pure reads (80.9M ST at size 100); `XMap` leads small mixed
  workloads (64.6M ST, 39.3M MT at size 100).
- **`XMap` collapses on large maps.** Read throughput falls to ~0.15M
  ops/s at 100k entries (a ~3.2s pass for 500k loads), a >400x drop from
  its small-map peak. This is a scaling cliff in the read path, not a
  tuning artifact — treat it as a known limitation pending investigation.
- **`HashTrieMap` degrades steadily with size** and falls behind
  `Sync::Map` from ~1k (mixed) and ~10k (read) onward.
- **These backends are about safe concurrent access, not throughput
  multiplication.** On this shared-key microbenchmark the MT numbers are
  flat-to-lower than ST; reader locks and lock-free reads are already
  cheap, so adding workers mostly adds coordination overhead.

## Backend Recommendations

| Workload | Recommended backend |
|----------|---------------------|
| General purpose / unsure | `Sync::Map` |
| Any map ≳ 1k entries | `Sync::Map` |
| Small (≤ ~1k), read-mostly, hot path | `Sync::HashTrieMap` |
| Small (≤ ~1k), mixed read/write | `Sync::XMap` |
| Large (≳ 10k) | `Sync::Map` (avoid `XMap`) |

When in doubt, use `Sync::Map`: it has the broadest API surface, the most
predictable behavior, and the best large-map throughput.

## Usage

All three backends share the same API. Pick one by requiring it:

```crystal
require "sync-map"               # Sync::Map (default)
require "sync-map/hash_trie_map" # Sync::HashTrieMap
require "sync-map/xmap"          # Sync::XMap

a = Sync::Map(String, Int32).new
b = Sync::HashTrieMap(String, Int32).new
c = Sync::XMap(String, Int32).new

[a, b, c].each do |m|
  m.store("k", 1)
  value, ok = m.load("k") # => {1, true}
end
```

Shared core API: `load`, `store`, `delete`, `clear`, `load_or_store`,
`load_and_delete`, `swap`, `compare_and_swap`, `compare_and_delete`,
`range`, plus the xsync extensions (`compute`, `load_or_compute`,
`delete_matching`, `stats`). `Sync::Map` additionally exposes the full
Crystal `Hash`-style surface and `Enumerable({K, V})`.

## Optimization Notes

- `Sync::Map` uses `Sync::RWLock(:unchecked)` and routes read-only
  operations through reader locks.
- Measured against a mutex baseline with the same current `HashTrieMap`,
  `XMap`, and harness on `BENCH_ITERS=5000000 BENCH_RUNS=6`:
  `Sync::Map` improved from `31.3M -> 38.8M` ST and `27.8M -> 35.8M` MT.
- On the mixed workload, the same mutex-vs-`RWLock` comparison improved
  `Sync::Map` from `31.1M -> 33.0M` ST and `19.1M -> 36.6M` MT.
- `HashTrieMap` keeps leaf entries as copy-on-write snapshots; reads stay
  lock-free and race-free by loading the current leaf snapshot atomically,
  while writes take the leaf mutex and publish a replaced snapshot.
- `HashTrieMap#load` is specialized for the fixed 2-level trie shape
  (`root -> internal -> leaf`) instead of using the generic depth-walk
  loop on the read hot path.
- A specialized `HashTrieMap` write descent for the fixed depth was tested
  and discarded because it regressed the mixed workload.
