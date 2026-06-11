# sync-map

A thread-safe concurrent map for Crystal, ported from Go's `sync.Map`
(stdlib, HashTrieMap-backed since Go 1.24) and `xsync.Map`
(puzpuzpuz/xsync, CLHT-based). API covers Go sync.Map, xsync extended
operations, and Crystal `Hash(K,V)` parity with `Enumerable({K,V})`.

## Commands

```bash
# Install dependencies
shards install

# Format check
crystal tool format --check src spec

# Lint
ameba src spec

# Run tests
crystal spec

# Run tests with multi-threading
crystal spec -Dpreview_mt -Dexecution_context

# Run all quality gates
crystal tool format --check src spec && ameba src spec && crystal spec -Dpreview_mt -Dexecution_context

# Clean temporary files
make clean
```

## Architecture

- `src/sync-map.cr` — `Sync::Map(K, V)` with `Sync::Mutex(:unchecked)` +
  `Hash(K,V)` backing. Snapshot-based iteration. Includes `Enumerable({K,V})`.
- `spec/sync-map_spec.cr` — 154 specs covering Go parity, Crystal Hash parity,
  xsync extended API, and MT-safety.
- `vendor/go` — upstream Go source (sync.Map reference)
- `vendor/xsync` — upstream xsync source (best performer in benchmarks)

See `docs/architecture.md` for details.

## Principles

- Upstream behavior is the source of truth. Port behavior first, Crystal idioms
  only where semantics stay unchanged.
- All public methods are MT-safe. Verified with `-Dpreview_mt -Dexecution_context`.
- Red-green TDD: write failing spec, implement minimal fix, run gates, commit.
- Never weaken assertions or change fixtures to fit current implementation.

## Conventions

- Require: `require "sync-map"` → provides `Sync::Map(K, V)`
- Version: 0.1.0 (see `shard.yml`)
- Crystal >= 1.20.2
