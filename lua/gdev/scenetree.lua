--- *gdev.scenetree* Browse a Godot scene as a tree
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Renders the node hierarchy of a `.tscn` file into a side pane, with
---   per-type icons colored by Godot's own node categories. See
---   |GdevScenetree.open()|.
--- - Resolves the scene from the buffer you are in: the scene itself, or the
---   scene that uses the script you are editing.
--- - Jumps from a node to its `[node ...]` line in the scene file, to its
---   attached script, or to the scene it instances.
--- - Parses without Godot running: it reads the file, so it answers for a
---   scene you have never opened in the editor. See |GdevScenetree.get_nodes()|.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.scenetree').setup({})`
--- (replace `{}` with your `config` table). It will create global Lua table
--- `GdevScenetree` which you can use for scripting or manually (with
--- `:lua GdevScenetree.*`).
---
--- See |GdevScenetree.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevscenetree_config` which should have same structure as
--- `GdevScenetree.config`. It is read from the buffer the command runs in, so
--- a per-project override belongs on the source buffer rather than the pane.
---
--- # Scene resolution ~
---
--- `:GdevScenetree` with no argument shows the scene the current buffer is
--- about: the buffer itself when it is a `.tscn`, otherwise the scene that
--- references the script you are editing -- picked through |vim.ui.select()|
--- when several do. Which files count as scripts is `config.script_extensions`.
---
--- With an argument it shows that scene, named as a `res://` path, a path
--- relative to the project root, or an absolute path inside it. Anything that
--- resolves outside the project is refused; the project is the one around the
--- current buffer, so browsing another project means opening a buffer in it
--- first.
---
--- Run from inside the pane, `:GdevScenetree` re-renders what the pane already
--- shows, which is also what `:GdevScenetreeRefresh` does.
---
--- # The pane ~
---
--- A `nofile` scratch buffer in a vertical split, placed and sized by
--- `config.buffer`. Opening it takes the cursor: it is a place to navigate
--- from, and its mappings are the point.
---
--- Default mappings, all buffer-local and all configurable through
--- `config.mappings` (`''` turns one off):
---
--- - `<CR>` - jump to this node's `[node ...]` line in the scene file.
--- - `y`    - yank the node's path (what Godot's `get_node()` takes) into the
---            unnamed register.
--- - `g`    - open the node's attached script, or the scene it instances.
--- - `r`    - reparse the scene file.
--- - `q`    - close the pane. The buffer survives, so reopening is instant.
---
--- Jumping opens the file in the window the pane was opened from, splitting
--- only when the pane is the only window left.
---
--- # Icons ~
---
--- `config.icons` is `'nerdfont'` (needs a patched font), `'ascii'`, `false`
--- for none, or a table merged over the `'nerdfont'` set -- so overriding a
--- few types keeps the rest:
--- >lua
---   icons = { types = { Camera2D = '@' } }
--- <
--- A type with no icon of its own falls back to its family (anything ending in
--- `2D`, `3D`, `Container`, `Button`, ...), then to `icons.generic`. Nodes with
--- an attached script get `icons.script_suffix` appended.
---
--- # Highlight groups ~
---
--- Only the icon is colored, by the category Godot's editor colors that node
--- with. Change the mapping from category to color through
--- `config.icon_colors`, or set the groups directly with |nvim_set_hl()|.
---
--- - `GdevScenetreeHeader` - first line of the pane, naming the scene.
--- - `GdevScenetreeIconRed` - 3D nodes.
--- - `GdevScenetreeIconBlue` - 2D nodes.
--- - `GdevScenetreeIconGreen` - `Control` nodes.
--- - `GdevScenetreeIconPurple` - animation nodes.
--- - `GdevScenetreeIconYellow` - nodes that bring in something else: an
---   instanced scene, or an editor plugin.
--- - `GdevScenetreeIconGrey` - nodes whose type the scene file does not state,
---   which is how Godot records an override of a node inside an instance.
--- - `GdevScenetreeIconWhite` - nodes in no family of their own: `Node`,
---   `Timer`, `CanvasLayer` and the like.
--- - `GdevScenetreeIcon` - everything else, which in practice means a
---   `class_name` of your own.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevscenetree_disable` (globally) or
--- `vim.b.gdevscenetree_disable` (for a buffer) to `true`.
--- |GdevScenetree.get_nodes()| and |GdevScenetree.status()| keep answering
--- while disabled, since neither touches the screen.
---@tag GdevScenetree

-- Module definition ==========================================================
local GdevScenetree = {}
local H = require('gdev.util').new('scenetree', GdevScenetree)

-- Project-root discovery and `res://` resolution, shared with 'gdev.run'
local Project = require('gdev.project')

