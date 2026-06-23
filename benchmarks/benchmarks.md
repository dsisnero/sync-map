# Concurrent Map Benchmarks

Crystal 1.20.2, macOS aarch64 (Apple Silicon), `--release`.

Three backends share the same concurrent-map core contract:

- `Sync::Map` — `Sync::RWLock(:unchecked)` + stdlib `Hash`
- `Sync::HashTrieMap` — lock-free reads over a hash trie
- `Sync::XMap` — CLHT (cache-line hash table)

> Benchmarks are only meaningful when built with `--release`. Without it
> Crystal does no optimization, and the optimizer also dead-code-eliminates
> work whose result is unused — so the harness accumulates every result into
> a sink that is checked against an expected count.

## Harness Notes

- `benchmarks/bench_harness.cr` pre-fills each map before timing.
- Each benchmark runs 5 times, discards the first (cold) run, and averages
  the last 4.
- A fixed total of `ITERS` operations is split evenly across the workers;
  throughput is `ITERS / wall_time`.
- Dead-code elimination is blocked with a sink count that must match the
  expected number of successful reads.
- MT workers run on a real `Fiber::ExecutionContext::Parallel` context (see
  below) — not plain `spawn`, which would not run in parallel.
- `BENCH_SIZE`, `BENCH_RUNS`, `BENCH_ITERS`, `BENCH_WORKERS`, and
  `BENCH_MODE=read|mixed` override the workload. Workers default to `1` (ST)
  and `8` (MT).
- For micro-optimization work, prefer a longer run such as
  `BENCH_ITERS=5000000 BENCH_RUNS=6` so each timed average lands well above
  the 10-20ms noise floor.

## Running the Benchmarks

```bash
# Single-thread (ST)
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache crystal build --release -o bin/bench benchmarks/bench_harness.cr
./bin/bench

# Multi-thread (MT) — note BOTH flags
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache crystal build --release -Dpreview_mt -Dexecution_context -o bin/bench_mt benchmarks/bench_harness.cr
BENCH_WORKERS=8 ./bin/bench_mt

# Full sweep used for the tables below
for w in 2 4 8; do
  for s in 100 1000 10000 100000; do
    for m in read mixed; do
      BENCH_WORKERS=$w BENCH_SIZE=$s BENCH_MODE=$m ./bin/bench_mt
    done
  done
done
```

## True Parallelism: the Execution-Context Gotcha

This is the single most important thing to get right when benchmarking (or
writing) concurrent Crystal — and it is easy to get wrong.

With `-Dpreview_mt -Dexecution_context`, the **default** execution context
has a capacity of **1**:

```crystal
Fiber::ExecutionContext.default.capacity # => 1
```

That means plain `spawn` runs every fiber on a **single OS thread**. You get
concurrency (interleaving), not parallelism (multiple cores). `CRYSTAL_WORKERS`
is ignored in this model. Measured here with a CPU-bound probe:

```text
serial            : 396.7 ms
plain spawn x8    : 395.5 ms   (1.00x)  <- NOT parallel
ctx.spawn x8      : 111.7 ms   (3.55x)  <- real parallelism (capacity 8)
```

To run in parallel you must create an explicit context and `ctx.spawn`:

```crystal
ctx = Fiber::ExecutionContext::Parallel.new("workers", 8)
ctx.spawn { work }
```

The harness does exactly this for MT runs and prints the capacities in its
header so you can confirm real parallelism:

```text
default_ctx_capacity=1, bench_ctx_capacity=8
```

If `bench_ctx_capacity` is 1, you are not measuring parallelism.

## Results — Size Sweep

Measured 2026-06-23. `iters=500000`, `runs=5` (first discarded, last 4
averaged), `Int32 => Int32` keys. Throughput in millions of ops/s (M).

### ST — single thread (`workers=1`)

100% reads:

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 38.4 | 80.9 | 70.6 |
| 1k   | 34.7 | 52.2 | 40.8 |
| 10k  | 33.7 | 26.7 | 4.78 |
| 100k | 18.8 | 5.18 | 0.16 |

87.5% read / 12.5% write:

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 34.8 | 36.2 | 64.6 |
| 1k   | 34.6 | 22.3 | 37.2 |
| 10k  | 36.6 | 10.8 | 4.11 |
| 100k | 18.5 | 3.31 | 0.15 |

### MT — real parallelism (`ExecutionContext::Parallel`)

Each cell shows throughput at **workers = 2 / 4 / 8**.

100% reads:

| Size | `Sync::Map` (2/4/8) | `HashTrieMap` (2/4/8) | `XMap` (2/4/8) |
|------|---------------------|-----------------------|----------------|
| 100  | 35.3 / 35.5 / 32.0 | 48.2 / 50.6 / 52.1 | 50.8 / 46.7 / 45.3 |
| 1k   | 32.4 / 35.3 / 32.7 | 32.4 / 39.3 / 35.5 | 34.9 / 34.7 / 35.4 |
| 10k  | 29.2 / 29.7 / 28.4 | 12.3 / 14.2 / 16.3 | 4.64 / 4.78 / 4.91 |
| 100k | 14.9 / 10.8 / 10.0 | 4.25 / 7.76 / 4.87 | 0.28 / 0.63 / 0.42 |

87.5% read / 12.5% write:

