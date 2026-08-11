# Module patterns

This project follows the mini.nvim module architecture. The golden template (`.templates/module.lua`)
is the executable form of this document; read canonical examples in `.ref/mini.nvim/lua/mini/`
(`trailspace.lua` and `cursorword.lua` are the smallest complete ones).

## File anatomy

Every module is one file, `lua/gdev/<name>.lua`, laid out in this exact order:

```
--- header annotation block        Doc comments rendered to vimdoc by mini.doc
-- Module definition ========      local GdevName = {}; local H = {}
--   setup(), config
-- Module functionality ======     Public API only
-- Helper data ================    H.default_config, timers, caches, namespaces
-- Helper functionality =======    Everything private, grouped by `----` subsections
return GdevName
```

Two tables, strict visibility split:

- `Gdev<Name>` — the public API. Everything here is documented, validated, and stable.
- `H` — private helpers. No doc annotations required; plain comments where intent is not obvious.
  Anything in `H` can change freely between versions.

Nothing else is module-level local. State lives in `H` (e.g. `H.cache`, `H.timer`) so it is
inspectable during debugging via upvalues and consistent across modules.

## setup() lifecycle

```lua
GdevName.setup = function(config)
  _G.GdevName = GdevName          -- export global for scripting/mappings/RPC
  config = H.setup_config(config) -- merge with defaults + validate types
  H.apply_config(config)          -- store + side effects driven by config (mappings)
  H.create_autocommands(config)   -- all autocmds in one augroup named `GdevName`
  H.create_user_commands()        -- if any
  H.create_default_hl()           -- `default = true` highlight groups
end
```

`setup()` must be re-runnable: creating the augroup with `nvim_create_augroup(name, {})` clears
previous autocmds, and `H.apply_config` should undo stale side effects where relevant (see
`mini.cursorword`'s match cleanup for an example).

## Config

- Defaults live in `Gdev<Name>.config`, wrapped in the `---@eval` / `--minidoc_afterlines_end`
  markers so mini.doc renders them verbatim into help. Every field carries a comment above it —
  this comment *is* the user documentation for the field.
- `H.default_config = vim.deepcopy(GdevName.config)` snapshots defaults before users mutate the
  global table.
- `H.setup_config` merges (`vim.tbl_deep_extend('force', ...)`) then validates every field with
  `H.check_type`. Validation errors name the exact field path (`mappings.action`).
- Runtime reads go through `H.get_config(config)`, which layers three sources at call time:

  ```
  GdevName.config  <  vim.b.gdev<name>_config  <  per-call opts
  ```

  Never read `GdevName.config` directly in functionality code — that skips buffer-local overrides.

## Conventions keyed to module name

For module `gdev.runner`:

| Thing | Name |
|---|---|
| Global table | `GdevRunner` |
| Augroup | `GdevRunner` |
| User commands | `:GdevRunner...` |
| Highlight groups | `GdevRunner<What>` |
| Disable variables | `vim.g.gdevrunner_disable`, `vim.b.gdevrunner_disable` |
| Buffer-local config | `vim.b.gdevrunner_config` |
| Error/notify prefix | `(gdev.runner) ` |

## Behavioral rules

- **Disabling**: every user-facing entry point (autocmd callbacks, public functions triggered by
  events) starts with `if H.is_disabled() then return end`. Users rely on this protocol for
  filetype/buffer-specific opt-out.
- **Errors**: `H.error()` prefixes the module name and raises with level 0 (no stack noise for
  user-facing errors). Non-fatal messages go through `H.notify()`.
- **Mappings**: created via `H.map`, which no-ops on empty `lhs` — empty string is the documented
  way for users to disable a mapping. RHS is a `<Cmd>lua GdevName.fn()<CR>` string (works over RPC
  and in dot-repeat contexts), except when `expr = true` requires a function.
- **Highlight groups**: defined with `default = true` (user overrides survive re-`setup()`) and
  re-applied on `ColorScheme`. Link to semantic builtin groups so any colorscheme works.
- **Timers/debounce**: `vim.uv.new_timer()` stored in `H`, always `:stop()` before `:start()`,
  callbacks wrapped in `vim.schedule_wrap`.
- **Buffer arguments**: public functions take `buf_id` with `nil`/`0` meaning current buffer,
  normalized through `H.validate_buf_id`.
- **Robust cleanup**: wrap teardown of externally-mutable state in `pcall` (e.g. `matchdelete`
  after a user ran `clearmatches()`).

## Code style

Enforced by `.stylua.toml` (2-space indent, 120 columns, single quotes, collapsed simple
statements). Beyond formatting:

- `M.fn = function(...)` assignment form, never `function M.fn(...)` — including for locals.
- Doc annotations (`---`, `---@param`, `---@return`, `---@usage`) on all public API. Written for
  senior developers: intent, contracts, and edge cases — not restated mechanics.
- Private helpers get plain `--` comments only where the *why* is non-obvious (workarounds,
  ordering constraints, upstream issues). Cite issue/commit when the reason is external.
- Comments are sentences; annotations link Neovim help targets with `|target|`.