--- Module setup
---
---@param config table|nil Module config table. See |GdevScenetree.config|.
---
---@usage >lua
---   require('gdev.scenetree').setup() -- use default config
---   -- OR
---   require('gdev.scenetree').setup({}) -- replace {} with your config table
--- <
GdevScenetree.setup = function(config)
  -- Export module
  _G.GdevScenetree = GdevScenetree

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.create_autocommands()
  H.create_user_commands()

  -- Create default highlighting
  H.create_default_hl()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevScenetree.config = {
  -- The pane. `position` is `'left'` or `'right'`; `size` is its width as a
  -- fraction of the editor.
  buffer = {
    position = 'left',
    size = 0.35,
  },

  -- Node icons: `'nerdfont'`, `'ascii'`, `false`, or a table with `generic`,
  -- `script_suffix` and `types` merged over the `'nerdfont'` set
  icons = 'nerdfont',

  -- Color of the icon column, per Godot node category. Each value is a
  -- highlight group to link to, or a table |nvim_set_hl()| accepts.
  icon_colors = {
    generic = 'Normal',
    groups = {
      White = 'Normal',
      Grey = 'Comment',
      Blue = 'DiagnosticInfo',
      Red = 'DiagnosticError',
      Green = 'DiagnosticOk',
      Purple = 'Constant',
      Yellow = 'DiagnosticWarn',
    },
  },

  -- Pane mappings. Use `''` (empty string) to disable one.
  mappings = {
    jump = '<CR>',
    yank = 'y',
    script = 'g',
    refresh = 'r',
    close = 'q',
  },

  -- Extensions of files treated as Godot scripts when resolving which scene
  -- the current buffer is about. Replaces this list rather than adding to it.
  script_extensions = { 'gd' },
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Show a scene in the pane
---
--- `scene` is a `res://` path, a path relative to the project root, or an
--- absolute path inside it. With `nil` the scene is resolved from the current
--- buffer; see |GdevScenetree| for the rules, including what happens when
--- several scenes use the script you are editing.
---
--- Opening focuses the pane. Reopening reuses its window and buffer, so the
--- pane never multiplies.
---
---@param scene string|nil Scene to show, or `nil` to resolve one.
---@param opts table|nil Options overriding `GdevScenetree.config` for this call.
---
---@return boolean Whether the pane now shows a scene, or a picker was opened.
GdevScenetree.open = function(scene, opts)
  if H.is_disabled() then
    return false
  end

  H.check_type('scene', scene, 'string', true)
  local config = H.get_config(opts)

  if scene ~= nil and scene ~= '' then
    local root = H.find_root()
    if root == nil then
      return H.report_no_project()
    end

    local res = Project.to_res(root, scene)
    if res == nil then
      H.notify(('%s is not inside %s'):format(scene, root), 'ERROR')
      return false
    end
    return H.show(res, root, config)
  end

  -- Asked from inside the pane, which belongs to no project: the scene it
  -- already shows is the only sensible answer
  if H.pane.scene ~= nil and vim.api.nvim_get_current_buf() == H.pane.buf_id then
    return H.show(H.pane.scene, H.pane.root, config)
  end

  local root = H.find_root()
  if root == nil then
    return H.report_no_project()
  end

  local path = H.buffer_path()
  if path == nil then
    H.notify('the current buffer has no file, so there is no scene to show', 'ERROR')
    return false
  end

  -- The root was found by walking up from this very path, so it always
  -- contains it and `to_res()` cannot fail here
  if Project.is_scene(path) then
    return H.show(Project.to_res(root, path), root, config)
  end

  if not Project.is_script(path, config.script_extensions) then
    H.notify(
      ('%s is neither a scene nor a Godot script'):format(vim.fn.fnamemodify(path, ':t')),
      'ERROR'
    )
    return false
  end

  local res = Project.to_res(root, path)
  local scenes = Project.scenes_with_script(root, path)
  if #scenes == 0 then
    H.notify(('no scene in %s uses %s'):format(root, res), 'ERROR')
    return false
  end
  if #scenes == 1 then
    return H.show(scenes[1], root, config)
  end

  -- Shown from the choice rather than through `GdevScenetree.open()` again:
  -- the offered scenes were resolved against `root`, and re-resolving on the
  -- way out would answer for whatever buffer the user is in when it closes
  vim.ui.select(scenes, { prompt = ('Scenes using %s'):format(res) }, function(choice)
    if choice == nil then
      return
    end
    H.show(choice, root, config)
  end)
  return true
end

--- Reparse the scene the pane shows
---
--- Picks up edits to the scene file, and re-renders with the config as it is
--- now. The cursor keeps its line, so a refresh does not lose your place.
---
--- With nothing shown yet this is |GdevScenetree.open()| with no argument.
---
---@param opts table|nil Options overriding `GdevScenetree.config` for this call.
---
---@return boolean Whether the pane now shows a scene.
GdevScenetree.refresh = function(opts)
  if H.is_disabled() then
    return false
  end
  if H.pane.scene == nil then
    return GdevScenetree.open(nil, opts)
  end

  return H.show(H.pane.scene, H.pane.root, H.get_config(opts))
end

--- Close the pane
---
--- The buffer is kept, so reopening costs nothing and does not reparse.
---
---@return boolean Whether a window was closed.
GdevScenetree.close = function()
  if H.is_disabled() then
    return false
  end

  local win_id = H.pane.win_id
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then
    return false
  end

  -- Closing the last window is refused by Neovim rather than quitting it
  local ok = pcall(vim.api.nvim_win_close, win_id, false)
  if ok then
    H.pane.win_id = nil
  end
  return ok
end

--- Jump to the node under the cursor in the scene file
---
--- Opens the `.tscn` at the node's `[node ...]` line, in the window the pane
--- was opened from.
---
---@return boolean Whether the jump happened.
GdevScenetree.jump_to_node = function()
  if H.is_disabled() then
    return false
  end

  local node = H.node_at_cursor()
  if node == nil then
    return false
  end

  vim.api.nvim_win_set_cursor(H.edit(H.pane.path), { node.line, 0 })
  return true
end

--- Yank the path of the node under the cursor
---
--- The path is the one Godot's `get_node()` takes, relative to the scene root
--- (`.` for the root itself). It goes into the unnamed register.
---
---@return boolean Whether something was yanked.
GdevScenetree.yank_node_path = function()
  if H.is_disabled() then
    return false
  end

  local node = H.node_at_cursor()
  if node == nil then
    return false
  end

  vim.fn.setreg('"', node.path)
  H.notify(('yanked %s'):format(node.path))
  return true
end

--- Open what the node under the cursor points at
---
--- The script attached to it, or -- for a node that instances another scene --
--- that scene. Both open in the window the pane was opened from.
---
---@return boolean Whether a file was opened.
GdevScenetree.open_script = function()
  if H.is_disabled() then
    return false
  end

  local node = H.node_at_cursor()
  if node == nil then
    return false
  end

  local res = node.script or node.instance
  if res == nil then
    H.notify(('%s has no attached script'):format(node.path), 'WARN')
    return false
  end

  local path = Project.to_path(H.pane.root, res)
  if path == nil or vim.fn.filereadable(path) ~= 1 then
    H.notify(('%s is not a readable file'):format(res), 'ERROR')
    return false
  end

  H.edit(path)
  return true
end

--- Nodes of a scene
---
--- Pure: parses the scene file and returns what is in it, touching no window.
--- Keeps answering while the module is disabled.
---
--- Each node is `{ name, type, parent, path, depth, line, script, instance }`.
--- `type` is absent when the file does not state one, which is how Godot
--- records an override of a node that lives inside an instanced scene.
--- `script` and `instance` are `res://` paths; `line` is the 1-based line of
--- the node's `[node ...]` header, and `path` is what `get_node()` takes.
---
---@param scene string|nil Scene to parse, resolved like |GdevScenetree.open()|
---   does. `nil` is the scene the pane shows.
---
---@return table Array of nodes in file order. Empty when the scene cannot be
---   read, which includes naming one outside the project.
GdevScenetree.get_nodes = function(scene)
  H.check_type('scene', scene, 'string', true)

  local path = (scene == nil or scene == '') and H.pane.path or H.scene_path(scene)
  if path == nil or vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  return H.parse(vim.fn.readfile(path))
end

--- Report what the pane would show
---
--- Pure, and keeps answering while the module is disabled -- which is when
--- |:checkhealth| asks. `icons` is the resolved style rather than the raw
--- config value, so `'nerdfont'` there means a patched font is required.
---
---@param opts table|nil Options overriding `GdevScenetree.config` for this call.
---
---@return table `{ root = string|nil, scene = string|nil, open = boolean,
---   icons = string|false }`, where `root` is the project around the current
---   buffer and `scene` the one the pane holds.
GdevScenetree.status = function(opts)
  local config = H.get_config(opts)
  local win_id = H.pane.win_id

  return {
    root = H.find_root(),
    scene = H.pane.scene,
    open = win_id ~= nil and vim.api.nvim_win_is_valid(win_id),
    icons = type(config.icons) == 'table' and 'table' or config.icons,
  }
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevScenetree.config)

