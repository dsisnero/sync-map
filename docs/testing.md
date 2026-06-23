# Testing

## Running Tests

```bash
# Single-threaded
make test

# Multi-threaded (true parallelism)
make test-mt

# Run specific spec
crystal spec spec/sync-map_spec.cr:42

# Run specific describe block
crystal spec spec/sync-map_spec.cr -e "MT-safety"
```

## Test Structure

- `spec/sync-map_spec.cr` — `Sync::Map` API, organized by feature area
- `spec/hash_trie_map_spec.cr` — `Sync::HashTrieMap` backend
- `spec/xmap_spec.cr` — `Sync::XMap` (CLHT) backend
- `spec/concurrent_map_contract_spec.cr` — shared concurrent-map contract
- `spec/spec_helper.cr` — test setup, requires `spec` and `../src/sync-map`

## Spec Categories

- Core API — Go sync.Map parity + Crystal idiomatic
- Hash parity — Crystal Hash method coverage
- xsync extended — compute, delete_matching, load_or_compute
- Enumerable — all?, any?, find, map, count
- Concurrency — atomic operations under contention
- Snapshot iteration — each/each_key/each_value consistency
- Block-under-lock — select, reject, transform, merge, invert, compact
- Stats + iterators — stats, block-less iterator returns

## Concurrency Testing

All concurrent tests use `spawn` for fibers and `Channel` for synchronization.
Run with `-Dpreview_mt` to exercise true parallel thread execution.

## Test Fixtures

Tests use `Sync::Map(String, Int32)` for basic type coverage and
`Sync::Map(Int32, Int32)` for concurrent tests (faster hashing, no allocations).
