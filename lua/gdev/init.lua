--- *gdev* Godot development for Neovim
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - One module per Godot workflow, each with its own `setup()`, config,
---   commands and off switch. In the order this module sets them up:
---   |gdev.lsp|, |gdev.treesitter|, |gdev.dap|, |gdev.format|, |gdev.server|,
---   |gdev.run|, |gdev.scenetree|, |gdev.docs|.
--- - |gdev.health| answers `:checkhealth gdev` and needs no setup.
--- - |Gdev.setup()| is a convenience router over those eight, for people who
---   would rather write one call than eight. Per-module `setup()` remains the
---   primary API: it is what the module help pages document, and the only way
---   to set up part of the plugin lazily.
---
--- # Setup ~
---
--- >lua
---   require('gdev').setup({
---     -- Each key holds the table that module's own `setup()` takes
---     run = { godot = '/opt/godot/4.3/godot' },
---     format = { formatter = 'gdformat' },
---     server = { autostart = true },
---
---     -- `false` skips a module; omitted keys get that module's defaults
---     dap = false,
---   })
--- <
--- The routing is deliberately dumb: nothing is shared between the tables. A
--- host or port named twice is named twice, because the editor's language
--- server, its debug adapter and the engine binary have no reason to agree
--- beyond convention, and a shared value here would have to be un-shared the
--- first time one of them moved.
---
--- Since an omitted key means defaults, `require('gdev').setup()` sets up all
--- eight modules. Two of those defaults are worth knowing before you rely on
--- them:
---
--- - `gdev.dap` warns when 'nvim-dap' is not installed. Pass `dap = false` if
---   you do not debug from Neovim.
--- - `gdev.treesitter` needs parsers you installed yourself; it highlights
---   nothing without them, and `:checkhealth gdev` says which are missing.
---
--- # Errors ~
---
--- Each module validates its own table and raises with its own name, so a bad
--- field reads as ``(gdev.run) `console.enabled` should be boolean, not string``
--- whether it came through here or not. The modules before it in the order
--- above are already set up when it raises: fix the field and call `setup()`
--- again, which every module supports.
---
--- A key naming no module is an error rather than a silent no-op — a typo in
--- `treesiter` would otherwise leave a module unconfigured with nothing to show
--- for it.
---@tag Gdev

-- Module definition ==========================================================
local Gdev = {}

-- A plain table rather than `require('gdev.util').new()`. Everything that
-- helper binds -- config resolution, the disable protocol, buffer arguments --
-- belongs to a module that has a config of its own, and this one has none: it
-- holds no state, reads nothing at runtime, and forwards what it is given. The
-- error format is reproduced rather than shared so a mistake in this call reads
-- like a mistake in a module's.
local H = {}

--- Set up several modules at once
---
--- Every key of `config` names a module and holds what that module's `setup()`
--- takes:
---
--- - a table sets the module up with it,
--- - `true` sets it up with its defaults, same as an empty table,
--- - `false` skips it entirely,
--- - an omitted key sets it up with its defaults.
---
--- Skipping is what `false` is for: a module that is never set up registers no
--- commands, no autocommands and no global table, and `:checkhealth gdev`
--- reports it as not set up rather than guessing at defaults it is not running.
---
--- Calling this a second time re-runs every module's `setup()`, which replaces
--- the previous configuration rather than adding to it.
---
---@param config table|nil Map of module name to a config table, `true` or
---   `false`. See |Gdev| for what the keys are and what sharing they do not do.
---
---@return table Array of module names that were set up, in setup order.
---
---@usage >lua
---   require('gdev').setup() -- every module, all defaults
---   -- OR
---   require('gdev').setup({ dap = false, run = { godot = 'godot4' } })
--- <
Gdev.setup = function(config)
  -- Export module
  _G.Gdev = Gdev

  config = H.setup_config(config)

  if config.csharp then
    H.notify('`csharp` is reserved for future C# support and does nothing yet', 'WARN')
  end

  local done = {}
  for _, name in ipairs(H.modules) do
    local spec = config[name]
    if spec ~= false then
      require('gdev.' .. name).setup(spec ~= true and spec or nil)
      table.insert(done, name)
    end
  end

  return done
end

-- Helper data ================================================================
-- Modules with a `setup()`, in the order they are set up. None of them depends
-- on another, so the order is here to make a run reproducible rather than
-- correct. `gdev.health` is absent because it has no setup; `gdev.util`,
-- `gdev.project` and `gdev.rst` because they are internal.
H.modules = { 'lsp', 'treesitter', 'dap', 'format', 'server', 'run', 'scenetree', 'docs' }

-- Keys accepted and not acted on. Reserved rather than rejected so that a
-- config written for a future version fails on the fields inside `csharp`, if
-- at all, instead of on the name of the key -- see the C# seams in the modules
-- that already carry them (`script_extensions`, `H.register_language`).
H.reserved = { 'csharp' }

-- Helper functionality =======================================================
H.error = function(msg)
  error('(gdev) ' .. msg, 0)
end

H.notify = function(msg, level)
  vim.notify('(gdev) ' .. msg, vim.log.levels[level or 'INFO'])
end

H.check_type = function(field, val, ref, allow_nil)
  if type(val) == ref or (allow_nil and val == nil) then
    return
  end
  H.error(string.format('`%s` should be %s, not %s', field, ref, type(val)))
end

H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = config or {}

  -- Sorted, so a config with two problems always reports the same one first
  local keys = vim.tbl_keys(config)
  table.sort(keys)

  for _, key in ipairs(keys) do
    if not H.is_known(key) then
      H.error(
        ('unknown module `%s`; expected one of %s'):format(key, table.concat(H.known(), ', '))
      )
    end

    local value = config[key]
    if type(value) ~= 'table' and type(value) ~= 'boolean' then
      H.error(('`%s` should be table or boolean, not %s'):format(key, type(value)))
    end
  end

  return config
end

H.is_known = function(key)
  return vim.tbl_contains(H.modules, key) or vim.tbl_contains(H.reserved, key)
end

H.known = function()
  local keys = vim.list_extend(vim.list_extend({}, H.modules), H.reserved)
  table.sort(keys)
  return keys
end

return Gdev
