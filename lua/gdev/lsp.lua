--- *gdev.lsp* Godot editor language server
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Attaches GDScript and shader buffers to the language server built into a
---   running Godot editor, over TCP. No separate language-server binary is
---   involved.
--- - |GdevLsp.reconnect()| re-attempts attachment in every open Godot buffer,
---   for when the editor was started or restarted after the files were opened.
--- - Opt-in inlay hints, gated on the editor advertising support, with a
---   per-buffer toggle in |GdevLsp.toggle_inlay_hints()|.
--- - Works around two Godot quirks: it advertises `textDocument/typeDefinition`
---   but answers the request with an error, and it reports unimplemented
---   methods as `window/showMessage` notifications instead of error responses.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.lsp').setup({})` (replace `{}`
--- with your `config` table). It will create global Lua table `GdevLsp` which
--- you can use for scripting or manually (with `:lua GdevLsp.*`).
---
--- See |GdevLsp.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevlsp_config` which should have same structure as `GdevLsp.config`.
---
--- # Requirements ~
---
--- The Godot editor has to be running, with the project open. Its language
--- server is always on in Godot 4 — there is no switch to enable, only
--- `remote_host` and `remote_port` under Editor Settings > Network > Language
--- Server, which have to match `host` and `port` here. Advice to "enable the TCP
--- LSP server" is left over from Godot 3 and does not apply.
---
--- The server is registered under the `gdscript` |lsp-config| name, replacing
--- any config already using it (one from 'nvim-lspconfig', say). Sharing the
--- name is deliberate: it is what stops a second client attaching to the same
--- buffer. Note that Neovim derives the client name from the config name, so
--- clients report as `gdscript`.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevlsp_disable` (globally) or `vim.b.gdevlsp_disable`
--- (for a buffer) to `true`.
---@tag GdevLsp

-- Module definition ==========================================================
local GdevLsp = {}
local H = require('gdev.util').new('lsp', GdevLsp)

