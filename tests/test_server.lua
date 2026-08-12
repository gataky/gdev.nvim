local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config)
  child.gdev_load('server', config)
end
local unload_module = function()
  child.gdev_unload('server')
end

-- Fixture addresses. Relative on purpose: `sun_path` is capped at ~104 bytes,
-- which an absolute path into a checkout can exceed.
local new_address = 'tests/dir-server/new.sock'
local config_address = 'tests/dir-server/from-config.sock'
local stale_address = 'tests/dir-server/stale.sock'
local live_address = 'tests/dir-server/live.sock'
local colon_address = 'tests/dir-server/host:1234.sock'
local plain_file = 'tests/dir-server/plain.txt'

-- Remove anything a case created, including after a failed one. Sockets bound
-- inside the child outlive it: the process is killed, so libuv never gets to
-- unlink them.
local clean_fixtures = function()
  for _, path in ipairs(vim.fn.glob('tests/dir-server/*.sock', true, true)) do
    vim.fn.delete(path)
  end
  vim.fn.delete(plain_file)
end

-- Stubs installed in the child.
--
-- mini.test starts children with `--listen`, and Neovim opens an address of its
-- own at startup regardless, so `v:servername` is never empty in here and "this
-- Neovim listens on nothing" cannot be arranged. `vim.fn.serverlist()` is the
-- module's only window onto that state, so a test dictates it instead.
--
-- `vim.fn.serverstart` is stubbed for every case, without exception: the real
-- one would leave live sockets behind, and the default address belongs to
-- whatever session the developer running these tests has open on it.
local install_stubs = function()
  child.lua([[
    _G.notifications, _G.attempts = {}, {}
    _G.reset = function() _G.notifications, _G.attempts = {}, {} end

    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end

    _G.notified = function(level)
      local out = {}
      for _, n in ipairs(_G.notifications) do
        if n.level == vim.log.levels[level] then table.insert(out, n.msg) end
      end
      return out
    end

    -- Records what was asked for and mirrors `serverstart()`'s own contract:
    -- binding to a path something already occupies fails.
    vim.fn.serverstart = function(address)
      table.insert(_G.attempts, address)
      if vim.uv.fs_stat(address) ~= nil then error('Vim:Failed to start server: address already in use', 0) end
      return address
    end

    _G.stub_serverlist = function(addresses)
      vim.fn.serverlist = function() return vim.deepcopy(addresses) end
    end

    -- A socket file with nothing behind it, which is what a crashed Neovim
    -- leaves: bound so the inode exists, never listening, and never closed
    -- (libuv unlinks the path as the handle closes).
    _G.pipes = {}
    _G.bind_socket = function(path, listening)
      local pipe = vim.uv.new_pipe(false)
      pipe:bind(path)
      if listening then pipe:listen(16, function() end) end
      table.insert(_G.pipes, pipe)
      return path
    end
  ]])
end

local servername = function()
  return child.lua_get('vim.v.servername')
end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
      install_stubs()
    end,
    post_case = clean_fixtures,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevServer)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#GdevServer'), 1)

  -- User command
  eq(child.fn.exists(':GdevServerStart'), 2)
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevServer.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevServer.config.address'), vim.NIL)
  eq(child.lua_get('GdevServer.config.autostart'), false)
  eq(child.lua_get('GdevServer.config.remove_stale_socket'), true)
  eq(child.lua_get('GdevServer.config.filetypes'), { 'gdscript', 'gdshader', 'gdresource' })
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({ address = config_address, remove_stale_socket = false, filetypes = { 'cs' } })

  eq(child.lua_get('GdevServer.config.address'), config_address)
  eq(child.lua_get('GdevServer.config.remove_stale_socket'), false)

  -- Replaced, not merged onto the three defaults
  eq(child.lua_get('GdevServer.config.filetypes'), { 'cs' })
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function()
      load_module(config)
    end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ address = 1 }, 'address', 'string')
  expect_config_error({ autostart = 'a' }, 'autostart', 'boolean')
  expect_config_error({ remove_stale_socket = 'a' }, 'remove_stale_socket', 'boolean')
  expect_config_error({ filetypes = 'a' }, 'filetypes', 'table')
end

T['setup()']['does not listen by default'] = function()
  unload_module()
  child.lua('_G.reset()')
  load_module({ address = new_address })

  eq(child.lua_get('_G.attempts'), {})
end

T['setup()']['respects `config.autostart`'] = function()
  unload_module()
  child.lua('_G.reset()')
  load_module({ autostart = true, address = new_address })

  eq(child.lua_get('_G.attempts'), { new_address })
end

T['setup()']['can be called repeatedly'] = function()
  load_module({ address = config_address })

  eq(child.lua_get('GdevServer.config.address'), config_address)
  eq(child.fn.exists(':GdevServerStart'), 2)
