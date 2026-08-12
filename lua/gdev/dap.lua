--- *gdev.dap* Godot debug adapter
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Registers the debug adapter built into the Godot editor with 'nvim-dap',
---   plus a "Launch scene" configuration for GDScript buffers, so `:DapContinue`
---   in a `.gd` file starts the project under the debugger.
--- - Opens and closes 'nvim-dap-ui' along with the debug session, when that
---   plugin is installed.
--- - Degrades instead of failing: with 'nvim-dap' absent, `setup()` warns and
---   leaves the editor untouched.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.dap').setup({})` (replace `{}`
--- with your `config` table). It will create global Lua table `GdevDap` which
--- you can use for scripting or manually (with `:lua GdevDap.*`).
---
--- See |GdevDap.config| for `config` structure and default values.
---
--- Everything here happens during `setup()`: the whole config is consumed to
--- register adapter, configurations and listeners, and nothing reads it again
--- afterwards. There is consequently no `vim.b.gdevdap_config` — a debug session
--- belongs to a project, not to a buffer. Change something by calling `setup()`
--- again, which replaces the previous registration rather than adding to it.
---
--- # Requirements ~
---
--- 'mfussenegger/nvim-dap' has to be installed and loadable by the time
--- `setup()` runs. If your plugin manager loads it lazily, make it a dependency
--- of this plugin, or the registration will be skipped with a warning.
---
--- Godot's debug adapter is part of the running editor, so the editor has to be
--- open for a session to connect. Its port is Editor Settings > Network > Debug
--- Adapter > Remote Port, and has to match `config.port`.
---
--- 'rcarriga/nvim-dap-ui' is optional. When installed, it is opened and closed
--- with the session. Setting it up stays yours to do: calling
--- `require('dapui').setup()` from here would quietly replace the configuration
--- you gave it.
---
--- # Debug configurations ~
---
--- The default `dap.configurations.gdscript` holds one entry, "Launch scene",
--- which starts the project in `${workspaceFolder}` and debugs the scene
--- currently open in the editor. Pass `config.configurations` to replace it —
--- with a `project` pointing elsewhere, say, or several entries to pick from.
---
--- Registration overwrites `dap.configurations.gdscript` wholesale, so entries
--- from a `launch.json` loaded by |dap-launch.json| have to be re-loaded after
--- this `setup()`, not before it.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevdap_disable` (globally) or `vim.b.gdevdap_disable`
--- (for a buffer) to `true`. This stops 'nvim-dap-ui' being opened for new
--- sessions; the adapter itself stays registered, since unregistering it would
--- break a session already running under it.
---@tag GdevDap

-- Module definition ==========================================================
local GdevDap = {}
local H = require('gdev.util').new('dap', GdevDap)

--- Module setup
---
---@param config table|nil Module config table. See |GdevDap.config|.
---
---@usage >lua
---   require('gdev.dap').setup() -- use default config
---   -- OR
---   require('gdev.dap').setup({}) -- replace {} with your config table
--- <
GdevDap.setup = function(config)
  -- Export module
  _G.GdevDap = GdevDap

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.register_gdscript(config)
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevDap.config = {
  -- Host the Godot editor's debug adapter listens on
  host = '127.0.0.1',

  -- Port of that adapter, matching Editor Settings > Network > Debug Adapter
  port = 6006,

  -- Whether to open and close 'nvim-dap-ui' with the debug session. Has no
  -- effect when that plugin is not installed.
  dapui = true,

  -- Array of nvim-dap configurations replacing the built-in "Launch scene" one.
  -- `nil` keeps the default; see |GdevDap| for its contents.
  configurations = nil,
}
--minidoc_afterlines_end

-- Module functionality =======================================================
-- Deliberately nothing beyond `setup()`. Debugging is driven through nvim-dap's
-- own API and commands (`:DapContinue`, `require('dap').continue()`), which
-- already know about the adapter this module registers; wrapping them here would
-- be a second, worse spelling of the same thing.

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevDap.config)

-- Filetype whose debug configurations this module owns
H.filetype = 'gdscript'

-- Name of the nvim-dap adapter entry, referenced by `type` in every
-- configuration below
H.adapter_name = 'godot'

-- Debug configurations used unless `config.configurations` replaces them.
-- `launch_scene` tells Godot to debug the scene open in the editor rather than
-- the project's main scene.
H.default_configurations = {
  {
    type = 'godot',
    request = 'launch',
    name = 'Launch scene',
    project = '${workspaceFolder}',
    launch_scene = true,
  },
}

-- Key this module's nvim-dap listeners are stored under. Listener tables are
-- keyed, so a namespaced key is what keeps a second `setup()` from stacking
-- another copy of the same callback.
H.listener_key = 'gdev.dap'

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('host', config.host, 'string')
  H.check_type('port', config.port, 'number')
  H.check_type('dapui', config.dapui, 'boolean')
  H.check_type('configurations', config.configurations, 'table', true)
  for i, configuration in ipairs(config.configurations or {}) do
    H.check_type('configurations[' .. i .. ']', configuration, 'table')
  end

  return config
end

H.apply_config = function(config)
  GdevDap.config = config
end

-- Adapter registration -------------------------------------------------------
H.register_gdscript = function(config)
  local adapter = { type = 'server', host = config.host, port = config.port }
  local configurations = config.configurations or H.default_configurations

  if not H.register_language(H.filetype, H.adapter_name, adapter, configurations) then
    H.notify(
      "nvim-dap is not available, so Godot debugging is off; install 'mfussenegger/nvim-dap'",
      'WARN'
    )
    return
  end

  H.configure_dapui(config)
end

-- The single point where a language's debugging support reaches nvim-dap.
-- Supporting C# later is another call with `coreclr` and `cs`, not a change
-- here; that is why the language is a parameter rather than baked in.
--
-- Returns whether nvim-dap was there to register with. Wording the warning is
-- left to the caller, since what a missing nvim-dap costs depends on the
-- language.
H.register_language = function(filetype, adapter_name, adapter, configurations)
  local dap = H.get_dap()
  if dap == nil then
    return false
  end

  dap.adapters[adapter_name] = adapter
  -- Copied, so that later edits to `GdevDap.config.configurations` cannot reach
  -- nvim-dap behind the user's back
  dap.configurations[filetype] = vim.deepcopy(configurations)
  return true
end

H.configure_dapui = function(config)
  local dap = H.get_dap()
  if dap == nil then
    return
  end

  -- Cleared first: a `setup()` that turns the integration off has to take the
  -- previous call's listeners with it
  dap.listeners.after.event_initialized[H.listener_key] = nil
  dap.listeners.before.event_terminated[H.listener_key] = nil
  dap.listeners.before.event_exited[H.listener_key] = nil

  if not config.dapui then
    return
  end

  local ok, dapui = pcall(require, 'dapui')
  if not ok then
    return
  end

  -- Opening is a reaction to a session starting, so the disable protocol
  -- applies. Closing is teardown of a window this module opened and runs
  -- regardless, rather than leaving it behind for a session that has ended.
  dap.listeners.after.event_initialized[H.listener_key] = function()
    if H.is_disabled() then
      return
    end
    dapui.open()
  end

  local close = function()
    dapui.close()
  end
  dap.listeners.before.event_terminated[H.listener_key] = close
  dap.listeners.before.event_exited[H.listener_key] = close
end

H.get_dap = function()
  local ok, dap = pcall(require, 'dap')
  return ok and dap or nil
end

return GdevDap
