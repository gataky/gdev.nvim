local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config)
  child.gdev_load('lsp', config)
end
local unload_module = function()
  child.gdev_unload('lsp')
end

-- Stubs installed in the child. Godot's server is never running during tests,
-- so anything that needs a client fakes one; `vim.lsp` is stubbed rather than
-- the module's own internals.
local install_stubs = function()
  child.lua([[
    -- Client whose advertised methods are dictated by the test
    _G.make_client = function(opts)
      opts = opts or {}
      return {
        name = 'gdscript',
        server_capabilities = { typeDefinitionProvider = true, inlayHintProvider = opts.inlay_hint == true },
        supports_method = function(_, method)
          if method == 'textDocument/inlayHint' then return opts.inlay_hint == true end
          return false
        end,
      }
    end

    _G.attach_clients = function(clients) vim.lsp.get_clients = function() return clients end end

    -- Record inlay hint changes and answer `is_enabled` from the same state
    _G.hint_calls = {}
    _G.stub_inlay_hints = function(initial)
      local state = initial == true
      vim.lsp.inlay_hint.enable = function(enabled, filter)
        state = enabled
        table.insert(_G.hint_calls, { enabled = enabled, bufnr = filter and filter.bufnr })
      end
      vim.lsp.inlay_hint.is_enabled = function() return state end
    end

    -- Stand in for the default `window/showMessage` handler
    _G.forwarded = {}
    _G.stub_show_message_handler = function()
      vim.lsp.handlers['window/showMessage'] = function(_, result)
        table.insert(_G.forwarded, type(result) == 'table' and result.message or '<no result>')
      end
    end

    _G.show_message = function(message)
      return vim.lsp.config.gdscript.handlers['window/showMessage'](nil, { type = 2, message = message }, {})
    end

    -- Buffer of a given filetype, without touching the file system
    _G.new_buf = function(filetype)
      local buf_id = vim.api.nvim_create_buf(true, false)
      vim.bo[buf_id].filetype = filetype
      return buf_id
    end
  ]])
end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
      install_stubs()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevLsp)'), 'table')

  -- User commands
  eq(child.fn.exists(':GdevLspReconnect'), 2)
  eq(child.fn.exists(':GdevLspToggleHints'), 2)
end

T['setup()']['registers the Godot language server'] = function()
  eq(child.lua_get('vim.lsp.is_enabled("gdscript")'), true)

  -- Fetched field by field: the resolved config holds functions, which cannot
  -- cross the RPC boundary to this process
  eq(
    child.lua_get('vim.lsp.config.gdscript.filetypes'),
    { 'gd', 'gdscript', 'gdscript3', 'gdshader' }
  )
  eq(child.lua_get('vim.lsp.config.gdscript.root_markers'), { 'project.godot', '.git' })

  -- The function that owns the TCP socket, built by `vim.lsp.rpc.connect()`
  eq(child.lua_get('type(vim.lsp.config.gdscript.cmd)'), 'function')

  eq(child.lua_get('type(vim.lsp.config.gdscript.on_attach)'), 'function')
  eq(child.lua_get([[type(vim.lsp.config.gdscript.handlers['window/showMessage'])]]), 'function')
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevLsp.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevLsp.config.host'), '127.0.0.1')
  eq(child.lua_get('GdevLsp.config.port'), 6005)
  eq(child.lua_get('GdevLsp.config.inlay_hints'), false)
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({ host = '0.0.0.0', port = 7000, inlay_hints = true })

  eq(child.lua_get('GdevLsp.config.host'), '0.0.0.0')
  eq(child.lua_get('GdevLsp.config.port'), 7000)
  eq(child.lua_get('GdevLsp.config.inlay_hints'), true)
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function()
      load_module(config)
    end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ host = 1 }, 'host', 'string')
  expect_config_error({ port = 'a' }, 'port', 'number')
  expect_config_error({ inlay_hints = 'a' }, 'inlay_hints', 'boolean')
end

T['setup()']['can be called repeatedly'] = function()
  load_module({ port = 7000 })

  eq(child.lua_get('GdevLsp.config.port'), 7000)
  eq(child.fn.exists(':GdevLspReconnect'), 2)
  eq(child.lua_get('vim.lsp.is_enabled("gdscript")'), true)
end

T['reconnect()'] = new_set()

