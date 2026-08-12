local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config) child.gdev_load('format', config) end
local unload_module = function() child.gdev_unload('format') end

-- Time constants scaled for CI (see `helpers.get_time_const`)
local wait_timeout = helpers.get_time_const(2000)
local pause = helpers.get_time_const(100)

-- Formatting is asynchronous, so assertions wait for the effect rather than for
-- a fixed delay. `vim.wait()` runs the child's event loop, which is what lets
-- the `vim.system()` callback and the `vim.schedule()` inside it happen.
local wait_for = function(cond)
  local code = ('(vim.wait(%d, function() return %s end, 5))'):format(wait_timeout, cond)
  eq(child.lua_get(code), true)
end

-- No real formatter is ever run: `tests/dir-format/bin` holds fakes that record
-- their argv and rewrite the file they are pointed at, and it goes on the front
-- of $PATH so it also shadows a formatter the machine happens to have.
local install_fakes = function()
  child.lua([[
    vim.env.PATH = vim.fn.fnamemodify('tests/dir-format/bin', ':p') .. ':' .. vim.env.PATH

    -- Each fake appends its own name and then one line per argument it got
    _G.argv_log = vim.fn.tempname()
    vim.env.GDEV_FORMAT_ARGV_LOG = _G.argv_log
    _G.argv = function()
      if vim.fn.filereadable(_G.argv_log) == 0 then return {} end
      return vim.fn.readfile(_G.argv_log)
    end

    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end

    -- Formatting rewrites files, so scripts under test are scratch copies. The
    -- buffer name is what gets formatted, and on macOS it is the `/private`
    -- prefixed resolution of what `tempname()` handed out.
    _G.new_script = function(lines)
      local path = vim.fn.tempname() .. '.gd'
      vim.fn.writefile(lines or { 'extends Node' }, path)
      vim.cmd('edit ' .. path)
      return vim.api.nvim_buf_get_name(0)
    end

    -- `vim.b` has to be set before `FileType` fires for the indent hook to see
    -- it, which means owning the buffer rather than opening a file
    _G.new_buffer = function(filetype)
      vim.cmd('enew')
      vim.bo.filetype = filetype
      return vim.api.nvim_get_current_buf()
    end
  ]])
end

local formatted_by = function(name) return { 'extends Node', '# formatted by ' .. name } end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
      install_fakes()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevFormat)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#GdevFormat'), 1)

  -- User command
  eq(child.fn.exists(':GdevFormat'), 2)
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevFormat.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevFormat.config.formatter'), 'gdscript-formatter')
  eq(child.lua_get('GdevFormat.config.command'), vim.NIL)
  eq(child.lua_get('GdevFormat.config.autoformat'), true)
  eq(child.lua_get('GdevFormat.config.indent'), false)
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({ formatter = 'gdformat', command = { 'gdev-fake-formatter' }, autoformat = false, indent = 2 })

  eq(child.lua_get('GdevFormat.config.formatter'), 'gdformat')
  eq(child.lua_get('GdevFormat.config.command'), { 'gdev-fake-formatter' })
  eq(child.lua_get('GdevFormat.config.autoformat'), false)
  eq(child.lua_get('GdevFormat.config.indent'), 2)
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function() load_module(config) end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')

  -- Anything but the two known formatters belongs in `command`
  expect_config_error({ formatter = 1 }, 'formatter', 'gdscript-formatter')
  expect_config_error({ formatter = 'gdfromat' }, 'formatter', 'gdscript-formatter')
  expect_config_error({ formatter = true }, 'formatter', 'gdscript-formatter')

  expect_config_error({ command = 1 }, 'command', 'string')
  expect_config_error({ command = '' }, 'command', 'string')
  expect_config_error({ command = '   ' }, 'command', 'string')
  expect_config_error({ command = {} }, 'command', 'string')
  expect_config_error({ command = { 1 } }, 'command', 'string')

  expect_config_error({ autoformat = 'a' }, 'autoformat', 'boolean')

  expect_config_error({ indent = 'a' }, 'indent', 'number')
  expect_config_error({ indent = true }, 'indent', 'number')
  expect_config_error({ indent = 0 }, 'indent', 'number')
end

T['setup()']['accepts a turned-off formatter'] = function()
  unload_module()
  load_module({ formatter = false })
  eq(child.lua_get('GdevFormat.config.formatter'), false)
end