end

T['start()'] = new_set()

T['start()']['works'] = function()
  eq(child.lua_get('GdevServer.start(...)', { new_address }), new_address)

  eq(child.lua_get('_G.attempts'), { new_address })
  expect.match(child.lua_get('_G.notified("INFO")')[1], 'listening on ' .. vim.pesc(new_address))
end

T['start()']['reuses the address this Neovim already listens on'] = function()
  -- Real state, not a stub: the child is listening on this address right now
  local own = servername()

  eq(child.lua_get('GdevServer.start(...)', { own }), own)

  -- Nothing started; a second listener on one address is impossible anyway
  eq(child.lua_get('_G.attempts'), {})
  expect.match(child.lua_get('_G.notified("INFO")')[1], 'already listening on ' .. vim.pesc(own))
end

T['start()']['prefers its argument over `config.address`'] = function()
  unload_module()
  load_module({ address = config_address })

  eq(child.lua_get('GdevServer.start(...)', { new_address }), new_address)
  eq(child.lua_get('_G.attempts'), { new_address })
end

T['start()']['falls back to `config.address`'] = function()
  unload_module()
  load_module({ address = config_address })
  child.lua('_G.reset()')

  -- Even though this Neovim already listens somewhere else. A configured
  -- address is the whole point: `v:servername` changes every session, so it is
  -- not something Godot's settings can hard-code.
  eq(child.lua_get('GdevServer.start()'), config_address)
  eq(child.lua_get('_G.attempts'), { config_address })
end

T['start()']['treats an empty argument as no argument'] = function()
  unload_module()
  load_module({ address = config_address })
  child.lua('_G.reset()')

  eq(child.lua_get('GdevServer.start("")'), config_address)
end

T['start()']['skips an address another process listens on'] = function()
  child.lua('_G.bind_socket(..., true)', { live_address })

  eq(child.lua_get('GdevServer.start(...)', { live_address }), vim.NIL)

  -- Taking the address over would silently redirect Godot to this session
  eq(child.lua_get('_G.attempts'), {})
  expect.match(child.lua_get('_G.notified("WARN")')[1], 'another process is listening')

  -- And the socket is still there for its owner
  eq(child.lua_get('vim.uv.fs_stat(...).type', { live_address }), 'socket')
end

T['start()']['removes a stale socket'] = function()
  child.lua('_G.bind_socket(..., false)', { stale_address })
  eq(child.lua_get('vim.uv.fs_stat(...).type', { stale_address }), 'socket')

  eq(child.lua_get('GdevServer.start(...)', { stale_address }), stale_address)

  -- Unlinked, and only then started
  eq(child.lua_get('vim.uv.fs_stat(...)', { stale_address }), vim.NIL)
  eq(child.lua_get('_G.attempts'), { stale_address })
  expect.match(child.lua_get('_G.notified("WARN")')[1], 'removed a stale socket')
end

T['start()']['respects `config.remove_stale_socket`'] = function()
  unload_module()
  load_module({ remove_stale_socket = false })
  child.lua('_G.bind_socket(..., false)', { stale_address })
  child.lua('_G.reset()')

  eq(child.lua_get('GdevServer.start(...)', { stale_address }), vim.NIL)

  -- Left alone, and the failure to bind is reported rather than swallowed
  eq(child.lua_get('vim.uv.fs_stat(...).type', { stale_address }), 'socket')
  expect.match(child.lua_get('_G.notified("ERROR")')[1], 'could not start a server')
end

T['start()']['reports a failure to remove the stale socket'] = function()
  child.lua('_G.bind_socket(..., false)', { stale_address })
  child.lua([[vim.uv.fs_unlink = function() return nil, 'EACCES: permission denied' end]])

  eq(child.lua_get('GdevServer.start(...)', { stale_address }), vim.NIL)

  -- Starting anyway would fail with a message about the wrong problem
  eq(child.lua_get('_G.attempts'), {})
  expect.match(
    child.lua_get('_G.notified("ERROR")')[1],
    'could not remove the stale socket.*EACCES'
  )
end

T['start()']['leaves a file that is not a socket alone'] = function()
  child.fn.writefile({ 'not a socket' }, plain_file)

  eq(child.lua_get('GdevServer.start(...)', { plain_file }), vim.NIL)

  -- A typo in `address` must not delete the file it points at
  eq(child.fn.readfile(plain_file), { 'not a socket' })
  expect.match(child.lua_get('_G.notified("ERROR")')[1], 'could not start a server')
end

T['start()']['works on a `host:port` address'] = function()
  eq(child.lua_get('GdevServer.start("127.0.0.1:6008")'), '127.0.0.1:6008')
  eq(child.lua_get('_G.attempts'), { '127.0.0.1:6008' })
