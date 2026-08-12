-- Tests for the Godot-project helpers shared by 'gdev.run' and
-- 'gdev.scenetree'. Like 'gdev.util' this is an internal module with no
-- `setup()`, so the baseline that applies is the per-function one: what each
-- contract promises, and what each returns when it cannot keep it.
local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

-- The fixture project lives at 'tests/dir-run/project', with 'outside.tscn' one
-- level above it to have something that is genuinely not in the project.
local load_project = function()
  child.lua([[
    _G.P = require('gdev.project')
    _G.root = vim.fs.normalize(vim.fn.fnamemodify('tests/dir-run/project', ':p'))
    _G.outside = vim.fs.normalize(vim.fn.fnamemodify('tests/dir-run/outside.tscn', ':p'))
  ]])
end

local root = function() return child.lua_get('_G.root') end
local lua_get = function(code, ...) return child.lua_get(code, { ... }) end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_project()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['find_root()'] = new_set()

T['find_root()']['finds the project a file belongs to'] = function()
  eq(lua_get('P.find_root(...)', 'tests/dir-run/project/Main.tscn'), root())
end

T['find_root()']['searches upward from a nested file'] = function()
  eq(lua_get('P.find_root(...)', 'tests/dir-run/project/scenes/Level.tscn'), root())
  eq(lua_get('P.find_root(...)', 'tests/dir-run/project/scripts/player.gd'), root())
end

T['find_root()']['accepts a directory'] = function()
  eq(lua_get('P.find_root(...)', 'tests/dir-run/project/scripts'), root())
  eq(lua_get('P.find_root(...)', 'tests/dir-run/project'), root())
end

T['find_root()']['falls back to the working directory'] = new_set({
  parametrize = { { 'nil' }, { '""' } },
}, {
  test = function(argument)
    -- Commands have to keep working from a buffer with no file behind it
    child.lua([[vim.fn.chdir('tests/dir-run/project/scenes')]])
    eq(child.lua_get('P.find_root(' .. argument .. ')'), root())
  end,
})

T['find_root()']['returns an absolute path'] = function()
  -- |vim.fs.find()| answers relatively when asked relatively, and a relative
  -- root would not match the absolute names buffers carry
  local resolved = lua_get('P.find_root(...)', 'tests/dir-run/project/Main.tscn')
  eq(resolved:sub(1, 1), '/')
end

T['find_root()']['returns nil outside any project'] = function()
  eq(lua_get('P.find_root(...)', 'tests/dir-run/outside.tscn'), vim.NIL)
end

T['to_res()'] = new_set()

T['to_res()']['converts an absolute path inside the project'] = function()
  eq(lua_get('P.to_res(_G.root, _G.root .. ...)', '/scenes/Level.tscn'), 'res://scenes/Level.tscn')
end

T['to_res()']['converts a path relative to the root'] = function()
  eq(lua_get('P.to_res(_G.root, ...)', 'scenes/Level.tscn'), 'res://scenes/Level.tscn')
end

T['to_res()']['is idempotent on a `res://` path'] = function()
  eq(lua_get('P.to_res(_G.root, ...)', 'res://scenes/Level.tscn'), 'res://scenes/Level.tscn')
end

T['to_res()']['normalizes the path first'] = function()
  eq(lua_get('P.to_res(_G.root, ...)', './scenes/../scenes//Level.tscn'), 'res://scenes/Level.tscn')
end

T['to_res()']['maps the root itself to `res://`'] = function() eq(child.lua_get('P.to_res(_G.root, _G.root)'), 'res://') end

T['to_res()']['rejects a path outside the project'] = new_set({
  parametrize = {
    -- Absolute, relative and `res://` spellings of the same escape: a
    -- `res://` path is re-resolved rather than trusted
    { '_G.outside' },
    { '"../outside.tscn"' },
    { '"res://../outside.tscn"' },
    { '"/etc/passwd"' },
  },
}, {
  test = function(argument) eq(child.lua_get('P.to_res(_G.root, ' .. argument .. ')'), vim.NIL) end,
})

T['to_res()']['rejects a sibling whose name starts with the root'] = function()
  -- Textual containment is not enough: '<root>-backup' is not in '<root>'
  eq(child.lua_get('P.to_res(_G.root, _G.root .. "-backup/Main.tscn")'), vim.NIL)
end

T['to_res()']['returns nil for missing arguments'] = new_set({
  parametrize = {
    { 'nil, "Main.tscn"' },
    { '"", "Main.tscn"' },
    { '_G.root, nil' },
    { '_G.root, ""' },
    { '_G.root, 1' },
  },
}, {
  test = function(arguments) eq(child.lua_get('P.to_res(' .. arguments .. ')'), vim.NIL) end,
})

T['to_path()'] = new_set()

T['to_path()']['resolves a `res://` path against the root'] = function()
  eq(lua_get('P.to_path(_G.root, ...)', 'res://scenes/Level.tscn'), root() .. '/scenes/Level.tscn')
