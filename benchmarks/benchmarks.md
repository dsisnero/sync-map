# Concurrent Map Benchmarks

Single-threaded 100% read benchmark. Crystal 1.20.2, `--release` mode.
macOS aarch64 (Apple Silicon).

## Implementations

| Name | Backing | Locking |
|------|---------|---------|
| `Sync::Map` | `Hash(K,V)` | `Sync::Mutex(:unchecked)` |
| `Sync::HashTrieMap` | Hash trie (32-way, lucaong/immutable pattern) | Lock-free reads, per-node mutex writes |
| `Sync::XMap` | CLHT (Cache-Line Hash Table, xsync port) | Lock-free reads, per-bucket mutex writes |

## Results: Int Keys, 100% Reads

| Size | Sync::Map | XMap | Speedup |
|------|-----------|------|---------|
| 100 | 44M ops/s | 108M ops/s | **2.5x** |
| 1,000 | 34M ops/s | 44M ops/s | **1.3x** |
| 5,000 | 32M ops/s | 11M ops/s | 0.3x |

## Results: String Keys, 100% Reads

| Size | Sync::Map | XMap | Speedup |
|------|-----------|------|---------|
| 100 | 17M ops/s | 82M ops/s | **4.8x** |
| 1,000 | 24M ops/s | 26M ops/s | 1.1x |

## Analysis

### XMap (CLHT)

**Strengths:**
- 2.5x (int) to 4.8x (string) faster at size=100 — SWAR-based
  metadata filtering avoids key comparisons for misses
- Lock-free reads: no mutex overhead on the load path
- Immutable entry pointers: atomic swaps, no torn reads

**Weaknesses:**
- Degrades at size=5,000 (11M vs 32M) — without resize, bucket
  chains grow long. 5,000 entries / 32 buckets = ~156 entries per
  chain = ~31 overflow buckets. Each lookup scans all meta bytes.
- No cooperative resize implemented yet (upstream xsync has it)
- String hashing cost dominates at larger sizes

### Sync::Map (baseline)

**Strengths:**
- Consistent O(1) performance across all sizes
- Full Crystal `Hash` API surface + `Enumerable`
- Simple, predictable, well-tested

**Weaknesses:**
- Every operation acquires a mutex, even reads
- No read scalability — all readers serialize

### HashTrieMap

**Not benchmarked** — sequential store (bulk insert) is
pathologically slow due to `lock_leaf` retry loop with expansion.
Each expansion redistributes all existing entries. For 1,000
entries, ~31 expansions × ~15,500 redistribute operations.
Needs bulk-load optimization before usable.

## Conclusions

1. **For small maps (<1,000 entries):** `XMap` is the clear winner,
   especially with string keys where SWAR filtering avoids expensive
   key comparisons.

2. **For medium maps (1,000-10,000):** `Sync::Map` is the safe choice
   until XMap gets cooperative resize.

3. **For lock-free reads:** Both XMap and HashTrieMap demonstrate
   that Crystal can support concurrent data structures with atomic
   pointer operations. The key is `StaticArray(Atomic(Pointer(Void)))`
   with indexed assignment for writes and `.get(:acquire)` for reads.

4. **Compilation cost:** Crystal's generic instantiation time is a
   real constraint. Single-type benchmarks compile in 5-30s; multi-type
   benchmarks compile in minutes.

## Crystal-Specific Lessons

See `docs/crystal-collection-design.md` in the porting-to-crystal skill.

- `StaticArray(Atomic(T)).new` works but indexed access returns value
  copies. Use `sa[idx] = Atomic.new(val)` for writes, `sa[idx].get()`
  for reads.
- Keep `.as(GenericClass(K,V))` calls to ≤2 per method.
- Tagged pointers (bit-tagging on Void*) compiled 50x slower than
  unified-node design.
- `lucaong/immutable` is the reference Crystal hash trie implementation.