| Size | `Sync::Map` (2/4/8) | `HashTrieMap` (2/4/8) | `XMap` (2/4/8) |
|------|---------------------|-----------------------|----------------|
| 100  | 27.3 / 35.3 / 29.1 | 15.7 / 24.8 / 23.3 | 38.3 / 43.2 / 41.4 |
| 1k   | 22.7 / 27.6 / 36.3 | 16.8 / 20.1 / 15.8 | 29.9 / 29.8 / 36.4 |
| 10k  | 23.4 / 30.9 / 25.5 | 8.94 / 6.59 / 10.4 | 4.90 / 4.26 / 4.81 |
| 100k | 8.58 / 11.7 / 10.0 | 2.67 / 3.73 / 2.57 | 0.27 / 0.50 / 0.66 |

## What the Numbers Mean

### More threads do not multiply throughput on one shared map

Going from 2 to 4 to 8 workers leaves throughput essentially flat — e.g.
`Sync::Map` reads at 1k run 32 / 35 / 33 M, and at 10k run 29 / 30 / 28 M.
The benchmark splits a *fixed* total of operations across workers that all
hammer a *single* shared map, so the bottleneck is shared-structure access
(lock acquisition, cache-line contention, memory bandwidth), not CPU work.

The takeaway: these structures give you **safe concurrent access**, not
linear scaling, on a single hot map. If you need throughput to scale with
cores, shard your data across many independent maps so threads rarely touch
the same one — that is a different design choice from picking a backend.

### Map size and workload decide the winner — not the thread count

The ranking is the same single-threaded and multi-threaded; it changes with
**size** and **read/write mix**:

- **Small (≤ ~1k):** `HashTrieMap` wins pure reads (lock-free reads over a
  shallow trie — 80.9M ST / up to 52M MT at size 100). `XMap` wins mixed
  read/write (CLHT write path — 64.6M ST / ~41M MT at size 100).
- **Large (≥ ~10k):** `Sync::Map` is the clear, robust winner in every mode
  and worker count. At 100k it is 10-19M while the others are far lower.
- **`XMap` collapses past ~10k** — down to ~0.15-0.66M ops/s at 100k (a
  multi-second pass for 500k ops), a >100x drop from its small-map peak.
  This is a scaling cliff in its read path; treat it as a hard limit for
  large maps pending investigation.
- **`HashTrieMap` degrades steadily with size** as the trie deepens, falling
  behind `Sync::Map` from ~1k (mixed) and ~10k (read) onward.
- **Writes:** `Sync::Map`'s `RWLock` serializes writers but lets readers run
  concurrently, so the 12.5%-write mixed workload stays strong even at scale
  (100k mixed: ~8-12M). The lock-free backends' small-map write speed does
  not survive growth.

## Backend Recommendations

| Workload | Recommended backend |
|----------|---------------------|
| General purpose / unsure | `Sync::Map` |
| Any map ≳ 1k entries | `Sync::Map` |
| Small (≤ ~1k), read-mostly, hot path | `Sync::HashTrieMap` |
| Small (≤ ~1k), mixed read/write | `Sync::XMap` |
| Large (≳ 10k) | `Sync::Map` (avoid `XMap`) |

The right backend depends on **expected size and write mix**, which are
runtime properties — so the choice is yours to make, not something a compile
flag can decide. When in doubt use `Sync::Map`: it never falls off a cliff,
has the broadest API, and the best large-map throughput.

## Using a Backend

All three backends implement the same core contract; pick one by requiring
it. Only `Sync::Map` adds the full Crystal `Hash` surface and `Enumerable`.

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

### Accessing a map from real parallel workers

Every backend is MT-safe (verified with
`crystal spec -Dpreview_mt -Dexecution_context`). But remember the gotcha
above: to actually run your own work in parallel you must spawn onto an
`ExecutionContext::Parallel` context, not plain `spawn`.

```crystal
require "sync-map"
require "wait_group"

map = Sync::Map(Int32, Int32).new
1000.times { |i| map.store(i, i) }

workers = 8
ctx = Fiber::ExecutionContext::Parallel.new("workers", workers)
wg = WaitGroup.new(workers)
workers.times do |w|
  ctx.spawn do
    10_000.times { |i| map.load((w &* 10_000 &+ i) % 1000) }
    wg.done
  end
end
wg.wait
```

Build/run it with both flags:

```bash
crystal run --release -Dpreview_mt -Dexecution_context app.cr
```

`Fiber::ExecutionContext::Parallel` only exists when compiled with
`-Dexecution_context`.

## Optimization Notes

- `Sync::Map` uses `Sync::RWLock(:unchecked)` and routes read-only
  operations through reader locks.
- `HashTrieMap` keeps leaf entries as copy-on-write snapshots; reads stay
  lock-free and race-free by loading the current leaf snapshot atomically,
  while writes take the leaf mutex and publish a replaced snapshot.
- `HashTrieMap#load` is specialized for the fixed 2-level trie shape
  (`root -> internal -> leaf`) instead of using the generic depth-walk loop
  on the read hot path.
- A specialized `HashTrieMap` write descent for the fixed depth was tested
  and discarded because it regressed the mixed workload.
- Earlier MT figures in this project's history (e.g. "35.8M MT") were
  collected before the harness used `ExecutionContext::Parallel`; they
  reflected single-thread concurrency, not parallelism, and are superseded
  by the tables above.
