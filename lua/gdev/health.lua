--- *gdev.health* Environment diagnosis
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - `:checkhealth gdev` reports, section by section, whether what the other
---   modules need is actually there: the Godot binary and its version, the two
---   optional plugins, treesitter parsers, the editor's language server and
---   debug adapter ports, the Neovim server Godot opens files through, `curl`
---   for the class reference, and the GDScript formatter.
--- - Every finding says what to do about it, and levels are meant literally.
---   Soft dependencies warn; only something genuinely broken is an error.
---
--- # Setup ~
---
--- None, deliberately. This module breaks the pattern the rest of the plugin
--- follows -- no `setup()`, no `config`, no `GdevHealth` global, no
--- autocommands, nothing to disable. |:checkhealth| asks exactly one thing of a
--- plugin, a `lua/<plugin>/health.lua` returning a table with a `check()`
--- function, and a diagnostic that had to be configured before it could
--- diagnose anything would be a poor diagnostic.
---
--- # What it reads ~
---
--- The state of every other module, through the global table that module's
--- `setup()` exports (`GdevRun`, `GdevDocs`, ...) and the pure status query on
--- it. A module that was never set up is reported as such rather than guessed
--- at: describing defaults this session is not running would be worse than no
--- answer at all.
---
--- So `:checkhealth gdev` describes the session it runs in, not the plugin in
--- the abstract. Run it once your plugin manager has loaded and configured the
--- modules you actually use.
---
--- # What it runs ~
---
--- `godot --version` and, per port, `nc -z`. Both are waited on, so a report
--- takes about a second when the Godot editor is not running. Without `nc`
--- installed the two port checks say so instead of guessing.
---@tag GdevHealth

-- Module definition ==========================================================
local GdevHealth = {}

-- A plain table rather than `require('gdev.util').new()`: everything that
-- helper binds -- module-prefixed errors and notifications, config resolution,
-- the disable protocol -- belongs to a module that has a config. This one does
-- not, and reports through |vim.health| rather than through messages.
local H = {}

-- Module functionality =======================================================
--- Run every check
---
--- The entry point |:checkhealth| calls; use `:checkhealth gdev` rather than
--- calling this directly. Reports through |vim.health| and returns nothing.
GdevHealth.check = function()
  for _, section in ipairs(H.sections) do
    vim.health.start(section.title)
    section.check()
  end
end

-- Helper data ================================================================
-- Port prober. Neovim has no synchronous TCP probe of its own, and `nc` is on
-- every macOS and Linux machine this plugin targets -- but not on all of them,
-- so its absence is reported rather than assumed away.
H.prober = 'nc'

-- Ceiling on a single probe. Generous: it exists to bound a wedged wrapper
-- script, not to time anything out that would otherwise have answered.
H.timeout_ms = 5000

-- The only plugin dependencies, both soft. A missing one is a warning because
-- only `gdev.dap` uses them: everything else here runs on Neovim's own APIs.
H.dependencies = {
  {
    name = 'nvim-dap',
    module = 'dap',
    advice = {
      'Only `gdev.dap` needs it; every other module works without it.',
      'Install https://github.com/mfussenegger/nvim-dap to debug a running project from Neovim.',
      'If your plugin manager loads it lazily, make it a dependency of this plugin so it is there when `setup()` runs.',
    },
  },
  {
    name = 'nvim-dap-ui',
    module = 'dapui',
    advice = {
      'Optional even for debugging: it is the panel `gdev.dap` opens and closes along with a session.',
      'Install https://github.com/rcarriga/nvim-dap-ui, or set `dapui = false` to stop expecting it.',
    },
  },
}

-- Parsers are the user's to install, because nvim-treesitter is not a
-- dependency of this plugin and Neovim ships no parser installer.
H.parser_advice = {
  'Run `:TSInstall <language>` if you have nvim-treesitter, or build the grammar with the `tree-sitter` CLI into '
    .. "`stdpath('data')/site/parser/`.",
  'Queries matter as much: a parser with no `highlights.scm` loads fine and highlights nothing. `:InspectTree` '
    .. 'tells the two apart.',
}

-- Where each formatter comes from. Anything else is a `command` override, which
-- only its author can be pointed at.
H.formatter_advice = {
  ['gdscript-formatter'] = {
    'Install or build it from https://github.com/GDQuest/GDScript-formatter, then check `gdscript-formatter --help`.',
    'Or switch to `formatter = "gdformat"`, or turn formatting off with `formatter = false`.',
  },
  gdformat = {
    'It ships with gdtoolkit: `pipx install "gdtoolkit==4.*"`. See https://github.com/Scony/godot-gdscript-toolkit.',
    'Or switch to `formatter = "gdscript-formatter"`, or turn formatting off with `formatter = false`.',
  },
}

-- Kept in step with the message `gdev.run` prints when a launch fails, so the
-- two never contradict each other.
H.godot_advice = {
  'Put the Godot binary on $PATH as `godot`.',
  'Or set `godot` in `require("gdev.run").setup()` to its full path.',
  'Or point `godot` at a version manager wrapper such as gdvm, and set `vim.b.gdevrun_config` per project.',
}

