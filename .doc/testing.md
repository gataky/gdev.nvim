# Testing

Tests use [mini.test](https://github.com/nvim-mini/mini.nvim/blob/main/TESTING.md). Read
`.ref/mini.nvim/TESTING.md` for the full hands-on guide; `.ref/mini.nvim/tests/test_trailspace.lua`
is a compact real-world suite. The golden test template is `.templates/test_module.lua`.

## Layout and scaffolding

```
lua/gdev/<name>.lua
tests/
  helpers.lua              -- from .templates/tests_helpers.lua (once)
  test_<name>.lua          -- from .templates/test_module.lua (per module)
  dir-<name>/              -- fixture files for <name>, if needed
  screenshots/             -- reference screenshots (committed)
scripts/
  minimal_init.lua
deps/mini.nvim             -- dev dependency, cloned by Makefile, gitignored
```

`scripts/minimal_init.lua`:

```lua
-- Add project root to 'runtimepath' to be able to use 'lua' files
vim.cmd([[let &rtp.=','.getcwd()]])

-- Set up 'mini.test' only when calling headless Neovim (like with `make test`)
if #vim.api.nvim_list_uis() == 0 then
  vim.cmd('set rtp+=deps/mini.nvim')
  require('mini.test').setup()
end
```

The real file also pins the colorscheme (via `mini.hues`), `'termguicolors'`, `'ruler'`, and
`'statusline'` inside that same headless block. Committed reference screenshots capture all of
these, and Neovim's defaults for them drift between versions — without pinning,
`child.expect_screenshot()` fails across the CI version matrix for reasons unrelated to the code
under test. Keep those lines.

`Makefile`:

```make
test: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua MiniTest.run()"

test_%: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/$@.lua')"

deps/mini.nvim:
	git clone --filter=blob:none https://github.com/nvim-mini/mini.nvim $@

gendoc: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua require('mini.doc').generate()" -c "qa!"
```

## Suite shape

Each test file builds a nested `MiniTest.new_set()` table and returns it. All testing happens in a
**child Neovim process** — never in the test runner's own instance — so state is hermetic and
crashes are survivable:

- `pre_case` hook restarts the child (`child.setup()`) and loads the module fresh; `post_once`
  stops it.
- Structure mirrors the public API: `T['setup()']`, `T['action()']`, one nested set per function,
  descriptive case names (`['works']`, `['validates arguments']`, `['respects X']`).
- Interact through `child.lua()` / `child.lua_get()` / `child.type_keys()` and the wrappers in
  `tests/helpers.lua`.

## Required coverage per module

Mirror mini.nvim's baseline — every module suite has at least:

1. `setup()` creates side effects (global table, augroup, user commands, highlight groups).
2. `setup()` creates `config` field with expected defaults.
3. `setup()` respects `config` argument.
4. `setup()` validates `config` argument — one assertion per field, matching the
   `H.check_type` error format.
5. Per public function: works, respects `opts`/config fields it reads, validates arguments,
   respects `vim.b.gdev<name>_config`, respects `vim.{g,b}.gdev<name>_disable`.
6. Integration cases for autocmd/mapping/command behavior.

## Idioms

- `parametrize` for testing the same behavior across values (modes, buftypes, `g` vs `b`).
- `child.expect_screenshot()` for anything visual (highlights, floating windows, UI). Screenshots
  are committed reference files; regenerate deliberately, never blindly.
- Timing: never hardcode sleeps — scale with `helpers.get_time_const()` and set
  `n_retry = helpers.get_n_retry(n)` so CI (slow, especially macOS/Windows) stays green.
- Validation-error tests match with `vim.pesc(name) .. '.*' .. vim.pesc(type)`.
- Prefer asserting observable effects (buffer lines, cursor, marks, screenshots) over internals.
  `H` is private; tests must not reach into it.
