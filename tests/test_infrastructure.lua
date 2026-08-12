-- Smoke tests for the test harness itself. Every module suite depends on the
-- guarantees checked here, so a break in 'scripts/minimal_init.lua' or
-- 'tests/helpers.lua' surfaces as one obvious failure instead of a confusing
-- cascade across every other suite.
local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function() child.setup() end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

T['child process'] = new_set()

T['child process']['starts and evaluates Lua'] = function() eq(child.lua_get('1 + 1'), 2) end

T['child process']['has project root on runtimepath'] = function()
  -- Without this, `require('gdev.<module>')` cannot resolve inside the child
  eq(child.lua_get('vim.tbl_contains(vim.opt.rtp:get(), vim.uv.cwd())'), true)
end

T['child process']['can resolve `gdev` namespace'] = function()
  -- Absent modules must fail as "not found", never as an unreadable path or a
  -- syntax error leaking from a half-written module
  local err = child.lua_get([[select(2, pcall(require, 'gdev.does-not-exist'))]])
  expect.match(err, 'module .*not found')
end

T['child process']['loads mini.test'] = function() eq(child.lua_get('type(_G.MiniTest)'), 'table') end

T['child process']['starts without errors'] = function()
  -- Worth a case of its own because the symptom is invisible: an error during
  -- startup leaves the child unable to exit cleanly, so mini.test's one-second
  -- `jobwait` on teardown times out for every case. Tests still pass; the suite
  -- just silently costs 25x more. Emptying 'packpath' did exactly this, by
  -- hiding Neovim's own bundled netrw package.
  eq(child.lua_get('vim.v.errmsg'), '')
end

T['child process']['pins appearance for reference screenshots'] = function()
  -- Reference screenshots are committed, so anything they capture has to be
  -- version-independent (see 'scripts/minimal_init.lua')
  eq(child.lua_get('vim.g.colors_name'), 'gdev-test-scheme')
  eq(child.o.termguicolors, true)
  eq(child.o.background, 'dark')
  eq(child.o.ruler, false)
end

-- Asserted in this process, not a child: mini.test starts its children with
-- `--clean`, so they are hermetic for free. This process is not — it is where
-- mini.test and mini.doc get required, with this machine's config on
-- 'runtimepath' (`--noplugin` does not remove it). See 'scripts/minimal_init.lua'.
T['test runner'] = new_set()

T['test runner']['loads mini.nvim from `deps`'] = function()
  -- A locally installed mini.nvim shadowing `deps/` would mean local runs and
  -- CI silently test against different versions
  expect.match(debug.getinfo(MiniTest.run, 'S').source, vim.pesc('deps/mini.nvim/lua/mini/test.lua'))
end

T['test runner']['keeps user directories off `runtimepath`'] = function()
  local user_dirs = { vim.fn.stdpath('config'), vim.fn.stdpath('data') .. '/site' }
  local leaked = vim.tbl_filter(function(dir)
    return vim.iter(user_dirs):any(function(user_dir) return vim.startswith(dir, user_dir) end)
  end, vim.opt.rtp:get())

  eq(leaked, {})
end

T['helpers'] = new_set()

T['helpers']['provide `match` expectations'] = function()
  expect.match('abcd', 'bc')
  expect.no_match('abcd', 'xy')
  expect.error(function() expect.match('abcd', 'xy') end, 'string matching')
end

T['helpers']['scale timing constants in CI'] = function()
  -- Cases must never hardcode sleeps; these are the knobs they use instead
  expect.equality(helpers.get_time_const(10) >= 10, true)
  expect.equality(helpers.get_n_retry(1) >= 1, true)
end

return T
