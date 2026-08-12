local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config) child.gdev_load('run', config) end
local unload_module = function() child.gdev_unload('run') end

-- Time constants scaled for CI (see `helpers.get_time_const`)
local wait_timeout = helpers.get_time_const(5000)
local pause = helpers.get_time_const(100)

-- Launching is asynchronous, so assertions wait for the effect rather than for
-- a fixed delay. `vim.wait()` runs the child's event loop, which is what lets
-- the `vim.system()` callbacks and the `vim.schedule()` inside them happen.
local wait_for = function(cond)
  local code = ('(vim.wait(%d, function() return %s end, 5))'):format(wait_timeout, cond)
  eq(child.lua_get(code), true)
end

-- No real Godot is ever started: 'tests/dir-run/bin/godot' is a fake that
-- records its argv and is driven by the environment, and it goes on the front
-- of $PATH so it also shadows an engine the machine happens to have.
local install_fixtures = function()
  child.lua([[
    vim.env.PATH = vim.fn.fnamemodify('tests/dir-run/bin', ':p') .. ':' .. vim.env.PATH

    _G.root = vim.fs.normalize(vim.fn.fnamemodify('tests/dir-run/project', ':p'))
    _G.open = function(relative) vim.cmd('edit tests/dir-run/project/' .. relative) end

    -- The fake logs its own name and then one line per argument it got
    _G.argv_log = vim.fn.tempname()
    vim.env.GDEV_RUN_ARGV_LOG = _G.argv_log
    _G.argv = function()
      if vim.fn.filereadable(_G.argv_log) == 0 then return {} end
      return vim.fn.readfile(_G.argv_log)
    end

    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end
    _G.last_message = function() return (_G.notifications[#_G.notifications] or {}).msg end

    -- Pickers are `vim.ui.select`; `_G.choice` is the index the stub picks, or
    -- `nil` for the user dismissing it
    _G.choice = nil
    _G.selected = nil
    vim.ui.select = function(items, opts, on_choice)
      _G.selected = { items = items, prompt = opts.prompt }
      on_choice(_G.choice ~= nil and items[_G.choice] or nil)
    end

    -- The console is asserted through the buffer and window it creates, since
    -- the module's own state is private
    _G.console_buf = function()
      for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf_id) == 'gdev://run-console' then return buf_id end
      end
    end
    _G.console_win = function()
      local buf_id = _G.console_buf()
      for _, win_id in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win_id) == buf_id then return win_id end
      end
    end
    _G.console_lines = function()
      local buf_id = _G.console_buf()
      return buf_id == nil and {} or vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
    end
    _G.console_text = function() return table.concat(_G.console_lines(), '\n') end
  ]])
end

local root = function() return child.lua_get('_G.root') end
local argv = function(...) return vim.list_extend({ 'godot', '--path', root() }, { ... }) end
local wait_for_exit = function() wait_for('_G.console_text():find("[exited]", 1, true) ~= nil') end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
      install_fixtures()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevRun)'), 'table')

  -- User commands
  eq(child.fn.exists(':GdevRunProject'), 2)
  eq(child.fn.exists(':GdevRunCurrentScene'), 2)
  eq(child.fn.exists(':GdevRunScene'), 2)
  eq(child.fn.exists(':GdevRunPicker'), 2)
  eq(child.fn.exists(':GdevRunConsole'), 2)
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevRun.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevRun.config.godot'), 'godot')
  eq(child.lua_get('GdevRun.config.script_extensions'), { 'gd' })
  eq(child.lua_get('GdevRun.config.console.enabled'), false)
  eq(child.lua_get('GdevRun.config.console.renderer'), 'buffer')
  eq(child.lua_get('GdevRun.config.console.buffer'), { position = 'bottom', size = 0.3 })
  eq(child.lua_get('GdevRun.config.console.float'), { width = 0.8, height = 0.25, border = 'rounded' })
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({
    godot = '/opt/godot',
    script_extensions = { 'gd', 'cs' },
    console = { enabled = true, renderer = 'float', buffer = { position = 'right' }, float = { border = 'single' } },
  })

  eq(child.lua_get('GdevRun.config.godot'), '/opt/godot')
  eq(child.lua_get('GdevRun.config.script_extensions'), { 'gd', 'cs' })
  eq(child.lua_get('GdevRun.config.console.enabled'), true)
  eq(child.lua_get('GdevRun.config.console.renderer'), 'float')
  eq(child.lua_get('GdevRun.config.console.buffer'), { position = 'right', size = 0.3 })
  eq(child.lua_get('GdevRun.config.console.float.border'), 'single')
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function() load_module(config) end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ godot = 1 }, 'godot', 'string')
  expect_config_error({ script_extensions = 'gd' }, 'script_extensions', 'table')

  expect_config_error({ console = 'a' }, 'console', 'table')
  expect_config_error({ console = { enabled = 'a' } }, 'console.enabled', 'boolean')
  expect_config_error({ console = { renderer = 'popup' } }, 'console.renderer', 'buffer')
  expect_config_error({ console = { renderer = 1 } }, 'console.renderer', 'buffer')

  expect_config_error({ console = { buffer = 'a' } }, 'console.buffer', 'table')
  expect_config_error({ console = { buffer = { position = 'top' } } }, 'console.buffer.position', 'bottom')
  expect_config_error({ console = { buffer = { size = 'a' } } }, 'console.buffer.size', 'number')
  expect_config_error({ console = { buffer = { size = 0 } } }, 'console.buffer.size', 'number')
  expect_config_error({ console = { buffer = { size = 1.5 } } }, 'console.buffer.size', 'number')

  expect_config_error({ console = { float = 'a' } }, 'console.float', 'table')
  expect_config_error({ console = { float = { width = 0 } } }, 'console.float.width', 'number')
  expect_config_error({ console = { float = { height = 2 } } }, 'console.float.height', 'number')
  expect_config_error({ console = { float = { border = 1 } } }, 'console.float.border', 'string')
