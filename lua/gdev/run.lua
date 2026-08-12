--- *gdev.run* Run a Godot project
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Starts the engine on the project around the current buffer, without
---   leaving Neovim. See |GdevRun.run_project()|.
--- - Runs a single scene: the one in the current buffer, one named on the
---   command line, or one picked from the project. See
---   |GdevRun.run_current_scene()|, |GdevRun.run_scene()| and
---   |GdevRun.pick_scene()|.
--- - Resolves scenes from a script buffer, so `:GdevRunCurrentScene` works
---   while you are editing the code rather than the scene.
--- - Optionally captures the engine's output into a scratch window instead of
---   letting a detached process write it nowhere. See |GdevRun.show_console()|.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.run').setup({})` (replace `{}`
--- with your `config` table). It will create global Lua table `GdevRun` which
--- you can use for scripting or manually (with `:lua GdevRun.*`).
---
--- See |GdevRun.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevrun_config` which should have same structure as `GdevRun.config`.
---
--- # Project and scene resolution ~
---
--- Every command starts by looking upward from the current buffer's file for a
--- `project.godot`, falling back to the current working directory when the
--- buffer has no file. That directory is what Godot is pointed at with
--- `--path`, and what scene names are resolved against.
---
--- A scene is named to the engine as a `res://` path. This module accepts that
--- form, a path relative to the project root, or an absolute path inside it,
--- and refuses anything that resolves outside the project -- including a
--- `res://` path that climbs out with `..`. Running a scene from another
--- project means opening a buffer in that project first.
---
--- `:GdevRunCurrentScene` in a `.tscn` buffer runs that scene. In a script
--- buffer it runs the scene that uses the script, or asks which one when
--- several do, via |vim.ui.select()|. Which files count as scripts is
--- `config.script_extensions`.
---
--- # Console ~
---
--- Off by default, and worth knowing why. A run with the console off is
--- detached: the game outlives this Neovim, and its output goes wherever a
--- detached process' output goes. With the console on, the run is attached
--- instead -- output is streamed into a scratch window, `print()` and engine
--- errors land in front of you, and quitting Neovim takes the game with it.
---
--- Only one captured run happens at a time; starting a second while the first
--- is alive is refused rather than interleaved into the same window. Detached
--- runs are not counted or limited.
---
--- A run opens the console window without taking the cursor, so you can keep
--- editing while output arrives -- and so the next command still resolves the
--- project from the file you are in rather than from the console. Moving there
--- is `:GdevRunConsole`, which also reopens the window after `q` closed it; the
--- output of the last run outlives its window.
---
--- The exception is `console.buffer.position = 'current'`, which shows the
--- console in the window you are in, because that is what it is for.
---
--- # The Godot executable ~
---
--- `config.godot` is looked up with |executable()|, so a bare name is resolved
--- on `$PATH` and a path is used as given. Projects pinned to different engine
--- versions are the usual reason to set it -- to an absolute path, or to a
--- wrapper from a version manager, per project through
--- `vim.b.gdevrun_config`.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevrun_disable` (globally) or `vim.b.gdevrun_disable`
--- (for a buffer) to `true`. |GdevRun.status()| keeps answering while disabled,
--- since that is when it gets asked.
---@tag GdevRun

-- Module definition ==========================================================
local GdevRun = {}
local H = require('gdev.util').new('run', GdevRun)

-- Project-root discovery and `res://` resolution, shared with 'gdev.scenetree'
local Project = require('gdev.project')

