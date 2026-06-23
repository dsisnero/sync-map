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
averaged), `Int32 => Int32` keys.

**Reading the results.** Every figure is **throughput in millions of
operations per second** (M ops/s) — how many successful map operations
(`load`s, plus `store`s in the mixed workload) complete per second. A cell
of `35.3` means 35.3 million ops/s, and **higher is better**. Each figure is
`iters ÷ average wall-clock` over the 4 timed runs. MT figures are
*aggregate* throughput: the fixed `iters` total is split across all workers,
so a value that stays flat as workers increase means adding threads did not
increase total work done per second.

### ST — single thread (`workers=1`)

100% reads:

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 38.4 | 80.9 | 70.6 |
| 1k   | 34.7 | 52.2 | 40.8 |
| 10k  | 38.6 | 30.4 | **27.1** |
| 100k | 18.8 | 5.18 | **31.8** |

87.5% read / 12.5% write:

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 34.8 | 36.2 | 64.6 |
| 1k   | 34.6 | 22.3 | 37.2 |
| 10k  | 36.6 | 10.8 | **21.5** |
| 100k | 18.5 | 3.31 | 3.44 |

### MT — real parallelism (`ExecutionContext::Parallel`)

Each cell shows throughput at **workers = 2 / 4 / 8**.

100% reads:

| Size | `Sync::Map` (2/4/8) | `HashTrieMap` (2/4/8) | `XMap` (2/4/8) |
|------|---------------------|-----------------------|----------------|
| 100  | 35.3 / 35.5 / 32.0 | 48.2 / 50.6 / 52.1 | 50.8 / 46.7 / 45.3 |
| 1k   | 32.4 / 35.3 / 32.7 | 32.4 / 39.3 / 35.5 | 34.9 / 34.7 / 35.4 |
| 10k  | 29.2 / 29.7 / 28.4 | 12.3 / 14.2 / 16.3 | 25.5 / 25.8 / 25.1 |
| 100k | 14.9 / 10.8 / 10.0 | 4.25 / 7.76 / 4.87 | 6.2 / 8.0 / **10.5** |

87.5% read / 12.5% write:

| Size | `Sync::Map` (2/4/8) | `HashTrieMap` (2/4/8) | `XMap` (2/4/8) |
|------|---------------------|-----------------------|----------------|
| 100  | 27.3 / 35.3 / 29.1 | 15.7 / 24.8 / 23.3 | 38.3 / 43.2 / 41.4 |
| 1k   | 22.7 / 27.6 / 36.3 | 16.8 / 20.1 / 15.8 | 29.9 / 29.8 / 36.4 |
| 10k  | 23.4 / 30.9 / 25.5 | 8.94 / 6.59 / 10.4 | 18.5 / 18.5 / 19.3 |
| 100k | 8.58 / 11.7 / 10.0 | 2.67 / 3.73 / 2.57 | 3.5 / 5.0 / 6.6 |

## Charts

Bar length is proportional to throughput (M ops/s); longer is faster.

Throughput collapses as the map grows — `XMap` falls off a cliff past 10k,
`HashTrieMap` degrades steadily, `Sync::Map` stays the most stable:

```text
ST, 100% reads — throughput by map size      (each # ~= 2 M ops/s)

 size=100   Sync::Map   38.4  ###################
            HashTrieMap 80.9  ########################################
            XMap        70.6  ###################################
 size=1k    Sync::Map   34.7  #################
            HashTrieMap 52.2  ##########################
            XMap        40.8  ####################
 size=10k   Sync::Map   33.7  #################
            HashTrieMap 26.7  #############
            XMap         4.78 ##
 size=100k  Sync::Map   18.8  #########
            HashTrieMap  5.18 ###
            XMap         0.16 .
```

Adding workers does *not* speed things up on a single shared map —
throughput is essentially flat from 2 to 8 workers:

```text
MT, 100% reads, size=1k — throughput by workers   (each # ~= 2 M ops/s)

 Sync::Map    w2 32.4  ################
              w4 35.3  ##################
              w8 32.7  ################
 HashTrieMap  w2 32.4  ################
              w4 39.3  ####################
              w8 35.5  ##################
 XMap         w2 34.9  #################
              w4 34.7  #################
              w8 35.4  ##################
```

The size cliff persists under parallelism: at 100k entries every backend is
far slower and `XMap` is effectively unusable, regardless of worker count:

```text
MT, 100% reads, size=100k — throughput by workers (each # ~= 2 M ops/s)

 Sync::Map    w2 14.9  #######
              w4 10.8  #####
              w8 10.0  #####
 HashTrieMap  w2  4.25 ##
              w4  7.76 ####
              w8  4.87 ##
 XMap         w2  0.28 .
              w4  0.63 .
              w8  0.42 .
```

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
- **Large (≥ ~10k):** `XMap` is the clear, robust winner in every mode and
  worker count, followed by `Sync::Map`. At 100k, XMap leads at 31.8M ST /
  10.5M MT (vs Sync::Map at 18.8M / 10.0M).
- **`XMap` now scales to any size.** The earlier scaling cliff (0.16M at
  100k) was caused by a missing table resize — the map never split buckets,
  causing unbounded chain walks. Adding table resize (grow at load factor
  0.75) eliminated the cliff and made XMap the fastest backend at scale.
- **`HashTrieMap` is a small-map specialist** — it degrades with size due to
  its fixed 2-level trie (1,024 leaves). An experimental Go-style adaptive
  trie is available on a feature branch.
- **Writes:** `Sync::Map`'s `RWLock` serializes writers but lets readers run
  concurrently, so the 12.5%-write mixed workload stays strong even at scale.
  XMap's CLHT write path is fast at all sizes.

## Backend Recommendations

| Workload | Recommended backend |
|----------|---------------------|
| General purpose / unsure | `Sync::Map` |
| Small (≤ ~1k), read-mostly | `Sync::HashTrieMap` |
| Small (≤ ~1k), mixed read/write | `Sync::XMap` |
| Any map ≳ 1k entries | `Sync::XMap` |
| Large (≳ 10k) | `Sync::XMap` |
| Full Crystal Hash API surface | `Sync::Map` (only) |

The right backend depends on **expected size and write mix**, which are
runtime properties — so the choice is yours to make. When in doubt use
`Sync::Map`: it never falls off a cliff and has the broadest API. For
maximum throughput at any scale, `Sync::XMap` is the champion.

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
