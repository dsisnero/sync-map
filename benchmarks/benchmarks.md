# Concurrent Map Benchmarks

Crystal 1.20.2, `--release`, macOS aarch64 (Apple Silicon).
5 runs per benchmark, first run discarded (cold), 4-run average.
3 full benchmark runs, averaged.

## Implementations

| Name | Backing | Read Locking |
|------|---------|-------------|
| `Sync::Map` | `Hash(K,V)` | `Sync::Mutex(:unchecked)` |
| `Sync::HashTrieMap` | Hash trie, 32-way, depth=2 | Lock-free (atomic child pointers) |
| `Sync::XMap` | CLHT, 5 entries/bucket, 64B CL | Lock-free (atomic meta + entry pointers) |

## Results: Int Keys, 100% Reads, size=1,000

| Map | ops/s | vs baseline |
|-----|-------|------------|
| `Sync::Map` | **36M** | 1.00x (baseline) |
| `Sync::HashTrieMap` | **53M** | 1.47x |
| `Sync::XMap` | **58M** | 1.61x |

## Optimization History

| Experiment | HashTrieMap | Change |
|-----------|-------------|--------|
| Initial (depth=6) | 14M | — |
| MAX_DEPTH 6→2 | **53M** | **+279%** |

Root cause: 6-level atomic descent (6 `Atomic.get` loads + pointer chasing)
vs 2-level. With 32^2 = 1024 leaves, depth=2 is optimal for 1,000 entries.

## Conclusions

1. **XMap** is the fastest all-around implementation (58M ST for 1K).
   SWAR byte-level meta matching avoids expensive key comparisons.

2. **HashTrieMap** is competitive after tuning (53M, 1.47x baseline).
   Depth must match expected data size for best performance.

3. **Sync::Map** is the simplest, most consistent implementation (36M).
   Full Crystal Hash API surface + `Enumerable`. No tuning needed.

4. **Dead code elimination** in `--release` mode silently inflates
   reported numbers. Always use a result sink (e.g., `sink += 1 if ok`).

## Benchmark Harness

`benchmarks/bench_harness.cr` — DCE-safe, multi-run averaging.

```bash
# Single-thread
crystal build --release -o bin/bench benchmarks/bench_harness.cr && ./bin/bench

# Multi-thread
crystal build --release -Dpreview_mt -Dexecution_context -o bin/bench_mt benchmarks/bench_harness.cr && ./bin/bench_mt
```
