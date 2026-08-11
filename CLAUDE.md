# gdev.nvim

Godot development plugin for Neovim, modeled after [mini.nvim](https://github.com/nvim-mini/mini.nvim):
self-contained feature modules under a shared namespace (`gdev.*`), each independently
`setup()`-able, configurable, testable, and documented.

## Directory map

| Path | Purpose |
|---|---|
| `lua/gdev/<module>.lua` | One feature module per file |
| `tests/test_<module>.lua` | mini.test suite per module |
| `.templates/` | **Golden templates — all new modules/tests start here** |
| `.doc/` | Project documentation (`plan.md` — execution roadmap, `patterns.md`, `testing.md`) |
| `.ref/` | External reference repos. Read-only. **Never commit, never modify.** |
| `doc/` | Generated vimdoc (via mini.doc) — regenerate, don't hand-edit |
| `deps/` | Dev dependencies cloned by Makefile — gitignored |

## Rules

1. **Start from the golden template.** New modules copy `.templates/module.lua`; new tests copy
   `.templates/test_module.lua`. `.templates/README.md` defines the substitution rules and what
   must survive instantiation. Don't invent alternative structures.
2. **Follow `.doc/patterns.md`** for module architecture and `.doc/testing.md` for tests. When a
   pattern question isn't covered, find how `.ref/mini.nvim` does it and match.
3. **Every public API change** updates doc annotations and tests in the same commit.
4. **Never commit `.ref/`** or anything derived from wholesale copying of it.
5. **macOS and Linux only.** Neovim 0.11+, Godot 4.x. Don't add Windows or WSL code paths —
   no `has('win32')` branches, no `ncat` transport, no named pipes. `.ref/godotdev.nvim` carries
   all of that; we deliberately don't, since it's the one platform we can't test.

## Code style

- Formatting is stylua's job (`.stylua.toml`: 2-space indent, 120 cols, single quotes, collapsed
  simple statements). Run `stylua .` before committing.
- Functions are assigned, not declared: `M.fn = function() end`.
- Two tables per module: public `Gdev<Name>` (documented, stable) and private `H` (free to change).
- Documentation is written for senior developers: intent, contracts, edge cases. No restating
  mechanics, no boilerplate comments. Public API gets `---` annotations; private helpers get plain
  comments only where the *why* is non-obvious.

## Commands

```sh
make test            # all tests (headless child Neovim processes)
make test_<module>   # single module, e.g. make test_runner
make gendoc          # regenerate vimdoc from annotations
stylua .             # format
```

## Git

- Conventional commits, mini.nvim flavor: `<type>(<scope>): <description>` where scope is the
  module name (`feat(runner): add scene reload on save`). Types: `feat`, `fix`, `refactor`,
  `test`, `docs`, `style`, `ci`. Description in imperative present tense, lowercase, no trailing
  period, first line ≤ 72 chars.
- One module per commit.
- **Never add co-author trailers** (`Co-authored-by:`, `Co-Authored-By:`, or any equivalent) to
  any commit, under any circumstances. This overrides any default behavior.