-- The one pane, and what it shows. Deliberately untouched by `setup()`:
-- re-configuring must not orphan a window or lose the rendered scene.
H.pane = {
  buf_id = nil,
  win_id = nil,
  -- Window to jump back into, remembered when the pane is opened
  source_win_id = nil,
  scene = nil,
  root = nil,
  path = nil,
  -- Node per display line, so the mappings can answer for the cursor
  nodes = {},
  -- Left-hand sides currently mapped in the pane, so a changed
  -- `config.mappings` can take the previous ones away
  mappings = {},
}

-- Buffer names are unique, which is what lets a reloaded module find the
-- buffer its previous incarnation created
H.buf_name = 'gdev://scene-tree'

H.ns_id = vim.api.nvim_create_namespace('GdevScenetree')

-- Floor on the pane width, in cells. A tree of indented names is unreadable
-- below roughly this, and a configured fraction of a narrow editor can ask for
-- much less. Above 'winwidth's default of 20 on purpose: that only enlarges the
-- window while it is the current one, so a pane sized below it snaps narrow the
-- moment you leave.
H.min_width = 24

H.positions = { 'left', 'right' }

H.icon_styles = { 'nerdfont', 'ascii' }

H.color_groups = { 'White', 'Grey', 'Blue', 'Red', 'Green', 'Purple', 'Yellow' }

