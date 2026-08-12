local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config) return child.lua_get([[require('gdev').setup(...)]], { config }) end

-- Notifications from the umbrella itself, told apart from the ones the modules
-- it routes to produce -- `gdev.dap` warns about a missing nvim-dap in every
-- child, since 'scripts/minimal_init.lua' deliberately leaves it off the
-- 'runtimepath'.
local install_stubs = function()
  child.lua([[
    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end

    _G.own_notifications = function()
      return vim.tbl_filter(function(n) return n.msg:find('^%(gdev%) ') ~= nil end, _G.notifications)
    end
  ]])
end

-- Data =======================================================================
-- Every module with a `setup()`, in the order the umbrella runs them
local all_modules = { 'lsp', 'treesitter', 'dap', 'format', 'server', 'run', 'scenetree', 'docs' }

-- One field per module, none of them a default, so a single `setup()` call
-- proves that every sub-table reached the module it names
local per_module_config = {
  lsp = { port = 7005 },
  treesitter = { highlight = false },
  dap = { port = 7006 },
  format = { formatter = 'gdformat' },
  server = { address = '/tmp/gdev-test-init.sock' },
  run = { godot = 'godot4' },
  scenetree = { icons = 'ascii' },
  docs = { renderer = 'buffer' },
}

local per_module_expected = {
  ['GdevLsp.config.port'] = 7005,
  ['GdevTreesitter.config.highlight'] = false,
  ['GdevDap.config.port'] = 7006,
  ['GdevFormat.config.formatter'] = 'gdformat',
  ['GdevServer.config.address'] = '/tmp/gdev-test-init.sock',
  ['GdevRun.config.godot'] = 'godot4',
  ['GdevScenetree.config.icons'] = 'ascii',
  ['GdevDocs.config.renderer'] = 'buffer',
}

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      install_stubs()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  load_module()

  -- Global variable
  eq(child.lua_get('type(_G.Gdev)'), 'table')

  -- Every module it routed to exported its own
  for _, name in ipairs(all_modules) do
    local global = 'Gdev' .. name:sub(1, 1):upper() .. name:sub(2)
    eq(child.lua_get(('type(_G.%s)'):format(global)), 'table')
  end

  -- And registered what it registers
  eq(child.fn.exists(':GdevLspReconnect'), 2)
  eq(child.fn.exists(':GdevFormat'), 2)
  eq(child.fn.exists(':GdevServerStart'), 2)
  eq(child.fn.exists(':GdevRunProject'), 2)
  eq(child.fn.exists(':GdevScenetree'), 2)
  eq(child.fn.exists(':GdevDocs'), 2)
  eq(child.fn.exists('#GdevTreesitter'), 1)

  -- Nothing of its own: no config table, no commands, no autocommands. It holds
  -- no state and reads nothing at runtime.
  eq(child.lua_get('_G.Gdev.config'), vim.NIL)
  eq(child.fn.exists('#Gdev'), 0)
end

T['setup()']['returns the modules it set up'] = function() eq(load_module(), all_modules) end

T['setup()']['forwards each sub-table to its module'] = function()
  load_module(per_module_config)

  for field, value in pairs(per_module_expected) do
    eq(child.lua_get(field), value)
  end
end

T['setup()']['sets omitted modules up with their defaults'] = function()
  load_module({ run = { godot = 'godot4' } })

  eq(child.lua_get('GdevRun.config.godot'), 'godot4')

  -- Untouched keys are not "unconfigured": they get the module's own defaults
  eq(child.lua_get('GdevLsp.config.port'), 6005)
  eq(child.lua_get('GdevTreesitter.config.highlight'), true)
  eq(child.lua_get('GdevDocs.config.renderer'), 'float')
end

T['setup()']['treats `true` as defaults'] = function()
  eq(load_module({ lsp = true, docs = true }), all_modules)

  eq(child.lua_get('GdevLsp.config.port'), 6005)
  eq(child.lua_get('GdevDocs.config.renderer'), 'float')
end

T['setup()']['shares nothing between modules'] = function()
  load_module({ lsp = { host = '192.168.1.5', port = 7005 } })

  -- Hosts and ports are named per module on purpose; the router does not
  -- propagate one module's value to its neighbours
  eq(child.lua_get('GdevDap.config.host'), '127.0.0.1')
  eq(child.lua_get('GdevDap.config.port'), 6006)
end

T['setup()']['validates `config` argument'] = function()
  local expect_config_error = function(config, pattern)
    expect.error(function() load_module(config) end, pattern)
  end

  expect_config_error('a', vim.pesc('`config`') .. '.*table')
  expect_config_error(1, vim.pesc('`config`') .. '.*table')

  -- A module key holds that module's table, so anything but a table or a
  -- boolean is a mistake here rather than one the module would report
  expect_config_error({ lsp = 'a' }, vim.pesc('`lsp` should be table or boolean, not string'))
  expect_config_error({ run = 1 }, vim.pesc('`run` should be table or boolean, not number'))

  -- Built in the child: a function cannot cross the RPC boundary
  expect.error(
    function() child.lua([[require('gdev').setup({ docs = function() end })]]) end,
    vim.pesc('`docs` should be table or boolean, not function')
  )

  -- Every error carries the umbrella's own prefix
  expect_config_error({ lsp = 'a' }, vim.pesc('(gdev) '))
