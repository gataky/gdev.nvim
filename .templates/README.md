# Golden templates

These files are the canonical starting point for all new code in this project. They encode the
patterns of [mini.nvim](https://github.com/nvim-mini/mini.nvim) (reference clone in `.ref/mini.nvim`,
read-only). Do not deviate from their structure without a documented reason in `.doc/`.

| Template | Instantiates as | Purpose |
|---|---|---|
| `module.lua` | `lua/gdev/<name>.lua` | One self-contained feature module |
| `test_module.lua` | `tests/test_<name>.lua` | mini.test suite for one module |
| `tests_helpers.lua` | `tests/helpers.lua` | Shared test infrastructure (copied once, not per module) |

## Instantiating a module

Copy `module.lua` and `test_module.lua`, then substitute names consistently. For a module named
`runner`:

| Placeholder | Replacement | Used for |
|---|---|---|
| `gdev.template` | `gdev.runner` | `require()` path, error/notify prefixes, doc tag |
| `GdevTemplate` | `GdevRunner` | Global table, augroup, user command, highlight group prefix |
| `gdevtemplate` | `gdevrunner` | `vim.g`/`vim.b` variables (`_disable`, `_config`) |

Then:

1. Rewrite the header annotation block: description, features, actual highlight groups.
2. Replace the example config (`mappings`/`delay`/`only_in_normal_buffers`/`hooks`) with the
   module's real options, keeping the comment-above-each-field style. Update `H.setup_config`
   validation to match, field for field.
3. Delete example functionality (`action`, timer, user command, ...) that the module does not
   need. Keep the section skeleton and `setup()` shape intact.
4. Mirror every change in the test file: every config field gets a validation test and a
   "respects" test; every public function gets a `T['fn()']` set.

## What must survive instantiation

- The two-table shape: public `Gdev<Name>` + private `H`, returned table last line.
- `H` comes from `require('gdev.util').new('<name>', Gdev<Name>)`. That supplies `error`,
  `notify`, `check_type`, `validate_buf_id`, `is_disabled`, `get_config` and `map`, already bound
  to the module's name and config. Add module helpers to the same table; don't redefine those.
- `setup()` step order: export global → `H.setup_config` → `H.apply_config` → behavior → highlighting.
- Section dividers (`====`/`----`) and their ordering.
- Config precedence: defaults < `setup()` config < `vim.b.gdev<name>_config` < per-call `opts`,
  always resolved through `H.get_config()` at call time — never read `Gdev<Name>.config` directly.
  Pass `buf_id` as the second argument from any callback that may run for a non-current buffer.
- `H.check_type` validation of every config field in `H.setup_config`.
- The disabling protocol (`vim.g`/`vim.b` `..._disable`) checked at every user-facing entry point.
- Doc annotations (`---`) on all public functions; `---@eval` block around config defaults.