-- Icons -----------------------------------------------------------------------
H.icons = {
  -- Nerd Font glyphs, all from the FontAwesome block every patched font
  -- carries. Written as escapes rather than literals so this file stays plain
  -- ASCII: the codepoints are checkable against a cheat sheet without a
  -- patched font, and no editor or pipeline can mangle them on the way in.
  nerdfont = {
    generic = '\u{f10c}',
    script_suffix = ' \u{f121}',
    types = {},
  },

  -- One glyph for every node: the indentation carries the shape and the
  -- highlight carries the category, so an unpatched font loses nothing but the
  -- pictogram.
  ascii = {
    generic = '>',
    script_suffix = ' *',
    types = {},
  },
}

-- Deliberately a small table, written glyph-first so each line reads as one
-- pictogram and the types that share it. Godot has hundreds of node types;
-- these are the ones scenes are actually made of. Everything else resolves
-- through `H.icon_families` and then `generic`, and `config.icons` extends it.
for glyph, types in pairs({
  -- Structure
  ['\u{f0e8}'] = { 'Node' }, -- sitemap
  ['\u{f096}'] = { 'Node2D' }, -- square-o
  ['\u{f1b2}'] = { 'Node3D' }, -- cube
  ['\u{f009}'] = { 'Control' }, -- th-large
  ['\u{f24d}'] = { 'CanvasLayer', 'SubViewport', 'Window' }, -- clone
  ['\u{f0c1}'] = { 'PackedScene' }, -- link, the type an instanced scene has
  -- Rendering
  ['\u{f03e}'] = { 'Sprite2D', 'Sprite3D', 'TextureRect' }, -- picture-o
  ['\u{f008}'] = { 'AnimatedSprite2D', 'AnimatedSprite3D', 'VideoStreamPlayer' }, -- film
  ['\u{f1b3}'] = { 'MeshInstance3D', 'MultiMeshInstance3D' }, -- cubes
  ['\u{f00a}'] = { 'TileMap', 'TileMapLayer', 'GridMap' }, -- th
  ['\u{f031}'] = { 'Label', 'Label3D', 'RichTextLabel' }, -- font
  -- Cameras, lights, sound
  ['\u{f030}'] = { 'Camera2D', 'Camera3D' }, -- camera
  ['\u{f0eb}'] = {
    'DirectionalLight2D',
    'DirectionalLight3D',
    'PointLight2D',
    'OmniLight3D',
    'SpotLight3D',
  }, -- bulb
  ['\u{f001}'] = { 'AudioStreamPlayer', 'AudioStreamPlayer2D', 'AudioStreamPlayer3D' }, -- music
  -- Physics
  ['\u{f192}'] = { 'Area2D', 'Area3D' }, -- dot-circle-o
  ['\u{f05b}'] = {
    'CollisionShape2D',
    'CollisionShape3D',
    'CollisionPolygon2D',
    'CollisionPolygon3D',
  }, -- crosshairs
  ['\u{f007}'] = { 'CharacterBody2D', 'CharacterBody3D' }, -- user
  ['\u{f0e7}'] = { 'RigidBody2D', 'RigidBody3D' }, -- bolt
  ['\u{f0c8}'] = { 'StaticBody2D', 'StaticBody3D', 'Panel' }, -- square
  ['\u{f124}'] = { 'RayCast2D', 'RayCast3D' }, -- location-arrow
  -- Interface
  ['\u{f046}'] = { 'Button', 'CheckBox' }, -- check-square-o
  ['\u{f036}'] = { 'LineEdit', 'TextEdit', 'CodeEdit' }, -- align-left
  ['\u{f080}'] = { 'ProgressBar', 'TextureProgressBar' }, -- bar-chart
  ['\u{f1de}'] = { 'HSlider', 'VSlider', 'HScrollBar', 'VScrollBar' }, -- sliders
  ['\u{f03a}'] = { 'ItemList', 'Tree' }, -- list
  ['\u{f0c9}'] = { 'MenuBar' }, -- bars
  -- Behavior
  ['\u{f04b}'] = { 'AnimationPlayer', 'AnimationTree' }, -- play
  ['\u{f017}'] = { 'Timer' }, -- clock-o
  ['\u{f0c2}'] = { 'HTTPRequest' }, -- cloud
  ['\u{f0ac}'] = { 'WorldEnvironment' }, -- globe
  ['\u{f041}'] = { 'Marker2D', 'Marker3D' }, -- map-marker
}) do
  for _, name in ipairs(types) do
    H.icons.nerdfont.types[name] = glyph
  end
end

-- Suffix a type is looked up under when it has no icon of its own, in the
-- order tried. The two dimensional families come first: `Label3D` is a 3D node
-- before it is a label, and a `PointLight2D` icon of its own is why every light
-- is listed above rather than reached by suffix.
H.icon_families = {
  { suffix = '2D', type = 'Node2D' },
  { suffix = '3D', type = 'Node3D' },
  { suffix = 'Container', type = 'Control' },
  { suffix = 'Button', type = 'Button' },
  { suffix = 'Bar', type = 'ProgressBar' },
  { suffix = 'Edit', type = 'LineEdit' },
  { suffix = 'Rect', type = 'TextureRect' },
}

