# Concurrent Map Benchmarks

Crystal 1.20.2, `--release`, macOS aarch64 (Apple Silicon).
Multi-threaded: `-Dpreview_mt -Dexecution_context`.

All benchmarks use a result sink (`sink += 1 if ok`) to prevent dead
code elimination. Each map is pre-filled with 1,000 Int32 entries
before the timed read loop.

## Implementations

| Name | Backing | Read Locking |
|------|---------|-------------|
| `Sync::Map` | `Hash(K,V)` | `Sync::Mutex(:unchecked)` |
| `Sync::HashTrieMap` | Hash trie (32-way, immutable pattern, max depth 6) | Lock-free (atomic child pointers) |
| `Sync::XMap` | CLHT (Cache-Line Hash Table, 5 entries/bucket, 64B cache line) | Lock-free (atomic meta + entry pointers) |

## Results: Int Keys, 100% Reads, size=1,000

| Map | Single-thread | 4-fiber MT | MT Scaling |
|-----|--------------|-----------|------------|
| `Sync::Map` | **35M** ops/s | 37M ops/s | 1.06x |
| `Sync::HashTrieMap` | 9M ops/s | 17M ops/s | **1.89x** |
| `Sync::XMap` | **67M** ops/s | **75M** ops/s | 1.12x |

## Results: Int Keys, 100% Reads, size=100

| Map | Single-thread |
|-----|--------------|
| `Sync::Map` | 57M ops/s |
| `Sync::HashTrieMap` | 14M ops/s |
| `Sync::XMap` | 206M ops/s |

## Results: Int Keys, 100% Reads, size=5,000

| Map | Single-thread |
|-----|--------------|
| `Sync::Map` | **58M** ops/s |
| `Sync::HashTrieMap` | 19M ops/s |
| `Sync::XMap` | 19M ops/s |

## Analysis

### XMap (CLHT) — Best overall

| Size | vs Sync::Map | Why |
|------|-------------|-----|
| 100 | **3.6x** | SWAR meta filtering avoids key comparisons |
| 1,000 | **1.9x** ST, **2.0x** MT | Lock-free reads, flat bucket structure |
| 5,000 | 0.3x | No resize — overflow chains degrade to O(n) |

**Strengths:** Fastest at small sizes, good MT scaling potential,
SWAR byte-level matching avoids expensive key comparisons on misses.

**Weaknesses:** Degrades at >1,000 entries without cooperative resize.
5 entries per bucket × 32 buckets = 160 base capacity. After that,
overflow chain traversal dominates.

### Sync::Map (Mutex + Hash) — Most consistent

**Strengths:** O(1) performance at all sizes. Predictable, well-tested,
full Crystal Hash API. No degradation at scale.

**Weaknesses:** Mutex on every operation limits MT scaling (1.06x).
All readers serialize on the single mutex.

### HashTrieMap — Best MT scaling, low base

**Strengths:** 1.89x MT scaling — lock-free reads scale with cores.
Correct hash trie distribution (each level uses distinct hash bits).

**Weaknesses:** 6-level atomic descent overhead (6 atomic loads per
read). Slower than Sync::Map at all sizes in single-thread.
32 StaticArray per node (256 bytes) is memory-heavy.

## Conclusions

1. **For all-around use:** `XMap` — fastest single-thread AND multi-thread
   at ≤1,000 entries. Needs resize for larger datasets.

2. **For consistent performance at any size:** `Sync::Map` — O(1) hash
   lookups, no degradation. Best choice when data size is unpredictable.

3. **For high-concurrency reads:** `HashTrieMap` — best MT scaling (1.89x),
   but starts from a lower base. Viable if contention on Sync::Map's mutex
   becomes the bottleneck at high core counts.

4. **Dead code elimination trap:** Crystal's `--release` mode eliminates
   unused return values. All benchmarks MUST use a result sink
   (e.g., `sink += 1 if ok`) for valid measurements.

## Crystal-Specific Lessons

See `docs/crystal-collection-design.md` in the porting-to-crystal skill.

- `StaticArray(Atomic(T))` indexed access returns value copies.
  Use `sa[idx] = Atomic.new(val)` for writes, `sa[idx].get()` for reads.
- Keep `.as(GenericClass(K,V))` calls to ≤2 per method.
- Tagged pointers (bit-tagging on Void*) compiled 50x slower.
- `lucaong/immutable` is the reference Crystal hash trie.
- Depth-increasing levels (immutable pattern) is the correct trie design
  but adds atomic descent overhead in single-thread.
- `--release` eliminates dead code — always sink benchmark results.

## Benchmark Harness

- `benchmarks/bench_int.cr` — single-thread read benchmark
- `benchmarks/bench_mt.cr` — multi-threaded read benchmark
- Run: `crystal build --release -Dpreview_mt -o bin benchmarks/bench_mt.cr && ./bin`