T['setup()']['indents buffers that are already open'] = function()
  -- Lazy-loaded setups run after the first Godot file is open, so those buffers
  -- never see the `FileType` event
  unload_module()
  child.cmd('edit tests/dir-format/script.gd')
  eq(child.bo.filetype, 'gdscript')
  eq(child.bo.shiftwidth, 0)

  -- Not the current buffer either, which is the usual state of the ones that
  -- were open before a lazy-loaded `setup()` ran
  child.lua('_G.buf = vim.api.nvim_get_current_buf()')
  child.cmd('enew')

  load_module({ indent = 2 })

  eq(child.lua_get('vim.bo[_G.buf].expandtab'), true)
  eq(child.lua_get('vim.bo[_G.buf].shiftwidth'), 2)
end

T['get_command()'] = new_set()

T['get_command()']['works'] = function()
  -- `--reorder-code` is what makes the default a formatter rather than a
  -- pretty-printer, so it is part of the default command line
  eq(child.lua_get('GdevFormat.get_command()'), { 'gdscript-formatter', '--reorder-code' })
end

T['get_command()']['respects `config.formatter`'] = new_set({
  parametrize = {
    { 'gdscript-formatter', { 'gdscript-formatter', '--reorder-code' } },
    -- `gdformat` has no equivalent of `--reorder-code`
    { 'gdformat', { 'gdformat' } },
    { false, vim.NIL },
  },
}, {
  test = function(formatter, expected)
    unload_module()
    load_module({ formatter = formatter })
    eq(child.lua_get('GdevFormat.get_command()'), expected)
  end,
})

T['get_command()']['respects `config.command`'] = new_set({
  parametrize = {
    { 'gdev-fake-formatter --check --quiet' },
    { { 'gdev-fake-formatter', '--check', '--quiet' } },
  },
}, {
  test = function(command)
    unload_module()
    load_module({ command = command })
    eq(child.lua_get('GdevFormat.get_command()'), { 'gdev-fake-formatter', '--check', '--quiet' })
  end,
})

T['get_command()']['lets `command` override a turned-off formatter'] = function()
  unload_module()
  load_module({ formatter = false, command = 'gdev-fake-formatter' })
  eq(child.lua_get('GdevFormat.get_command()'), { 'gdev-fake-formatter' })
end

T['get_command()']['respects `opts` argument'] = function()
  eq(child.lua_get('GdevFormat.get_command(0, { formatter = "gdformat" })'), { 'gdformat' })
end

T['get_command()']['respects `vim.b.gdevformat_config`'] = function()
  -- Read off the given buffer, which is not the current one here
  child.lua([[
    _G.buf = vim.api.nvim_create_buf(true, false)
    vim.b[_G.buf].gdevformat_config = { formatter = 'gdformat' }
  ]])

  eq(child.lua_get('GdevFormat.get_command(_G.buf)'), { 'gdformat' })
  eq(child.lua_get('GdevFormat.get_command()'), { 'gdscript-formatter', '--reorder-code' })
end

T['get_command()']['validates arguments'] = function()
  expect.error(function() child.lua('GdevFormat.get_command("a")') end, '`buf_id`.*valid buffer id')
end

T['get_command()']['keeps answering while disabled'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    -- `:checkhealth gdev` asks exactly when things are switched off
    child[var_type].gdevformat_disable = true
    eq(child.lua_get('GdevFormat.get_command()'), { 'gdscript-formatter', '--reorder-code' })
  end,
})

T['format()'] = new_set()

T['format()']['works'] = function()
  child.lua('_G.path = _G.new_script()')

  eq(child.lua_get('GdevFormat.format()'), true)
  wait_for('#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 1')

  -- The formatter rewrote the file and the buffer picked the result up
  eq(child.get_lines(), formatted_by('gdscript-formatter'))
  eq(child.lua_get('_G.argv()'), { 'gdscript-formatter', '--reorder-code', child.lua_get('_G.path') })
  eq(child.lua_get('_G.notifications'), {})
end

T['format()']['works on a non-current buffer'] = function()
  child.lua([[
    _G.path = _G.new_script()
    _G.buf = vim.api.nvim_get_current_buf()
    vim.cmd('enew')
  ]])

  eq(child.lua_get('GdevFormat.format(_G.buf)'), true)
  wait_for('#vim.api.nvim_buf_get_lines(_G.buf, 0, -1, false) > 1')

  eq(child.lua_get('vim.api.nvim_buf_get_lines(_G.buf, 0, -1, false)'), formatted_by('gdscript-formatter'))
end

T['format()']['respects `opts` argument'] = function()
  child.lua('_G.path = _G.new_script()')

  eq(child.lua_get('GdevFormat.format(0, { formatter = "gdformat" })'), true)
  wait_for('#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 1')

  eq(child.get_lines(), formatted_by('gdformat'))
  eq(child.lua_get('_G.argv()'), { 'gdformat', child.lua_get('_G.path') })