-- Helper functionality =======================================================
-- Module state ---------------------------------------------------------------
H.global = function(module) return 'Gdev' .. module:sub(1, 1):upper() .. module:sub(2) end

-- Public table of a module, or `nil` after reporting that it was never set up.
-- Health never `require()`s a module: loading one would report the defaults it
-- ships with rather than the config this session is running, which is the one
-- question a health check exists to answer.
H.module = function(module)
  local mod = _G[H.global(module)]
  if mod ~= nil then return mod end

  -- An informational level on purpose: not setting up a module is a supported
  -- choice, not a fault, and `:checkhealth` is a reasonable first thing to run
  vim.health.info(("`gdev.%s` is not set up; call `require('gdev.%s').setup()` to use it"):format(module, module))
  return nil
end

-- Ask a module the status question it exposes for exactly this. The second
-- return distinguishes a query that legitimately answered `nil` --
-- `GdevFormat.get_command()` does when formatting is off -- from a module that
-- could not be asked at all.
H.query = function(module, query, ...)
  local mod = H.module(module)
  if mod == nil then return nil, false end

  local ok, result = pcall(mod[query], ...)
  if ok then return result, true end

  vim.health.error(('`%s.%s()` raised: %s'):format(H.global(module), query, result))
  return nil, false
end

-- Probes ---------------------------------------------------------------------
-- Run a command to completion, `nil` when it could not be run at all.
-- `vim.system()` raises synchronously on ENOENT, and a health check that raises
-- loses every section after it.
H.run = function(argv)
  local spawned, proc = pcall(vim.system, argv, { text = true })
  if not spawned then return nil end

  local finished, out = pcall(proc.wait, proc, H.timeout_ms)
  return finished and out or nil
end

-- Whether something answers on a TCP port. `nil` is "could not tell", which is
-- what a machine without a prober gets -- reported as such, since a guess here
-- would send someone looking for a Godot setting that is already correct.
H.port_open = function(host, port)
  if vim.fn.executable(H.prober) ~= 1 then return nil end

  local out = H.run({ H.prober, '-z', '-w', '1', host, tostring(port) })
  if out == nil then return nil end

  return out.code == 0
end

-- First line of `godot --version`, which is all Godot prints:
-- `4.3.stable.official.77dcf97d8`. `nil` when the binary did not answer.
H.godot_version = function(executable)
  local out = H.run({ executable, '--version' })
  if out == nil or out.code ~= 0 then return nil end

  local version = vim.trim(vim.split(out.stdout or '', '\n')[1] or '')
  return version ~= '' and version or nil
end

-- Sections -------------------------------------------------------------------
H.report_godot = function()
  local status = H.query('run', 'status')
  if status == nil then return end

  vim.health.info('Project root: ' .. (status.root or 'no `project.godot` above the working directory'))

  if not status.executable then
    return vim.health.error(('Godot executable `%s` not found'):format(status.godot), H.godot_advice)
  end

  local path = vim.fn.exepath(status.godot)
  vim.health.info('Godot executable: ' .. (path ~= '' and path or status.godot))

  local version = H.godot_version(status.godot)
  if version == nil then
    return vim.health.warn(('`%s --version` did not answer'):format(status.godot), {
      'The file is executable but does not behave like Godot. A wrapper script swallowing the flag does this.',
    })
  end

  vim.health.ok('Godot ' .. version)

  local major, minor = version:match('^(%d+)%.(%d+)')
  if major == nil then
    return vim.health.info('That does not start with `major.minor`, so the 4.3 check was skipped')
  end
  if tonumber(major) > 4 or (tonumber(major) == 4 and tonumber(minor) >= 3) then return end

  vim.health.warn(('Godot %s.%s is older than 4.3'):format(major, minor), {
    'This plugin targets Godot 4.3 and later. Older editors lack settings and endpoints it expects, so parts of '
      .. 'it will not work.',
  })
end

H.report_dependencies = function()
  for _, dependency in ipairs(H.dependencies) do
    if pcall(require, dependency.module) then
      vim.health.ok(("'%s' is installed"):format(dependency.name))
    else
      vim.health.warn(("'%s' is not installed"):format(dependency.name), dependency.advice)
    end
  end
end

H.report_editor = function()
  if vim.fn.executable(H.prober) ~= 1 then
    vim.health.info(("'%s' is not installed, so no port below could be probed"):format(H.prober))
  end

  H.report_port('lsp', 'language server', 'Editor Settings > Network > Language Server')
  H.report_port('dap', 'debug adapter', 'Editor Settings > Network > Debug Adapter')
end