--- Module setup
---
---@param config table|nil Module config table. See |GdevRun.config|.
---
---@usage >lua
---   require('gdev.run').setup() -- use default config
---   -- OR
---   require('gdev.run').setup({}) -- replace {} with your config table
--- <
GdevRun.setup = function(config)
  -- Export module
  _G.GdevRun = GdevRun

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.create_user_commands()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevRun.config = {
  -- Godot executable: a name to find on `$PATH`, or a path to run directly.
  -- Point it at a version manager's wrapper to pin an engine per project.
  godot = 'godot',

  -- Extensions of files treated as Godot scripts when resolving which scene to
  -- run from the current buffer. Replaces this list rather than adding to it.
  script_extensions = { 'gd' },

  -- Capture of the engine's output. With `enabled = false` a run is detached
  -- and its output is lost; see |GdevRun| for the trade.
  console = {
    -- Whether to capture output at all
    enabled = false,

    -- Where to show it: `'buffer'` for a split, `'float'` for a floating window
    renderer = 'buffer',

    -- Split placement. `position` is `'bottom'`, `'right'` or `'current'`
    -- (reuse the window you are in); `size` is a fraction of the editor.
    buffer = {
      position = 'bottom',
      size = 0.3,
    },

    -- Floating window, sized as a fraction of the editor and centered in it.
    -- `border` takes anything |nvim_open_win()| accepts.
    float = {
      width = 0.8,
      height = 0.25,
      border = 'rounded',
    },
  },
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Run the whole project
---
--- Starts the engine on the project around the current buffer, with no scene
--- argument, so Godot plays the project's main scene.
---
---@param opts table|nil Options overriding `GdevRun.config` for this call.
---
---@return boolean Whether the engine was started.
GdevRun.run_project = function(opts)
  if H.is_disabled() then
    return false
  end

  local config, root = H.resolve(opts)
  if root == nil then
    return false
  end

  return H.launch(nil, root, config)
end

--- Run the scene the current buffer is about
---
--- In a `.tscn` buffer that is the scene itself. In a script buffer it is the
--- scene that references the script -- run straight away when exactly one does,
--- offered through |vim.ui.select()| when several do, and reported as an error
--- when none does, which usually means the script is not attached to anything
--- yet.
---
--- Anything else -- a buffer with no file, a file of another kind, a file
--- belonging to no Godot project -- is an error naming what was expected. Use
--- |GdevRun.pick_scene()| when the buffer is not the thing you want to run.
---
---@param opts table|nil Options overriding `GdevRun.config` for this call.
---
---@return boolean Whether the engine was started, or a picker was opened.
GdevRun.run_current_scene = function(opts)
  if H.is_disabled() then
    return false
  end

  local config, root = H.resolve(opts)
  if root == nil then
    return false
  end

  local path = H.buffer_path()
  if path == nil then
    H.notify('the current buffer has no file, so there is no scene to run', 'ERROR')
    return false
  end

  -- The root was found by walking up from this very path, so it always
  -- contains it and `to_res()` cannot fail here
  if Project.is_scene(path) then
    return H.launch(Project.to_res(root, path), root, config)
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
    return H.launch(scenes[1], root, config)
  end

  return H.select(scenes, ('Scenes using %s'):format(res), root, config)
end

--- Run a named scene
---
--- `scene` may be a `res://` path, a path relative to the project root, or an
--- absolute path inside it; see |GdevRun| for how they are resolved. The scene
--- file is not required to exist -- Godot reports a missing one better than a
--- guess from here would.
---
---@param scene string Scene to run.
---@param opts table|nil Options overriding `GdevRun.config` for this call.
---
---@return boolean Whether the engine was started.
GdevRun.run_scene = function(scene, opts)
  if H.is_disabled() then
    return false
  end

  H.check_type('scene', scene, 'string')

  local config, root = H.resolve(opts)
  if root == nil then
    return false
  end

  local res = Project.to_res(root, scene)
  if res == nil then
    H.notify(('%s is not inside %s'):format(scene, root), 'ERROR')
    return false
  end

  return H.launch(res, root, config)
end

--- Pick a scene to run
---
--- Offers every scene in the project through |vim.ui.select()|, sorted. Users
--- with a `vim.ui.select` adapter (Telescope, fzf-lua, snacks) get their own
--- picker here for free.
---
---@param opts table|nil Options overriding `GdevRun.config` for this call.
---
---@return boolean Whether a picker was opened.
GdevRun.pick_scene = function(opts)
  if H.is_disabled() then
    return false
  end

  local config, root = H.resolve(opts)
  if root == nil then
    return false
  end

  local scenes = Project.list_scenes(root)
  if #scenes == 0 then
    H.notify(('no scenes found in %s'):format(root), 'WARN')
    return false
  end

  return H.select(scenes, 'Godot scenes', root, config)
end

--- Show the captured console
---
--- Reopens the window holding the output of the last captured run, or focuses
--- it when it is already open. Output survives closing the window, so this is
--- how you get back to what a run printed.
---
--- Nothing has been captured until a run happens with `config.console.enabled`
--- set; detached runs leave nothing to show.
---
---@param opts table|nil Options overriding `GdevRun.config` for this call.
---
---@return boolean Whether a console window is now open.
GdevRun.show_console = function(opts)
  if H.is_disabled() then
    return false
  end

  local buf_id = H.console.buf_id
  if buf_id == nil or not vim.api.nvim_buf_is_valid(buf_id) then
    H.notify('no Godot output has been captured yet')
    return false
  end

  H.console_open(buf_id, H.get_config(opts), true)
  H.console_follow(buf_id)
  return true
end

--- Report what a run would use
---
--- Pure: resolves the project root and the engine to run without starting
--- anything, so it is safe to call from |:checkhealth| and from a statusline.
--- Keeps answering while the module is disabled, since that is when it gets
--- asked.
---
---@param opts table|nil Options overriding `GdevRun.config` for this call.
---
---@return table `{ root = string|nil, godot = string, executable = boolean }`,
---   where `root` is the project around the current buffer and `executable`
---   says whether `godot` can be run.
GdevRun.status = function(opts)
  local config = H.get_config(opts)
  return {
    root = Project.find_root(H.buffer_path()),
    godot = config.godot,
    executable = vim.fn.executable(config.godot) == 1,
  }
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevRun.config)

