local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Data =======================================================================
-- Sections in the order `check()` reports them
local section_titles = {
  'Godot',
  'Plugin dependencies',
  'Godot editor connection',
  'Editor server',
  'Treesitter parsers',
  'GDScript formatter',
  'Godot class reference',
  'Scene tree',
}

-- Every module health reads, and the name it is reported under
local modules = { 'dap', 'docs', 'format', 'lsp', 'run', 'scenetree', 'server', 'treesitter' }

-- Fakes installed on $PATH unless a case wants one of them missing. Names map
-- to the script in 'tests/dir-health/bin' that answers for them.
local all_fakes = { nc = 'nc', godot = 'godot', curl = 'present', ['gdscript-formatter'] = 'present' }

-- Helpers with child processes ===============================================
local install_harness = function()
  child.lua(
    [[
    local module_names = ...

    -- Findings are recorded off `vim.health` rather than scraped out of the
    -- report buffer, because the level is the part worth asserting -- a soft
    -- dependency reported as an error would be a real defect -- and the buffer
    -- only carries it as an emoji. Installed by `_G.report()` rather than here,
    -- so `:checkhealth` still runs against the real thing.
    _G.calls = {}
    local record = function(level)
      return function(msg, advice) table.insert(_G.calls, { level = level, msg = msg, advice = advice }) end
    end
    _G.recorder = {
      start = record('start'),
      ok = record('ok'),
      warn = record('warn'),
      error = record('error'),
      info = record('info'),
    }

    -- `gdev.dap` warns during `setup()` when nvim-dap is absent, which is not
    -- what this suite is looking at
    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end

    local fake_bin = vim.fn.fnamemodify('tests/dir-health/bin', ':p')

    -- $PATH is replaced rather than prepended to, so "not installed" stays
    -- testable on a machine that has the real thing -- and this one does have a
    -- Godot editor listening on 6005 from time to time.
    _G.set_path = function(fakes)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      for name, fake in pairs(fakes) do
        vim.uv.fs_symlink(vim.fs.joinpath(fake_bin, fake), vim.fs.joinpath(dir, name))
      end
      vim.env.PATH = dir
    end

    -- Set up explicitly per case rather than in `pre_case`: what health reports
    -- for a module that was never set up is half of what it does. A `false`
    -- entry leaves that module alone.
    _G.setup = function(configs)
      configs = configs or {}
      for _, name in ipairs(module_names) do
        if configs[name] ~= false then require('gdev.' .. name).setup(configs[name]) end
      end
    end

    _G.report = function()
      _G.calls = {}
      vim.health = _G.recorder
      require('gdev.health').check()
      return _G.calls
    end
  ]],
    { modules }
  )
end

local set_path = function(fakes) child.lua('_G.set_path(...)', { fakes or all_fakes }) end

local set_path_without = function(name)
  local fakes = vim.deepcopy(all_fakes)
  fakes[name] = nil
  child.lua('_G.set_path(...)', { fakes })
end

local set_env = function(vars) child.lua('for k, v in pairs(...) do vim.env[k] = v end', { vars }) end

local setup_modules = function(configs) child.lua('_G.setup(...)', { configs or {} }) end

local report = function() return child.lua_get('_G.report()') end

-- Report assertions ==========================================================
local matching = function(calls, level, pattern)
  local found = {}
  for _, call in ipairs(calls) do
    if call.level == level and call.msg:find(pattern) ~= nil then table.insert(found, call) end
  end
  return found
end

local describe_report = function(calls)
  local lines = {}
  for _, call in ipairs(calls) do
    table.insert(lines, string.format('%-5s %s', call.level, (call.msg:gsub('\n', ' | '))))
  end
  return table.concat(lines, '\n')
end

local expect_finding = MiniTest.new_expectation(
  'health finding',
  function(calls, level, pattern) return #matching(calls, level, pattern) == 1 end,
  function(calls, level, pattern)
    return string.format('Exactly one %s matching %s\nReport:\n%s', level, vim.inspect(pattern), describe_report(calls))
  end
)