end

T['format()']['runs a `command` list verbatim'] = function()
  child.lua('_G.path = _G.new_script()')

  eq(child.lua_get('GdevFormat.format(0, { command = { "gdev-fake-formatter", "--check" } })'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), { 'gdev-fake-formatter', '--check', child.lua_get('_G.path') })
end

T['format()']['splits a `command` string'] = function()
  child.lua('_G.path = _G.new_script()')

  eq(child.lua_get('GdevFormat.format(0, { command = "gdev-fake-formatter  --check" })'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), { 'gdev-fake-formatter', '--check', child.lua_get('_G.path') })
end

T['format()']['reports what the formatter said'] = new_set({
  parametrize = {
    { { stderr = 'parse error on line 3' }, 'parse error on line 3' },
    -- Some formatters print their complaints on stdout
    { { stdout = 'nothing to do, badly' }, 'nothing to do, badly' },
    -- And some say nothing at all, which still has to reach the user
    { {}, 'gdev%-failing%-formatter` exited with 1' },
  },
}, {
  test = function(output, pattern)
    child.lua(
      [[
      vim.env.GDEV_FORMAT_STDERR = (...).stderr or ''
      vim.env.GDEV_FORMAT_STDOUT = (...).stdout or ''
      _G.new_script()
    ]],
      { output }
    )

    eq(child.lua_get('GdevFormat.format(0, { command = "gdev-failing-formatter" })'), true)
    wait_for('#_G.notifications > 0')

    eq(#child.lua_get('_G.notifications'), 1)
    expect.match(child.lua_get('_G.notifications[1].msg'), '^%(gdev%.format%) ')
    expect.match(child.lua_get('_G.notifications[1].msg'), pattern)
    eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))

    -- A failed run leaves the buffer alone
    eq(child.get_lines(), { 'extends Node' })
  end,
})

T['format()']['warns once about a formatter that is not installed'] = function()
  child.lua('_G.new_script()')

  eq(child.lua_get('GdevFormat.format(0, { command = "gdev-not-installed" })'), false)
  eq(child.lua_get('GdevFormat.format(0, { command = "gdev-not-installed" })'), false)

  -- Once, not once per save
  eq(#child.lua_get('_G.notifications'), 1)
  expect.match(child.lua_get('_G.notifications[1].msg'), 'gdev%-not%-installed')
  expect.match(child.lua_get('_G.notifications[1].msg'), 'checkhealth gdev')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.WARN'))
end

T['format()']['warns again after `setup()`'] = function()
  child.lua('_G.new_script()')
  child.lua('GdevFormat.format(0, { command = "gdev-not-installed" })')

  -- Re-configuring is the moment the missing formatter may have been installed
  load_module()
  child.lua('GdevFormat.format(0, { command = "gdev-not-installed" })')

  eq(#child.lua_get('_G.notifications'), 2)
end

T['format()']['does nothing when the formatter is turned off'] = function()
  unload_module()
  load_module({ formatter = false })
  child.lua('_G.new_script()')

  eq(child.lua_get('GdevFormat.format()'), false)

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.argv()'), {})
  eq(child.lua_get('_G.notifications'), {})
end

T['format()']['refuses a modified buffer'] = function()
  child.lua('_G.new_script()')
  child.set_lines({ 'extends Node', 'var unsaved = true' })

  -- Formatters rewrite files, so unsaved work would be formatted away
  eq(child.lua_get('GdevFormat.format()'), false)
  eq(child.lua_get('_G.argv()'), {})
  expect.match(child.lua_get('_G.notifications[1].msg'), 'unsaved changes')
end

T['format()']['ignores buffers with no file'] = function()
  eq(child.lua_get('GdevFormat.format(vim.api.nvim_create_buf(true, false))'), false)
  eq(child.lua_get('_G.argv()'), {})
end

T['format()']['validates arguments'] = function()
  expect.error(function() child.lua('GdevFormat.format("a")') end, '`buf_id`.*valid buffer id')
end

T['format()']['respects `vim.b.gdevformat_config`'] = function()
  child.lua('_G.path = _G.new_script()')
  child.b.gdevformat_config = { formatter = 'gdformat' }

  eq(child.lua_get('GdevFormat.format()'), true)
  wait_for('#_G.argv() > 0')

  eq(child.lua_get('_G.argv()'), { 'gdformat', child.lua_get('_G.path') })
end

T['format()']['respects `vim.{g,b}.gdevformat_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.new_script()')
    child[var_type].gdevformat_disable = true

    eq(child.lua_get('GdevFormat.format()'), false)

    helpers.sleep(pause, child)
    eq(child.lua_get('_G.argv()'), {})
  end,
})