-- The one captured run and the window showing it. Deliberately untouched by
-- `setup()`: re-configuring must not orphan a process or a buffer.
H.console = {
  buf_id = nil,
  win_id = nil,
  process = nil,
  -- Trailing bytes of each stream that have not been terminated by a newline
  partial = { stdout = '', stderr = '' },
}

-- Name of the console buffer. Buffer names are unique, which is what lets a
-- reloaded module find the buffer its previous incarnation created.
H.console_name = 'gdev://run-console'

-- Floor on a console window's size, in cells. Small on purpose: a configured
-- fraction should be honored rather than quietly replaced by a nicer number.
H.min_size = 3

H.renderers = { 'buffer', 'float' }

H.positions = { 'bottom', 'current', 'right' }

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('godot', config.godot, 'string')
  H.check_type('script_extensions', config.script_extensions, 'table')
  H.check_type('console', config.console, 'table')
  H.check_type('console.enabled', config.console.enabled, 'boolean')
  H.check_one_of('console.renderer', config.console.renderer, H.renderers)
  H.check_type('console.buffer', config.console.buffer, 'table')
  H.check_one_of('console.buffer.position', config.console.buffer.position, H.positions)
  H.check_fraction('console.buffer.size', config.console.buffer.size)
  H.check_type('console.float', config.console.float, 'table')
  H.check_fraction('console.float.width', config.console.float.width)
  H.check_fraction('console.float.height', config.console.float.height)
  H.check_border('console.float.border', config.console.float.border)

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

-- |nvim_open_win()| takes a border style by name or as an array of characters,
-- and both are worth allowing through
H.check_border = function(field, value)
  if type(value) == 'string' or type(value) == 'table' then
    return
  end
  H.error(('`%s` should be a string or table, not %s'):format(field, type(value)))
end

H.apply_config = function(config)
  GdevRun.config = config
end

H.create_user_commands = function()
  local command = function(name, callback, opts)
    vim.api.nvim_create_user_command(name, callback, opts or {})
  end

  command('GdevRunProject', function()
    GdevRun.run_project()
  end, { desc = 'Run the Godot project' })
  command('GdevRunCurrentScene', function()
    GdevRun.run_current_scene()
  end, { desc = 'Run the current Godot scene' })
  command('GdevRunScene', function(data)
    GdevRun.run_scene(data.args)
  end, {
    nargs = 1,
    complete = 'file',
    desc = 'Run a Godot scene by path',
  })
  command('GdevRunPicker', function()
    GdevRun.pick_scene()
  end, { desc = 'Pick a Godot scene to run' })
  command('GdevRunConsole', function()
    GdevRun.show_console()
  end, { desc = 'Show the captured Godot output' })
end

-- Launching ------------------------------------------------------------------
-- Config and project root, the two things every entry point needs first. A
-- `nil` root has already been reported when it comes back.
H.resolve = function(opts)
  local config = H.get_config(opts)
  local root = Project.find_root(H.buffer_path())
  if root == nil then
    H.notify('no `project.godot` above the current buffer or working directory', 'ERROR')
  end
  return config, root