local expect_no_finding = MiniTest.new_expectation(
  'no health finding',
  function(calls, level, pattern) return #matching(calls, level, pattern) == 0 end,
  function(calls, level, pattern)
    return string.format('No %s matching %s\nReport:\n%s', level, vim.inspect(pattern), describe_report(calls))
  end
)

local advice_of = function(calls, level, pattern)
  expect_finding(calls, level, pattern)
  return table.concat(matching(calls, level, pattern)[1].advice or {}, '\n')
end

local titles_of = function(calls)
  local titles = {}
  for _, call in ipairs(calls) do
    if call.level == 'start' then table.insert(titles, call.msg) end
  end
  return titles
end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      install_harness()
      set_path()
      set_env({ GDEV_HEALTH_VERSION = '4.5.stable.official.deadbee', GDEV_HEALTH_OPEN_PORTS = '' })
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['check()'] = new_set()

T['check()']['reports every section'] = function()
  setup_modules()
  eq(titles_of(report()), section_titles)
end

T['check()']['reports every section without any module set up'] = function() eq(titles_of(report()), section_titles) end

T['check()']['reports modules that were never set up'] = function()
  local calls = report()

  for _, name in ipairs(modules) do
    expect_finding(calls, 'info', vim.pesc('`gdev.' .. name .. '` is not set up'))
  end

  -- Nothing configured is not an error, and must not read like one
  expect_no_finding(calls, 'error', '.')
end

T['check()']['survives a module whose query raises'] = function()
  setup_modules()
  child.lua([[GdevRun.status = function() error('boom') end]])

  local calls = report()
  expect_finding(calls, 'error', vim.pesc('`GdevRun.status()` raised'))

  -- Every later section still runs
  eq(titles_of(calls), section_titles)
end

-- Sections ===================================================================
T['Godot'] = new_set()

T['Godot']['reports the version'] = new_set({
  parametrize = { { '4.5.stable.official.deadbee' }, { '4.3.stable' }, { '4.4.1.stable' } },
}, {
  test = function(version)
    setup_modules()
    set_env({ GDEV_HEALTH_VERSION = version })

    local calls = report()
    expect_finding(calls, 'ok', vim.pesc('Godot ' .. version))
    expect_no_finding(calls, 'warn', 'older than 4%.3')
  end,
})

T['Godot']['warns below 4.3'] = new_set({
  parametrize = { { '4.2.stable' }, { '4.0.beta1' }, { '3.5.stable' } },
}, {
  test = function(version)
    setup_modules()
    set_env({ GDEV_HEALTH_VERSION = version })

    local calls = report()
    expect_finding(calls, 'ok', vim.pesc('Godot ' .. version))
    expect_finding(calls, 'warn', 'older than 4%.3')
  end,
})

T['Godot']['reports a missing executable'] = function()
  setup_modules()
  set_path_without('godot')

  local calls = report()
  expect_finding(calls, 'error', vim.pesc('Godot executable `godot` not found'))
  expect.match(advice_of(calls, 'error', 'not found'), 'gdvm')
  expect_no_finding(calls, 'ok', '^Godot %d')
end

T['Godot']['warns when the executable does not answer'] = function()
  setup_modules()
  set_env({ GDEV_HEALTH_EXIT = '1' })

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc('`godot --version` did not answer'))
  expect_no_finding(calls, 'ok', '^Godot %d')
end

-- `executable()` sees the execute bit and nothing else, so an existing wrapper
-- whose interpreter is missing gets that far and then raises out of
-- `vim.system()`. A health check that raises loses every section after it.
T['Godot']['warns when the executable cannot be spawned'] = function()
  setup_modules()
  set_path({ nc = 'nc', godot = 'unrunnable' })

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc('`godot --version` did not answer'))
  eq(titles_of(calls), section_titles)
end

