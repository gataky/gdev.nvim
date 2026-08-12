-- Godot-project domain knowledge, shared by every `gdev.*` module that has to
-- reason about a project on disk. Both `gdev.run` and `gdev.scenetree` need to
-- answer the same four questions -- where the project starts, what a file's
-- `res://` name is, which scenes exist, and which of them use a given script --
-- and neither one wants its own copy of the answers.
--
-- Not a feature module: no `setup()`, no global table, no vimdoc, no config.
-- 'lua/gdev/util.lua' is the other half of that split and holds per-module
-- plumbing; this file holds what is specific to Godot.
--
-- Two rules keep it usable from more than one module:
--
-- - The project root is always an argument, never rediscovered here. A command
--   resolves it once and every subsequent answer is consistent, even if the
--   user changes buffer while a picker is open.
-- - Nothing here prompts, notifies or raises. Functions return `nil` or an
--   empty list; deciding what that means to the user, and in what words, is
--   the module's job, and the wording differs between modules.
--
-- Plain comments on purpose: `---` would put this internal module into the
-- generated vimdoc alongside the user-facing ones.
local Project = {}
local H = {}

-- Directory holding the `project.godot` above `path`, or `nil` when there is
-- none above it.
--
-- `path` may name a file or a directory; `nil` or `''` starts the search at the
-- current working directory, which is what keeps commands working from a buffer
-- with no file behind it. The result is absolute and normalized, so it compares
-- with `==` against anything else this module returns.
Project.find_root = function(path)
  local start = path
  if type(start) ~= 'string' or start == '' then start = vim.uv.cwd() or '.' end
  if vim.fn.isdirectory(start) == 0 then start = vim.fs.dirname(start) end

  local marker = vim.fs.find(H.marker, { upward = true, path = start, type = 'file' })[1]
  if marker == nil then return nil end

  -- |vim.fs.find()| answers in the same shape it was asked, so a relative
  -- `path` yields a relative root -- which every containment check downstream
  -- would then compare against absolute buffer names
  return H.absolute(vim.fs.dirname(marker))
end

-- `path` as the `res://` name Godot knows it by, or `nil` when it does not
-- point inside `root`.
--
-- Accepts an absolute path, a path relative to `root`, or a `res://` name --
-- which is re-resolved rather than trusted, so `res://../elsewhere.tscn` is
-- rejected like any other escape from the project. `.`, `..` and repeated
-- separators are resolved first, so "inside" means inside after normalization
-- rather than textually. The file does not have to exist.
--
-- `root` itself maps to `res://`, which is what Godot calls the project root.
Project.to_res = function(root, path)
  root = H.normalize_root(root)
  if root == nil or type(path) ~= 'string' or path == '' then return nil end

  local relative = path:match('^res://(.*)$') or path
  local absolute = vim.fs.normalize(vim.startswith(relative, '/') and relative or (root .. '/' .. relative))

  if absolute == root then return 'res://' end
  if not vim.startswith(absolute, root .. '/') then return nil end

  return 'res://' .. absolute:sub(#root + 2)
end

-- Absolute path a `res://` name points at, or `nil` when `res` is not a
-- `res://` name or resolves outside `root`. The inverse of `Project.to_res()`,
-- with the same normalization and containment rules; the file does not have to
-- exist.
Project.to_path = function(root, res)
  root = H.normalize_root(root)
  if root == nil or type(res) ~= 'string' then return nil end

  local relative = res:match('^res://(.*)$')
  if relative == nil then return nil end

  local absolute = vim.fs.normalize(root .. '/' .. relative)
  if absolute ~= root and not vim.startswith(absolute, root .. '/') then return nil end

  return absolute
end

-- Every scene in the project, as sorted `res://` names. Empty when `root` is
-- `nil` or holds no scenes.
Project.list_scenes = function(root) return H.to_res_list(root, H.scene_files(root)) end

-- Sorted `res://` names of the scenes that reference `script`, which may be
-- given in any form `Project.to_res()` accepts.
--
-- Matching is textual: a scene uses a script when the script's `res://` name
-- appears quoted in the scene file, which is how `[ext_resource]` records it in
-- every `.tscn` variant Godot 4 writes -- with or without the `uid` that 4.4
-- added. Requiring the quotes is what stops `res://player.gd` from matching a
-- scene that only mentions `res://player.gdshader`.
--
-- An empty list means both "no scene uses it" and "that path is not in this
-- project". A caller that has to tell those apart checks `Project.to_res()`
-- first.
Project.scenes_with_script = function(root, script)
  local res = Project.to_res(root, script)
  if res == nil then return {} end

  local needle = '"' .. res .. '"'
  local used = vim.tbl_filter(function(path) return H.file_contains(path, needle) end, H.scene_files(root))

  return H.to_res_list(root, used)
end

-- Whether `path` names a Godot scene file.
Project.is_scene = function(path) return H.has_extension(path, { H.scene_extension }) end

-- Whether `path` names a Godot script, according to `extensions` -- bare
-- extensions without the dot, `nil` for `{ 'gd' }`.
--
-- That list is the C# seam. Every entry point that starts from "the script I am
-- looking at" goes through here, so adding `'cs'` to a module's configured list
-- is all C# support needs from this file.
Project.is_script = function(path, extensions) return H.has_extension(path, extensions or H.default_script_extensions) end

-- Helper data ================================================================
-- File whose presence marks a directory as the root of a Godot project
H.marker = 'project.godot'

H.scene_extension = 'tscn'

H.default_script_extensions = { 'gd' }

-- Helper functionality =======================================================
H.normalize_root = function(root)
  if type(root) ~= 'string' or root == '' then return nil end
  return H.absolute(root)
end

-- Symlinks are deliberately not resolved: a buffer name keeps whatever path the
-- file was opened by, and a root that resolved them would stop matching it.
H.absolute = function(path) return vim.fs.normalize(vim.fn.fnamemodify(path, ':p')) end

-- Absolute paths of every scene file in the project.
--
-- `nosuf` is on: 'wildignore' and 'suffixes' are the user's editing
-- preferences and have no business hiding scenes from a project-wide answer.
-- `**` does not descend into directories whose name starts with a dot, which is
-- what keeps Godot's `.godot/` cache out of the result -- worth preserving if
-- this is ever rewritten on top of |vim.fs.find()|, which has no such rule.
H.scene_files = function(root)
  root = H.normalize_root(root)
  if root == nil then return {} end
  return vim.fn.globpath(root, '**/*.' .. H.scene_extension, true, true)
end

H.to_res_list = function(root, paths)
  local res_paths = {}
  for _, path in ipairs(paths) do
    local res = Project.to_res(root, path)
    if res ~= nil then table.insert(res_paths, res) end
  end

  -- Redundant against today's `globpath()`, which sorts its own matches, but
  -- that is an implementation detail of Vim's wildcard expansion and the order
  -- is a promise these functions make. Removing it changes no test.
  table.sort(res_paths)
  return res_paths
end

H.file_contains = function(path, needle)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return false end
  return vim.iter(lines):any(function(line) return line:find(needle, 1, true) ~= nil end)
end

H.has_extension = function(path, extensions)
  if type(path) ~= 'string' or type(extensions) ~= 'table' then return false end

  local extension = path:match('%.([^./]+)$')
  return extension ~= nil and vim.tbl_contains(extensions, extension)
end

return Project
