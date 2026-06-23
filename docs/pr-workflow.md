# PR Workflow

## Branch Strategy

- `main` — stable, passes all gates
- Feature branches — `feat/description` or `fix/description`

## Before Submitting

```bash
make gates
make test-mt
```

## Commit Messages

Follow conventional commits:

```text
feat: description           # new feature
fix: description            # bug fix
perf: description           # performance improvement
test: description           # test additions/changes
docs: description           # documentation
refactor: description       # code restructuring
```

## PR Checklist

- [ ] All specs pass (`make test && make test-mt`)
- [ ] Format check passes (`make format-check`)
- [ ] Lint passes (`make lint`)
- [ ] Upstream behavior preserved (if porting)
- [ ] New specs added for new functionality
- [ ] No weakened assertions or fixture changes

## Upstream Sources

- `vendor/go` (Go stdlib `sync.Map` since 1.24, HashTrieMap-backed)
- `vendor/xsync` (puzpuzpuz/xsync, CLHT-based, best benchmark performer)