T['Godot']['skips the version check on unreadable output'] = function()
  setup_modules()
  set_env({ GDEV_HEALTH_VERSION = 'gdvm: using godot 4.2' })

  local calls = report()
  expect_finding(calls, 'ok', vim.pesc('Godot gdvm: using godot 4.2'))
  expect_finding(calls, 'info', vim.pesc('the 4.3 check was skipped'))
  expect_no_finding(calls, 'warn', 'older than 4%.3')
end

T['Godot']['reports the project root'] = function()
  setup_modules()
  child.lua([[vim.fn.chdir('tests/dir-health/project')]])

  expect_finding(report(), 'info', vim.pesc('Project root: ') .. '.*' .. vim.pesc('dir-health/project'))
end

T['Godot']['reports no project root outside a project'] = function()
  setup_modules()
  expect_finding(report(), 'info', vim.pesc('no `project.godot` above the working directory'))
end

T['Godot']['respects `GdevRun.config.godot`'] = function()
  setup_modules({ run = { godot = 'godot-wrapper' } })
  set_path({ nc = 'nc', ['godot-wrapper'] = 'godot' })

  expect_finding(report(), 'ok', vim.pesc('Godot 4.5.stable.official.deadbee'))
end

T['Plugin dependencies'] = new_set()

T['Plugin dependencies']['warns rather than errors when they are missing'] = function()
  setup_modules()

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc("'nvim-dap' is not installed"))
  expect_finding(calls, 'warn', vim.pesc("'nvim-dap-ui' is not installed"))

  -- Soft dependencies: reporting either as an error would be the defect
  expect_no_finding(calls, 'error', 'nvim%-dap')
  expect.match(advice_of(calls, 'warn', "'nvim%-dap' is not installed"), 'mfussenegger/nvim%-dap')
end

T['Plugin dependencies']['reports an installed dependency'] = function()
  child.cmd('set rtp+=deps/nvim-dap')
  setup_modules()

  local calls = report()
  expect_finding(calls, 'ok', vim.pesc("'nvim-dap' is installed"))
  expect_finding(calls, 'warn', vim.pesc("'nvim-dap-ui' is not installed"))
end

T['Godot editor connection'] = new_set()

T['Godot editor connection']['probes both ports'] = function()
  setup_modules()
  set_env({ GDEV_HEALTH_OPEN_PORTS = '6005' })

  local calls = report()
  expect_finding(calls, 'ok', vim.pesc('Godot editor language server answers on 127.0.0.1:6005'))
  expect_finding(calls, 'warn', vim.pesc('Nothing answers on 127.0.0.1:6006'))
  expect.match(advice_of(calls, 'warn', 'Nothing answers on 127.0.0.1:6006'), 'Debug Adapter')
end

T['Godot editor connection']['skips the probes without a prober'] = function()
  setup_modules()
  set_path_without('nc')

  local calls = report()
  expect_finding(calls, 'info', vim.pesc("'nc' is not installed"))
  expect_finding(calls, 'info', vim.pesc('Godot editor language server expected at 127.0.0.1:6005'))
  expect_finding(calls, 'info', vim.pesc('Godot editor debug adapter expected at 127.0.0.1:6006'))

  -- A guess either way would send someone looking for a setting that is fine
  expect_no_finding(calls, 'ok', '600[56]')
  expect_no_finding(calls, 'warn', '600[56]')
end

T['Godot editor connection']['respects the configured ports'] = function()
  setup_modules({ lsp = { port = 7005 }, dap = { port = 7006 } })
  set_env({ GDEV_HEALTH_OPEN_PORTS = '7006' })

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc('Nothing answers on 127.0.0.1:7005'))
  expect_finding(calls, 'ok', vim.pesc('Godot editor debug adapter answers on 127.0.0.1:7006'))

  -- Each port is named after the Godot setting that moves it, not the other one
  expect.match(advice_of(calls, 'warn', '7005'), 'Language Server matches port 7005')
end

T['Godot editor connection']['reports each module separately'] = function()
  setup_modules({ dap = false })
  set_env({ GDEV_HEALTH_OPEN_PORTS = '6005' })

  local calls = report()
  expect_finding(calls, 'ok', vim.pesc('Godot editor language server answers on 127.0.0.1:6005'))
  expect_finding(calls, 'info', vim.pesc('`gdev.dap` is not set up'))
  expect_no_finding(calls, 'warn', '6006')
