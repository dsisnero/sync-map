# Architecture

## Overview

`Sync::Map(K, V)` is a thread-safe concurrent map for Crystal, ported from
Go's `sync.Map` and `xsync.Map`. It provides a concurrent-safe alternative
to wrapping a `Hash(K, V)` with a `Mutex`.

## Backing Store

- **Primary**: `Hash(K, V)` — Crystal's stdlib hash table
- **Lock**: `Sync::RWLock(:unchecked)` — read-only operations take a reader
  lock and proceed concurrently; mutations take the writer lock

## Backends

Three concurrent-map implementations share the same contract:

- `Sync::Map` (default) — `RWLock` + `Hash`, broadest API surface
- `Sync::HashTrieMap` — lock-free reads over a hash trie
- `Sync::XMap` — CLHT (cache-line hash table), best raw throughput

See [benchmarks](../benchmarks/benchmarks.md) for measured throughput and
backend selection guidance.

## API Layers

1. **Go sync.Map parity** — `load`, `store`, `delete`, `clear`, `load_or_store`,
   `load_and_delete`, `swap`, `compare_and_swap`, `compare_and_delete`, `range`
2. **xsync extended** — `load_and_store`, `load_or_compute`, `compute`,
   `delete_matching`, `stats`
3. **Crystal Hash parity** — `[]`, `[]=`, `[]?`, `fetch`, `has_key?`,
   `has_value?`, `key_for`, `put_if_absent`, `shift`, `dup`, `clone`, `merge`,
   `merge!`, `select`, `reject`, `select!`, `reject!`, `transform_keys`,
   `transform_values`, `compact`, `compact!`, `invert`, `dig`, `dig?`,
   `each_key`, `each_value`, `values_at`, `first_key`, `last_key`, `first_value`,
   `last_value`, `to_a`, `to_h`
4. **Enumerable inclusion** — `each` yields `{K, V}` tuples for
   `Enumerable({K, V})`, providing `map`, `reduce`, `find`, `all?`, `any?`,
   `count`, `sum`, `min`, `max`, `group_by`, `partition`, and more for free

## Thread Safety

- **SAFE (52 methods)**: hold lock for entire operation, no user callback
- **SNAPSHOT (7 methods)**: take snapshot under lock, release, iterate snapshot
  — `each`, `each_key`, `each_value`, `range` and their block-less forms
- **BLOCK_UNDER_LOCK (19 methods)**: execute user-provided block while holding
  lock. Inherits deadlock risk if block re-enters the map (same as upstream Go)

## Iteration Strategy

SNAPSHOT methods (each, each_key, each_value, range):

1. Acquire lock
2. Copy all entries/keys/values to an array
3. Release lock
4. Iterate the snapshot array

This ensures iteration never blocks writers and avoids deadlock when the
iteration callback accesses the map.
