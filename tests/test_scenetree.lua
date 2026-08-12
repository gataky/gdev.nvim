local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config) child.gdev_load('scenetree', config) end
local unload_module = function() child.gdev_unload('scenetree') end
local type_keys = function(...) return child.type_keys(...) end

-- Everything the pane does is asserted through the buffer, the window and the
-- extmarks it creates; the module's own state is private.
local install_fixtures = function()
  child.lua([[
    _G.root = vim.fs.normalize(vim.fn.fnamemodify('tests/dir-scenetree/project', ':p'))
    _G.open = function(relative) vim.cmd('edit tests/dir-scenetree/project/' .. relative) end

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

    _G.pane_buf = function()
      for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf_id) == 'gdev://scene-tree' then return buf_id end
      end
    end
    _G.pane_win = function()
      local buf_id = _G.pane_buf()
      for _, win_id in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win_id) == buf_id then return win_id end
      end
    end
    _G.other_win = function()
      local pane_win = _G.pane_win()
      for _, win_id in ipairs(vim.api.nvim_list_wins()) do
        if win_id ~= pane_win then return win_id end
      end
    end
    _G.lines = function()
      local buf_id = _G.pane_buf()
      return buf_id == nil and {} or vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
    end

    -- Highlighting is icon-only, so a span is only ever part of a line
    _G.marks = function()
      local buf_id, out = _G.pane_buf(), {}
      if buf_id == nil then return out end

      local ns_id = vim.api.nvim_get_namespaces()['GdevScenetree']
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf_id, ns_id, 0, -1, { details = true })) do
        local details = mark[4]
        table.insert(out, {
          line = mark[2] + 1,
          end_line = details.end_row + 1,
          col = mark[3],
          end_col = details.end_col,
          group = details.hl_group,
        })
      end
      return out
    end
    _G.groups = function()
      return vim.tbl_map(function(mark) return mark.group end, _G.marks())
    end
  ]])
end

local root = function() return child.lua_get('_G.root') end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.set_size(24, 80)
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
  eq(child.lua_get('type(_G.GdevScenetree)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#GdevScenetree'), 1)

  -- User commands
  eq(child.fn.exists(':GdevScenetree'), 2)
  eq(child.fn.exists(':GdevScenetreeRefresh'), 2)

  -- Highlight groups
  child.cmd('hi clear')
  load_module()
  expect.match(child.cmd_capture('hi GdevScenetreeHeader'), 'links to Title')
  expect.match(child.cmd_capture('hi GdevScenetreeIcon'), 'links to Normal')
  expect.match(child.cmd_capture('hi GdevScenetreeIconRed'), 'links to DiagnosticError')
  expect.match(child.cmd_capture('hi GdevScenetreeIconGrey'), 'links to Comment')
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevScenetree.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevScenetree.config.buffer'), { position = 'left', size = 0.35 })
  eq(child.lua_get('GdevScenetree.config.icons'), 'nerdfont')
  eq(child.lua_get('GdevScenetree.config.icon_colors.generic'), 'Normal')
  eq(child.lua_get('GdevScenetree.config.icon_colors.groups'), {
    White = 'Normal',
    Grey = 'Comment',
    Blue = 'DiagnosticInfo',
    Red = 'DiagnosticError',
    Green = 'DiagnosticOk',
    Purple = 'Constant',
    Yellow = 'DiagnosticWarn',
  })
  eq(child.lua_get('GdevScenetree.config.mappings'), {
    jump = '<CR>',
    yank = 'y',
    script = 'g',
    refresh = 'r',
    close = 'q',
  })
  eq(child.lua_get('GdevScenetree.config.script_extensions'), { 'gd' })
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  -- Highlight groups are created with `default = true`, so the ones the first
  -- `setup()` defined would otherwise survive this one
  child.cmd('hi clear')
  load_module({
    buffer = { position = 'right', size = 0.5 },
    icons = 'ascii',
    icon_colors = { generic = { fg = '#ff0000' }, groups = { Blue = 'Question' } },
    mappings = { close = 'x' },
    script_extensions = { 'gd', 'cs' },
  })

  eq(child.lua_get('GdevScenetree.config.buffer'), { position = 'right', size = 0.5 })
  eq(child.lua_get('GdevScenetree.config.icons'), 'ascii')
  eq(child.lua_get('GdevScenetree.config.icon_colors.groups.Blue'), 'Question')
  -- Untouched keys keep their defaults
  eq(child.lua_get('GdevScenetree.config.icon_colors.groups.Red'), 'DiagnosticError')
  eq(child.lua_get('GdevScenetree.config.mappings.close'), 'x')
  eq(child.lua_get('GdevScenetree.config.mappings.jump'), '<CR>')
  eq(child.lua_get('GdevScenetree.config.script_extensions'), { 'gd', 'cs' })

  expect.match(child.cmd_capture('hi GdevScenetreeIconBlue'), 'links to Question')
  expect.match(child.cmd_capture('hi GdevScenetreeIcon'), 'ff0000')
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function() load_module(config) end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')

  expect_config_error({ buffer = 'a' }, 'buffer', 'table')
  expect_config_error({ buffer = { position = 'top' } }, 'buffer.position', 'left')
  expect_config_error({ buffer = { position = 1 } }, 'buffer.position', 'left')
  expect_config_error({ buffer = { size = 'a' } }, 'buffer.size', 'number')
  expect_config_error({ buffer = { size = 0 } }, 'buffer.size', 'number')
  expect_config_error({ buffer = { size = 1.5 } }, 'buffer.size', 'number')

  expect_config_error({ icons = 1 }, 'icons', 'table')
  expect_config_error({ icons = 'emoji' }, 'icons', 'table')
  expect_config_error({ icons = true }, 'icons', 'table')

  expect_config_error({ icon_colors = 'a' }, 'icon_colors', 'table')
  expect_config_error({ icon_colors = { generic = 1 } }, 'icon_colors.generic', 'string')
  expect_config_error({ icon_colors = { groups = 'a' } }, 'icon_colors.groups', 'table')
  expect_config_error({ icon_colors = { groups = { Blue = 1 } } }, 'icon_colors.groups.Blue', 'string')

  expect_config_error({ mappings = 'a' }, 'mappings', 'table')
  expect_config_error({ mappings = { jump = 1 } }, 'mappings.jump', 'string')
  expect_config_error({ mappings = { close = false } }, 'mappings.close', 'string')

  expect_config_error({ script_extensions = 'gd' }, 'script_extensions', 'table')