end

T['to_path()']['maps `res://` to the root'] = function() eq(child.lua_get('P.to_path(_G.root, "res://")'), root()) end

T['to_path()']['reverses to_res()'] = function()
  eq(
    child.lua_get('P.to_path(_G.root, P.to_res(_G.root, _G.root .. "/scenes/Menu.tscn"))'),
    root() .. '/scenes/Menu.tscn'
  )
end

T['to_path()']['rejects anything that is not a `res://` path'] = new_set({
  parametrize = { { '"scenes/Level.tscn"' }, { '"/tmp/Level.tscn"' }, { 'nil' }, { '1' } },
}, {
  test = function(argument) eq(child.lua_get('P.to_path(_G.root, ' .. argument .. ')'), vim.NIL) end,
})

T['to_path()']['rejects a path that escapes the project'] = function()
  eq(child.lua_get('P.to_path(_G.root, "res://../outside.tscn")'), vim.NIL)
end

T['list_scenes()'] = new_set()

T['list_scenes()']['lists every scene, sorted'] = function()
  -- 'world.tscn' sits at the top level and sorts after 'scenes/', so a walk
  -- that returned its own order would put it in the wrong place
  eq(child.lua_get('P.list_scenes(_G.root)'), {
    'res://Main.tscn',
    'res://scenes/Level.tscn',
    'res://scenes/Menu.tscn',
    'res://scenes/Shaded.tscn',
    'res://world.tscn',
  })
end

T['list_scenes()']['skips dot-directories'] = function()
  -- Godot's '.godot/' cache holds copies of the very scenes being listed
  eq(child.lua_get('vim.tbl_contains(P.list_scenes(_G.root), "res://.godot/Cached.tscn")'), false)
end

T['list_scenes()']['is empty for a project with no scenes'] = function()
  child.lua([[_G.empty = vim.fs.normalize(vim.fn.fnamemodify('tests/dir-run/empty', ':p'))]])
  eq(child.lua_get('P.list_scenes(_G.empty)'), {})
end

T['list_scenes()']['is empty without a root'] = function() eq(child.lua_get('P.list_scenes(nil)'), {}) end

T['scenes_with_script()'] = new_set()

T['scenes_with_script()']['finds every scene using the script, sorted'] = function()
  eq(child.lua_get('P.scenes_with_script(_G.root, "scripts/player.gd")'), {
    'res://Main.tscn',
    'res://scenes/Menu.tscn',
    'res://world.tscn',
  })
end

T['scenes_with_script()']['finds a single user'] = function()
  eq(child.lua_get('P.scenes_with_script(_G.root, "scripts/level.gd")'), { 'res://scenes/Level.tscn' })
end

T['scenes_with_script()']['is empty for an unused script'] = function()
  -- 'scenes/Shaded.tscn' references 'res://scripts/orphan.gdshader', which has
  -- this script's name as a prefix: matching has to require the closing quote
  eq(child.lua_get('P.scenes_with_script(_G.root, "scripts/orphan.gd")'), {})
end

T['scenes_with_script()']['accepts every spelling of the script path'] = new_set({
  parametrize = { { '"scripts/level.gd"' }, { '"res://scripts/level.gd"' }, { '_G.root .. "/scripts/level.gd"' } },
}, {
  test = function(argument)
    eq(child.lua_get('P.scenes_with_script(_G.root, ' .. argument .. ')'), { 'res://scenes/Level.tscn' })
  end,
})

T['scenes_with_script()']['is empty for a script outside the project'] = function()
  eq(child.lua_get('P.scenes_with_script(_G.root, "../outside.gd")'), {})
end

T['is_scene()'] = new_set()

T['is_scene()']['recognizes scene files'] = new_set({
  parametrize = {
    { '"/a/b/Main.tscn"', true },
    { '"Main.tscn"', true },
    { '"/a/b/Main.scn"', false },
    { '"/a/b/player.gd"', false },
    -- A directory called 'tscn' is not a scene
    { '"/a/tscn/Main"', false },
    { 'nil', false },
  },
}, {
  test = function(argument, expected) eq(child.lua_get('P.is_scene(' .. argument .. ')'), expected) end,
})

T['is_script()'] = new_set()

T['is_script()']['defaults to GDScript'] = new_set({
  parametrize = {
    { '"/a/b/player.gd"', true },
    { '"/a/b/player.cs"', false },
    { '"/a/b/shader.gdshader"', false },
    { '"/a/b/Main.tscn"', false },
    { 'nil', false },
  },
}, {
  test = function(argument, expected) eq(child.lua_get('P.is_script(' .. argument .. ')'), expected) end,
})

T['is_script()']['respects the extension list'] = function()
  -- The C# seam: one extra extension is all a C# module has to supply
  eq(child.lua_get('P.is_script("/a/b/Player.cs", { "gd", "cs" })'), true)
  eq(child.lua_get('P.is_script("/a/b/player.gd", { "cs" })'), false)
end

return T