end

T['setup()']['accepts a border given as characters'] = function()
  unload_module()
  load_module({ console = { float = { border = { '', '', '', '│', '', '', '', '│' } } } })
  eq(child.lua_get('GdevRun.config.console.float.border'), { '', '', '', '│', '', '', '', '│' })
end

T['status()'] = new_set()

T['status()']['works'] = function()
  child.lua('_G.open("Main.tscn")')
  eq(child.lua_get('GdevRun.status()'), { root = root(), godot = 'godot', executable = true })
end

T['status()']['reports a missing executable'] = function()
  unload_module()
  load_module({ godot = 'gdev-no-such-godot' })
  child.lua('_G.open("Main.tscn")')

  eq(child.lua_get('GdevRun.status()'), { root = root(), godot = 'gdev-no-such-godot', executable = false })
end

T['status()']['omits a root it cannot find'] = function()
  child.lua([[vim.fn.chdir('tests/dir-format')]])
  eq(child.lua_get('GdevRun.status().root'), vim.NIL)
end

T['status()']['starts nothing'] = function()
  child.lua('_G.open("Main.tscn")')
  child.lua('GdevRun.status()')

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.argv()'), {})
end

T['status()']['respects `opts` argument'] = function()
  eq(child.lua_get('GdevRun.status({ godot = "gdev-no-such-godot" }).godot'), 'gdev-no-such-godot')
end

T['status()']['respects `vim.b.gdevrun_config`'] = function()
  child.b.gdevrun_config = { godot = 'gdev-no-such-godot' }
  eq(child.lua_get('GdevRun.status().godot'), 'gdev-no-such-godot')
end

T['status()']['keeps answering while disabled'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    -- `:checkhealth gdev` asks exactly when things are switched off
    child.lua('_G.open("Main.tscn")')
    child[var_type].gdevrun_disable = true

    eq(child.lua_get('GdevRun.status()'), { root = root(), godot = 'godot', executable = true })
  end,
})

T['run_project()'] = new_set()

T['run_project()']['works'] = function()
  child.lua('_G.open("Main.tscn")')

  eq(child.lua_get('GdevRun.run_project()'), true)
  wait_for('#_G.argv() > 0')

  -- No scene argument: Godot plays the project's main scene
  eq(child.lua_get('_G.argv()'), argv())
end

