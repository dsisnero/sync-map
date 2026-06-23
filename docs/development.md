# Development

## Setup

```bash
git clone https://github.com/dsisnero/sync-map
cd sync-map
shards install
```

Initialize submodules (upstream Go sources for reference):

```bash
git submodule update --init --depth 1
```

## Quality Gates

Every change must pass all gates before committing:

```bash
make gates
```

Individual gate commands:

```bash
make format-check   # crystal tool format --check src spec
make lint           # ameba src spec
make test           # crystal spec
make test-mt        # crystal spec -Dpreview_mt -Dexecution_context
```

## Development Loop (TDD)

1. Write a failing spec (red)
2. Implement minimal fix (green)
3. Run `make gates`
4. Commit with descriptive message

## Requirements

- Crystal >= 1.20.2
- ameba (install: `shards install` or `brew install crystal-ameba`)