end

H.launch = function(scene, root, config)
  if vim.fn.executable(config.godot) ~= 1 then
    H.notify(H.missing_godot_message(config.godot), 'ERROR')
    return false
  end

  local cmd = { config.godot, '--path', root }
  if scene ~= nil then
    table.insert(cmd, scene)
  end

  if config.console.enabled then
    return H.console_run(cmd, root, config)
  end

  -- Detached, so closing Neovim leaves the game running. Output is not piped
  -- anywhere a user can read; `config.console.enabled` is the fix for that.
  vim.system(cmd, { cwd = root, detach = true, text = true }, vim.schedule_wrap(H.report_exit))
  return true
end

H.report_exit = function(out)
  if out.code == 0 then
    return
  end

  local reported = vim.trim(out.stderr or '')
  H.notify(reported ~= '' and reported or ('Godot exited with %d'):format(out.code), 'ERROR')
end

-- Launches straight from the choice rather than going back through
-- `GdevRun.run_scene()`: the scenes offered were resolved against `root`, and
-- re-resolving on the way out would answer for whatever buffer the user
-- happens to be in when the picker closes.
H.select = function(scenes, prompt, root, config)
  vim.ui.select(scenes, { prompt = prompt }, function(choice)
    if choice == nil then
      return
    end
    H.launch(choice, root, config)
  end)
  return true
end

H.missing_godot_message = function(executable)
  return table.concat({
    ('`%s` is not executable. Either:'):format(executable),
    '- put the Godot binary on $PATH as `godot`',
    '- set `godot` in `require("gdev.run").setup()` to its full path',
    '- point `godot` at a wrapper from a version manager such as gdvm, and set',
    '  `vim.b.gdevrun_config` per project to pick the engine that project needs',
  }, '\n')
end

-- Console --------------------------------------------------------------------
H.console_run = function(cmd, root, config)
  if H.console.process ~= nil then
    H.notify('a captured run is still going; wait for it to exit or turn the console off', 'WARN')
    return false
  end

  local buf_id = H.console_buf()
  H.console_open(buf_id, config, false)
  H.console_write(buf_id, 0, -1, {
    ('Command: %s'):format(table.concat(cmd, ' ')),
    ('Project: %s'):format(root),
    '',
  })
  H.console.partial = { stdout = '', stderr = '' }

  -- Stream callbacks run in a fast event context, where buffer writes are not
  -- allowed; scheduling the whole body keeps chunks in the order they arrived.
  local stream = function(name)
    return function(err, data)
      vim.schedule(function()
        if err ~= nil then
          return H.console_append({ ('[%s error] %s'):format(name, err) })
        end
        H.console_append(H.console_split(name, data))
      end)
    end
  end

  local ok, process = pcall(vim.system, cmd, {
    cwd = root,
    text = true,
    stdout = stream('stdout'),
    stderr = stream('stderr'),
  }, function(out)
    vim.schedule(function()
      H.console_finish(out)
    end)
  end)

  if not ok then
    H.console_append({ ('[spawn error] %s'):format(process) })
    return false
  end

  H.console.process = process
  return true
end

-- Complete lines from a chunk, holding back whatever followed the last newline
-- until the next chunk (or the exit) completes it
H.console_split = function(name, data)
  if data == nil or data == '' then
    return {}
  end

  local lines = vim.split(H.console.partial[name] .. data, '\n', { plain = true })
  H.console.partial[name] = table.remove(lines)

  return H.console_label(name, lines)
end

-- Streams interleave in one window, so the less usual one is marked
H.console_label = function(name, lines)
  if name ~= 'stderr' then
    return lines
  end
  return vim.tbl_map(function(line)
    return '[stderr] ' .. line
  end, lines)
end

H.console_finish = function(out)
  H.console.process = nil

  local lines = {}
  for _, name in ipairs({ 'stdout', 'stderr' }) do
    local pending = H.console.partial[name]
    if pending ~= '' then
      vim.list_extend(lines, H.console_label(name, { pending }))
    end
    H.console.partial[name] = ''
  end

  vim.list_extend(
    lines,
    { '', ('[exited] code=%d signal=%d'):format(out.code or 0, out.signal or 0) }
  )
  H.console_append(lines)
