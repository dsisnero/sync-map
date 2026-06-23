# sync-map

A thread-safe concurrent map for Crystal, ported from Go's `sync.Map`
(stdlib, `HashTrieMap`-backed since Go 1.24) and `xsync.Map`
(puzpuzpuz/xsync, CLHT-based). It provides a concurrent-safe alternative
to wrapping a `Hash(K, V)` with a `Mutex`.

The API covers three surfaces:

- **Go `sync.Map`** — `load`, `store`, `delete`, `clear`, `load_or_store`,
  `load_and_delete`, `swap`, `compare_and_swap`, `compare_and_delete`,
  `range`
- **xsync extended** — `load_and_store`, `load_or_compute`, `compute`,
  `delete_matching`, `stats`
- **Crystal `Hash(K, V)`** — `[]`, `[]=`, `[]?`, `fetch`, `has_key?`,
  `merge`, `select`, `reject`, `transform_values`, `dig`, and more, plus
  `Enumerable({K, V})` for `map`, `reduce`, `find`, `count`, and friends

All public methods are MT-safe, verified with
`-Dpreview_mt -Dexecution_context`.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     sync-map:
       github: dsisnero/sync-map
   ```

2. Run `shards install`

## Usage

```crystal
require "sync-map"

map = Sync::Map(String, Int32).new

# Crystal Hash-style access
map["a"] = 1
map["b"]?            # => 2 or nil

# Go sync.Map-style access (returns {value, ok})
map.store("c", 3)
value, ok = map.load("c")            # => {3, true}
value, loaded = map.load_or_store("c", 99)  # => {3, true}

# Atomic compute
map.compute("a") do |old, present|
  {old + 10, Sync::Map::ComputeOp::Update}
end

# Snapshot iteration (never blocks writers)
map.each do |key, value|
  puts "#{key} => #{value}"
end
```

## Choosing a backend

Three backends share the same concurrent-map contract:

```crystal
require "sync-map"               # Sync::Map (default)
require "sync-map/hash_trie_map" # Sync::HashTrieMap
require "sync-map/xmap"          # Sync::XMap
```

| Workload | Recommended backend |
|----------|---------------------|
| General purpose / unsure | `Sync::Map` |
| Any map ≳ 1k entries | `Sync::Map` |
| Small (≤ ~1k), read-mostly | `Sync::HashTrieMap` |
| Small (≤ ~1k), mixed read/write | `Sync::XMap` |
| Large (≳ 10k) | `Sync::Map` (avoid `XMap`) |

`Sync::Map` is the safe default: broadest API, most predictable behavior,
and the best large-map throughput. `XMap` is fastest on small maps but
regresses sharply past ~10k entries. See
[benchmarks](benchmarks/benchmarks.md) for the full size sweep.

## Documentation

- [Architecture](docs/architecture.md) — backing store, API layers, and
  thread-safety model
- [Development](docs/development.md) — setup, quality gates, and the TDD
  loop
- [Testing](docs/testing.md) — running specs, MT testing, and spec
  categories
- [Coding Guidelines](docs/coding-guidelines.md) — porting rules, naming,
  and conventions
- [PR Workflow](docs/pr-workflow.md) — branch strategy, commit format, and
  checklist
- [Benchmarks](benchmarks/benchmarks.md) — harness notes and results for
  the map backends

## Development

See [docs/development.md](docs/development.md). In short:

```bash
shards install
make gates     # format-check + lint + test
make test-mt   # specs under true parallelism
```

## Contributing

1. Fork it (<https://github.com/dsisnero/sync-map/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

See [docs/pr-workflow.md](docs/pr-workflow.md) for the full workflow.

## Contributors

- [Dominic Sisneros](https://github.com/dsisnero) - creator and maintainer

## License

MIT — see [LICENSE](LICENSE).
