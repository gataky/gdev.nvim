local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config) child.gdev_load('dap', config) end

-- nvim-dap is a real dependency under `deps/`, but 'scripts/minimal_init.lua'
-- deliberately leaves it off 'runtimepath': a child that has not opted in is a
-- runtime with no nvim-dap, which is what makes the missing-dependency path
-- testable without any faking.
local enable_dap = function() child.lua([[vim.cmd('set rtp+=deps/nvim-dap')]]) end
local load_with_dap = function(config)
  enable_dap()
  load_module(config)
end

-- Stubs installed in the child. Functions cannot cross the RPC boundary, so
-- everything is built inside the child and driven through globals.
local install_stubs = function()
  child.lua([[
    -- Notifications are the only user-visible output this module has
    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end

    -- nvim-dap-ui is faked rather than cloned: three functions are all this
    -- module touches, and a second real dependency buys no extra confidence.
    _G.dapui_calls = {}
    _G.fake_dapui = function()
      package.loaded['dapui'] = {
        setup = function() table.insert(_G.dapui_calls, 'setup') end,
        open = function() table.insert(_G.dapui_calls, 'open') end,
        close = function() table.insert(_G.dapui_calls, 'close') end,
      }
    end

    -- Stand in for a debug session reaching a listener group, the way
    -- `dap.Session` does. Returns how many listeners ran, which is how listener
    -- stacking shows up.
    _G.fire = function(when, event)
      local n = 0
      for _, listener in pairs(require('dap').listeners[when][event]) do
        n = n + 1
        listener()
      end
      return n
    end

    _G.listener_keys = function(when, event) return vim.tbl_keys(require('dap').listeners[when][event]) end
  ]])
end

-- Data =======================================================================
local default_adapter = { type = 'server', host = '127.0.0.1', port = 6006 }

local default_configurations = {
  {
    type = 'godot',
    request = 'launch',
    name = 'Launch scene',
    project = '${workspaceFolder}',
    launch_scene = true,
  },
}

local custom_configurations = {
  { type = 'godot', request = 'launch', name = 'Launch project', project = '/tmp/game', launch_scene = false },
  { type = 'godot', request = 'launch', name = 'Launch scene', project = '/tmp/game', launch_scene = true },
}

-- Output test set ============================================================
-- The module is not loaded by the hook: every case decides for itself whether
-- nvim-dap and nvim-dap-ui exist, and both have to be in place before `setup()`
-- runs to have any effect.
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
  load_with_dap()

  -- Global variable
  eq(child.lua_get('type(_G.GdevDap)'), 'table')

  -- Nothing else: this module has no commands, autocommands or mappings of its
  -- own, since debugging is driven through nvim-dap's
  eq(child.fn.exists('#GdevDap'), 0)
end

T['setup()']['creates `config` field'] = function()
  load_with_dap()
  eq(child.lua_get('type(_G.GdevDap.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevDap.config.host'), '127.0.0.1')
  eq(child.lua_get('GdevDap.config.port'), 6006)
  eq(child.lua_get('GdevDap.config.dapui'), true)
  eq(child.lua_get('GdevDap.config.configurations'), vim.NIL)
end

T['setup()']['respects `config` argument'] = function()
  load_with_dap({ host = '0.0.0.0', port = 7006, dapui = false, configurations = custom_configurations })

  eq(child.lua_get('GdevDap.config.host'), '0.0.0.0')
  eq(child.lua_get('GdevDap.config.port'), 7006)
  eq(child.lua_get('GdevDap.config.dapui'), false)
  eq(child.lua_get('GdevDap.config.configurations'), custom_configurations)
end

T['setup()']['validates `config` argument'] = function()
  local expect_config_error = function(config, name, target_type)
    expect.error(function() load_module(config) end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ host = 1 }, 'host', 'string')
  expect_config_error({ port = 'a' }, 'port', 'number')
  expect_config_error({ dapui = 'a' }, 'dapui', 'boolean')
  expect_config_error({ configurations = 'a' }, 'configurations', 'table')
  expect_config_error({ configurations = { 'a' } }, 'configurations[1]', 'table')
  expect_config_error({ configurations = { {}, 2 } }, 'configurations[2]', 'table')
end

T['setup()']['registers the Godot adapter'] = function()
  load_with_dap()

  eq(child.lua_get('require("dap").adapters.godot'), default_adapter)
  eq(child.lua_get('require("dap").configurations.gdscript'), default_configurations)
end

T['setup()']['respects `config.host` and `config.port`'] = function()
  load_with_dap({ host = '192.168.1.5', port = 7006 })

  eq(child.lua_get('require("dap").adapters.godot'), { type = 'server', host = '192.168.1.5', port = 7006 })
end

T['setup()']['respects `config.configurations`'] = function()
  load_with_dap({ configurations = custom_configurations })

  -- Replaces the default rather than adding to it
  eq(child.lua_get('require("dap").configurations.gdscript'), custom_configurations)
end

