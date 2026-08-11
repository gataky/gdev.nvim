local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config) child.gdev_load('template', config) end
local unload_module = function() child.gdev_unload('template') end
local set_lines = function(...) return child.set_lines(...) end
local get_lines = function(...) return child.get_lines(...) end
local set_cursor = function(...) return child.set_cursor(...) end
local get_cursor = function(...) return child.get_cursor(...) end
local type_keys = function(...) return child.type_keys(...) end

-- Time constants scaled for CI (see `helpers.get_time_const`)
local default_delay = helpers.get_time_const(100)
local small_time = helpers.get_time_const(10)

-- Data =======================================================================
local example_lines = { 'aaa', 'bbb', 'ccc' }

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevTemplate)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#GdevTemplate'), 1)

  -- User command
  eq(child.fn.exists(':GdevTemplate'), 2)

  -- Highlight groups
  child.cmd('hi clear')
  load_module()
  expect.match(child.cmd_capture('hi GdevTemplateTitle'), 'links to Title')
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevTemplate.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevTemplate.config.delay'), 100)
  eq(child.lua_get('GdevTemplate.config.only_in_normal_buffers'), true)
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({ delay = 200 })
  eq(child.lua_get('GdevTemplate.config.delay'), 200)
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function() load_module(config) end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ mappings = 'a' }, 'mappings', 'table')
  expect_config_error({ mappings = { action = 1 } }, 'mappings.action', 'string')
  expect_config_error({ delay = 'a' }, 'delay', 'number')
  expect_config_error({ only_in_normal_buffers = 'a' }, 'only_in_normal_buffers', 'boolean')
  expect_config_error({ hooks = { post_action = 'a' } }, 'hooks.post_action', 'callable')
end

T['action()'] = new_set()

T['action()']['works'] = function()
  set_lines(example_lines)
  eq(child.lua_get('GdevTemplate.action()'), true)

  -- Reaction is debounced: validate nothing happened before `delay` passed,
  -- then validate observable effect (lines, extmarks, cursor, messages, ...)
  helpers.sleep(default_delay - small_time, child)
  helpers.sleep(2 * small_time, child)
end

T['action()']['respects `opts` argument'] = function()
  eq(child.lua_get('GdevTemplate.action(0, { only_in_normal_buffers = false })'), true)
end

T['action()']['validates arguments'] = function()
  expect.error(function() child.lua('GdevTemplate.action("a")') end, '`buf_id`.*valid buffer id')
end

T['action()']['respects `config.only_in_normal_buffers`'] = new_set({
  parametrize = { { '' }, { 'nofile' }, { 'help' } },
}, {
  test = function(buftype)
    child.bo.buftype = buftype
    eq(child.lua_get('GdevTemplate.action()'), buftype == '')
  end,
})

T['action()']['respects `vim.b.gdevtemplate_config`'] = function()
  child.bo.buftype = 'nofile'
  child.b.gdevtemplate_config = { only_in_normal_buffers = false }
  eq(child.lua_get('GdevTemplate.action()'), true)
end

T['action()']['respects `vim.{g,b}.gdevtemplate_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].gdevtemplate_disable = true
    eq(child.lua_get('GdevTemplate.action()'), false)
  end,
})

-- Integration tests ==========================================================
T[':GdevTemplate'] = new_set()

T[':GdevTemplate']['works'] = function()
  set_lines(example_lines)
  child.cmd('GdevTemplate')
  -- Validate observable effect, prefer `child.expect_screenshot()` for
  -- anything visual
end

return T
