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

T['child process']['loads mini.test from `deps`'] = function() eq(child.lua_get('type(_G.MiniTest)'), 'table') end

T['child process']['pins appearance for reference screenshots'] = function()
  -- Reference screenshots are committed, so anything they capture has to be
  -- version-independent (see 'scripts/minimal_init.lua')
  eq(child.lua_get('vim.g.colors_name'), 'gdev-test-scheme')
  eq(child.o.termguicolors, true)
  eq(child.o.background, 'dark')
  eq(child.o.ruler, false)
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
