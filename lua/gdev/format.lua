--- *gdev.format* GDScript formatting
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Formats Godot script buffers after they are written, by running an
---   external formatter over the saved file and reloading the buffer from it.
---   See |GdevFormat.format()|.
--- - Knows both GDScript formatters in circulation and takes an arbitrary
---   command line for anything else. See |GdevFormat.get_command()|.
--- - `:GdevFormat` formats on demand, including when format-on-save is off.
--- - Optional indent override for people who want spaces in a language whose
---   editor writes tabs.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.format').setup({})` (replace
--- `{}` with your `config` table). It will create global Lua table `GdevFormat`
--- which you can use for scripting or manually (with `:lua GdevFormat.*`).
---
--- See |GdevFormat.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevformat_config` which should have same structure as
--- `GdevFormat.config`.
---
--- # Formatters ~
---
--- Neither formatter ships with Godot or with this plugin; one of them has to
--- be on `$PATH`. A missing one is reported once, not once per save.
---
--- - `gdscript-formatter` (default), from GDQuest:
---   https://github.com/GDQuest/GDScript-formatter. Run with `--reorder-code`,
---   which sorts a script into Godot's documented member order.
--- - `gdformat`, from the godot-gdscript-toolkit:
---   https://github.com/Scony/godot-gdscript-toolkit.
---
--- Both rewrite files in place, which is why this module formats what is on
--- disk rather than buffer contents.
---
--- # Indentation ~
---
--- Off by default, because Neovim already handles it: the bundled `gdscript`
--- ftplugin sets `noexpandtab tabstop=4 softtabstop=0 shiftwidth=0` — tabs,
--- which is what Godot's own editor writes and what `gdscript-formatter`
--- produces. Setting `config.indent` to a number opts out of that and indents
--- with that many spaces instead.
---
--- Setting `vim.g.gdscript_recommended_style = 0` tells the ftplugin to leave
--- indentation options alone entirely, which is the other way to take control
--- of them. `config.indent` does not need it: this module's |FileType| hook
--- runs after the ftplugin and wins either way.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevformat_disable` (globally) or
--- `vim.b.gdevformat_disable` (for a buffer) to `true`.
---@tag GdevFormat

-- Module definition ==========================================================
local GdevFormat = {}
local H = require('gdev.util').new('format', GdevFormat)