-- Colors ----------------------------------------------------------------------
-- Godot's editor tints a node's icon by the family it belongs to. Most of that
-- is derivable from the type name, so only what the suffix rules get wrong is
-- listed here.
H.categories = {
  -- 2D nodes whose names do not end in `2D`
  TileMap = 'Blue',
  TileMapLayer = 'Blue',
  ParallaxLayer = 'Blue',
  CanvasGroup = 'Blue',
  CanvasModulate = 'Blue',
  BackBufferCopy = 'Blue',
  -- 3D nodes whose names do not end in `3D`
  Decal = 'Red',
  FogVolume = 'Red',
  GridMap = 'Red',
  LightmapGI = 'Red',
  VoxelGI = 'Red',
  ReflectionProbe = 'Red',
  -- `Control` nodes the suffix rules miss
  Control = 'Green',
  Panel = 'Green',
  Tree = 'Green',
  ItemList = 'Green',
  GraphNode = 'Green',
  SpinBox = 'Green',
  CheckBox = 'Green',
  Range = 'Green',
  VideoStreamPlayer = 'Green',
  -- Animation
  AnimationPlayer = 'Purple',
  AnimationTree = 'Purple',
  -- Nodes that pull in something else
  PackedScene = 'Yellow',
  -- Nodes in no family at all, which Godot's editor draws white. Listed rather
  -- than made the default so that a type this module has never heard of -- a
  -- `class_name` of your own, most of the time -- is visibly not one of these.
  Node = 'White',
  Timer = 'White',
  CanvasLayer = 'White',
  ParallaxBackground = 'White',
  Window = 'White',
  SubViewport = 'White',
  AudioStreamPlayer = 'White',
  HTTPRequest = 'White',
  WorldEnvironment = 'White',
  MultiplayerSpawner = 'White',
  MultiplayerSynchronizer = 'White',
  ResourcePreloader = 'White',
}

H.control_suffixes =
  { 'Container', 'Button', 'Label', 'Bar', 'Edit', 'Rect', 'Slider', 'Separator', 'Picker' }

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('buffer', config.buffer, 'table')
  H.check_one_of('buffer.position', config.buffer.position, H.positions)
  H.check_fraction('buffer.size', config.buffer.size)

  H.check_icons('icons', config.icons)

  H.check_type('icon_colors', config.icon_colors, 'table')
  H.check_hl('icon_colors.generic', config.icon_colors.generic)
  H.check_type('icon_colors.groups', config.icon_colors.groups, 'table')
  for _, name in ipairs(H.color_groups) do
    H.check_hl('icon_colors.groups.' .. name, config.icon_colors.groups[name])
  end

  H.check_type('mappings', config.mappings, 'table')
  for _, name in ipairs({ 'jump', 'yank', 'script', 'refresh', 'close' }) do
    H.check_type('mappings.' .. name, config.mappings[name], 'string')
  end

  H.check_type('script_extensions', config.script_extensions, 'table')

  return config
end

H.check_one_of = function(field, value, allowed)
  if vim.tbl_contains(allowed, value) then
    return
  end
  local quoted = vim.tbl_map(vim.inspect, allowed)
  H.error(
    ('`%s` should be one of %s, not %s'):format(
      field,
      table.concat(quoted, ', '),
      vim.inspect(value)
    )
  )
end

H.check_fraction = function(field, value)
  if type(value) == 'number' and 0 < value and value <= 1 then
    return
  end
  H.error(('`%s` should be a number between 0 and 1, not %s'):format(field, vim.inspect(value)))
end

H.check_icons = function(field, value)
  if value == false or type(value) == 'table' or vim.tbl_contains(H.icon_styles, value) then
    return
  end
  local styles = table.concat(vim.tbl_map(vim.inspect, H.icon_styles), ' or ')
  H.error(('`%s` should be `false`, a table, %s, not %s'):format(field, styles, vim.inspect(value)))
end

-- |nvim_set_hl()| takes an attribute table; a string is the common case of
-- linking to an existing group, spelled without the `link =` ceremony
H.check_hl = function(field, value)
  if type(value) == 'string' or type(value) == 'table' then
    return
  end
  H.error(('`%s` should be a string or table, not %s'):format(field, type(value)))
end

H.apply_config = function(config)
  GdevScenetree.config = config
end

H.create_autocommands = function()
  local gr = vim.api.nvim_create_augroup('GdevScenetree', {})
  vim.api.nvim_create_autocmd(
    'ColorScheme',
    { group = gr, callback = H.create_default_hl, desc = 'Ensure colors' }
  )
end