T['setup()']['does not alias `config.configurations`'] = function()
  load_with_dap({ configurations = custom_configurations })
  child.lua('GdevDap.config.configurations[1].project = "/tmp/elsewhere"')

  -- Editing the config table after the fact must not reach nvim-dap
  eq(child.lua_get('require("dap").configurations.gdscript[1].project'), '/tmp/game')
end

T['setup()']['can be called repeatedly'] = function()
  load_with_dap()
  load_module({ port = 7006, configurations = custom_configurations })

  eq(child.lua_get('require("dap").adapters.godot'), { type = 'server', host = '127.0.0.1', port = 7006 })
  eq(child.lua_get('require("dap").configurations.gdscript'), custom_configurations)
end

T['setup()']['warns and returns when nvim-dap is missing'] = function()
  -- No `enable_dap()`: this runtime genuinely has no nvim-dap
  eq(child.lua_get('(pcall(require, "dap"))'), false)

  load_module()

  local notifications = child.lua_get('_G.notifications')
  eq(#notifications, 1)
  expect.match(notifications[1].msg, '^%(gdev%.dap%) ')
  expect.match(notifications[1].msg, 'nvim%-dap')
  eq(notifications[1].level, child.lua_get('vim.log.levels.WARN'))

  -- Config is still applied, so `:checkhealth` and a later retry can read it
  eq(child.lua_get('GdevDap.config.port'), 6006)
end

T['setup()']['is quiet when nvim-dap is present'] = function()
  load_with_dap()
  eq(child.lua_get('_G.notifications'), {})
end

-- Integration tests ==========================================================
T['nvim-dap-ui'] = new_set()

T['nvim-dap-ui']['opens on session start'] = function()
  child.lua('_G.fake_dapui()')
  load_with_dap()

  eq(child.lua_get('_G.fire("after", "event_initialized")'), 1)
  eq(child.lua_get('_G.dapui_calls'), { 'open' })
end

T['nvim-dap-ui']['closes on session end'] = new_set({
  parametrize = { { 'event_terminated' }, { 'event_exited' } },
}, {
  test = function(event)
    child.lua('_G.fake_dapui()')
    load_with_dap()

    eq(child.lua_get('_G.fire("before", ...)', { event }), 1)
    eq(child.lua_get('_G.dapui_calls'), { 'close' })
  end,
})

T['nvim-dap-ui']['does not stack listeners across repeated `setup()`'] = function()
  child.lua('_G.fake_dapui()')
  load_with_dap()
  load_module()
  load_module()

  -- Listener tables are keyed, so the namespaced key is what makes this hold
  eq(child.lua_get('_G.listener_keys("after", "event_initialized")'), { 'gdev.dap' })
  eq(child.lua_get('_G.fire("after", "event_initialized")'), 1)
  eq(child.lua_get('_G.dapui_calls'), { 'open' })
end

T['nvim-dap-ui']['is not wired when `config.dapui` is `false`'] = function()
  child.lua('_G.fake_dapui()')
  load_with_dap({ dapui = false })

  eq(child.lua_get('_G.listener_keys("after", "event_initialized")'), {})
  eq(child.lua_get('_G.fire("after", "event_initialized")'), 0)
  eq(child.lua_get('_G.dapui_calls'), {})
end

T['nvim-dap-ui']['is unwired by a later `setup()` turning it off'] = function()
  child.lua('_G.fake_dapui()')
  load_with_dap()
  load_module({ dapui = false })

  -- Stale side effects of the previous call have to go with it
  eq(child.lua_get('_G.listener_keys("before", "event_terminated")'), {})
  eq(child.lua_get('_G.fire("after", "event_initialized")'), 0)
  eq(child.lua_get('_G.dapui_calls'), {})
end

T['nvim-dap-ui']['stays quiet when the plugin is absent'] = function()
  load_with_dap()

  eq(child.lua_get('_G.listener_keys("after", "event_initialized")'), {})

  -- Optional means optional: no warning for not having it
  eq(child.lua_get('_G.notifications'), {})
end

T['nvim-dap-ui']['does not set the plugin up'] = function()
  child.lua('_G.fake_dapui()')
  load_with_dap()
  child.lua('_G.fire("after", "event_initialized")')

  -- Calling `dapui.setup()` from here would replace the user's own config
  eq(child.lua_get('_G.dapui_calls'), { 'open' })
end

T['nvim-dap-ui']['respects `vim.{g,b}.gdevdap_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.fake_dapui()')
    load_with_dap()
    child[var_type].gdevdap_disable = true

    child.lua('_G.fire("after", "event_initialized")')
    eq(child.lua_get('_G.dapui_calls'), {})
  end,
})

T['nvim-dap-ui']['closes while disabled'] = function()
  child.lua('_G.fake_dapui()')
  load_with_dap()
  child.lua('_G.fire("after", "event_initialized")')

  -- Teardown is not gated on the disable protocol: a window this module opened
  -- must not be left behind by a session that has ended
  child.g.gdevdap_disable = true
  child.lua('_G.fire("before", "event_terminated")')

  eq(child.lua_get('_G.dapui_calls'), { 'open', 'close' })
end

return T