T['run_project()']['finds the root from a nested buffer'] = function()
  child.lua('_G.open("scenes/Level.tscn")')

  eq(child.lua_get('GdevRun.run_project()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv())
end

T['run_project()']['falls back to the working directory'] = function()
  -- A buffer with no file still belongs to whatever project you are cd'd into
  child.lua([[vim.fn.chdir('tests/dir-run/project/scenes')]])

  eq(child.lua_get('GdevRun.run_project()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv())
end

T['run_project()']['ignores a buffer that is not a file'] = function()
  -- A scratch, terminal or help buffer carries a name that is not a path.
  -- Searching upward from `gdev://not-a-file` walks a relative `gdev:/` and
  -- stops at the working directory, never reaching the project above it.
  child.lua([[
    vim.fn.chdir('tests/dir-run/project/scenes')
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch, 'gdev://not-a-file')
    vim.api.nvim_set_current_buf(scratch)
  ]])

  eq(child.lua_get('GdevRun.run_project()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv())
end

T['run_project()']['reports a missing project'] = function()
  child.lua([[vim.fn.chdir('tests/dir-format')]])

  eq(child.lua_get('GdevRun.run_project()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'project%.godot')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))
  eq(child.lua_get('_G.argv()'), {})
end

T['run_project()']['explains a missing executable'] = function()
  unload_module()
  load_module({ godot = 'gdev-no-such-godot' })
  child.lua('_G.open("Main.tscn")')

  eq(child.lua_get('GdevRun.run_project()'), false)

  local message = child.lua_get('_G.last_message()')
  expect.match(message, '^%(gdev%.run%) ')
  expect.match(message, 'gdev%-no%-such%-godot')
  expect.match(message, '%$PATH')
  expect.match(message, 'setup%(%)')
  expect.match(message, 'gdvm')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))
end

T['run_project()']['reports a failed run'] = new_set({
  parametrize = {
    { 'could not open project', 'could not open project' },
    -- Godot can fail without saying anything, which still has to reach the user
    { '', 'Godot exited with 2' },
  },
}, {
  test = function(stderr, pattern)
    child.lua('vim.env.GDEV_RUN_EXIT = "2"; vim.env.GDEV_RUN_STDERR = ...; _G.open("Main.tscn")', { stderr })

    eq(child.lua_get('GdevRun.run_project()'), true)
    wait_for('#_G.notifications > 0')

    expect.match(child.lua_get('_G.last_message()'), vim.pesc(pattern))
    eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))
  end,
})

T['run_project()']['stays quiet on a clean exit'] = function()
  child.lua('_G.open("Main.tscn")')
  child.lua('GdevRun.run_project()')
  wait_for('#_G.argv() > 0')

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.notifications'), {})
end

T['run_project()']['respects `opts` argument'] = function()
  child.lua('_G.open("Main.tscn")')

  eq(child.lua_get('GdevRun.run_project({ godot = "gdev-no-such-godot" })'), false)
  expect.match(child.lua_get('_G.last_message()'), 'gdev%-no%-such%-godot')
end

T['run_project()']['respects `vim.b.gdevrun_config`'] = function()
  child.lua('_G.open("Main.tscn")')
  child.b.gdevrun_config = { godot = 'gdev-no-such-godot' }

  eq(child.lua_get('GdevRun.run_project()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'gdev%-no%-such%-godot')
end

T['run_project()']['respects `vim.{g,b}.gdevrun_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Main.tscn")')
    child[var_type].gdevrun_disable = true

    eq(child.lua_get('GdevRun.run_project()'), false)

    helpers.sleep(pause, child)
    eq(child.lua_get('_G.argv()'), {})
  end,
})

T['run_scene()'] = new_set()

T['run_scene()']['accepts every spelling of a scene inside the project'] = new_set({
  parametrize = {
    { '"res://scenes/Level.tscn"' },
    { '"scenes/Level.tscn"' },
    { '_G.root .. "/scenes/Level.tscn"' },
  },
}, {
  test = function(argument)
    child.lua('_G.open("Main.tscn")')

    eq(child.lua_get('GdevRun.run_scene(' .. argument .. ')'), true)
    wait_for('#_G.argv() > 0')

    eq(child.lua_get('_G.argv()'), argv('res://scenes/Level.tscn'))
  end,
})

T['run_scene()']['rejects a scene outside the project'] = new_set({
  parametrize = { { '"../outside.tscn"' }, { '"res://../outside.tscn"' }, { '"/tmp/outside.tscn"' } },
}, {
  test = function(argument)
    child.lua('_G.open("Main.tscn")')

    eq(child.lua_get('GdevRun.run_scene(' .. argument .. ')'), false)
    expect.match(child.lua_get('_G.last_message()'), 'is not inside ')
    eq(child.lua_get('_G.argv()'), {})
  end,
})

T['run_scene()']['validates arguments'] = function()
  expect.error(function() child.lua('GdevRun.run_scene(1)') end, vim.pesc('`scene` should be string'))
  expect.error(function() child.lua('GdevRun.run_scene()') end, vim.pesc('`scene` should be string'))
end

T['run_scene()']['respects `opts` argument'] = function()
  child.lua('_G.open("Main.tscn")')

  eq(child.lua_get('GdevRun.run_scene("res://Main.tscn", { godot = "gdev-no-such-godot" })'), false)
  expect.match(child.lua_get('_G.last_message()'), 'gdev%-no%-such%-godot')
end

T['run_scene()']['respects `vim.b.gdevrun_config`'] = function()
  child.lua('_G.open("Main.tscn")')
  child.b.gdevrun_config = { godot = 'gdev-no-such-godot' }

  eq(child.lua_get('GdevRun.run_scene("res://Main.tscn")'), false)
  expect.match(child.lua_get('_G.last_message()'), 'gdev%-no%-such%-godot')
end

T['run_scene()']['respects `vim.{g,b}.gdevrun_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Main.tscn")')
    child[var_type].gdevrun_disable = true

    eq(child.lua_get('GdevRun.run_scene("res://Main.tscn")'), false)

    helpers.sleep(pause, child)
    eq(child.lua_get('_G.argv()'), {})
  end,
})

T['run_current_scene()'] = new_set()

T['run_current_scene()']['runs the scene in the buffer'] = function()
  child.lua('_G.open("scenes/Level.tscn")')

  eq(child.lua_get('GdevRun.run_current_scene()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv('res://scenes/Level.tscn'))
end

T['run_current_scene()']['runs the only scene using the script'] = function()
  child.lua('_G.open("scripts/level.gd")')

  eq(child.lua_get('GdevRun.run_current_scene()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv('res://scenes/Level.tscn'))
  eq(child.lua_get('_G.selected'), vim.NIL)
end

T['run_current_scene()']['asks which scene when several use the script'] = function()
  child.lua('_G.open("scripts/player.gd"); _G.choice = 2')

  eq(child.lua_get('GdevRun.run_current_scene()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.selected.items'), { 'res://Main.tscn', 'res://scenes/Menu.tscn', 'res://world.tscn' })
  expect.match(child.lua_get('_G.selected.prompt'), 'res://scripts/player%.gd')
  eq(child.lua_get('_G.argv()'), argv('res://scenes/Menu.tscn'))
end

T['run_current_scene()']['starts nothing when the picker is dismissed'] = function()
  child.lua('_G.open("scripts/player.gd")')

  eq(child.lua_get('GdevRun.run_current_scene()'), true)

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.argv()'), {})
end

T['run_current_scene()']['reports a script no scene uses'] = function()
  child.lua('_G.open("scripts/orphan.gd")')

  eq(child.lua_get('GdevRun.run_current_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'no scene in .* uses res://scripts/orphan%.gd')
  eq(child.lua_get('_G.argv()'), {})
end

T['run_current_scene()']['reports a buffer that is neither'] = function()
  child.lua('_G.open("project.godot")')

  eq(child.lua_get('GdevRun.run_current_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'project%.godot is neither a scene nor a Godot script')
end

T['run_current_scene()']['reports a buffer with no file'] = function()
  child.lua([[vim.fn.chdir('tests/dir-run/project')]])

  eq(child.lua_get('GdevRun.run_current_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'has no file')
end

T['run_current_scene()']['reports a scene belonging to no project'] = function()
  -- The buffer decides which project a command is about, so a scene outside
  -- every project is a missing project rather than a scene outside this one
  child.lua([[vim.fn.chdir('tests/dir-run/project'); vim.cmd('edit ../outside.tscn')]])

  eq(child.lua_get('GdevRun.run_current_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'project%.godot')
  eq(child.lua_get('_G.argv()'), {})
end

T['run_current_scene()']['respects `config.script_extensions`'] = function()
  -- The C# seam, exercised with the extension this fixture project has
  child.lua('_G.open("scripts/orphan.gdshader")')
  eq(child.lua_get('GdevRun.run_current_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'neither a scene nor a Godot script')

  eq(child.lua_get('GdevRun.run_current_scene({ script_extensions = { "gdshader" } })'), true)
  wait_for('#_G.argv() > 0')
  eq(child.lua_get('_G.argv()'), argv('res://scenes/Shaded.tscn'))
end

T['run_current_scene()']['respects `vim.b.gdevrun_config`'] = function()
  child.lua('_G.open("scenes/Level.tscn")')
  child.b.gdevrun_config = { godot = 'gdev-no-such-godot' }

  eq(child.lua_get('GdevRun.run_current_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'gdev%-no%-such%-godot')
end

T['run_current_scene()']['respects `vim.{g,b}.gdevrun_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("scenes/Level.tscn")')
    child[var_type].gdevrun_disable = true

    eq(child.lua_get('GdevRun.run_current_scene()'), false)

    helpers.sleep(pause, child)
    eq(child.lua_get('_G.argv()'), {})
  end,
})

T['pick_scene()'] = new_set()

T['pick_scene()']['offers every scene, sorted'] = function()
  child.lua('_G.open("scripts/orphan.gd"); _G.choice = 3')

  eq(child.lua_get('GdevRun.pick_scene()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.selected.items'), {
    'res://Main.tscn',
    'res://scenes/Level.tscn',
    'res://scenes/Menu.tscn',
    'res://scenes/Shaded.tscn',
    'res://world.tscn',
  })
  eq(child.lua_get('_G.argv()'), argv('res://scenes/Menu.tscn'))
end

T['pick_scene()']['warns about a project with no scenes'] = function()
  child.lua([[vim.fn.chdir('tests/dir-run/empty')]])

  eq(child.lua_get('GdevRun.pick_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'no scenes found in ')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.WARN'))
  eq(child.lua_get('_G.selected'), vim.NIL)
end

T['pick_scene()']['reports a missing project'] = function()
  child.lua([[vim.fn.chdir('tests/dir-format')]])

  eq(child.lua_get('GdevRun.pick_scene()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'project%.godot')
end

T['pick_scene()']['respects `vim.b.gdevrun_config`'] = function()
  -- The picked scene is launched with the config the picker was opened with
  child.lua('_G.open("Main.tscn"); _G.choice = 1')
  child.b.gdevrun_config = { godot = 'gdev-no-such-godot' }

  eq(child.lua_get('GdevRun.pick_scene()'), true)
  expect.match(child.lua_get('_G.last_message()'), 'gdev%-no%-such%-godot')
  eq(child.lua_get('_G.argv()'), {})
end

T['pick_scene()']['respects `vim.{g,b}.gdevrun_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Main.tscn")')
    child[var_type].gdevrun_disable = true

    eq(child.lua_get('GdevRun.pick_scene()'), false)
    eq(child.lua_get('_G.selected'), vim.NIL)
  end,
})

T['show_console()'] = new_set()

T['show_console()']['reports that nothing was captured'] = function()
  eq(child.lua_get('GdevRun.show_console()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'no Godot output has been captured yet')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.INFO'))
end

T['show_console()']['respects `vim.{g,b}.gdevrun_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].gdevrun_disable = true
    eq(child.lua_get('GdevRun.show_console()'), false)
    eq(child.lua_get('_G.notifications'), {})
  end,
})

-- Integration tests ==========================================================
T['console'] = new_set({
  hooks = {
    pre_case = function()
      child.set_size(24, 80)
      unload_module()
      load_module({ console = { enabled = true } })
      child.lua('_G.open("Main.tscn")')
    end,
  },
})

T['console']['captures output instead of detaching'] = function()
  child.lua('vim.env.GDEV_RUN_STDOUT = "Godot Engine v4.4.stable"')

  eq(child.lua_get('GdevRun.run_project()'), true)
  wait_for_exit()

  eq(child.lua_get('_G.console_lines()'), {
    'Command: godot --path ' .. root(),
    'Project: ' .. root(),
    '',
    'Godot Engine v4.4.stable',
    '',
    '[exited] code=0 signal=0',
  })
end

T['console']['marks the error stream'] = function()
  child.lua('vim.env.GDEV_RUN_STDERR = "SCRIPT ERROR: Parse Error"')

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.lua_get('_G.console_lines()')[4], '[stderr] SCRIPT ERROR: Parse Error')
end

T['console']['flushes a line with no trailing newline'] = function()
  child.lua('vim.env.GDEV_RUN_STDOUT = "complete"; vim.env.GDEV_RUN_PARTIAL = "cut off"')

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.lua_get('_G.console_lines()'), {
    'Command: godot --path ' .. root(),
    'Project: ' .. root(),
    '',
    'complete',
    'cut off',
    '',
    '[exited] code=0 signal=0',
  })
end

T['console']['reports the exit status'] = function()
  child.lua('vim.env.GDEV_RUN_EXIT = "3"')

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.lua_get('_G.console_lines()')[#child.lua_get('_G.console_lines()')], '[exited] code=3 signal=0')

  -- A captured failure is shown, not also notified
  eq(child.lua_get('_G.notifications'), {})
end

T['console']['starts each run from a clean buffer'] = function()
  child.lua('vim.env.GDEV_RUN_STDOUT = "first"')
  child.lua('GdevRun.run_project()')
  wait_for_exit()

  child.lua('vim.env.GDEV_RUN_STDOUT = "second"')
  child.lua('GdevRun.run_scene("res://scenes/Level.tscn")')
  wait_for('_G.console_text():find("second", 1, true) ~= nil')

  expect.no_match(child.lua_get('_G.console_text()'), 'first')
  eq(child.lua_get('_G.console_lines()')[1], 'Command: godot --path ' .. root() .. ' res://scenes/Level.tscn')
end

T['console']['refuses a second run while one is going'] = function()
  child.lua('vim.env.GDEV_RUN_SLEEP = "1"')

  eq(child.lua_get('GdevRun.run_project()'), true)
  eq(child.lua_get('GdevRun.run_project()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'a captured run is still going')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.WARN'))

  wait_for_exit()

  -- The guard lifts once the process is gone
  child.lua('vim.env.GDEV_RUN_SLEEP = ""')
  eq(child.lua_get('GdevRun.run_project()'), true)
end

T['console']['does not limit detached runs'] = function()
  unload_module()
  load_module()
  child.lua('vim.env.GDEV_RUN_SLEEP = "1"')

  eq(child.lua_get('GdevRun.run_project()'), true)
  eq(child.lua_get('GdevRun.run_project()'), true)
  eq(child.lua_get('_G.notifications'), {})
end

T['console']['builds a scratch buffer'] = function()
  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.lua_get('vim.bo[_G.console_buf()].buftype'), 'nofile')
  eq(child.lua_get('vim.bo[_G.console_buf()].filetype'), 'log')
  eq(child.lua_get('vim.bo[_G.console_buf()].modifiable'), false)
  eq(child.lua_get('vim.bo[_G.console_buf()].buflisted'), false)
end

T['console']['keeps the newest output in view'] = function()
  child.lua('GdevRun.run_project()')
  wait_for_exit()

  local win = child.lua_get('_G.console_win()')
  eq(child.api.nvim_win_get_cursor(win)[1], #child.lua_get('_G.console_lines()'))
end

T['console']['opens a split below by default'] = function()
  child.lua('GdevRun.run_project()')
  wait_for_exit()

  local config = child.lua_get('vim.api.nvim_win_get_config(_G.console_win())')
  eq(config.split, 'below')
  eq(config.relative, '')
  eq(child.lua_get('vim.api.nvim_win_get_height(_G.console_win())'), 7)
end

T['console']['respects `config.console.buffer`'] = new_set({
  parametrize = {
    { { position = 'bottom', size = 0.5 }, 'below', 12 },
    { { position = 'right', size = 0.25 }, 'right', 20 },
  },
}, {
  test = function(buffer_config, split, size)
    unload_module()
    load_module({ console = { enabled = true, buffer = buffer_config } })
    child.lua('GdevRun.run_project()')
    wait_for_exit()

    local dimension = split == 'right' and 'nvim_win_get_width' or 'nvim_win_get_height'
    eq(child.lua_get('vim.api.nvim_win_get_config(_G.console_win()).split'), split)
    eq(child.lua_get(('vim.api.%s(_G.console_win())'):format(dimension)), size)
  end,
})

T['console']['reuses the current window'] = function()
  unload_module()
  load_module({ console = { enabled = true, buffer = { position = 'current' } } })
  child.lua('_G.open("Main.tscn")')

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
  eq(child.lua_get('vim.api.nvim_get_current_buf()'), child.lua_get('_G.console_buf()'))
end

T['console']['respects `config.console.renderer`'] = function()
  unload_module()
  load_module({ console = { enabled = true, renderer = 'float' } })
  child.lua('_G.open("Main.tscn")')

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  local config = child.lua_get('vim.api.nvim_win_get_config(_G.console_win())')
  eq(config.relative, 'editor')
  eq(config.width, 64)
  eq(config.height, 6)
  eq(config.row, 8)
  eq(config.col, 8)
  eq(config.style, 'minimal')
  eq(config.title, { { ' Godot console ' } })
end

T['console']['respects `config.console.float`'] = function()
  unload_module()
  load_module({
    console = { enabled = true, renderer = 'float', float = { width = 0.5, height = 0.5, border = 'single' } },
  })
  child.lua('_G.open("Main.tscn")')

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  local config = child.lua_get('vim.api.nvim_win_get_config(_G.console_win())')
  eq(config.width, 40)
  eq(config.height, 12)
  eq(config.border[1], '┌')
end

T['console']['reads as a log rather than a file'] = function()
  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.lua_get('vim.wo[_G.console_win()].wrap'), false)
  eq(child.lua_get('vim.wo[_G.console_win()].number'), false)
  eq(child.lua_get('vim.wo[_G.console_win()].signcolumn'), 'no')
end

T['console']['leaves the cursor where it was'] = function()
  -- A run that took the cursor would also make the next command resolve the
  -- project from the console buffer, which belongs to none
  local buf = child.api.nvim_get_current_buf()

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  eq(child.api.nvim_get_current_buf(), buf)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)

  -- So a second run still knows where it is
  eq(child.lua_get('GdevRun.run_project()'), true)
end

T['console']['closes with `q`'] = function()
  child.lua('GdevRun.run_project()')
  wait_for_exit()

  child.cmd('GdevRunConsole')
  child.type_keys('q')
  eq(child.lua_get('_G.console_win()'), vim.NIL)

  -- The output survives the window
  expect.match(child.lua_get('_G.console_text()'), '%[exited%]')
end

T['console']['respects `vim.b.gdevrun_config`'] = function()
  unload_module()
  load_module()
  child.lua('_G.open("Main.tscn")')
  child.b.gdevrun_config = { console = { enabled = true } }

  child.lua('GdevRun.run_project()')
  wait_for_exit()

  expect.match(child.lua_get('_G.console_text()'), 'Command: godot')
end

T[':GdevRunConsole'] = new_set()

T[':GdevRunConsole']['reopens the last console'] = function()
  child.set_size(24, 80)
  unload_module()
  load_module({ console = { enabled = true } })
  child.lua('_G.open("Main.tscn"); vim.env.GDEV_RUN_STDOUT = "the output"')

  child.lua('GdevRun.run_project()')
  wait_for_exit()
  local lines = child.lua_get('_G.console_lines()')

  child.cmd('GdevRunConsole')
  child.type_keys('q')
  eq(child.lua_get('_G.console_win()'), vim.NIL)

  child.cmd('GdevRunConsole')
  expect.no_equality(child.lua_get('_G.console_win()'), vim.NIL)
  eq(child.lua_get('_G.console_lines()'), lines)
end

T[':GdevRunConsole']['focuses a console that is already open'] = function()
  child.set_size(24, 80)
  unload_module()
  load_module({ console = { enabled = true } })
  child.lua('_G.open("Main.tscn")')

  child.lua('GdevRun.run_project()')
  wait_for_exit()
  local win = child.lua_get('_G.console_win()')
  expect.no_equality(child.api.nvim_get_current_win(), win)

  child.cmd('GdevRunConsole')

  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
  eq(child.api.nvim_get_current_win(), win)
end

T[':GdevRunProject'] = new_set()

T[':GdevRunProject']['works'] = function()
  child.lua('_G.open("Main.tscn")')
  child.cmd('GdevRunProject')
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv())
end

T[':GdevRunCurrentScene'] = new_set()

T[':GdevRunCurrentScene']['works'] = function()
  child.lua('_G.open("scenes/Menu.tscn")')
  child.cmd('GdevRunCurrentScene')
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv('res://scenes/Menu.tscn'))
end

T[':GdevRunScene'] = new_set()

T[':GdevRunScene']['works'] = function()
  child.lua('_G.open("Main.tscn")')
  child.cmd('GdevRunScene scenes/Level.tscn')
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv('res://scenes/Level.tscn'))
end

T[':GdevRunPicker'] = new_set()

T[':GdevRunPicker']['works'] = function()
  child.lua('_G.open("Main.tscn"); _G.choice = 1')
  child.cmd('GdevRunPicker')
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), argv('res://Main.tscn'))
end

return T