end

H.console_buf = function()
  local buf_id = H.console.buf_id
  if buf_id ~= nil and vim.api.nvim_buf_is_valid(buf_id) then
    return buf_id
  end

  -- A reloaded module starts with empty state while the buffer its previous
  -- incarnation named is still around, and buffer names have to be unique
  buf_id = H.find_buf(H.console_name)
  if buf_id == nil then
    buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf_id, H.console_name)
    vim.bo[buf_id].filetype = 'log'
    vim.bo[buf_id].modifiable = false
    H.map('n', 'q', '<Cmd>close<CR>', { buffer = buf_id, desc = 'Close the Godot console' })
  end

  H.console.buf_id = buf_id
  return buf_id
end

-- `focus` is false for a run and true for `:GdevRunConsole`. Starting a run
-- must not move the cursor: the project a command applies to comes from the
-- current buffer, and a console that stole the cursor would make the next
-- command resolve against itself.
H.console_open = function(buf_id, config, focus)
  local win_id = H.console.win_id

  if win_id ~= nil and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, buf_id)
    if focus then
      vim.api.nvim_set_current_win(win_id)
    end
  elseif config.console.renderer == 'float' then
    H.console.win_id = vim.api.nvim_open_win(buf_id, focus, H.float_config(config.console.float))
  else
    H.console.win_id = H.open_split(buf_id, config.console.buffer, focus)
  end

  H.window_options(H.console.win_id)
  return H.console.win_id
end

H.open_split = function(buf_id, opts, focus)
  -- `'current'` is the one placement that takes the cursor's window whether or
  -- not the caller asked to focus it; that is what the user chose it for
  if opts.position == 'current' then
    local win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win_id, buf_id)
    return win_id
  end

  local vertical = opts.position == 'right'
  local editor = vertical and vim.o.columns or vim.o.lines
  local win_config = { split = vertical and 'right' or 'below', win = -1 }
  win_config[vertical and 'width' or 'height'] =
    math.max(math.floor(editor * opts.size), H.min_size)

  return vim.api.nvim_open_win(buf_id, focus, win_config)
end

H.float_config = function(opts)
  local width =
    math.min(math.max(math.floor(vim.o.columns * opts.width), H.min_size), vim.o.columns)
  local height = math.min(math.max(math.floor(vim.o.lines * opts.height), H.min_size), vim.o.lines)

  return {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = opts.border,
    title = ' Godot console ',
    title_pos = 'center',
  }
end

-- A log is read, not edited: no wrapping (engine backtraces are long and the
-- columns line up), no numbers, nothing in the gutter
H.window_options = function(win_id)
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then
    return
  end

  local wo = vim.wo[win_id]
  wo.wrap, wo.number, wo.relativenumber, wo.signcolumn, wo.cursorline =
    false, false, false, 'no', false
end

H.console_write = function(buf_id, start, finish, lines)
  vim.bo[buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(buf_id, start, finish, false, lines)
  vim.bo[buf_id].modifiable = false
end

H.console_append = function(lines)
  local buf_id = H.console.buf_id
  if #lines == 0 or buf_id == nil or not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  H.console_write(buf_id, -1, -1, lines)
  H.console_follow(buf_id)
end

-- Keep the newest output in view, unconditionally rather than only while the
-- cursor already sits at the end. A console is read from the bottom, and the
-- alternative is a window that silently stops updating.
H.console_follow = function(buf_id)
  local win_id = H.console.win_id
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then
    return
  end
  if vim.api.nvim_win_get_buf(win_id) ~= buf_id then
    return
  end

  vim.api.nvim_win_set_cursor(win_id, { vim.api.nvim_buf_line_count(buf_id), 0 })
end

-- Paths ----------------------------------------------------------------------
-- Only a normal file buffer says anything about where the project is. A
-- console, a terminal or a help buffer carries a name too, and searching upward
-- from something like `gdev://run-console` finds nothing at all -- worse than
-- falling back to the working directory.
H.buffer_path = function()
  if vim.bo.buftype ~= '' then
    return nil
  end

  local path = vim.api.nvim_buf_get_name(0)
  return path ~= '' and path or nil
end

H.find_buf = function(name)
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf_id) == name then
      return buf_id
    end
  end
end

return GdevRun