end

T['setup()']['accepts `icons = false`'] = function()
  unload_module()
  load_module({ icons = false })
  eq(child.lua_get('GdevScenetree.config.icons'), false)
end

T['get_nodes()'] = new_set()

T['get_nodes()']['parses a flat scene'] = function()
  child.lua('_G.open("Flat.tscn")')

  eq(child.lua_get('GdevScenetree.get_nodes("res://Flat.tscn")'), {
    { name = 'Main', type = 'Node2D', path = '.', depth = 0, line = 3 },
    { name = 'Camera', type = 'Camera2D', parent = '.', path = 'Camera', depth = 1, line = 5 },
    { name = 'Sprite', type = 'Sprite2D', parent = '.', path = 'Sprite', depth = 1, line = 7 },
  })
end

T['get_nodes()']['parses a nested scene'] = function()
  child.lua('_G.open("Flat.tscn")')
  local nodes = child.lua_get('GdevScenetree.get_nodes("res://scenes/Nested.tscn")')

  eq(vim.tbl_map(function(node) return node.path end, nodes), {
    '.',
    'Player',
    'Player/Body',
    'Player/Weapon',
    'Player/Weapon/Tip',
    'Ui',
    'Ui/Score',
  })
  eq(vim.tbl_map(function(node) return node.depth end, nodes), { 0, 1, 2, 2, 3, 1, 2 })
  -- Line numbers point at the `[node ...]` header, not the properties under it
  eq(vim.tbl_map(function(node) return node.line end, nodes), { 3, 5, 8, 10, 12, 14, 16 })
end

T['get_nodes()']['resolves attached scripts through `ext_resource`'] = function()
  child.lua('_G.open("Flat.tscn")')
  local nodes = child.lua_get('GdevScenetree.get_nodes("res://scenes/Scripted.tscn")')

  -- Both `[ext_resource]` spellings Godot 4 writes: with and without a `uid`
  eq(nodes[1].script, 'res://scripts/shared.gd')
  eq(nodes[2].script, 'res://scripts/player.gd')

  -- `death_script` is an exported property of the third node pointing at a
  -- resource of its own, not the script attached to it
  eq(child.lua_get('GdevScenetree.get_nodes("res://scenes/Scripted.tscn")[3].script'), vim.NIL)
end

T['get_nodes()']['parses an instanced scene'] = function()
  child.lua('_G.open("Flat.tscn")')
  local nodes = child.lua_get('GdevScenetree.get_nodes("res://scenes/Instanced.tscn")')

  -- `instance=ExtResource("id")` is unquoted, so it is resolved on its own
  -- rather than read as an attribute
  eq(nodes[2].name, 'Hero')
  eq(nodes[2].instance, 'res://Flat.tscn')
  eq(nodes[2].type, 'PackedScene')

  -- A node that only overrides properties of one inside the instance: its type
  -- lives in the other file, so this scene does not state one
  eq(nodes[3].name, 'Camera')
  eq(child.lua_get('GdevScenetree.get_nodes("res://scenes/Instanced.tscn")[3].type'), vim.NIL)
  eq(nodes[3].path, 'Hero/Camera')
  eq(nodes[3].depth, 2)
end

