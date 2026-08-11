-- Tests for the helpers every module shares. Behaviour verified here is not
-- re-tested per module: the module suites assert what they do with these, not
-- that the helpers themselves work.
local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- A stand-in module, so the suite does not depend on any real one
local load_util = function()
  child.lua([[
    _G.Mod = { config = { flag = true, delay = 100, nested = { x = 1, y = 2 } } }
    _G.H = require('gdev.util').new('demo', _G.Mod)
  ]])
end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_util()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['error()'] = new_set()

T['error()']['prefixes with the module name'] = function()
  expect.error(function() child.lua('H.error("something broke")') end, vim.pesc('(gdev.demo) something broke'))
end

T['error()']['raises without a stack trace'] = function()
  -- Level 0: these are read by users, not by whoever wrote the call site
  local message = child.lua_get('select(2, pcall(H.error, "plain"))')
  eq(message, '(gdev.demo) plain')
end

T['notify()'] = new_set()

T['notify()']['prefixes and defaults to INFO'] = function()
  child.lua([[
    _G.notified = {}
    vim.notify = function(msg, level) table.insert(_G.notified, { msg = msg, level = level }) end
    H.notify('all good')
    H.notify('not good', 'WARN')
  ]])

  eq(child.lua_get('_G.notified[1]'), { msg = '(gdev.demo) all good', level = child.lua_get('vim.log.levels.INFO') })
  eq(child.lua_get('_G.notified[2].level'), child.lua_get('vim.log.levels.WARN'))
end

T['check_type()'] = new_set()

T['check_type()']['accepts matching types'] = function()
  child.lua('H.check_type("flag", true, "boolean")')
  child.lua('H.check_type("delay", 1, "number")')
  child.lua('H.check_type("hook", function() end, "callable")')
end

T['check_type()']['names the field and the expected type'] = function()
  expect.error(
    function() child.lua('H.check_type("mappings.action", 1, "string")') end,
    vim.pesc('`mappings.action` should be string, not number')
  )
end

T['check_type()']['respects `allow_nil`'] = function()
  child.lua('H.check_type("hook", nil, "callable", true)')
  expect.error(function() child.lua('H.check_type("hook", nil, "callable")') end, 'hook.*callable')
end

T['validate_buf_id()'] = new_set()

T['validate_buf_id()']['resolves `nil` and 0 to the current buffer'] = function()
  local current = child.api.nvim_get_current_buf()
  eq(child.lua_get('H.validate_buf_id(nil)'), current)
  eq(child.lua_get('H.validate_buf_id(0)'), current)
end

T['validate_buf_id()']['passes a valid buffer through'] = function()
  child.lua('_G.buf = vim.api.nvim_create_buf(true, false)')
  eq(child.lua_get('H.validate_buf_id(_G.buf)'), child.lua_get('_G.buf'))
end

T['validate_buf_id()']['rejects anything else'] = new_set({
  parametrize = { { '"a"' }, { '{}' }, { '999999' } },
}, {
  test = function(argument)
    expect.error(function() child.lua('H.validate_buf_id(' .. argument .. ')') end, '`buf_id`.*valid buffer id')
  end,
})

T['is_disabled()'] = new_set()

T['is_disabled()']['reads variables derived from the module name'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    eq(child.lua_get('H.is_disabled()'), false)

    child[var_type].gdevdemo_disable = true
    eq(child.lua_get('H.is_disabled()'), true)
  end,
})

T['is_disabled()']['ignores values other than `true`'] = function()
  child.g.gdevdemo_disable = 1
  eq(child.lua_get('H.is_disabled()'), false)
end

T['get_config()'] = new_set()

T['get_config()']['returns module config by default'] = function()
  eq(child.lua_get('H.get_config().delay'), 100)
  eq(child.lua_get('H.get_config().flag'), true)
end

T['get_config()']['layers buffer config over module config'] = function()
  child.b.gdevdemo_config = { delay = 200 }

  eq(child.lua_get('H.get_config().delay'), 200)
  -- Untouched fields still come from the module config
  eq(child.lua_get('H.get_config().flag'), true)
end

T['get_config()']['layers per-call options over everything'] = function()
  child.b.gdevdemo_config = { delay = 200 }
  eq(child.lua_get('H.get_config({ delay = 300 }).delay'), 300)
end

T['get_config()']['merges nested tables rather than replacing them'] = function()
  child.b.gdevdemo_config = { nested = { x = 10 } }

  eq(child.lua_get('H.get_config().nested'), { x = 10, y = 2 })
end

T['get_config()']['reads the buffer variable off the given buffer'] = function()
  -- Autocommand and LSP callbacks run for buffers that are not current
  child.lua([[
    _G.other = vim.api.nvim_create_buf(true, false)
    vim.b[_G.other].gdevdemo_config = { delay = 500 }
  ]])

  eq(child.lua_get('H.get_config(nil, _G.other).delay'), 500)
  eq(child.lua_get('H.get_config().delay'), 100)
end

T['get_config()']['follows a reassigned module config'] = function()
  -- `setup()` replaces the table wholesale, so this cannot be captured up front
  child.lua('_G.Mod.config = { flag = false, delay = 1 }')
  eq(child.lua_get('H.get_config().delay'), 1)
end

T['map()'] = new_set()

T['map()']['creates a mapping'] = function()
  child.lua([[H.map('n', '<Leader>zz', '<Cmd>echo 1<CR>', { desc = 'demo' })]])
  expect.match(child.cmd_capture('nmap <Leader>zz'), 'echo 1')
end

T['map()']['treats an empty `lhs` as "off"'] = function()
  -- The documented way for users to disable a mapping
  local before = child.lua_get('#vim.api.nvim_get_keymap("n")')

  child.lua([[H.map('n', '', '<Cmd>echo 1<CR>')]])

  eq(child.lua_get('#vim.api.nvim_get_keymap("n")'), before)
end

return T