end

T['Editor server'] = new_set()

T['Editor server']['reports a listening address'] = function()
  setup_modules()

  local calls = report()
  local address = child.lua_get('GdevServer.status().address')
  expect_finding(calls, 'ok', vim.pesc('Neovim is listening on ' .. address))
  expect_finding(calls, 'info', vim.pesc('--server ' .. address .. ' --remote {file}'))
end

T['Editor server']['warns when nothing is listening'] = function()
  setup_modules({ server = { address = '/tmp/gdev-health-not-listening' } })

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc('Neovim is not listening on /tmp/gdev-health-not-listening'))
  expect.match(advice_of(calls, 'warn', 'not listening'), 'GdevServerStart')
end

T['Treesitter parsers'] = new_set()

T['Treesitter parsers']['names every missing parser'] = function()
  setup_modules()

  -- No Godot parser is installed in the child, and none can be faked: the
  -- loader looks for a `tree_sitter_<lang>` symbol
  local calls = report()
  expect_finding(calls, 'warn', vim.pesc("No 'gdscript' parser, so gdscript files"))
  expect_finding(calls, 'warn', vim.pesc("No 'gdshader' parser, so gdshader files"))
  expect_finding(calls, 'warn', vim.pesc("No 'gdresource' parser, so gdresource files"))
  expect.match(advice_of(calls, 'warn', "'gdscript' parser"), 'TSInstall')

  -- A report whose lines move around between runs is a worse report
  local parsers = {}
  for _, call in ipairs(matching(calls, 'warn', 'parser')) do
    table.insert(parsers, call.msg:match("No '([%w_]+)' parser"))
  end
  eq(parsers, { 'gdresource', 'gdscript', 'gdshader' })
end

T['Treesitter parsers']['reports installed parsers'] = function()
  setup_modules()

  -- Driven through the query contract health consumes, since a real parser
  -- cannot be faked
  child.lua([[
    GdevTreesitter.parser_status = function()
      return {
        gdscript = { lang = 'gdscript', available = true },
        gdresource = { lang = 'godot_resource', available = true },
        gdshader = { lang = 'gdshader', available = false },
      }
    end
  ]])

  local calls = report()
  expect_finding(calls, 'ok', vim.pesc("'gdscript' parser found, used for gdscript files"))
  expect_finding(calls, 'ok', vim.pesc("'godot_resource' parser found, used for gdresource files"))
  expect_finding(calls, 'warn', vim.pesc("No 'gdshader' parser"))
end

T['GDScript formatter'] = new_set()

T['GDScript formatter']['reports the resolved command'] = function()
  setup_modules()

  local calls = report()
  expect_finding(calls, 'info', vim.pesc('Command: gdscript-formatter --reorder-code <file>'))
  expect_finding(calls, 'ok', vim.pesc("'gdscript-formatter' found"))
end

T['GDScript formatter']['warns about a missing formatter'] = new_set({
  parametrize = { { 'gdscript-formatter', 'GDQuest' }, { 'gdformat', 'gdtoolkit' } },
}, {
  test = function(formatter, pointer)
    setup_modules({ format = { formatter = formatter } })
    set_path_without('gdscript-formatter')

    local calls = report()
    expect_finding(calls, 'warn', vim.pesc(("'%s' not found"):format(formatter)))
    expect.match(advice_of(calls, 'warn', 'not found'), pointer)
  end,
})

T['GDScript formatter']['reports formatting turned off'] = function()
  setup_modules({ format = { formatter = false } })

  local calls = report()
  expect_finding(calls, 'info', vim.pesc('Formatting is turned off'))
  expect_no_finding(calls, 'warn', 'not found, so nothing will be formatted')
end