-- `gdev.lsp` and `gdev.dap` expose no status query, so their config table is
-- read directly. Neither has a buffer-local override to honor: a connection to
-- the editor belongs to the session, not to a buffer.
H.report_port = function(module, what, setting)
  local mod = H.module(module)
  if mod == nil then return end

  local config = mod.config
  local target = ('%s:%s'):format(config.host, config.port)

  local open = H.port_open(config.host, config.port)
  if open == nil then return vim.health.info(('Godot editor %s expected at %s'):format(what, target)) end
  if open then return vim.health.ok(('Godot editor %s answers on %s'):format(what, target)) end

  vim.health.warn(('Nothing answers on %s, where the Godot editor %s is expected'):format(target, what), {
    'Start the Godot editor and open the project; the server is part of the editor, not of the running game.',
    ('Check that %s matches port %s.'):format(setting, config.port),
  })
end

H.report_server = function()
  local status = H.query('server', 'status')
  if status == nil then return end

  if status.listening then
    vim.health.ok(('Neovim is listening on %s'):format(status.address))
  else
    vim.health.warn(('Neovim is not listening on %s'):format(status.address), {
      'Run `:GdevServerStart`, or set `autostart = true` in `require("gdev.server").setup()`.',
    })
  end

  vim.health.info(table.concat({
    'Point Godot at it in Editor Settings > Text Editor > External:',
    '  Use External Editor: on',
    '  Exec Path:  nvim',
    ('  Exec Flags: --server %s --remote {file}'):format(status.address),
  }, '\n'))
end

H.report_treesitter = function()
  local status = H.query('treesitter', 'parser_status')
  if status == nil then return end

  local filetypes = vim.tbl_keys(status)
  table.sort(filetypes)

  for _, filetype in ipairs(filetypes) do
    local parser = status[filetype]
    if parser.available then
      vim.health.ok(("'%s' parser found, used for %s files"):format(parser.lang, filetype))
    else
      local msg = ("No '%s' parser, so %s files fall back to regular syntax highlighting"):format(parser.lang, filetype)
      vim.health.warn(msg, H.parser_advice)
    end
  end
end

H.report_formatter = function()
  local argv, asked = H.query('format', 'get_command')
  if not asked then return end
  if argv == nil then return vim.health.info('Formatting is turned off (`formatter = false`)') end

  vim.health.info('Command: ' .. table.concat(argv, ' ') .. ' <file>')

  local executable = argv[1]
  if vim.fn.executable(executable) == 1 then return vim.health.ok(("'%s' found"):format(executable)) end

  local advice = H.formatter_advice[executable]
    or { 'Put it on $PATH, or give `command` in `require("gdev.format").setup()` its full path.' }
  vim.health.warn(("'%s' not found, so nothing will be formatted"):format(executable), advice)
end

H.report_docs = function()
  local status = H.query('docs', 'status')
  if status == nil then return end

  vim.health.info(('Renderer: %s (fallback: %s)'):format(status.renderer, tostring(status.fallback_renderer)))
  vim.health.info('Source: ' .. status.source_url)
  vim.health.info('Website: ' .. status.page_url)

  local cache = status.cache
  local held = cache.enabled and ('%d of %d pages'):format(cache.entries, cache.max_entries) or 'disabled'
  vim.health.info('Cache: ' .. held)

  -- The website renderer opens a published page, so nothing is ever fetched
  if status.renderer == 'browser' then
    return vim.health.info(("The '%s' renderer fetches nothing, so it needs no fetcher"):format(status.renderer))
  end

  if status.curl then return vim.health.ok("'curl' found") end

  vim.health.warn(("'curl' not found, so the '%s' renderer cannot fetch a page"):format(status.renderer), {
    'Install curl, or set `renderer = "browser"` in `require("gdev.docs").setup()` to read the pages on the website.',
  })
end

H.report_scenetree = function()
  local status = H.query('scenetree', 'status')
  if status == nil then return end

  vim.health.info(status.open and ('Pane is open, showing ' .. (status.scene or 'nothing')) or 'Pane is closed')
  vim.health.info('Node icons: ' .. (status.icons == false and 'off' or tostring(status.icons)))

  if status.icons ~= 'nerdfont' then return end

  vim.health.warn('Node icons are Nerd Font glyphs, which need a patched font', {
    'Boxes or blanks in the pane mean your terminal font has no glyphs for them.',
    'Set `icons = "ascii"` or `icons = false` in `require("gdev.scenetree").setup()` if you have no patched font.',
  })
end

-- Sections in report order. Adding one means appending an entry: a section
-- reads everything it needs itself and shares no state with its neighbours,
-- which is what keeps a future C# section (dotnet, a C# language server,
-- netcoredbg) additive rather than woven through this file.
--
-- Here rather than under "Helper data" only because every entry names a
-- function defined above it.
H.sections = {
  { title = 'Godot', check = H.report_godot },
  { title = 'Plugin dependencies', check = H.report_dependencies },
  { title = 'Godot editor connection', check = H.report_editor },
  { title = 'Editor server', check = H.report_server },
  { title = 'Treesitter parsers', check = H.report_treesitter },
  { title = 'GDScript formatter', check = H.report_formatter },
  { title = 'Godot class reference', check = H.report_docs },
  { title = 'Scene tree', check = H.report_scenetree },
}

return GdevHealth
