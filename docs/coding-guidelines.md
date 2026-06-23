# Coding Guidelines

## Porting from Upstream

1. Upstream behavior is the source of truth
2. Port behavior first, Crystal idioms only where semantics unchanged
3. Preserve parameter order, edge cases, and invalid-input behavior
4. Never weaken assertions or change fixtures to fit implementation

## Conventions

- All public methods must be MT-safe
- Use `Sync::Mutex(:unchecked)` for lowest overhead
- Iteration methods that yield to caller must snapshot
  (lock → copy → release → yield)
- Methods that execute user blocks under the lock must document the reentrancy risk

## Naming

- Go sync.Map methods: `load`, `store`, `delete`, `clear`, `load_or_store`,
  `load_and_delete`, `swap`, `compare_and_swap`, `compare_and_delete`, `range`
- Crystal Hash methods: `[]`, `[]=`, `[]?`, `fetch`, `has_key?`, `has_value?`,
  `key_for`, `put_if_absent`, `shift`, `dup`, `clone`, `merge`, `merge!`,
  `select`, `reject`, `transform_keys`, `transform_values`, `dig`, `dig?`, etc.
- xsync methods: `load_and_store`, `load_or_compute`, `compute`,
  `delete_matching`, `stats`

## Types

- `K` must be `Hash`-compatible (responds to `hash` and `==`)
- `V` can be any type
- `Sync::Map::ComputeOp` enum: `Cancel = 0`, `Update = 1`, `Delete = 2`

## Testing

- Favor spec-driven development (red-green TDD)
- Write concurrent stress tests with `spawn` and `Channel`
- Run with `-Dpreview_mt -Dexecution_context` to verify MT safety
- Use `be_true`/`be_false` instead of `eq(true)`/`eq(false)`
