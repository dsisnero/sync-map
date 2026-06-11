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

- `spec/sync-map_spec.cr` — 154 specs organized by feature area
- `spec/spec_helper.cr` — test setup, requires `spec` and `../src/sync-map`

## Spec Categories

| Category | Count | Purpose |
|----------|-------|---------|
| Core API | 30 | Go sync.Map parity + Crystal idiomatic |
| Hash parity | 45 | Crystal Hash method coverage |
| xsync extended | 10 | Compute, delete_matching, load_or_compute |
| Enumerable | 6 | all?, any?, find, map, count |
| Concurrency | 15 | Atomic operations under contention |
| Snapshot iteration | 6 | each/each_key/each_value consistency |
| Block-under-lock | 13 | select, reject, transform, merge, invert, compact |
| Snapshot safety | 2 | each_key/each_value re-entrant calls |
| Stats + iterators | 6 | Stats, block-less iterator returns |

## Concurrency Testing

All concurrent tests use `spawn` for fibers and `Channel` for synchronization.
Run with `-Dpreview_mt` to exercise true parallel thread execution.

## Test Fixtures

Tests use `Sync::Map(String, Int32)` for basic type coverage and
`Sync::Map(Int32, Int32)` for concurrent tests (faster hashing, no allocations).