H.create_user_commands = function()
  vim.api.nvim_create_user_command('GdevScenetree', function(data)
    GdevScenetree.open(data.args)
  end, {
    nargs = '?',
    complete = 'file',
    desc = 'Show a Godot scene as a tree',
  })
  vim.api.nvim_create_user_command('GdevScenetreeRefresh', function()
    GdevScenetree.refresh()
  end, {
    desc = 'Reparse the scene the tree pane shows',
  })
end

-- Reads the applied config rather than |H.get_config()|: highlight groups are
-- global, so a buffer-local override has nothing to say about them.
H.create_default_hl = function()
  local colors = GdevScenetree.config.icon_colors

  vim.api.nvim_set_hl(0, 'GdevScenetreeHeader', { default = true, link = 'Title' })
  H.set_hl('GdevScenetreeIcon', colors.generic)
  for name, spec in pairs(colors.groups) do
    H.set_hl('GdevScenetreeIcon' .. name, spec)
  end
end

H.set_hl = function(group, spec)
  local value = type(spec) == 'string' and { link = spec } or vim.deepcopy(spec)
  value.default = true
  vim.api.nvim_set_hl(0, group, value)
end

-- Parsing --------------------------------------------------------------------
-- Nodes of a `.tscn`, in file order.
--
-- The format is INI-like: `[section attributes]` headers, each followed by the
-- properties of whatever it declared. Only two sections matter -- `[node]`, and
-- the `[ext_resource]` entries a node's `script` and `instance` refer to by id.
--
-- Everything is resolved in one pass, which works because Godot writes every
-- `[ext_resource]` before the first `[node]`.
H.parse = function(lines)
  local resources, nodes, node = {}, {}, nil

  for index, line in ipairs(lines) do
    local kind, attributes = line:match('^%[(%a[%w_]*)%s*(.-)%]%s*$')

    if kind ~= nil then
      -- Any section ends the previous node, so a `script` property of a later
      -- `[sub_resource]` or `[connection]` cannot be attributed to it
      node = nil

      if kind == 'ext_resource' then
        local attrs = H.attributes(attributes)
        if attrs.id ~= nil and attrs.path ~= nil then
          resources[attrs.id] = attrs
        end
      elseif kind == 'node' then
        node =
          H.node(H.attributes(attributes), resources[H.resource_id(attributes, 'instance')], index)
        table.insert(nodes, node)
      end
    elseif node ~= nil then
      local resource = resources[H.resource_id(line, 'script')]
      if resource ~= nil then
        node.script = resource.path
      end
    end
  end

  return nodes
end

-- Quoted attributes only. Godot 4 quotes every value that matters here, and
-- accepting bare ones would read `instance=ExtResource("1_x")` as the value
-- `ExtResource(` -- which is what `H.resource_id()` is for.
H.attributes = function(text)
  local attrs = {}
  for key, value in text:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do
    attrs[key] = value
  end
  return attrs
end

-- The `[ext_resource]` id in `<key> = ExtResource("id")`.
--
-- The frontier pattern is what keeps `script` from also matching an exported
-- property such as `death_script`, which points at a resource of the node's own
-- rather than at the script attached to it.
H.resource_id = function(text, key)
  return text:match(('%%f[%%w_]%s%%s*=%%s*ExtResource%%(%%s*"([^"]*)"%%s*%%)'):format(key))
end

H.node = function(attrs, instance, line)
  local name, parent = attrs.name or '', attrs.parent
  local path, depth = '.', 0

  if parent == '.' then
    path, depth = name, 1
  elseif parent ~= nil and parent ~= '' then
    -- One level for the root the parent path is relative to, one for the
    -- parent itself, and one per component below it
    path, depth = parent .. '/' .. name, 2 + select(2, parent:gsub('/', ''))
  end

  return {
    name = name,
    -- Absent for a node that only overrides properties of one inside an
    -- instanced scene: its type lives in the other file
    type = attrs.type or (instance ~= nil and (instance.type or 'PackedScene')) or nil,
    parent = parent,
    path = path,
    depth = depth,
    line = line,
    instance = instance ~= nil and instance.path or nil,
  }
end

-- Rendering ------------------------------------------------------------------
H.show = function(res, root, config)
  local path = Project.to_path(root, res)
  if vim.fn.filereadable(path) ~= 1 then
    H.notify(('%s is not a readable scene file'):format(res), 'ERROR')
    return false
  end

  local nodes = H.parse(vim.fn.readfile(path))
  local lines, spans = H.render(nodes, config)

  local buf_id = H.pane_buf(config)
  local line = H.cursor_line(buf_id)
  local win_id = H.pane_open(buf_id, config)

  H.write(buf_id, vim.list_extend({ ('Scene: %s'):format(res) }, lines))
  H.highlight(buf_id, spans)

  H.pane.scene, H.pane.root, H.pane.path = res, root, path
  H.pane.nodes = {}
  for index, node in ipairs(nodes) do
    H.pane.nodes[index + 1] = node
  end

  H.place_cursor(win_id, line)
  return true
end