T['reconnect()']['works'] = function()
  child.lua([[
    _G.gdscript_buf = _G.new_buf('gdscript')
    _G.gdshader_buf = _G.new_buf('gdshader')
    _G.gdresource_buf = _G.new_buf('gdresource')
    _G.lua_buf = _G.new_buf('lua')
  ]])

  local reconnected = child.lua_get('GdevLsp.reconnect()')
  local expected = child.lua_get('{ _G.gdscript_buf, _G.gdshader_buf, _G.gdresource_buf }')

  -- Only Godot buffers, and `gdresource` among them
  eq(vim.deepcopy(reconnected), expected)
  eq(vim.tbl_contains(reconnected, child.lua_get('_G.lua_buf')), false)
end

T['reconnect()']['ignores buffers that are not loaded'] = function()
  local unloaded =
    child.lua_get('vim.fn.bufadd(vim.fn.fnamemodify("tests/dir-lsp/script.gd", ":p"))')
  eq(child.lua_get('vim.api.nvim_buf_is_loaded(...)', { unloaded }), false)

  eq(vim.tbl_contains(child.lua_get('GdevLsp.reconnect()'), unloaded), false)

  -- Once loaded it is detected as `gdscript` and reported
  child.lua('vim.fn.bufload(...)', { unloaded })
  eq(child.lua_get('vim.bo[...].filetype', { unloaded }), 'gdscript')
  eq(vim.tbl_contains(child.lua_get('GdevLsp.reconnect()'), unloaded), true)
end

T['reconnect()']['leaves buffer contents alone'] = function()
  child.cmd('edit tests/dir-lsp/script.gd')
  child.set_lines({ 'extends Node', 'var unsaved = true' })
  eq(child.bo.modified, true)

  child.lua('GdevLsp.reconnect()')

  -- Unsaved work has to survive; that is the whole point of not reloading
  eq(child.get_lines(), { 'extends Node', 'var unsaved = true' })
  eq(child.bo.modified, true)
end

T['reconnect()']['respects `vim.{g,b}.gdevlsp_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.new_buf("gdscript")')
    child[var_type].gdevlsp_disable = true
    eq(child.lua_get('GdevLsp.reconnect()'), {})
  end,
})

T['toggle_inlay_hints()'] = new_set()

T['toggle_inlay_hints()']['works'] = function()
  child.lua([[
    _G.stub_inlay_hints(false)
    _G.attach_clients({ _G.make_client({ inlay_hint = true }) })
  ]])

  eq(child.lua_get('GdevLsp.toggle_inlay_hints()'), true)
  eq(child.lua_get('GdevLsp.toggle_inlay_hints()'), false)

  local calls = child.lua_get('_G.hint_calls')
  eq(#calls, 2)
  eq(calls[1].enabled, true)
  eq(calls[2].enabled, false)
  eq(calls[1].bufnr, child.api.nvim_get_current_buf())
end

T['toggle_inlay_hints()']['works on a non-current buffer'] = function()
  child.lua([[
    _G.stub_inlay_hints(false)
    _G.attach_clients({ _G.make_client({ inlay_hint = true }) })
    _G.other_buf = _G.new_buf('gdscript')
  ]])

  eq(child.lua_get('GdevLsp.toggle_inlay_hints(_G.other_buf)'), true)
  eq(child.lua_get('_G.hint_calls[1].bufnr'), child.lua_get('_G.other_buf'))
end

T['toggle_inlay_hints()']['refuses when no attached server supports hints'] = new_set({
  parametrize = { { 'none' }, { 'unsupported' } },
}, {
  test = function(case)
    child.lua(
      [[
      _G.stub_inlay_hints(false)
      _G.attach_clients(... == 'none' and {} or { _G.make_client({ inlay_hint = false }) })
    ]],
      { case }
    )

    eq(child.lua_get('GdevLsp.toggle_inlay_hints()'), vim.NIL)

    -- Nothing toggled, and the user is told why
    eq(child.lua_get('_G.hint_calls'), {})
  end,
})

T['toggle_inlay_hints()']['validates arguments'] = function()
  expect.error(function()
    child.lua('GdevLsp.toggle_inlay_hints("a")')
  end, '`buf_id`.*valid buffer id')
end

T['toggle_inlay_hints()']['respects `vim.{g,b}.gdevlsp_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua([[
      _G.stub_inlay_hints(false)
      _G.attach_clients({ _G.make_client({ inlay_hint = true }) })
    ]])
    child[var_type].gdevlsp_disable = true

    eq(child.lua_get('GdevLsp.toggle_inlay_hints()'), vim.NIL)
    eq(child.lua_get('_G.hint_calls'), {})
  end,
})

