# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Sync::Map(K, V)` — thread-safe concurrent map backed by
  `Sync::RWLock(:unchecked)` + stdlib `Hash`, with snapshot-based iteration
  and `Enumerable({K, V})`.
- Go `sync.Map` parity: `load`, `store`, `delete`, `clear`, `load_or_store`,
  `load_and_delete`, `swap`, `compare_and_swap`, `compare_and_delete`, `range`.
- xsync extended API: `load_and_store`, `load_or_compute`, `compute`,
  `delete_matching`, `stats`.
- Crystal `Hash(K, V)` parity surface: `[]`, `[]=`, `[]?`, `fetch`, `has_key?`,
  `has_value?`, `key_for`, `put_if_absent`, `shift`, `dup`, `clone`, `merge`,
  `merge!`, `select`, `reject`, `transform_keys`, `transform_values`, `compact`,
  `invert`, `dig`, `dig?`, and more.
- `Sync::HashTrieMap(K, V)` — lock-free-read hash trie backend.
- `Sync::XMap(K, V)` — CLHT (cache-line hash table) backend.
- Benchmark harness (`benchmarks/bench_harness.cr`) with size sweeps,
  read/mixed modes, ST/MT workers, and backend selection recommendations.
- Project docs under `docs/` and quality gates via `make gates`.
- Markdown linting wired into `make lint` via `rumdl fmt`.

[Unreleased]: https://github.com/dsisnero/sync-map
