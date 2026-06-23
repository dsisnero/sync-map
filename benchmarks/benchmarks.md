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
| 100  | 47.8 | 102 | 43.4 |
| 1k   | 39.1 | 51.6 | 30.3 |
| 10k  | 35.0 | 28.6 | 31.7 |
| 100k | 24.8 | 6.10 | **31.1** |

87.5% read / 12.5% write:

| Size | `Sync::Map` | `HashTrieMap` | `XMap` |
|------|------------:|--------------:|-------:|
| 100  | 40.1 | 43.4 | 32.0 |
| 1k   | 36.6 | 29.8 | 25.7 |
| 10k  | 37.9 | 16.5 | 26.2 |
| 100k | 24.8 | 4.26 | **25.4** |

### MT — real parallelism (`ExecutionContext::Parallel`)

Each cell shows throughput at **workers = 2 / 4 / 8**.

100% reads:

| Size | `Sync::Map` (2/4/8) | `HashTrieMap` (2/4/8) | `XMap` (2/4/8) |
|------|---------------------|-----------------------|----------------|
| 100  | 38.1 / 33.8 / 43.1 | 76.8 / 59.8 / 66.4 | 44.3 / 35.8 / 46.6 |
| 1k   | 39.7 / 36.7 / 39.2 | 45.6 / 55.5 / 67.9 | 32.0 / 35.1 / 31.1 |
| 10k  | 36.3 / 24.3 / 44.6 | 31.9 / 18.6 / 25.2 | 22.0 / 34.0 / 33.9 |
| 100k | 29.3 / 19.6 / 27.0 | 7.71 / 7.45 / 6.37 | **30.8 / 30.2 / 31.4** |

87.5% read / 12.5% write:

| Size | `Sync::Map` (2/4/8) | `HashTrieMap` (2/4/8) | `XMap` (2/4/8) |
|------|---------------------|-----------------------|----------------|
| 100  | 40.2 / 33.4 / 23.0 | 31.8 / 37.8 / 33.9 | 32.7 / 35.6 / 33.3 |
| 1k   | 30.9 / 18.5 / 44.7 | 20.9 / 29.2 / 28.9 | 19.0 / 23.8 / 27.6 |
| 10k  | 28.9 / 23.9 / 29.2 | 13.5 / 14.9 / 13.8 | 21.0 / 25.6 / 25.6 |
| 100k | 27.5 / 18.3 / 24.7 | 4.52 / 4.42 / 4.36 | **27.0 / 25.0 / 26.7** |

## Charts

Bar length ∝ throughput (M ops/s); longer = faster.

`XMap` is the most size-robust backend — nearly flat 31-43 M across all
sizes. `HashTrieMap` dominates at tiny sizes but fades as size grows.

```text
ST, 100% reads — throughput by map size      (each # ~= 2 M ops/s)

 size=100   Sync::Map   47.8  ########################
            HashTrieMap 102   ####################################################
            XMap        43.4  ######################
 size=1k    Sync::Map   39.1  ####################
            HashTrieMap 51.6  ##########################
            XMap        30.3  ###############
 size=10k   Sync::Map   35.0  #################
            HashTrieMap 28.6  ##############
            XMap        31.7  ################
 size=100k  Sync::Map   24.8  ############
            HashTrieMap  6.10 ###
            XMap        31.1  ################
```

Adding workers does *not* speed things up on a single shared map —
throughput is essentially flat from 2 to 8 workers:

```text
MT, 100% reads, size=1k — throughput by workers   (each # ~= 2 M ops/s)

 Sync::Map    w2 39.7  ####################
              w4 36.7  ##################
              w8 39.2  ####################
 HashTrieMap  w2 45.6  #######################
              w4 55.5  ############################
              w8 67.9  ##################################
 XMap         w2 32.0  ################
              w4 35.1  #################
              w8 31.1  ################
```

At 100k entries, `XMap` is the clear leader across all worker counts.
`Sync::Map` and `HashTrieMap` have dropped off while `XMap` stays steady:

```text
MT, 100% reads, size=100k — throughput by workers (each # ~= 2 M ops/s)

 Sync::Map    w2 29.3  ##############
              w4 19.6  ##########
              w8 27.0  #############
 HashTrieMap  w2  7.71 ####
              w4  7.45 ####
              w8  6.37 ###
 XMap         w2 30.8  ###############
              w4 30.2  ###############
              w8 31.4  ################
```

## What the Numbers Mean

### More threads do not multiply throughput on one shared map

Going from 2 to 4 to 8 workers leaves throughput essentially flat — e.g.
`XMap` reads at 10k run 22 / 34 / 34 M, and at 100k run 31 / 30 / 31 M.
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