-- Integration tests ==========================================================
T['BufWritePost'] = new_set()

T['BufWritePost']['formats Godot scripts on save'] = function()
  child.lua('_G.path = _G.new_script()')
  child.set_lines({ 'extends Node', 'var x = 1' })
  child.cmd('write')

  wait_for('vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] ~= "var x = 1"')

  eq(child.get_lines(), formatted_by('gdscript-formatter'))
  eq(child.lua_get('_G.argv()'), { 'gdscript-formatter', '--reorder-code', child.lua_get('_G.path') })
end

T['BufWritePost']['respects `config.autoformat`'] = function()
  unload_module()
  load_module({ autoformat = false })

  child.lua('_G.new_script()')
  child.cmd('write')

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.argv()'), {})
end

T['BufWritePost']['ignores buffers that are not Godot scripts'] = function()
  child.lua([[
    local path = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'return {}' }, path)
    vim.cmd('edit ' .. path)
  ]])
  eq(child.bo.filetype, 'lua')
  child.cmd('write')

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.argv()'), {})
end

T['BufWritePost']['respects `vim.b.gdevformat_config`'] = function()
  child.lua('_G.new_script()')
  child.b.gdevformat_config = { autoformat = false }
  child.cmd('write')

  helpers.sleep(pause, child)
  eq(child.lua_get('_G.argv()'), {})
end

T['BufWritePost']['respects `vim.{g,b}.gdevformat_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.new_script()')
    child[var_type].gdevformat_disable = true
    child.cmd('write')

    helpers.sleep(pause, child)
    eq(child.lua_get('_G.argv()'), {})
  end,
})

T[':GdevFormat'] = new_set()

T[':GdevFormat']['works when `autoformat` is off'] = function()
  unload_module()
  load_module({ autoformat = false })

  child.lua('_G.path = _G.new_script()')
  child.cmd('GdevFormat')
  wait_for('#vim.api.nvim_buf_get_lines(0, 0, -1, false) > 1')

  eq(child.get_lines(), formatted_by('gdscript-formatter'))
  eq(child.lua_get('_G.argv()'), { 'gdscript-formatter', '--reorder-code', child.lua_get('_G.path') })
end

T['FileType'] = new_set()

T['FileType']['leaves indentation to Neovim by default'] = function()
  child.cmd('edit tests/dir-format/script.gd')

  -- Neovim's bundled `gdscript` ftplugin sets tabs 4 columns wide, which is
  -- what Godot's editor and both formatters write
  eq(child.bo.expandtab, false)
  eq(child.bo.tabstop, 4)
  eq(child.bo.softtabstop, 0)
  eq(child.bo.shiftwidth, 0)
end

T['FileType']['applies `config.indent`'] = function()
  unload_module()
  load_module({ indent = 2 })

  child.cmd('edit tests/dir-format/script.gd')

  -- Registered after the bundled ftplugin, so this wins
  eq(child.bo.expandtab, true)
  eq(child.bo.tabstop, 2)
  eq(child.bo.softtabstop, 2)
  eq(child.bo.shiftwidth, 2)
end

T['FileType']['applies `config.indent` to hand-set filetypes'] = new_set({
  parametrize = { { 'gd' }, { 'gdscript' }, { 'gdscript3' } },
}, {
  test = function(filetype)
    unload_module()
    load_module({ indent = 3 })

    child.lua('_G.new_buffer(...)', { filetype })
    eq(child.bo.expandtab, true)
    eq(child.bo.shiftwidth, 3)
  end,
})

T['FileType']['stays out of other filetypes'] = function()
  unload_module()
  load_module({ indent = 3 })

  child.lua('_G.new_buffer("lua")')
  eq(child.bo.expandtab, false)
  expect.no_equality(child.bo.shiftwidth, 3)
end

T['FileType']['respects `vim.b.gdevformat_config`'] = function()
  child.lua([[
    vim.cmd('enew')
    vim.b.gdevformat_config = { indent = 3 }
    vim.bo.filetype = 'gdscript'
  ]])

  eq(child.bo.expandtab, true)
  eq(child.bo.shiftwidth, 3)
end

T['FileType']['respects `vim.{g,b}.gdevformat_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    unload_module()
    load_module({ indent = 2 })

    child.lua('vim.cmd("enew")')
    child[var_type].gdevformat_disable = true
    child.lua('vim.bo.filetype = "gdscript"')

    eq(child.bo.expandtab, false)
    eq(child.bo.shiftwidth, 0)
  end,
})

return T
