--- *gdev.template* One-line module description
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Bullet list of user-facing capabilities. One sentence each, link public
---   functions like |GdevTemplate.action()|.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.template').setup({})`
--- (replace `{}` with your `config` table). It will create global Lua table
--- `GdevTemplate` which you can use for scripting or manually (with
--- `:lua GdevTemplate.*`).
---
--- See |GdevTemplate.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevtemplate_config` which should have same structure as
--- `GdevTemplate.config`.
---
--- # Highlight groups ~
---
--- - `GdevTemplateTitle` - example highlight group.
---
--- To change any highlight group, set it directly with |nvim_set_hl()|.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevtemplate_disable` (globally) or
--- `vim.b.gdevtemplate_disable` (for a buffer) to `true`.
---@tag GdevTemplate

-- Module definition ==========================================================
local GdevTemplate = {}
local H = {}

--- Module setup
---
---@param config table|nil Module config table. See |GdevTemplate.config|.
---
---@usage >lua
---   require('gdev.template').setup() -- use default config
---   -- OR
---   require('gdev.template').setup({}) -- replace {} with your config table
--- <
GdevTemplate.setup = function(config)
  -- Export module
  _G.GdevTemplate = GdevTemplate

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.create_autocommands(config)
  H.create_user_commands()

  -- Create default highlighting
  H.create_default_hl()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevTemplate.config = {
  -- Module mappings. Use `''` (empty string) to disable one.
  mappings = {
    action = '<Leader>ga',
  },

  -- Delay (in ms) between triggering event and reaction
  delay = 100,

  -- Whether to react only in normal buffers (ones with empty 'buftype')
  only_in_normal_buffers = true,

  -- Hooks called at meaningful points. Each is `nil` (no hook) or a callable.
  hooks = {
    -- Called after action is performed; receives buffer id
    post_action = nil,
  },
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Perform action
---
--- Describe observable behavior and notable edge cases. Write for a reader
--- who already knows the Neovim API: explain intent, not mechanics.
---
---@param buf_id integer|nil Buffer handle, or 0 / `nil` for current buffer.
---@param opts table|nil Options overriding `GdevTemplate.config` for this call.
---
---@return boolean Whether action was scheduled.
GdevTemplate.action = function(buf_id, opts)
  if H.is_disabled() then return false end

  buf_id = H.validate_buf_id(buf_id)
  opts = vim.tbl_deep_extend('force', H.get_config(), opts or {})

  if opts.only_in_normal_buffers and not H.is_buffer_normal(buf_id) then return false end

  -- Debounce to react only after events settle
  H.timer:stop()
  H.timer:start(opts.delay, 0, vim.schedule_wrap(function() H.do_action(buf_id, opts) end))
  return true
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevTemplate.config)

-- Timer for debounced reaction
H.timer = vim.uv.new_timer()

-- Cache shared across helper functions (state that survives between calls)
H.cache = {}

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('mappings', config.mappings, 'table')
  H.check_type('mappings.action', config.mappings.action, 'string')
  H.check_type('delay', config.delay, 'number')
  H.check_type('only_in_normal_buffers', config.only_in_normal_buffers, 'boolean')
  H.check_type('hooks', config.hooks, 'table')
  H.check_type('hooks.post_action', config.hooks.post_action, 'callable', true)

  return config
end

H.apply_config = function(config)
  GdevTemplate.config = config

  -- Mappings are created once during `setup()`; later `config.mappings`
  -- changes have no effect
  H.map('n', config.mappings.action, '<Cmd>lua GdevTemplate.action()<CR>', { desc = 'Perform action' })
end

H.create_autocommands = function(config)
  local gr = vim.api.nvim_create_augroup('GdevTemplate', {})

  local au = function(event, pattern, callback, desc)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = callback, desc = desc })
  end

  au({ 'BufEnter' }, '*', function() GdevTemplate.action() end, 'Perform action')
  au('ColorScheme', '*', H.create_default_hl, 'Ensure colors')
end

H.create_user_commands = function()
  local callback = function(_) GdevTemplate.action(0, { delay = 0 }) end
  vim.api.nvim_create_user_command('GdevTemplate', callback, { desc = 'Perform action' })
end

H.create_default_hl = function() vim.api.nvim_set_hl(0, 'GdevTemplateTitle', { default = true, link = 'Title' }) end

H.is_disabled = function() return vim.g.gdevtemplate_disable == true or vim.b.gdevtemplate_disable == true end

H.get_config = function(config)
  return vim.tbl_deep_extend('force', GdevTemplate.config, vim.b.gdevtemplate_config or {}, config or {})
end

-- Actions ---------------------------------------------------------------------
H.do_action = function(buf_id, opts)
  if not vim.api.nvim_buf_is_valid(buf_id) then return end

  -- Replace with real functionality. Keep side effects here, not in the
  -- public wrapper, so both mapping and scripting paths behave identically.
  H.cache.last_buf_id = buf_id

  if vim.is_callable(opts.hooks.post_action) then opts.hooks.post_action(buf_id) end
end

-- Predicates -------------------------------------------------------------------
H.is_buffer_normal = function(buf_id) return vim.bo[buf_id or 0].buftype == '' end

-- Utilities ------------------------------------------------------------------
H.error = function(msg) error('(gdev.template) ' .. msg, 0) end

H.notify = function(msg, level) vim.notify('(gdev.template) ' .. msg, vim.log.levels[level or 'INFO']) end

H.check_type = function(name, val, ref, allow_nil)
  if type(val) == ref or (ref == 'callable' and vim.is_callable(val)) or (allow_nil and val == nil) then return end
  H.error(string.format('`%s` should be %s, not %s', name, ref, type(val)))
end

H.validate_buf_id = function(buf_id)
  if buf_id == nil or buf_id == 0 then return vim.api.nvim_get_current_buf() end
  if not (type(buf_id) == 'number' and vim.api.nvim_buf_is_valid(buf_id)) then
    H.error('`buf_id` should be `nil` or valid buffer id, not ' .. vim.inspect(buf_id))
  end
  return buf_id
end

H.map = function(mode, lhs, rhs, opts)
  if lhs == '' then return end
  opts = vim.tbl_deep_extend('force', { silent = true }, opts or {})
  vim.keymap.set(mode, lhs, rhs, opts)
end

return GdevTemplate
