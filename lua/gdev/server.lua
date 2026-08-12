--- *gdev.server* Neovim server for Godot's external editor
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Makes this Neovim reachable at a fixed address, so clicking a script in
---   the Godot editor opens it here instead of in a new instance. See
---   |GdevServer.start()|.
--- - Resolves that address from the command argument, the config, the address
---   Neovim already listens on, or a documented default, in that order.
--- - Recovers an address whose socket file a crashed Neovim left behind, and
---   refuses to fight over one a live process still answers on.
--- - Reports the resolved address and whether it is live through
---   |GdevServer.status()|, which is what you paste into Godot's settings.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.server').setup({})` (replace
--- `{}` with your `config` table). It will create global Lua table `GdevServer`
--- which you can use for scripting or manually (with `:lua GdevServer.*`).
---
--- See |GdevServer.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevserver_config` which should have same structure as
--- `GdevServer.config`.
---
--- # Godot side ~
---
--- In Godot: Editor Settings > Text Editor > External > `Use External Editor`,
--- with `Exec Path` pointing at Neovim (or at a wrapper script that also
--- raises your terminal) and `Exec Flags` substituting the clicked script: >
---
---   --server /tmp/godot.nvim --remote {file}
--- <
--- `--server` is what decides which Neovim receives the file, so the address
--- there and the one this module listens on have to be the same string.
--- `:lua = GdevServer.status()` prints the one in effect.
---
--- Godot also offers `{line}` and `{col}`, but `--remote` takes everything
--- after it as file names and would open a buffer called `+12`. Placing the
--- cursor needs `--remote-send`, or a wrapper script — which is where the
--- terminal-raising belongs anyway.
---
--- # Addresses ~
---
--- An address with a colon is a `host:port` pair; anything else is the path of
--- a Unix domain socket. Only socket paths can go stale, since only they leave
--- a file behind. See |serverstart()| for the full grammar.
---
--- Neovim always listens on an address of its own (|v:servername|), generated
--- at startup. Starting a server here adds a second address rather than
--- replacing that one, which is the point: `/tmp/godot.nvim` is stable enough
--- to hard-code into Godot's settings, while the generated one changes every
--- session.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevserver_disable` (globally) or
--- `vim.b.gdevserver_disable` (for a buffer) to `true`.
---@tag GdevServer

-- Module definition ==========================================================
local GdevServer = {}
local H = require('gdev.util').new('server', GdevServer)

--- Module setup
---
---@param config table|nil Module config table. See |GdevServer.config|.
---
---@usage >lua
---   require('gdev.server').setup() -- use default config
---   -- OR
---   require('gdev.server').setup({}) -- replace {} with your config table
--- <
GdevServer.setup = function(config)
  -- Export module
  _G.GdevServer = GdevServer

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.create_autocommands(config)
  H.create_user_commands()

  if config.autostart then GdevServer.start() end
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevServer.config = {
  -- Address to listen on: a socket path, or `host:port` for TCP. `nil` means
  -- the address Neovim generated for itself at startup (|v:servername|), which
  -- is different every session — set this to something stable, matching what
  -- Godot's `Exec Flags` pass to `--server`.
  address = nil,

  -- Whether to start the server during `setup()` and when a Godot buffer is
  -- opened. Off by default: listening is a side effect worth opting into.
  autostart = false,

  -- Whether to remove a socket file left behind by a crashed Neovim. Only
  -- applies when nothing answers on it; a live address is never touched.
  remove_stale_socket = true,

  -- Filetypes whose buffers trigger `autostart`. Replaces this list rather
  -- than adding to it.
  filetypes = { 'gdscript', 'gdshader', 'gdresource' },
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Start listening for Godot
---
--- Resolves the address (see |GdevServer.config|) and hands it to
--- |serverstart()|. Reports what happened through |vim.notify()| in every case,
--- because the address is the one thing the user has to mirror in Godot's
--- settings.
---
--- Four things can be at the resolved address:
--- - This Neovim, already listening: reused, since a second listener on the
---   same address is impossible and unnecessary.
--- - Another live process: skipped with a warning. Taking the address away
---   from a running session would silently redirect Godot to a dead one.
--- - A socket file with nothing behind it: left over from a Neovim that
---   crashed, removed when `config.remove_stale_socket` allows it.
--- - Nothing: started.
---
---@param address string|nil Address to listen on, overriding `config.address`
---   for this call. Empty string counts as `nil`.
---
---@return string|nil Address now being listened on — which |serverstart()| may
---   report differently from the one asked for — or `nil` if nothing is.
GdevServer.start = function(address)
  if H.is_disabled() then return nil end

  H.check_type('address', address, 'string', true)

  local config = H.get_config()
  local target = H.resolve_address(address, config)
  local state = H.probe(target)

  if state == 'ours' then
    H.notify('already listening on ' .. target)
    return target
  end

  if state == 'other' then
    H.notify('another process is listening on ' .. target .. '; not taking it over', 'WARN')
    return nil
  end

  if state == 'stale' and config.remove_stale_socket then
    local ok, err = vim.uv.fs_unlink(target)
    if not ok then
      H.notify(('could not remove the stale socket at %s: %s'):format(target, err), 'ERROR')
      return nil
    end
    H.notify('removed a stale socket left at ' .. target, 'WARN')
  end

  local ok, result = pcall(vim.fn.serverstart, target)
  if not ok then
    H.notify(('could not start a server on %s: %s'):format(target, result), 'ERROR')
    return nil
  end

  H.notify('listening on ' .. result)
  return result
end

--- Report the address Godot should be pointed at
---
--- Pure: resolves the configured address without probing or starting anything,
--- so it is safe to call from |:checkhealth| and from a mapping. Keeps
--- answering while the module is disabled, since that is when it gets asked.
---
--- Note that an address can be live without this module having started it —
--- `nil` config resolves to the address Neovim opened at startup.
---
---@return table `{ address = string, listening = boolean }`, where `listening`
---   says whether this Neovim currently answers on `address`.
GdevServer.status = function()
  local address = H.resolve_address(nil, H.get_config())
  return { address = address, listening = vim.tbl_contains(H.listening(), address) }
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevServer.config)

-- Address used when nothing else resolves. Matches the convention the Godot
-- community's external-editor wrapper scripts settled on, so a user who
-- already has one of those does not have to change it.
H.default_address = '/tmp/godot.nvim'

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('address', config.address, 'string', true)
  H.check_type('autostart', config.autostart, 'boolean')
  H.check_type('remove_stale_socket', config.remove_stale_socket, 'boolean')
  H.check_type('filetypes', config.filetypes, 'table')

  return config
end

H.apply_config = function(config) GdevServer.config = config end

H.create_autocommands = function(config)
  local gr = vim.api.nvim_create_augroup('GdevServer', {})
  if not config.autostart then return end

  -- `FileType` rather than a `BufReadPost *.gd` pattern: it fires for buffers
  -- that never came from a file, and the Godot filetypes are already the
  -- vocabulary the rest of the plugin is keyed to.
  vim.api.nvim_create_autocmd('FileType', {
    group = gr,
    pattern = vim.deepcopy(config.filetypes),
    callback = function() GdevServer.start() end,
    desc = 'Start the editor server for Godot buffers',
  })
end

H.create_user_commands = function()
  local start = function(data) GdevServer.start(data.args) end
  vim.api.nvim_create_user_command('GdevServerStart', start, {
    nargs = '?',
    complete = 'file',
    desc = 'Listen for the Godot editor on the configured address',
  })
end

-- Addresses ------------------------------------------------------------------
H.resolve_address = function(address, config)
  if H.is_address(address) then return address end
  if H.is_address(config.address) then return config.address end

  -- `v:servername` is documented as the first entry of `serverlist()`. Reading
  -- the list keeps every question about what this Neovim listens on going
  -- through one API, and unlike `v:servername` it also sees addresses added
  -- later by `serverstart()`.
  local own = H.listening()[1]
  if H.is_address(own) then return own end

  return H.default_address
end

H.listening = function() return vim.fn.serverlist() end

-- What occupies `address`: 'ours', 'other', 'stale' or 'free'.
--
-- Neovim 0.12 grew the same stale-socket recovery inside `serverstart()`
-- itself, which makes this redundant there but not on 0.11, and Neovim's
-- version is silent and unconditional where this one reports what it removed
-- and can be turned off.
H.probe = function(address)
  if vim.tbl_contains(H.listening(), address) then return 'ours' end

  -- Only socket paths leave a file to go stale; a `host:port` that is taken
  -- fails loudly in `serverstart()` and there is nothing to clean up.
  if not H.is_socket_path(address) then return 'free' end

  local stat = vim.uv.fs_stat(address)
  if stat == nil then return 'free' end
  if H.can_connect(address) then return 'other' end

  -- Only a socket inode is evidence of a dead Neovim. Anything else at the
  -- path belongs to somebody else and is reported by `serverstart()` instead.
  return stat.type == 'socket' and 'stale' or 'free'
end

H.can_connect = function(address)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', address, { rpc = true })
  if not ok or type(chan) ~= 'number' or chan <= 0 then return false end
  pcall(vim.fn.chanclose, chan)
  return true
end

-- Predicates -----------------------------------------------------------------
H.is_address = function(x) return type(x) == 'string' and x ~= '' end

H.is_socket_path = function(address) return address:find(':', 1, true) == nil end

return GdevServer