T['GDScript formatter']['respects a `command` override'] = function()
  setup_modules({ format = { command = { 'my-formatter', '--in-place' } } })
  set_path({ nc = 'nc', godot = 'godot', ['my-formatter'] = 'present' })

  local calls = report()
  expect_finding(calls, 'info', vim.pesc('Command: my-formatter --in-place <file>'))
  expect_finding(calls, 'ok', vim.pesc("'my-formatter' found"))
end

T['GDScript formatter']['points an unknown formatter at $PATH'] = function()
  setup_modules({ format = { command = 'my-formatter' } })
  set_path_without('gdscript-formatter')

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc("'my-formatter' not found"))
  expect.match(advice_of(calls, 'warn', 'not found'), '%$PATH')
end

T['Godot class reference'] = new_set()

T['Godot class reference']['reports renderer, source and cache'] = function()
  setup_modules()

  local calls = report()
  expect_finding(calls, 'info', vim.pesc('Renderer: float (fallback: browser)'))
  expect_finding(calls, 'info', vim.pesc('Source: https://raw.githubusercontent.com/godotengine/godot-docs/master'))
  expect_finding(calls, 'info', vim.pesc('Website: https://docs.godotengine.org/en/stable'))
  expect_finding(calls, 'info', vim.pesc('Cache: 0 of 64 pages'))
  expect_finding(calls, 'ok', vim.pesc("'curl' found"))
end

T['Godot class reference']['warns about a missing fetcher'] = function()
  setup_modules()
  set_path_without('curl')

  local calls = report()
  expect_finding(calls, 'warn', vim.pesc("'curl' not found, so the 'float' renderer cannot fetch a page"))
  expect_no_finding(calls, 'ok', 'curl')
end

T['Godot class reference']['needs no fetcher for the browser renderer'] = function()
  setup_modules({ docs = { renderer = 'browser' } })
  set_path_without('curl')

  local calls = report()
  expect_finding(calls, 'info', vim.pesc("The 'browser' renderer fetches nothing"))
  expect_no_finding(calls, 'warn', 'curl')
end

T['Godot class reference']['reports a disabled cache'] = function()
  setup_modules({ docs = { cache = { enabled = false } } })
  expect_finding(report(), 'info', vim.pesc('Cache: disabled'))
end

T['Scene tree'] = new_set()

T['Scene tree']['warns about Nerd Font icons'] = function()
  setup_modules()

  local calls = report()
  expect_finding(calls, 'info', vim.pesc('Node icons: nerdfont'))
  expect_finding(calls, 'warn', vim.pesc('Node icons are Nerd Font glyphs, which need a patched font'))
  expect.match(advice_of(calls, 'warn', 'Nerd Font'), vim.pesc('icons = "ascii"'))
end

T['Scene tree']['reports other icon styles'] = new_set({
  parametrize = { { 'ascii', 'ascii' }, { false, 'off' }, { { types = { Node = '#' } }, 'table' } },
}, {
  test = function(icons, reported)
    setup_modules({ scenetree = { icons = icons } })

    local calls = report()
    expect_finding(calls, 'info', vim.pesc('Node icons: ' .. reported))
    expect_no_finding(calls, 'warn', 'Nerd Font')
  end,
})

T['Scene tree']['reports an open pane'] = function()
  setup_modules()
  child.lua([[vim.fn.chdir('tests/dir-scenetree/project')]])
  child.lua([[GdevScenetree.open('res://Flat.tscn')]])

  expect_finding(report(), 'info', vim.pesc('Pane is open, showing res://Flat.tscn'))
end

-- Integration tests ==========================================================
T[':checkhealth gdev'] = new_set()

T[':checkhealth gdev']['finds and runs the module'] = function()
  setup_modules()
  child.cmd('checkhealth gdev')

  local report_text = table.concat(child.get_lines(), '\n')
  for _, title in ipairs(section_titles) do
    expect.match(report_text, vim.pesc(title) .. ' ~')
  end

  -- The report has to be produced by us, not by checkhealth's own failure paths
  expect.no_match(report_text, 'Failed to run healthcheck')
  expect.no_match(report_text, 'ERROR')
end

return T