--- Module setup
---
---@param config table|nil Module config table. See |GdevLsp.config|.
---
---@usage >lua
---   require('gdev.lsp').setup() -- use default config
---   -- OR
---   require('gdev.lsp').setup({}) -- replace {} with your config table
--- <
GdevLsp.setup = function(config)
  -- Export module
  _G.GdevLsp = GdevLsp

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.register_server(config)
  H.create_user_commands()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevLsp.config = {
  -- Host the Godot editor's language server listens on
  host = '127.0.0.1',

  -- Port of that server, matching Editor Settings > Network > Language Server
  port = 6005,

  -- Whether to show inlay hints in attached buffers. Has no effect unless the
  -- running Godot build advertises `textDocument/inlayHint`, which not all do.
  inlay_hints = false,
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Re-attempt language server attachment in all Godot buffers
---
--- Use after starting or restarting the Godot editor: buffers opened while its
--- server was unreachable have no client, and this gives them another attempt.
--- Buffer contents are untouched, so unsaved changes and undo history survive.
---
--- Buffers of every Godot filetype are reported, including `gdresource`
--- (`.tscn` / `.tres`) ones that the default config does not attach to, since
--- attachment ultimately depends on the |lsp-config| in effect.
---
---@return table Array of buffer ids that were considered for attachment.
GdevLsp.reconnect = function()
  if H.is_disabled() then return {} end

  local buffers = vim.tbl_filter(H.is_godot_buffer, vim.api.nvim_list_bufs())

  -- Re-enabling is Neovim's own path for activating a server in buffers that
  -- are already open: it replays the |FileType| hook for every loaded buffer,
  -- which retries attachment without reloading anything.
  vim.lsp.enable(H.server_name)

  H.notify(string.format('reconnecting %d Godot buffer(s)', #buffers))
  return buffers
end

--- Toggle inlay hints in a buffer
---
--- Independent of `config.inlay_hints`, which only decides the initial state of
--- a buffer when its client attaches.
---
--- Refuses to act unless some attached client advertises
--- `textDocument/inlayHint`; enabling hints no server can produce would report
--- success and then show nothing.
---
---@param buf_id integer|nil Buffer handle, or 0 / `nil` for current buffer.
---
---@return boolean|nil Whether hints are now shown, or `nil` if no attached
---   server supports them.
GdevLsp.toggle_inlay_hints = function(buf_id)
  if H.is_disabled() then return nil end

  buf_id = H.validate_buf_id(buf_id)

  if not H.supports_inlay_hints(buf_id) then
    H.notify('no language server attached to this buffer advertises inlay hints', 'WARN')
    return nil
  end

  local enabled = not vim.lsp.inlay_hint.is_enabled({ bufnr = buf_id })
  vim.lsp.inlay_hint.enable(enabled, { bufnr = buf_id })
  return enabled
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevLsp.config)

-- Name of the |lsp-config| entry this module owns
H.server_name = 'gdscript'

-- Filetypes the server is registered for. Neovim maps only `gdscript` and
-- `gdshader` from file names; `gd` and `gdscript3` are honored for users who
-- assign them by hand.
H.server_filetypes = { 'gd', 'gdscript', 'gdscript3', 'gdshader' }

-- Filetypes |GdevLsp.reconnect()| walks. Superset of `H.server_filetypes`:
-- `gdresource` buffers are Godot files too, and whether they attach is up to
-- the config in effect rather than something this module should presume.
H.godot_filetypes = { 'gd', 'gdscript', 'gdscript3', 'gdshader', 'gdresource' }

-- Server messages to drop. Godot reports methods it does not implement as
-- `window/showMessage` notifications, so an editor session otherwise fills with
-- warnings triggered by nothing the user did.
H.ignored_server_messages = { 'Method not found: godot/reloadScript' }

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('host', config.host, 'string')
  H.check_type('port', config.port, 'number')
  H.check_type('inlay_hints', config.inlay_hints, 'boolean')

  return config
end

H.apply_config = function(config) GdevLsp.config = config end

H.create_user_commands = function()
  local reconnect = function(_) GdevLsp.reconnect() end
  vim.api.nvim_create_user_command('GdevLspReconnect', reconnect, {
    desc = 'Reconnect Godot buffers to the editor language server',
  })

  local toggle_hints = function(_) GdevLsp.toggle_inlay_hints(0) end
  vim.api.nvim_create_user_command('GdevLspToggleHints', toggle_hints, {
    desc = 'Toggle Godot inlay hints in the current buffer',
  })
end

-- Server registration --------------------------------------------------------
H.register_server = function(config)
  vim.lsp.config[H.server_name] = {
    -- Godot speaks LSP over a bare TCP socket that Neovim owns directly
    cmd = vim.lsp.rpc.connect(config.host, config.port),
    filetypes = vim.deepcopy(H.server_filetypes),
    root_markers = { 'project.godot', '.git' },
    -- Supplying the handler here rather than patching `client.handlers` on
    -- attach keeps re-`setup()` from stacking one filter on top of another
    handlers = { ['window/showMessage'] = H.handle_show_message },
    on_attach = H.on_attach,
  }

  vim.lsp.enable(H.server_name)
end

H.on_attach = function(client, buf_id)
  -- Godot lists `typeDefinitionProvider` and then fails the request. Client
  -- capabilities cannot express the opt-out, because Neovim deep-merges them
  -- over `vim.lsp.protocol.make_client_capabilities()` and so restores anything
  -- removed there; clearing the server flag is what keeps requests away.
  client.server_capabilities.typeDefinitionProvider = nil

  if H.is_disabled() then return end
  if not H.get_config(nil, buf_id).inlay_hints then return end
  if not client:supports_method('textDocument/inlayHint') then return end

  vim.lsp.inlay_hint.enable(true, { bufnr = buf_id })
end

H.handle_show_message = function(err, result, ctx, config)
  local message = type(result) == 'table' and result.message or nil
  if type(message) == 'string' then
    for _, ignored in ipairs(H.ignored_server_messages) do
      if message:find(ignored, 1, true) ~= nil then return end
    end
  end

  -- Resolved per call so a user replacing the default handler still wins
  local fallback = vim.lsp.handlers['window/showMessage']
  if type(fallback) == 'function' then return fallback(err, result, ctx, config) end
end

-- Predicates -----------------------------------------------------------------
H.is_godot_buffer = function(buf_id)
  if not vim.api.nvim_buf_is_loaded(buf_id) then return false end
  return vim.tbl_contains(H.godot_filetypes, vim.bo[buf_id].filetype)
end

H.supports_inlay_hints = function(buf_id)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf_id })) do
    if client:supports_method('textDocument/inlayHint') then return true end
  end
  return false
end

return GdevLsp
