local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- `plugin/gdev-dev-reload.lua` reads its gate while it is being sourced, which
-- happens after the `-u` file and before any `-c`. `--cmd` is the only startup
-- hook early enough to set it.
local start = function(enabled)
  local args = { '-u', 'scripts/minimal_init.lua' }
  if enabled then args = vim.list_extend({ '--cmd', 'let g:gdev_dev_reload = 1' }, args) end
  child.restart(args)
  child.bo.readonly = false

  child.lua([[
    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end

    -- No file is written: the reload keys off the name it is handed, so driving
    -- the event directly keeps the suite from rewriting the sources under test
    _G.write = function(path) vim.api.nvim_exec_autocmds('BufWritePost', { pattern = path }) end
    _G.module_path = function(name) return vim.fn.getcwd() .. '/lua/gdev/' .. name .. '.lua' end
  ]])
end

-- Output test set ============================================================
local T = new_set({
  hooks = { post_once = child.stop },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['gate'] = new_set()

T['gate']['is closed without `vim.g.gdev_dev_reload`'] = function()
  start(false)

  -- The script is sourced in every Neovim that has this plugin on
  -- 'runtimepath', so an unset gate has to leave no autocommand behind
  eq(child.fn.exists('#GdevDevReload'), 0)
end

T['gate']['opens with `vim.g.gdev_dev_reload`'] = function()
  start(true)
  eq(child.fn.exists('#GdevDevReload'), 1)
end

T['reload'] = new_set({ hooks = { pre_case = function() start(true) end } })

T['reload']['replaces a module that was set up'] = function()
  child.lua([[require('gdev.run').setup({ godot = 'godot4' })]])
  child.lua('_G.before = _G.GdevRun')

  child.lua('_G.write(_G.module_path("run"))')

  -- A fresh table, from a freshly loaded file
  eq(child.lua_get('_G.before ~= _G.GdevRun'), true)
  eq(child.lua_get('type(_G.GdevRun)'), 'table')

  -- Running config survives: it is read off the old table before the reload,
  -- and a resolved config merged over the defaults again is the same config
  eq(child.lua_get('GdevRun.config.godot'), 'godot4')
  eq(child.fn.exists(':GdevRunProject'), 2)
end

T['reload']['leaves a module that was not set up alone'] = function()
  child.lua([[require('gdev.run').setup()]])
  child.lua('_G.write(_G.module_path("run"))')

  eq(child.lua_get('_G.GdevDocs'), vim.NIL)
  eq(child.fn.exists(':GdevDocs'), 0)
end

T['reload']['reloads internal modules too'] = function()
  child.lua([[require('gdev.run').setup()]])
  child.lua([=[_G.before = package.loaded['gdev.project']]=])

  child.lua('_G.write(_G.module_path("project"))')

  -- `gdev.run` requires it, so reloading the pair is what proves the whole
  -- namespace was dropped rather than only the modules with a `setup()`
  eq(child.lua_get([[type(package.loaded['gdev.project'])]]), 'table')
  eq(child.lua_get([=[_G.before ~= package.loaded['gdev.project']]=]), true)
end

T['reload']['refreshes the umbrella global'] = function()
  child.lua([[require('gdev').setup({ dap = false, run = { godot = 'godot4' } })]])
  child.lua('_G.before = _G.Gdev')

  child.lua('_G.write(_G.module_path("init"))')

  eq(child.lua_get('_G.before ~= _G.Gdev'), true)
  eq(child.lua_get('type(_G.Gdev.setup)'), 'function')

  -- The module skipped through the umbrella stays skipped
  eq(child.lua_get('_G.GdevDap'), vim.NIL)
  eq(child.lua_get('GdevRun.config.godot'), 'godot4')
end

T['reload']['reports what it reloaded'] = function()
  child.lua([[require('gdev.run').setup()]])
  child.lua([[require('gdev.docs').setup()]])
  child.lua('_G.notifications = {}')

  child.lua('_G.write(_G.module_path("run"))')

  local notifications = child.lua_get('_G.notifications')
  eq(#notifications, 1)
  expect.match(notifications[1].msg, '^%(gdev%) reloaded ')
  expect.match(notifications[1].msg, 'run')
  expect.match(notifications[1].msg, 'docs')
  expect.match(notifications[1].msg, 'run%.lua$')
  eq(notifications[1].level, child.lua_get('vim.log.levels.INFO'))
end

T['reload']['is quiet when nothing was set up'] = function()
  child.lua('_G.write(_G.module_path("run"))')
  eq(child.lua_get('_G.notifications'), {})
end

-- The second case is inside this repository but outside `lua/gdev/`: editing
-- the suite must not reload the plugin
T['reload']['ignores a Lua file outside the plugin'] = new_set({
  parametrize = { { '/tmp/gdev-not-mine.lua' }, { 'tests/test_init.lua' } },
}, {
  test = function(path)
    child.lua([[require('gdev.run').setup()]])
    child.lua('_G.before = _G.GdevRun')

    child.lua('_G.write(vim.fn.fnamemodify(..., ":p"))', { path })

    eq(child.lua_get('_G.before == _G.GdevRun'), true)
    eq(child.lua_get('_G.notifications'), {})
  end,
})

T['reload']['survives a module that fails to load'] = function()
  child.lua([[require('gdev.run').setup()]])
  child.lua([[require('gdev.docs').setup()]])

  -- Stand in for a half-written file: the module loads and then raises
  child.lua([[
    _G.notifications = {}
    package.preload['gdev.docs'] = function() return { setup = function() error('unexpected symbol', 0) end } end
  ]])

  child.lua('_G.write(_G.module_path("docs"))')

  local notifications = child.lua_get('_G.notifications')
  eq(#notifications, 2)
  expect.match(notifications[1].msg, 'reload after docs%.lua failed')
  expect.match(notifications[1].msg, 'unexpected symbol')
  eq(notifications[1].level, child.lua_get('vim.log.levels.ERROR'))

  -- The rest still reloaded, which is the point of reporting rather than raising
  expect.match(notifications[2].msg, '^%(gdev%) reloaded run')
end

return T