-- Display lines for the nodes, and the icon spans to highlight. A span's `line`
-- is already the 0-based buffer row: the header line the pane prepends shifts
-- every node down by exactly the one line that 1-based indexing takes back.
H.render = function(nodes, config)
  local icons = H.resolve_icons(config.icons)
  local lines, spans = {}, {}

  for _, node in ipairs(nodes) do
    local indent = ('  '):rep(node.depth)
    local icon = H.icon(node, icons)
    local text = indent
      .. (icon ~= nil and (icon .. ' ') or '')
      .. (node.name ~= '' and node.name or '<unnamed>')

    -- What a node instances says more than `PackedScene` does
    local label = node.instance or node.type
    if label ~= nil then
      text = text .. (' [%s]'):format(label)
    end
    if node.script ~= nil then
      text = text .. (icons ~= nil and icons.script_suffix or ' *')
    end

    table.insert(lines, text)
    if icon ~= nil then
      local group = 'GdevScenetreeIcon' .. (H.category(node.type) or '')
      table.insert(
        spans,
        { line = #lines, col = #indent, end_col = #indent + #icon, group = group }
      )
    end
  end

  if #lines == 0 then
    table.insert(lines, 'no [node] sections in this scene')
  end
  return lines, spans
end

H.resolve_icons = function(icons)
  if icons == false then
    return nil
  end
  if type(icons) ~= 'table' then
    return H.icons[icons]
  end
  return vim.tbl_deep_extend('force', vim.deepcopy(H.icons.nerdfont), icons)
end

H.icon = function(node, icons)
  if icons == nil then
    return nil
  end
  if node.type == nil then
    return icons.generic
  end

  local icon = icons.types[node.type]
  if icon ~= nil then
    return icon
  end

  for _, family in ipairs(H.icon_families) do
    if vim.endswith(node.type, family.suffix) and icons.types[family.type] ~= nil then
      return icons.types[family.type]
    end
  end

  return icons.generic
end

-- Category name whose highlight group colors this type's icon, or `nil` when
-- the type belongs to none and the generic group is the answer.
H.category = function(node_type)
  if node_type == nil then
    return 'Grey'
  end
  if H.categories[node_type] ~= nil then
    return H.categories[node_type]
  end

  if vim.endswith(node_type, 'EditorPlugin') then
    return 'Yellow'
  end
  if vim.endswith(node_type, '3D') then
    return 'Red'
  end
  if vim.endswith(node_type, '2D') then
    return 'Blue'
  end
  for _, suffix in ipairs(H.control_suffixes) do
    if vim.endswith(node_type, suffix) then
      return 'Green'
    end
  end
end

H.highlight = function(buf_id, spans)
  vim.api.nvim_buf_clear_namespace(buf_id, H.ns_id, 0, -1)
  vim.api.nvim_buf_set_extmark(
    buf_id,
    H.ns_id,
    0,
    0,
    { end_row = 1, hl_group = 'GdevScenetreeHeader' }
  )

  for _, span in ipairs(spans) do
    local opts = { end_col = span.end_col, hl_group = span.group }
    vim.api.nvim_buf_set_extmark(buf_id, H.ns_id, span.line, span.col, opts)
  end
end

H.write = function(buf_id, lines)
  vim.bo[buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  vim.bo[buf_id].modifiable = false
end

-- Refreshing keeps your place in the tree; a fresh render starts on the first
-- node, which is the scene root. Read before the pane is opened, since opening
-- one puts the cursor on line 1.
H.cursor_line = function(buf_id)
  local win_id = H.pane.win_id
  local showing = win_id ~= nil
    and vim.api.nvim_win_is_valid(win_id)
    and vim.api.nvim_win_get_buf(win_id) == buf_id
  return showing and vim.api.nvim_win_get_cursor(win_id)[1] or 2
end

-- Clamped, since the scene may have lost nodes since it was last parsed
H.place_cursor = function(win_id, line)
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win_id))
  vim.api.nvim_win_set_cursor(win_id, { math.min(math.max(line, 1), count), 0 })
end

-- The pane -------------------------------------------------------------------
H.pane_buf = function(config)
  local buf_id = H.pane.buf_id
  if buf_id == nil or not vim.api.nvim_buf_is_valid(buf_id) then
    -- A reloaded module starts with empty state while the buffer its previous
    -- incarnation named is still around, and buffer names have to be unique
    buf_id = H.find_buf(H.buf_name)
  end

  if buf_id == nil then
    buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf_id, H.buf_name)
    vim.bo[buf_id].filetype = 'gdev-scenetree'
    vim.bo[buf_id].modifiable = false
  end

  H.pane.buf_id = buf_id
  H.create_mappings(buf_id, config)
  return buf_id
end