T['get_nodes()']['ends a node at the next section'] = function()
  -- A `script` property below a later section belongs to that section. Godot
  -- writes sub-resources above the nodes, but nothing about the format says a
  -- generated or hand-edited scene has to.
  child.lua('_G.open("Flat.tscn")')
  local nodes = child.lua_get('GdevScenetree.get_nodes("res://scenes/Trailing.tscn")')

  eq(#nodes, 1)
  eq(nodes[1].script, nil)
end

T['get_nodes()']['answers for a scene with no nodes'] = function()
  child.lua('_G.open("Flat.tscn")')
  eq(child.lua_get('GdevScenetree.get_nodes("res://scenes/Empty.tscn")'), {})
end

T['get_nodes()']['accepts every spelling of a scene inside the project'] = new_set({
  parametrize = {
    { '"res://scenes/Nested.tscn"' },
    { '"scenes/Nested.tscn"' },
    { '_G.root .. "/scenes/Nested.tscn"' },
  },
}, {
  test = function(argument)
    child.lua('_G.open("Flat.tscn")')
    eq(#child.lua_get('GdevScenetree.get_nodes(' .. argument .. ')'), 7)
  end,
})

T['get_nodes()']['is empty for anything it cannot read'] = new_set({
  parametrize = { { '"res://nope.tscn"' }, { '"../outside.tscn"' }, { '"res://../outside.tscn"' } },
}, {
  test = function(argument)
    child.lua('_G.open("Flat.tscn")')
    eq(child.lua_get('GdevScenetree.get_nodes(' .. argument .. ')'), {})
    eq(child.lua_get('_G.notifications'), {})
  end,
})

T['get_nodes()']['answers for the pane with no argument'] = function()
  child.lua('_G.open("scenes/Nested.tscn")')
  eq(child.lua_get('GdevScenetree.get_nodes()'), {})

  child.lua('GdevScenetree.open()')
  eq(#child.lua_get('GdevScenetree.get_nodes()'), 7)
end

T['get_nodes()']['validates arguments'] = function()
  expect.error(function() child.lua('GdevScenetree.get_nodes(1)') end, vim.pesc('`scene` should be string'))
end

T['get_nodes()']['keeps answering while disabled'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Flat.tscn")')
    child[var_type].gdevscenetree_disable = true

    eq(#child.lua_get('GdevScenetree.get_nodes("res://Flat.tscn")'), 3)
  end,
})

T['status()'] = new_set()

T['status()']['works'] = function()
  child.lua('_G.open("Flat.tscn")')
  eq(child.lua_get('GdevScenetree.status()'), { root = root(), open = false, icons = 'nerdfont' })

  child.lua('GdevScenetree.open()')
  eq(child.lua_get('GdevScenetree.status()'), {
    root = root(),
    scene = 'res://Flat.tscn',
    open = true,
    icons = 'nerdfont',
  })
end

T['status()']['reports a pane closed from outside'] = function()
  -- `:q` or `:only` in the pane window leaves this module's handle stale
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  child.lua('vim.api.nvim_win_close(_G.pane_win(), true)')

  eq(child.lua_get('GdevScenetree.status().open'), false)
  -- The scene survives the window, which is what a refresh reopens
  eq(child.lua_get('GdevScenetree.status().scene'), 'res://Flat.tscn')
end

T['status()']['omits a root it cannot find'] = function()
  child.lua([[vim.fn.chdir('tests/dir-format')]])
  eq(child.lua_get('GdevScenetree.status().root'), vim.NIL)
end

T['status()']['reports the resolved icon style'] = new_set({
  parametrize = { { 'false', false }, { '"ascii"', 'ascii' }, { '{ generic = "#" }', 'table' } },
}, {
  test = function(argument, reported)
    eq(child.lua_get('GdevScenetree.status({ icons = ' .. argument .. ' }).icons'), reported)
  end,
})

T['status()']['opens nothing'] = function()
  child.lua('_G.open("Flat.tscn")')
  child.lua('GdevScenetree.status()')

  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
  eq(child.lua_get('_G.pane_buf()'), vim.NIL)
end

T['status()']['respects `vim.b.gdevscenetree_config`'] = function()
  child.b.gdevscenetree_config = { icons = 'ascii' }
  eq(child.lua_get('GdevScenetree.status().icons'), 'ascii')
end

T['status()']['keeps answering while disabled'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    -- `:checkhealth gdev` asks exactly when things are switched off
    child.lua('_G.open("Flat.tscn")')
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.status()'), { root = root(), open = false, icons = 'nerdfont' })
  end,
})

T['open()'] = new_set()

T['open()']['shows the scene in the buffer'] = function()
  child.lua('_G.open("Flat.tscn")')

  eq(child.lua_get('GdevScenetree.open()'), true)
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://Flat.tscn')
  eq(#child.lua_get('_G.lines()'), 4)
end

T['open()']['accepts every spelling of a scene inside the project'] = new_set({
  parametrize = {
    { '"res://scenes/Nested.tscn"' },
    { '"scenes/Nested.tscn"' },
    { '_G.root .. "/scenes/Nested.tscn"' },
  },
}, {
  test = function(argument)
    child.lua('_G.open("Flat.tscn")')

    eq(child.lua_get('GdevScenetree.open(' .. argument .. ')'), true)
    eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Nested.tscn')
  end,
})

T['open()']['rejects a scene outside the project'] = new_set({
  parametrize = { { '"../outside.tscn"' }, { '"res://../outside.tscn"' } },
}, {
  test = function(argument)
    child.lua('_G.open("Flat.tscn")')

    eq(child.lua_get('GdevScenetree.open(' .. argument .. ')'), false)
    expect.match(child.lua_get('_G.last_message()'), 'is not inside ')
    eq(child.lua_get('_G.pane_buf()'), vim.NIL)
  end,
})

T['open()']['reports a scene that does not exist'] = function()
  child.lua('_G.open("Flat.tscn")')

  eq(child.lua_get('GdevScenetree.open("res://nope.tscn")'), false)
  expect.match(child.lua_get('_G.last_message()'), 'res://nope%.tscn is not a readable scene file')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))
end

T['open()']['shows the only scene using the script'] = function()
  child.lua('_G.open("scripts/player.gd")')

  eq(child.lua_get('GdevScenetree.open()'), true)
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Scripted.tscn')
  eq(child.lua_get('_G.selected'), vim.NIL)
end

T['open()']['asks which scene when several use the script'] = function()
  child.lua('_G.open("scripts/shared.gd"); _G.choice = 2')

  eq(child.lua_get('GdevScenetree.open()'), true)
  eq(child.lua_get('_G.selected.items'), { 'res://scenes/Scripted.tscn', 'res://scenes/Shared.tscn' })
  expect.match(child.lua_get('_G.selected.prompt'), 'res://scripts/shared%.gd')
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Shared.tscn')
end

T['open()']['shows nothing when the picker is dismissed'] = function()
  child.lua('_G.open("scripts/shared.gd")')

  eq(child.lua_get('GdevScenetree.open()'), true)
  eq(child.lua_get('_G.pane_buf()'), vim.NIL)
end

T['open()']['reports a script no scene uses'] = function()
  child.lua('_G.open("scripts/orphan.gd")')

  eq(child.lua_get('GdevScenetree.open()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'no scene in .* uses res://scripts/orphan%.gd')
end

T['open()']['reports a buffer that is neither'] = function()
  child.lua('_G.open("project.godot")')

  eq(child.lua_get('GdevScenetree.open()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'project%.godot is neither a scene nor a Godot script')
end

T['open()']['reports a buffer with no file'] = function()
  child.lua([[vim.fn.chdir('tests/dir-scenetree/project')]])

  eq(child.lua_get('GdevScenetree.open()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'has no file')
end

T['open()']['ignores a buffer that is not a file'] = function()
  -- A scratch, terminal or help buffer carries a name that is not a path.
  -- Searching upward from `gdev://not-a-file` walks a relative `gdev:/` and
  -- stops at the working directory, never reaching the project above it -- so
  -- the report has to be about the buffer, not about a project it did find.
  child.lua([[
    vim.fn.chdir('tests/dir-scenetree/project/scenes')
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch, 'gdev://not-a-file')
    vim.api.nvim_set_current_buf(scratch)
  ]])

  eq(child.lua_get('GdevScenetree.open()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'has no file')
end

T['open()']['reports a missing project'] = function()
  child.lua([[vim.fn.chdir('tests/dir-format')]])

  eq(child.lua_get('GdevScenetree.open()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'project%.godot')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))
end

T['open()']['reuses one pane'] = function()
  child.lua('_G.open("Flat.tscn")')
  child.lua('GdevScenetree.open()')
  local win_id = child.lua_get('_G.pane_win()')

  child.lua('GdevScenetree.open("res://scenes/Nested.tscn")')

  eq(child.lua_get('_G.pane_win()'), win_id)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Nested.tscn')
end

T['open()']['respects `config.script_extensions`'] = function()
  -- The C# seam, exercised with the extension this fixture project has
  child.lua('_G.open("scripts/orphan.gdshader")')
  eq(child.lua_get('GdevScenetree.open()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'neither a scene nor a Godot script')

  eq(child.lua_get('GdevScenetree.open(nil, { script_extensions = { "gdshader" } })'), true)
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Shaded.tscn')
end

T['open()']['validates arguments'] = function()
  expect.error(function() child.lua('GdevScenetree.open(1)') end, vim.pesc('`scene` should be string'))
end

T['open()']['respects `vim.b.gdevscenetree_config`'] = function()
  child.lua('_G.open("Flat.tscn")')
  child.b.gdevscenetree_config = { icons = 'ascii' }

  eq(child.lua_get('GdevScenetree.open()'), true)
  eq(child.lua_get('_G.lines()')[2], '> Main [Node2D]')
end

T['open()']['respects `vim.{g,b}.gdevscenetree_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Flat.tscn")')
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.open()'), false)
    eq(child.lua_get('_G.pane_buf()'), vim.NIL)
  end,
})

T['refresh()'] = new_set()

T['refresh()']['reparses the scene file'] = function()
  -- A project of its own under `/tmp`, since this one is edited mid-case
  child.lua([[
    _G.temp = vim.fn.tempname()
    vim.fn.mkdir(_G.temp, 'p')
    vim.fn.writefile({ 'config_version=5' }, _G.temp .. '/project.godot')
    _G.write = function(name)
      vim.fn.writefile({ '[gd_scene format=3]', '', ('[node name="%s" type="Node"]'):format(name) }, _G.temp .. '/S.tscn')
    end
  ]])
  child.lua('_G.write("Before"); vim.cmd("edit " .. _G.temp .. "/S.tscn")')
  child.lua('GdevScenetree.open()')
  eq(child.lua_get('_G.lines()')[2], '\u{f0e8} Before [Node]')

  child.lua('_G.write("After")')
  eq(child.lua_get('GdevScenetree.refresh()'), true)
  eq(child.lua_get('_G.lines()')[2], '\u{f0e8} After [Node]')

  child.lua('vim.fn.delete(_G.temp, "rf")')
end

T['refresh()']['keeps the cursor on its line'] = function()
  child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open()')
  child.lua('vim.api.nvim_win_set_cursor(_G.pane_win(), { 5, 0 })')

  child.lua('GdevScenetree.refresh()')

  eq(child.api.nvim_win_get_cursor(child.lua_get('_G.pane_win()'))[1], 5)
end

T['refresh()']['picks up a changed config'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  eq(child.lua_get('_G.lines()')[2], '\u{f096} Main [Node2D]')

  eq(child.lua_get('GdevScenetree.refresh({ icons = false })'), true)
  eq(child.lua_get('_G.lines()')[2], 'Main [Node2D]')
end

T['refresh()']['falls back to opening'] = function()
  child.lua('_G.open("Flat.tscn")')

  eq(child.lua_get('GdevScenetree.refresh()'), true)
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://Flat.tscn')
end

T['refresh()']['respects `vim.{g,b}.gdevscenetree_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    -- With a pane already open, so that this is `refresh()` refusing rather
    -- than the `open()` it delegates to when nothing has been shown yet
    child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
    child.lua([[
      vim.bo[_G.pane_buf()].modifiable = true
      vim.api.nvim_buf_set_lines(_G.pane_buf(), 0, -1, false, { 'stale' })
    ]])
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.refresh()'), false)
    eq(child.lua_get('_G.lines()'), { 'stale' })
  end,
})

T['close()'] = new_set()

T['close()']['closes the window and keeps the buffer'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  local buf_id = child.lua_get('_G.pane_buf()')

  eq(child.lua_get('GdevScenetree.close()'), true)

  eq(child.lua_get('_G.pane_win()'), vim.NIL)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
  eq(child.lua_get('_G.pane_buf()'), buf_id)

  -- Reopening does not lose the scene it was showing
  eq(child.lua_get('GdevScenetree.refresh()'), true)
  eq(child.lua_get('_G.lines()')[1], 'Scene: res://Flat.tscn')
end

T['close()']['reports a pane that is not open'] = function() eq(child.lua_get('GdevScenetree.close()'), false) end

T['close()']['refuses to close the last window'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  child.lua('vim.api.nvim_win_close(_G.other_win(), true)')

  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
  eq(child.lua_get('GdevScenetree.close()'), false)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
end

T['close()']['respects `vim.{g,b}.gdevscenetree_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.close()'), false)
    expect.no_equality(child.lua_get('_G.pane_win()'), vim.NIL)
  end,
})

T['jump_to_node()'] = new_set()

T['jump_to_node()']['goes to the node line in the scene file'] = new_set({
  parametrize = { { 2, 3 }, { 3, 5 }, { 6, 12 }, { 8, 16 } },
}, {
  test = function(pane_line, scene_line)
    child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open()')
    child.set_cursor(pane_line, 0)

    eq(child.lua_get('GdevScenetree.jump_to_node()'), true)

    expect.match(child.api.nvim_buf_get_name(0), 'Nested%.tscn$')
    eq(child.api.nvim_win_get_cursor(0)[1], scene_line)
  end,
})

T['jump_to_node()']['returns to the window the pane was opened from'] = function()
  child.lua('_G.open("scenes/Nested.tscn")')
  local source_win = child.api.nvim_get_current_win()
  child.lua('GdevScenetree.open()')
  child.set_cursor(3, 0)

  child.lua('GdevScenetree.jump_to_node()')

  eq(child.api.nvim_get_current_win(), source_win)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
end

T['jump_to_node()']['splits when the pane is the only window'] = function()
  child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open()')
  child.lua('vim.api.nvim_win_close(_G.other_win(), true)')
  child.set_cursor(3, 0)

  eq(child.lua_get('GdevScenetree.jump_to_node()'), true)

  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
  expect.match(child.api.nvim_buf_get_name(0), 'Nested%.tscn$')
  eq(child.api.nvim_win_get_cursor(0)[1], 5)
end

T['jump_to_node()']['reports a cursor that is not on a node'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  child.set_cursor(1, 0)

  eq(child.lua_get('GdevScenetree.jump_to_node()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'not on a node')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.WARN'))
end

T['jump_to_node()']['reports a cursor outside the pane'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  child.lua('vim.api.nvim_set_current_win(_G.other_win())')

  eq(child.lua_get('GdevScenetree.jump_to_node()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'not in the scene tree pane')
end

T['jump_to_node()']['respects `vim.{g,b}.gdevscenetree_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.jump_to_node()'), false)
    eq(child.api.nvim_get_current_buf(), child.lua_get('_G.pane_buf()'))
  end,
})

T['yank_node_path()'] = new_set()

T['yank_node_path()']['yanks the path `get_node()` takes'] = new_set({
  parametrize = { { 2, '.' }, { 3, 'Player' }, { 6, 'Player/Weapon/Tip' }, { 8, 'Ui/Score' } },
}, {
  test = function(pane_line, path)
    child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open()')
    child.set_cursor(pane_line, 0)

    eq(child.lua_get('GdevScenetree.yank_node_path()'), true)
    eq(child.fn.getreg('"'), path)
    expect.match(child.lua_get('_G.last_message()'), 'yanked ' .. vim.pesc(path))
  end,
})

T['yank_node_path()']['reports a cursor that is not on a node'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  child.set_cursor(1, 0)

  eq(child.lua_get('GdevScenetree.yank_node_path()'), false)
  eq(child.fn.getreg('"'), '')
end

T['yank_node_path()']['respects `vim.{g,b}.gdevscenetree_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.yank_node_path()'), false)
    eq(child.fn.getreg('"'), '')
  end,
})

T['open_script()'] = new_set()

T['open_script()']['opens the attached script'] = new_set({
  parametrize = { { 2, 'shared%.gd' }, { 3, 'player%.gd' } },
}, {
  test = function(pane_line, pattern)
    child.lua('_G.open("scenes/Scripted.tscn"); GdevScenetree.open()')
    child.set_cursor(pane_line, 0)

    eq(child.lua_get('GdevScenetree.open_script()'), true)

    expect.match(child.api.nvim_buf_get_name(0), pattern)
    eq(child.bo.filetype, 'gdscript')
    -- Opened in the source window, not over the pane
    expect.no_equality(child.lua_get('_G.pane_win()'), vim.NIL)
  end,
})

T['open_script()']['opens the scene an instance points at'] = function()
  child.lua('_G.open("scenes/Instanced.tscn"); GdevScenetree.open()')
  child.set_cursor(3, 0)

  eq(child.lua_get('GdevScenetree.open_script()'), true)
  expect.match(child.api.nvim_buf_get_name(0), 'Flat%.tscn$')
end

T['open_script()']['reports a node with nothing attached'] = function()
  child.lua('_G.open("scenes/Scripted.tscn"); GdevScenetree.open()')
  child.set_cursor(4, 0)

  eq(child.lua_get('GdevScenetree.open_script()'), false)
  expect.match(child.lua_get('_G.last_message()'), 'Plain has no attached script')
  eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.WARN'))
end

T['open_script()']['reports a script it cannot open'] = new_set({
  -- One that resolves inside the project but is not there, and one that does
  -- not resolve at all: `res://` is not the only scheme Godot writes
  parametrize = { { 2, 'res://scripts/gone%.gd' }, { 3, 'user://elsewhere%.gd' } },
}, {
  test = function(pane_line, pattern)
    child.lua('_G.open("scenes/Missing.tscn"); GdevScenetree.open()')
    child.set_cursor(pane_line, 0)

    eq(child.lua_get('GdevScenetree.open_script()'), false)
    expect.match(child.lua_get('_G.last_message()'), pattern .. ' is not a readable file')
    eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.ERROR'))
  end,
})

T['open_script()']['respects `vim.{g,b}.gdevscenetree_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua('_G.open("scenes/Scripted.tscn"); GdevScenetree.open()')
    child.set_cursor(3, 0)
    child[var_type].gdevscenetree_disable = true

    eq(child.lua_get('GdevScenetree.open_script()'), false)
    eq(child.api.nvim_get_current_buf(), child.lua_get('_G.pane_buf()'))
  end,
})

-- Integration tests ==========================================================
T['rendering'] = new_set()

T['rendering']['indents by depth and names the type'] = function()
  child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open(nil, { icons = false })')

  eq(child.lua_get('_G.lines()'), {
    'Scene: res://scenes/Nested.tscn',
    'World [Node2D]',
    '  Player [CharacterBody2D]',
    '    Body [CollisionShape2D]',
    '    Weapon [Node2D]',
    '      Tip [Marker2D]',
    '  Ui [CanvasLayer]',
    '    Score [Label]',
  })
end

T['rendering']['marks nodes with a script'] = function()
  child.lua('_G.open("scenes/Scripted.tscn"); GdevScenetree.open(nil, { icons = false })')

  eq(child.lua_get('_G.lines()'), {
    'Scene: res://scenes/Scripted.tscn',
    'Root [Node] *',
    '  Player [CharacterBody2D] *',
    '  Plain [Node2D]',
  })
end

T['rendering']['names what a node instances'] = function()
  -- `PackedScene` says nothing a user can act on; the scene it instances does
  child.lua('_G.open("scenes/Instanced.tscn"); GdevScenetree.open(nil, { icons = false })')

  eq(child.lua_get('_G.lines()'), {
    'Scene: res://scenes/Instanced.tscn',
    'Level [Node2D]',
    '  Hero [res://Flat.tscn]',
    '    Camera',
  })
end

T['rendering']['says when a scene has no nodes'] = function()
  child.lua('_G.open("scenes/Empty.tscn"); GdevScenetree.open()')

  eq(child.lua_get('_G.lines()'), {
    'Scene: res://scenes/Empty.tscn',
    'no [node] sections in this scene',
  })
  eq(child.lua_get('#_G.marks()'), 1)
end

T['rendering']['respects `config.icons`'] = new_set({
  parametrize = {
    { 'false', { 'Main [Node2D]', '  Camera [Camera2D]', '  Sprite [Sprite2D]' } },
    { '"ascii"', { '> Main [Node2D]', '  > Camera [Camera2D]', '  > Sprite [Sprite2D]' } },
    -- A table extends the nerdfont set, so `Camera2D` changes and the rest stays
    {
      '{ types = { Camera2D = "@" } }',
      { '\u{f096} Main [Node2D]', '  @ Camera [Camera2D]', '  \u{f03e} Sprite [Sprite2D]' },
    },
  },
}, {
  test = function(icons, nodes)
    child.lua('_G.open("Flat.tscn"); GdevScenetree.open(nil, { icons = ' .. icons .. ' })')

    eq(child.lua_get('_G.lines()'), vim.list_extend({ 'Scene: res://Flat.tscn' }, nodes))
  end,
})

T['rendering']['uses nerdfont icons by default'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')

  eq(child.lua_get('_G.lines()'), {
    'Scene: res://Flat.tscn',
    '\u{f096} Main [Node2D]',
    '  \u{f030} Camera [Camera2D]',
    '  \u{f03e} Sprite [Sprite2D]',
  })
end

T['rendering']['falls back through the type family'] = function()
  -- `PanelContainer` has no icon of its own but is a `Control`; `Marker2D` is
  -- a `Node2D`; a type in no family at all gets `generic`
  child.lua('_G.open("scenes/Types.tscn"); GdevScenetree.open()')
  local lines = child.lua_get('_G.lines()')

  expect.match(lines[5], '^  \u{f009} Ui ')
  expect.match(lines[7], '^  \u{f10c} Plugin ')
end

T['rendering']['respects a table `script_suffix`'] = function()
  child.lua('_G.open("scenes/Scripted.tscn")')
  child.lua('GdevScenetree.open(nil, { icons = { script_suffix = " [script]" } })')

  eq(child.lua_get('_G.lines()')[2], '\u{f0e8} Root [Node] [script]')
end

T['rendering']['respects a table `generic`'] = function()
  child.lua('_G.open("scenes/Types.tscn")')
  child.lua('GdevScenetree.open(nil, { icons = { generic = "#" } })')

  -- `GridMapEditorPlugin` is in no family, so it is what `generic` is for
  eq(child.lua_get('_G.lines()')[7], '  # Plugin [GridMapEditorPlugin]')
end

T['rendering']['highlights the icon by node category'] = function()
  child.lua('_G.open("scenes/Types.tscn"); GdevScenetree.open(nil, { icons = "ascii" })')

  eq(child.lua_get('_G.groups()'), {
    'GdevScenetreeHeader',
    'GdevScenetreeIconWhite',
    'GdevScenetreeIconBlue',
    'GdevScenetreeIconRed',
    'GdevScenetreeIconGreen',
    'GdevScenetreeIconPurple',
    'GdevScenetreeIconYellow',
    'GdevScenetreeIconBlue',
    -- A `class_name` of the project's own belongs to no Godot family
    'GdevScenetreeIcon',
  })
end

T['rendering']['greys a node whose type the scene does not state'] = function()
  child.lua('_G.open("scenes/Instanced.tscn"); GdevScenetree.open(nil, { icons = "ascii" })')

  eq(child.lua_get('_G.groups()'), {
    'GdevScenetreeHeader',
    'GdevScenetreeIconBlue',
    'GdevScenetreeIconYellow',
    'GdevScenetreeIconGrey',
  })
end

T['rendering']['highlights the icon and nothing else'] = function()
  child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open(nil, { icons = "ascii" })')
  local marks = child.lua_get('_G.marks()')

  -- Header spans its whole line; every other span is one glyph wide, after the
  -- indent of its node
  eq(marks[1], { line = 1, end_line = 2, col = 0, end_col = 0, group = 'GdevScenetreeHeader' })
  eq(marks[2], { line = 2, end_line = 2, col = 0, end_col = 1, group = 'GdevScenetreeIconBlue' })
  eq(marks[3], { line = 3, end_line = 3, col = 2, end_col = 3, group = 'GdevScenetreeIconBlue' })
  eq(marks[6], { line = 6, end_line = 6, col = 6, end_col = 7, group = 'GdevScenetreeIconBlue' })
end

T['rendering']['spans a multi-byte icon'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')
  local marks = child.lua_get('_G.marks()')

  -- Columns are byte offsets, and a Nerd Font glyph is three bytes
  eq(marks[2], { line = 2, end_line = 2, col = 0, end_col = 3, group = 'GdevScenetreeIconBlue' })
  eq(marks[3], { line = 3, end_line = 3, col = 2, end_col = 5, group = 'GdevScenetreeIconBlue' })
end

T['rendering']['clears the highlights of the scene before'] = function()
  child.lua('_G.open("scenes/Nested.tscn"); GdevScenetree.open(nil, { icons = "ascii" })')
  eq(#child.lua_get('_G.marks()'), 8)

  child.lua('GdevScenetree.open("res://Flat.tscn", { icons = "ascii" })')

  eq(#child.lua_get('_G.marks()'), 4)
end

T['rendering']['drops icons and their highlights together'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open(nil, { icons = false })')

  eq(child.lua_get('_G.groups()'), { 'GdevScenetreeHeader' })
end

T['rendering']['looks like a scene tree'] = function()
  -- The one case that asserts the pane as a whole rather than through the API,
  -- so that the icon column and its seven colors are checked as they are seen.
  --
  -- `'ascii'` deliberately: Nerd Font glyphs are multi-byte and Neovim's
  -- character-width tables have changed between versions, which a committed
  -- screenshot has no way to survive. The pane is left alone on screen for the
  -- same reason -- the scene file beside it would put Neovim's own bundled
  -- `gdresource` syntax into the reference.
  child.set_size(12, 44)
  child.lua('_G.open("scenes/Types.tscn"); GdevScenetree.open(nil, { icons = "ascii" })')
  child.cmd('only')

  child.expect_screenshot()
end

T['the pane'] = new_set()

T['the pane']['is a scratch buffer'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')

  eq(child.lua_get('vim.bo[_G.pane_buf()].buftype'), 'nofile')
  eq(child.lua_get('vim.bo[_G.pane_buf()].filetype'), 'gdev-scenetree')
  eq(child.lua_get('vim.bo[_G.pane_buf()].modifiable'), false)
  eq(child.lua_get('vim.bo[_G.pane_buf()].buflisted'), false)
  eq(child.lua_get('vim.bo[_G.pane_buf()].swapfile'), false)
end

T['the pane']['opens a vertical split on the left'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')

  local config = child.lua_get('vim.api.nvim_win_get_config(_G.pane_win())')
  eq(config.split, 'left')
  eq(config.relative, '')
  eq(child.lua_get('vim.api.nvim_win_get_width(_G.pane_win())'), 28)
end

T['the pane']['respects `config.buffer`'] = new_set({
  parametrize = {
    { { position = 'right', size = 0.5 }, 'right', 40 },
    { { position = 'left', size = 0.35 }, 'left', 28 },
    -- Below the floor a tree stops being readable, so the fraction gives way.
    -- The floor is above 'winwidth', which would otherwise hide it here.
    { { position = 'left', size = 0.1 }, 'left', 24 },
  },
}, {
  test = function(buffer_config, split, width)
    unload_module()
    load_module({ buffer = buffer_config })
    child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')

    eq(child.lua_get('vim.api.nvim_win_get_config(_G.pane_win()).split'), split)
    eq(child.lua_get('vim.api.nvim_win_get_width(_G.pane_win())'), width)
  end,
})

T['the pane']['reads as a tree rather than a file'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')

  eq(child.lua_get('vim.wo[_G.pane_win()].wrap'), false)
  eq(child.lua_get('vim.wo[_G.pane_win()].number'), false)
  eq(child.lua_get('vim.wo[_G.pane_win()].signcolumn'), 'no')
  eq(child.lua_get('vim.wo[_G.pane_win()].cursorline'), true)
  eq(child.lua_get('vim.wo[_G.pane_win()].winfixwidth'), true)
end

T['the pane']['takes the cursor and starts on the root node'] = function()
  child.lua('_G.open("Flat.tscn"); GdevScenetree.open()')

  eq(child.api.nvim_get_current_buf(), child.lua_get('_G.pane_buf()'))
  eq(child.get_cursor()[1], 2)
end

T['mappings'] = new_set({
  hooks = {
    pre_case = function() child.lua('_G.open("scenes/Scripted.tscn"); GdevScenetree.open()') end,
  },
})

T['mappings']['`<CR>` jumps to the node line'] = function()
  child.set_cursor(3, 0)
  type_keys('<CR>')

  expect.match(child.api.nvim_buf_get_name(0), 'Scripted%.tscn$')
  eq(child.get_cursor()[1], 9)
end

T['mappings']['`y` yanks the node path'] = function()
  child.set_cursor(3, 0)
  type_keys('y')

  eq(child.fn.getreg('"'), 'Player')
end

T['mappings']['`g` opens the attached script'] = function()
  child.set_cursor(3, 0)
  type_keys('g')

  expect.match(child.api.nvim_buf_get_name(0), 'player%.gd$')
end

T['mappings']['`r` refreshes'] = function()
  child.lua([[
    vim.bo[_G.pane_buf()].modifiable = true
    vim.api.nvim_buf_set_lines(_G.pane_buf(), 0, -1, false, { 'stale' })
  ]])

  type_keys('r')

  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Scripted.tscn')
end

T['mappings']['`q` closes the pane'] = function()
  type_keys('q')

  eq(child.lua_get('_G.pane_win()'), vim.NIL)
  expect.no_equality(child.lua_get('_G.pane_buf()'), vim.NIL)
end

T['mappings']['respects `config.mappings`'] = function()
  child.lua('GdevScenetree.refresh({ mappings = { yank = "Y" } })')
  child.set_cursor(3, 0)

  type_keys('Y')
  eq(child.fn.getreg('"'), 'Player')

  -- The default it replaced is gone, so `y` is Neovim's own operator again
  eq(child.lua_get('vim.fn.maparg("y", "n", false, true).buffer'), vim.NIL)
end

T['mappings']['can be turned off one at a time'] = function()
  child.lua('GdevScenetree.refresh({ mappings = { close = "" } })')

  -- Not typed: with `q` unmapped it is Neovim's own "record macro", which
  -- would block the child waiting for a register name
  eq(child.lua_get('vim.fn.maparg("q", "n", false, true).buffer'), vim.NIL)
  eq(child.lua_get('vim.fn.maparg("r", "n", false, true).buffer'), 1)
end

T[':GdevScenetree'] = new_set()

T[':GdevScenetree']['works'] = function()
  child.lua('_G.open("scenes/Nested.tscn")')
  child.cmd('GdevScenetree')

  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Nested.tscn')
end

T[':GdevScenetree']['takes a scene path'] = function()
  child.lua('_G.open("Flat.tscn")')
  child.cmd('GdevScenetree scenes/Nested.tscn')

  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Nested.tscn')
end

T[':GdevScenetree']['re-renders when run from the pane'] = function()
  -- The pane is a `nofile` buffer belonging to no project, so resolving from
  -- it the usual way would find nothing at all
  child.lua('_G.open("scenes/Nested.tscn")')
  child.cmd('GdevScenetree')
  eq(child.api.nvim_get_current_buf(), child.lua_get('_G.pane_buf()'))

  child.cmd('GdevScenetree')

  eq(child.lua_get('_G.lines()')[1], 'Scene: res://scenes/Nested.tscn')
  eq(child.lua_get('_G.notifications'), {})
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
end

T[':GdevScenetree']['resolves a path against the project the pane belongs to'] = function()
  child.lua('_G.open("scenes/Nested.tscn")')
  child.cmd('GdevScenetree')

  child.cmd('GdevScenetree Flat.tscn')

  eq(child.lua_get('_G.lines()')[1], 'Scene: res://Flat.tscn')
end

T[':GdevScenetreeRefresh'] = new_set()

T[':GdevScenetreeRefresh']['works'] = function()
  child.lua('_G.open("Flat.tscn")')
  child.cmd('GdevScenetree')
  child.lua([[
    vim.bo[_G.pane_buf()].modifiable = true
    vim.api.nvim_buf_set_lines(_G.pane_buf(), 0, -1, false, { 'stale' })
  ]])

  child.cmd('GdevScenetreeRefresh')

  eq(child.lua_get('_G.lines()')[1], 'Scene: res://Flat.tscn')
end

return T