--- Module setup
---
---@param config table|nil Module config table. See |GdevFormat.config|.
---
---@usage >lua
---   require('gdev.format').setup() -- use default config
---   -- OR
---   require('gdev.format').setup({}) -- replace {} with your config table
--- <
GdevFormat.setup = function(config)
  -- Export module
  _G.GdevFormat = GdevFormat

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.create_autocommands()
  H.create_user_commands()

  -- Godot buffers open before `setup()` ran never see the `FileType` event
  H.indent_open_buffers()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevFormat.config = {
  -- Formatter to run: `'gdscript-formatter'`, `'gdformat'`, or `false` for no
  -- formatting at all. Anything else belongs in `command`.
  formatter = 'gdscript-formatter',

  -- Command line to run instead of the one `formatter` implies, as a string
  -- (split on whitespace) or an argv array. The file path is appended to it.
  -- Set, it wins over `formatter`, including over `formatter = false`.
  command = nil,

  -- Whether to format Godot script buffers after writing them
  autoformat = true,

  -- Number of spaces to indent Godot scripts with, or `false` to leave
  -- indentation options untouched. `false` is not "no indentation": Neovim's
  -- bundled `gdscript` ftplugin already sets up tabs 4 columns wide, matching
  -- Godot's editor and both formatters. A number here overrides that with
  -- spaces, in this plugin's buffers only. See |GdevFormat| for how it relates
  -- to `vim.g.gdscript_recommended_style`.
  indent = false,
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Format a buffer's file
---
--- Runs the formatter over the file on disk and, once it succeeds, reloads the
--- buffer with |:checktime|. Asynchronous: it returns as soon as the process is
--- started, and reports failure through |vim.notify()| with whatever the
--- formatter wrote to stderr.
---
--- GDScript formatters rewrite files in place and do not read stdin, so buffer
--- contents never reach them. A modified buffer is therefore refused instead of
--- being formatted from its stale saved state.
---
--- Any buffer backed by a file is accepted. Restricting to Godot filetypes is
--- the on-save hook's business, not this function's, so `:GdevFormat` stays
--- usable in a buffer whose filetype was never detected.
---
---@param buf_id integer|nil Buffer handle, or 0 / `nil` for current buffer.
---@param opts table|nil Options overriding `GdevFormat.config` for this call.
---
---@return boolean Whether a formatter process was started.
GdevFormat.format = function(buf_id, opts)
  if H.is_disabled() then return false end

  buf_id = H.validate_buf_id(buf_id)

  local argv = GdevFormat.get_command(buf_id, opts)
  if argv == nil then return false end

  local path = vim.api.nvim_buf_get_name(buf_id)
  if path == '' then return false end

  if vim.bo[buf_id].modified then
    H.notify('buffer has unsaved changes; write it before formatting', 'WARN')
    return false
  end

  if vim.fn.executable(argv[1]) ~= 1 then
    H.notify_missing(argv[1])
    return false
  end

  table.insert(argv, path)
  vim.system(argv, { text = true }, vim.schedule_wrap(function(out) H.report(buf_id, argv, out) end))
  return true
end

--- Resolve the formatter command line
---
--- The argv |GdevFormat.format()| runs, without the file path it appends. Use
--- it to answer "what will actually run", and to find the executable a health
--- check should look for.
---
--- Keeps working while the module is disabled, since that is when it tends to
--- be asked.
---
--- Note that a `command` array in `vim.b.gdevformat_config` merges with the
--- configured one element by element rather than replacing it, per
--- |vim.tbl_deep_extend()|. The string form has no such wrinkle.
---
---@param buf_id integer|nil Buffer handle, or 0 / `nil` for current buffer.
---@param opts table|nil Options overriding `GdevFormat.config` for this call.
---
---@return table|nil Argv array, or `nil` when formatting is turned off.
GdevFormat.get_command = function(buf_id, opts)
  buf_id = H.validate_buf_id(buf_id)
  local config = H.get_config(opts, buf_id)

  local command = config.command
  if type(command) == 'table' then return vim.deepcopy(command) end
  if type(command) == 'string' then return vim.split(command, '%s+', { trimempty = true }) end

  return vim.deepcopy(H.formatter_argv[config.formatter])
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevFormat.config)

-- Command line each supported formatter is run with. `--reorder-code` is part
-- of what makes `gdscript-formatter` a formatter rather than a pretty-printer;
-- `gdformat` has no equivalent flag. `false` maps to nothing, which is what
-- turns formatting off.
H.formatter_argv = {
  ['gdscript-formatter'] = { 'gdscript-formatter', '--reorder-code' },
  gdformat = { 'gdformat' },
}

-- Filetypes treated as Godot scripts. Neovim assigns `gdscript` from the file
-- name; the other two are honored for people who set them by hand, matching
-- |GdevLsp|.
H.script_filetypes = { 'gd', 'gdscript', 'gdscript3' }

-- Executables already reported as missing, so a broken setup costs one message
-- rather than one per save. Reset by `setup()`.
H.cache = { missing = {} }

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_formatter(config.formatter)
  H.check_command(config.command)
  H.check_type('autoformat', config.autoformat, 'boolean')
  H.check_indent(config.indent)

  return config
end

H.check_formatter = function(formatter)
  if formatter == false or H.formatter_argv[formatter] ~= nil then return end
  local known = vim.tbl_keys(H.formatter_argv)
  table.sort(known)
  H.error(
    string.format(
      '`formatter` should be one of %s or `false`, not %s. Use `command` to run anything else.',
      table.concat(vim.tbl_map(vim.inspect, known), ', '),
      vim.inspect(formatter)
    )
  )