end

T['setup()']['rejects a key naming no module'] = function()
  -- A typo has no observable effect otherwise: the module would simply be set
  -- up with its defaults and the misspelled table ignored
  expect.error(function() load_module({ treesiter = {} }) end, vim.pesc('unknown module `treesiter`'))

  -- The message names the keys that would have worked
  local ok, err = pcall(load_module, { treesiter = {} })
  eq(ok, false)
  expect.match(err, 'treesitter')
  expect.match(err, 'csharp')

  -- Nothing was set up: validation happens before any forwarding
  eq(child.lua_get('_G.GdevLsp'), vim.NIL)
end

T['setup()']['skips a module set to `false`'] = function()
  eq(load_module({ dap = false, docs = false }), { 'lsp', 'treesitter', 'format', 'server', 'run', 'scenetree' })

  -- A module that was never set up leaves no trace, which is what makes
  -- `:checkhealth gdev` report it as not set up rather than guess at defaults
  eq(child.lua_get('_G.GdevDap'), vim.NIL)
  eq(child.lua_get('_G.GdevDocs'), vim.NIL)
  eq(child.fn.exists(':GdevDocs'), 0)

  -- The rest are unaffected
  eq(child.lua_get('type(_G.GdevRun)'), 'table')
  eq(child.fn.exists(':GdevRunProject'), 2)
end

T['setup()']['can skip every module'] = function()
  local none = {}
  for _, name in ipairs(all_modules) do
    none[name] = false
  end

  eq(load_module(none), {})
  eq(child.lua_get('type(_G.Gdev)'), 'table')
  eq(child.lua_get('_G.GdevRun'), vim.NIL)
end

T['setup()']['can be called repeatedly'] = function()
  load_module({ run = { godot = 'godot3' } })
  eq(load_module({ run = { godot = 'godot4' } }), all_modules)

  eq(child.lua_get('GdevRun.config.godot'), 'godot4')

  -- A module omitted from a later call is set up again, with its defaults --
  -- each `setup()` replaces the previous configuration rather than merging
  eq(child.lua_get('GdevLsp.config.port'), 6005)
  load_module({ lsp = { port = 7005 } })
  load_module()
  eq(child.lua_get('GdevLsp.config.port'), 6005)
end

T['setup()']['does not undo a module by skipping it later'] = function()
  load_module({ run = { godot = 'godot4' } })
  load_module({ run = false })

  -- Skipping is "do not set up", not "tear down": the module keeps what the
  -- earlier call gave it
  eq(child.lua_get('GdevRun.config.godot'), 'godot4')
  eq(child.fn.exists(':GdevRunProject'), 2)
end

T['setup()']['reserves `csharp`'] = function()
  eq(load_module({ csharp = true }), all_modules)

  local own = child.lua_get('_G.own_notifications()')
  eq(#own, 1)
  expect.match(own[1].msg, 'csharp')
  eq(own[1].level, child.lua_get('vim.log.levels.WARN'))
end

T['setup()']['is quiet about `csharp` when it is off'] = new_set({
  parametrize = { { false }, { nil } },
}, {
  test = function(value)
    load_module({ csharp = value })
    eq(child.lua_get('_G.own_notifications()'), {})
  end,
})

T['setup()']['accepts a `csharp` table without acting on it'] = function()
  load_module({ csharp = { dap = true } })

  eq(#child.lua_get('_G.own_notifications()'), 1)
  eq(child.lua_get('_G.GdevCsharp'), vim.NIL)
end

-- Integration tests ==========================================================
T['errors from a module'] = new_set()

T['errors from a module']['name the module and the field'] = function()
  expect.error(function() load_module({ run = { console = { enabled = 'a' } } }) end, vim.pesc('(gdev.run) '))
  expect.error(
    function() load_module({ run = { console = { enabled = 'a' } } }) end,
    vim.pesc('`console.enabled` should be boolean, not string')
  )
end

T['errors from a module']['leave earlier modules set up'] = function()
  -- Sub-tables cannot be validated without handing them to their module, so a
  -- bad one is reported partway through. Documented, not worked around.
  expect.error(function() load_module({ docs = { renderer = 1 } }) end, vim.pesc('(gdev.docs) '))

  eq(child.fn.exists(':GdevLspReconnect'), 2)
  eq(child.fn.exists(':GdevScenetree'), 2)

  -- The failing module is half-applied, and the commands are the honest signal:
  -- every module exports its global before validating its config, so
  -- `_G.GdevDocs` exists while holding untouched defaults
  eq(child.fn.exists(':GdevDocs'), 0)
  eq(child.lua_get('GdevDocs.config.renderer'), 'float')
end

return T