end

T['start()']['never removes a file behind an address with a port'] = function()
  -- A colon makes it a network address, whatever happens to sit on disk under
  -- that name. This fixture is a socket nothing answers on, which is every
  -- signal the stale-socket path looks for, and it still must survive.
  child.lua('_G.bind_socket(..., false)', { colon_address })

  eq(child.lua_get('GdevServer.start(...)', { colon_address }), vim.NIL)
  eq(child.lua_get('vim.uv.fs_stat(...).type', { colon_address }), 'socket')
end

T['start()']['validates arguments'] = function()
  expect.error(function()
    child.lua('GdevServer.start(1)')
  end, '`address`.*string')
end

T['start()']['respects `vim.b.gdevserver_config`'] = function()
  child.b.gdevserver_config = { address = config_address }

  eq(child.lua_get('GdevServer.start()'), config_address)
  eq(child.lua_get('_G.attempts'), { config_address })
end

T['start()']['respects `vim.{g,b}.gdevserver_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].gdevserver_disable = true

    eq(child.lua_get('GdevServer.start(...)', { new_address }), vim.NIL)
    eq(child.lua_get('_G.attempts'), {})
  end,
})

T['status()'] = new_set()

T['status()']['reports the address this Neovim listens on'] = function()
  -- Nothing configured: the address Neovim generated for itself at startup
  eq(child.lua_get('GdevServer.status()'), { address = servername(), listening = true })
end

T['status()']['prefers `config.address`'] = function()
  unload_module()
  load_module({ address = config_address })

  eq(child.lua_get('GdevServer.status()'), { address = config_address, listening = false })
end

T['status()']['falls back to a documented default'] = function()
  -- The one arrangement a child process cannot reach on its own. Nothing is
  -- started here, so the real `/tmp/godot.nvim` is never touched.
  child.lua('_G.stub_serverlist({})')

  eq(child.lua_get('GdevServer.status()'), { address = '/tmp/godot.nvim', listening = false })
end

T['status()']['respects `vim.b.gdevserver_config`'] = function()
  child.b.gdevserver_config = { address = config_address }

  eq(child.lua_get('GdevServer.status().address'), config_address)
end

T['status()']['still answers while disabled'] = function()
  -- Diagnostics have to keep working when the module is switched off, since
  -- that is when they get asked. `:checkhealth gdev` relies on this.
  child.g.gdevserver_disable = true

  eq(child.lua_get('GdevServer.status()'), { address = servername(), listening = true })
end

-- Integration tests ==========================================================
T[':GdevServerStart'] = new_set()

T[':GdevServerStart']['works'] = function()
  unload_module()
  load_module({ address = config_address })
  child.lua('_G.reset()')

  child.cmd('GdevServerStart')
  eq(child.lua_get('_G.attempts'), { config_address })
end

T[':GdevServerStart']['accepts an address'] = function()
  unload_module()
  load_module({ address = config_address })
  child.lua('_G.reset()')

  child.cmd('GdevServerStart ' .. new_address)
  eq(child.lua_get('_G.attempts'), { new_address })
end

T['FileType'] = new_set()

T['FileType']['starts the server in Godot buffers'] = new_set({
  parametrize = {
    { 'tests/dir-server/script.gd' },
    { 'tests/dir-server/shader.gdshader' },
    { 'tests/dir-server/scene.tscn' },
  },
}, {
  test = function(path)
    unload_module()
    load_module({ autostart = true, address = new_address })
    child.lua('_G.reset()')

    child.cmd('edit ' .. path)
    eq(child.lua_get('_G.attempts'), { new_address })
  end,
})

T['FileType']['stays quiet for other filetypes'] = function()
  unload_module()
  load_module({ autostart = true, address = new_address })
  child.lua('_G.reset()')

  child.cmd('edit tests/helpers.lua')
  eq(child.lua_get('_G.attempts'), {})
end

T['FileType']['is not wired unless `autostart` is set'] = function()
  eq(child.fn.exists('#GdevServer#FileType'), 0)

  child.cmd('edit tests/dir-server/script.gd')
  eq(child.bo.filetype, 'gdscript')
  eq(child.lua_get('_G.attempts'), {})
end

T['FileType']['respects `config.filetypes`'] = function()
  unload_module()
  load_module({ autostart = true, address = new_address, filetypes = { 'lua' } })
  child.lua('_G.reset()')

  child.cmd('edit tests/dir-server/script.gd')
  eq(child.lua_get('_G.attempts'), {})

  child.cmd('edit tests/helpers.lua')
  eq(child.lua_get('_G.attempts'), { new_address })
end

return T