-- Re-created on every render rather than once with the buffer, so a changed
-- `config.mappings` takes effect without closing the pane -- which is also why
-- the previous set has to go first.
H.create_mappings = function(buf_id, config)
  for _, lhs in ipairs(H.pane.mappings) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = buf_id })
  end
  H.pane.mappings = {}

  -- `H.map()` is what makes an empty `lhs` mean "no mapping"; returning early
  -- only keeps the empty one out of the list of mappings to undo next time
  local map = function(lhs, fn, desc)
    if lhs == '' then
      return
    end
    H.map(
      'n',
      lhs,
      ('<Cmd>lua GdevScenetree.%s()<CR>'):format(fn),
      { buffer = buf_id, desc = desc }
    )
    table.insert(H.pane.mappings, lhs)
  end

  map(config.mappings.jump, 'jump_to_node', 'Jump to node in scene file')
  map(config.mappings.yank, 'yank_node_path', 'Yank node path')
  map(config.mappings.script, 'open_script', 'Open attached script')
  map(config.mappings.refresh, 'refresh', 'Reparse the scene')
  map(config.mappings.close, 'close', 'Close the scene tree')
end

H.pane_open = function(buf_id, config)
  local win_id = H.pane.win_id
  if win_id ~= nil and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, buf_id)
    vim.api.nvim_set_current_win(win_id)
    return win_id
  end

  -- Whatever window the pane is opened from is where jumps go back to
  H.pane.source_win_id = vim.api.nvim_get_current_win()

  local width = math.max(math.floor(vim.o.columns * config.buffer.size), H.min_width)
  win_id =
    vim.api.nvim_open_win(buf_id, true, { split = config.buffer.position, win = -1, width = width })
  H.pane.win_id = win_id
  H.window_options(win_id)

  return win_id
end

-- A tree is navigated, not edited: nothing in the gutter, no wrapping (deep
-- nesting is long and scrolls better than it folds), and a visible cursor line
-- because every mapping acts on it.
H.window_options = function(win_id)
  local wo = vim.wo[win_id]
  wo.wrap, wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn =
    false, false, false, 'no', '0'
  wo.cursorline, wo.winfixwidth, wo.list, wo.spell = true, true, false, false
end

-- Navigation ------------------------------------------------------------------
-- Node the cursor is on, or `nil` -- with the reason reported -- when the
-- cursor is not in the pane at all, or is on its header line.
H.node_at_cursor = function()
  local buf_id = H.pane.buf_id
  if buf_id == nil or vim.api.nvim_get_current_buf() ~= buf_id then
    H.notify('the cursor is not in the scene tree pane', 'WARN')
    return nil
  end

  local node = H.pane.nodes[vim.api.nvim_win_get_cursor(0)[1]]
  if node == nil then
    H.notify('the cursor is not on a node', 'WARN')
  end
  return node
end

-- Window to open a file in: the one the pane was opened from while it is still
-- there, else any other ordinary window, else `nil` -- which means the pane has
-- become the only window and the caller has to make one.
H.source_window = function()
  local candidates = { H.pane.source_win_id }
  vim.list_extend(candidates, vim.api.nvim_list_wins())

  for _, win_id in ipairs(candidates) do
    local usable = win_id ~= H.pane.win_id and vim.api.nvim_win_is_valid(win_id)
    if usable and vim.api.nvim_win_get_config(win_id).relative == '' then
      return win_id
    end
  end
end

-- Deliberately not `:edit`: that fails on a file already open and modified
-- somewhere else, which a jump has no business refusing.
H.edit = function(path)
  local buf_id = vim.fn.bufadd(path)
  vim.fn.bufload(buf_id)
  vim.bo[buf_id].buflisted = true

  local win_id = H.source_window()
  if win_id == nil then
    local position = H.get_config().buffer.position == 'left' and 'right' or 'left'
    win_id = vim.api.nvim_open_win(buf_id, false, { split = position, win = -1 })
  else
    vim.api.nvim_win_set_buf(win_id, buf_id)
  end

  vim.api.nvim_set_current_win(win_id)
  return win_id
end

-- Paths ----------------------------------------------------------------------
-- Only a normal file buffer says where the project is. The pane itself carries
-- a name too, and searching upward from `gdev://scene-tree` finds nothing --
-- worse than falling back to the working directory.
H.buffer_path = function()
  if vim.bo.buftype ~= '' then
    return nil
  end

  local path = vim.api.nvim_buf_get_name(0)
  return path ~= '' and path or nil
end

-- The pane is where the cursor is once it opens, and it belongs to no project
-- of its own -- but it remembers the one it was opened for, which beats the
-- working directory the `nil` path would otherwise fall back to.
H.find_root = function()
  if H.pane.root ~= nil and vim.api.nvim_get_current_buf() == H.pane.buf_id then
    return H.pane.root
  end
  return Project.find_root(H.buffer_path())
end

-- Absolute path of a scene named in any form `Project.to_res()` accepts, or
-- `nil` when there is no project around the current buffer or the scene is not
-- inside it. The file does not have to exist.
H.scene_path = function(scene)
  local root = H.find_root()
  if root == nil then
    return nil
  end

  local res = Project.to_res(root, scene)
  return res ~= nil and Project.to_path(root, res) or nil
end

H.report_no_project = function()
  H.notify('no `project.godot` above the current buffer or working directory', 'ERROR')
  return false
end

H.find_buf = function(name)
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf_id) == name then
      return buf_id
    end
  end
end

return GdevScenetree