-- Integration tests ==========================================================
T['on_attach'] = new_set({
  hooks = {
    pre_case = function()
      child.lua('_G.stub_inlay_hints(false)')
    end,
  },
})

local attach = function(client_opts, buf_lua)
  child.lua(
    ([[
      _G.client = _G.make_client(...)
      vim.lsp.config.gdscript.on_attach(_G.client, %s)
    ]]):format(buf_lua or '0'),
    { client_opts or {} }
  )
end

T['on_attach']['stops `typeDefinition` requests reaching Godot'] = function()
  attach()
  -- Godot advertises the capability and then errors on the request
  eq(child.lua_get('_G.client.server_capabilities.typeDefinitionProvider'), vim.NIL)
end

T['on_attach']['does not enable hints by default'] = function()
  attach({ inlay_hint = true })
  eq(child.lua_get('_G.hint_calls'), {})
end

T['on_attach']['enables hints when configured and supported'] = function()
  unload_module()
  load_module({ inlay_hints = true })
  install_stubs()
  child.lua('_G.stub_inlay_hints(false)')

  child.lua('_G.buf = _G.new_buf("gdscript")')
  attach({ inlay_hint = true }, '_G.buf')

  local calls = child.lua_get('_G.hint_calls')
  eq(#calls, 1)
  eq(calls[1].enabled, true)
  eq(calls[1].bufnr, child.lua_get('_G.buf'))
end

T['on_attach']['skips hints when the server lacks support'] = function()
  unload_module()
  load_module({ inlay_hints = true })
  install_stubs()
  child.lua('_G.stub_inlay_hints(false)')

  attach({ inlay_hint = false })
  eq(child.lua_get('_G.hint_calls'), {})
end

T['on_attach']['respects `vim.b.gdevlsp_config`'] = function()
  -- Read off the attached buffer, which is not necessarily the current one
  child.lua([[
    _G.buf = _G.new_buf('gdscript')
    vim.b[_G.buf].gdevlsp_config = { inlay_hints = true }
  ]])

  attach({ inlay_hint = true }, '_G.buf')

  local calls = child.lua_get('_G.hint_calls')
  eq(#calls, 1)
  eq(calls[1].bufnr, child.lua_get('_G.buf'))
end

T['on_attach']['respects `vim.{g,b}.gdevlsp_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    unload_module()
    load_module({ inlay_hints = true })
    install_stubs()
    child.lua('_G.stub_inlay_hints(false)')

    child[var_type].gdevlsp_disable = true
    attach({ inlay_hint = true })

    eq(child.lua_get('_G.hint_calls'), {})

    -- The capability workaround is not a user-facing reaction, so it still runs
    eq(child.lua_get('_G.client.server_capabilities.typeDefinitionProvider'), vim.NIL)
  end,
})

T['window/showMessage'] = new_set({
  hooks = {
    pre_case = function()
      child.lua('_G.stub_show_message_handler()')
    end,
  },
})

T['window/showMessage']['drops Godot method-not-found chatter'] = function()
  child.lua('_G.show_message("Method not found: godot/reloadScript")')
  eq(child.lua_get('_G.forwarded'), {})
end

T['window/showMessage']['forwards everything else'] = function()
  child.lua('_G.show_message("Something worth reading")')
  eq(child.lua_get('_G.forwarded'), { 'Something worth reading' })
end

T['window/showMessage']['forwards results it cannot inspect'] = function()
  -- Only known noise is dropped; malformed notifications stay the default
  -- handler's business rather than being silently swallowed here
  child.lua([[vim.lsp.config.gdscript.handlers['window/showMessage'](nil, nil, {})]])
  eq(child.lua_get('_G.forwarded'), { '<no result>' })
end

T[':GdevLspReconnect'] = new_set()

T[':GdevLspReconnect']['works'] = function()
  child.lua('_G.new_buf("gdscript")')
  child.cmd('GdevLspReconnect')

  -- Still enabled afterwards; the command must not tear the config down
  eq(child.lua_get('vim.lsp.is_enabled("gdscript")'), true)
end

T[':GdevLspToggleHints'] = new_set()

T[':GdevLspToggleHints']['works'] = function()
  child.lua([[
    _G.stub_inlay_hints(false)
    _G.attach_clients({ _G.make_client({ inlay_hint = true }) })
  ]])

  child.cmd('GdevLspToggleHints')
  eq(child.lua_get('_G.hint_calls[1].enabled'), true)

  child.cmd('GdevLspToggleHints')
  eq(child.lua_get('_G.hint_calls[2].enabled'), false)
end

return T