end

H.check_command = function(command)
  if command == nil then return end
  if type(command) == 'string' and vim.trim(command) ~= '' then return end
  if H.is_argv(command) then return end
  H.error('`command` should be a non-empty string or array of strings, not ' .. vim.inspect(command))
end

H.check_indent = function(indent)
  if indent == false or (type(indent) == 'number' and indent > 0) then return end
  H.error('`indent` should be a positive number or `false`, not ' .. vim.inspect(indent))
end

H.apply_config = function(config)
  GdevFormat.config = config

  -- A fresh setup is a fresh chance to complain about a formatter that is not
  -- installed, and the config change may well have been the fix
  H.cache.missing = {}
end

H.create_autocommands = function()
  local gr = vim.api.nvim_create_augroup('GdevFormat', {})

  local au = function(event, pattern, callback, desc)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = callback, desc = desc })
  end

  -- Matched on filetype rather than on a `*.gd` file pattern, so a script whose
  -- filetype came from somewhere other than its name is covered too
  au('BufWritePost', '*', H.on_write, 'Format Godot scripts after writing')

  -- Registered during `setup()`, hence after the bundled `gdscript` ftplugin
  -- had its say about indentation, which is what lets this override it
  au('FileType', H.script_filetypes, function(args) H.apply_indent(args.buf) end, 'Apply Godot indent options')
end

H.create_user_commands = function()
  local format = function(_) GdevFormat.format(0) end
  vim.api.nvim_create_user_command('GdevFormat', format, { desc = 'Format the current buffer' })
end

-- Formatting -----------------------------------------------------------------
H.on_write = function(args)
  if not H.is_script_buffer(args.buf) then return end
  if not H.get_config(nil, args.buf).autoformat then return end
  GdevFormat.format(args.buf)
end

H.report = function(buf_id, argv, out)
  if not vim.api.nvim_buf_is_valid(buf_id) then return end

  if out.code ~= 0 then return H.notify(H.failure_message(argv, out), 'ERROR') end

  -- The file changed behind the buffer's back. |:checktime| is the reload that
  -- keeps undo history, marks and the cursor, and it refuses to clobber a
  -- buffer the user modified while the formatter ran.
  vim.api.nvim_buf_call(buf_id, function() vim.cmd('checktime') end)
end

H.failure_message = function(argv, out)
  -- Formatters report syntax errors on stderr and diffs on stdout, and some
  -- report nothing at all, so all three cases have to say something useful
  local reported = vim.trim(out.stderr or '')
  if reported == '' then reported = vim.trim(out.stdout or '') end
  if reported ~= '' then return reported end

  return string.format('`%s` exited with %d', argv[1], out.code)
end

H.notify_missing = function(bin)
  if H.cache.missing[bin] then return end
  H.cache.missing[bin] = true
  H.notify(string.format('`%s` is not executable. Run `:checkhealth gdev` for install pointers.', bin), 'WARN')
end

-- Indentation ----------------------------------------------------------------
H.apply_indent = function(buf_id)
  if H.is_disabled() then return end

  local indent = H.get_config(nil, buf_id).indent
  if type(indent) ~= 'number' then return end

  local bo = vim.bo[buf_id]
  bo.expandtab, bo.shiftwidth, bo.softtabstop, bo.tabstop = true, indent, indent, indent
end

H.indent_open_buffers = function()
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf_id) and H.is_script_buffer(buf_id) then H.apply_indent(buf_id) end
  end
end

-- Predicates -----------------------------------------------------------------
H.is_script_buffer = function(buf_id) return vim.tbl_contains(H.script_filetypes, vim.bo[buf_id].filetype) end

H.is_argv = function(command)
  if not (vim.islist(command) and #command > 0) then return false end
  return vim.iter(command):all(function(word) return type(word) == 'string' end)
end

return GdevFormat
