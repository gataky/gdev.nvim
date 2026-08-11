-- Internal helpers shared by every `gdev.*` module.
--
-- Not a feature module: no `setup()`, no global table, no vimdoc. It exists
-- because the boilerplate below is identical everywhere except for the module
-- name, and mini.nvim's habit of restating it per module only pays off for a
-- plugin whose modules get copied out one at a time. Ours do not.
--
-- Deliberately excluded: anything a module can reasonably want to do
-- differently. Config validation, autocommand groups and user commands stay in
-- the modules, where the differences between them are visible.
local Util = {}

-- Build the private helper table a module starts from. `name` is the module
-- name without the namespace ('lsp'), `mod` its public table, the one holding
-- `config`.
--
--   local GdevName = {}
--   local H = require('gdev.util').new('name', GdevName)
--
-- `mod` is held by reference and read lazily, so `get_config()` sees whatever
-- `mod.config` holds at call time -- `setup()` replaces that table wholesale.
--
-- Modules add their own helpers to the returned table, so call sites read the
-- same as if these were defined locally: `H.error(...)`, `H.get_config(...)`.
--
-- Plain comments on purpose: `---` would put this internal module into the
-- generated vimdoc alongside the user-facing ones.
Util.new = function(name, mod)
  local H = {}

  local prefix = ('(gdev.%s) '):format(name)
  local var = 'gdev' .. name

  -- Level 0: user-facing errors read better without a Lua stack trace attached
  H.error = function(msg) error(prefix .. msg, 0) end

  H.notify = function(msg, level) vim.notify(prefix .. msg, vim.log.levels[level or 'INFO']) end

  H.check_type = function(field, val, ref, allow_nil)
    if type(val) == ref or (ref == 'callable' and vim.is_callable(val)) or (allow_nil and val == nil) then return end
    H.error(string.format('`%s` should be %s, not %s', field, ref, type(val)))
  end

  H.validate_buf_id = function(buf_id)
    if buf_id == nil or buf_id == 0 then return vim.api.nvim_get_current_buf() end
    if not (type(buf_id) == 'number' and vim.api.nvim_buf_is_valid(buf_id)) then
      H.error('`buf_id` should be `nil` or valid buffer id, not ' .. vim.inspect(buf_id))
    end
    return buf_id
  end

  H.is_disabled = function() return vim.g[var .. '_disable'] == true or vim.b[var .. '_disable'] == true end

  -- Resolve config at call time: defaults < `setup()` < buffer < per-call. The
  -- buffer variable is read off `buf_id` rather than the current buffer, because
  -- autocommand and LSP callbacks run for buffers that are not visible.
  H.get_config = function(config, buf_id)
    local buf_config = vim.b[buf_id or 0][var .. '_config'] or {}
    return vim.tbl_deep_extend('force', mod.config, buf_config, config or {})
  end

  -- An empty `lhs` is the documented way for users to turn a mapping off
  H.map = function(mode, lhs, rhs, opts)
    if lhs == '' then return end
    opts = vim.tbl_deep_extend('force', { silent = true }, opts or {})
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  return H
end

return Util
