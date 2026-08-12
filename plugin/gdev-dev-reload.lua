-- Reload this plugin's Lua modules when one of its files is written, so it can
-- be worked on without restarting Neovim. For developing gdev.nvim itself; of no
-- use to anyone using it.
--
-- Opt in before the plugin is sourced, which for most plugin managers means the
-- top of your config:
--
--   vim.g.gdev_dev_reload = true
--
-- Every module that has been set up is set up again with the config it is
-- currently running, so the reload is invisible apart from the notification.
-- Modules that were never set up stay that way.
if not vim.g.gdev_dev_reload then return end

-- The repository this file was sourced from, rather than a path guessed from
-- `$HOME`: a plugin manager, a worktree and a clone made by hand all put it
-- somewhere different.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local watched = root .. '/lua/gdev/'

-- Modules with a `setup()`, in the same order 'lua/gdev/init.lua' uses
local modules = { 'lsp', 'treesitter', 'dap', 'format', 'server', 'run', 'scenetree', 'docs' }

local global = function(module) return 'Gdev' .. module:sub(1, 1):upper() .. module:sub(2) end

local reload = function(path)
  -- Configs first: they are read off the tables that are about to be replaced.
  -- A module's own `config` is the resolved one, and merging it over the
  -- defaults again is a no-op, so this preserves whatever the user asked for
  -- without this script having to know what that was.
  local configs = {}
  for _, module in ipairs(modules) do
    local mod = _G[global(module)]
    if mod ~= nil then configs[module] = vim.deepcopy(mod.config) end
  end
  local had_umbrella = _G.Gdev ~= nil

  for name, _ in pairs(package.loaded) do
    if name == 'gdev' or name:match('^gdev%.') then package.loaded[name] = nil end
  end

  -- One failure is reported and the rest still reload: a half-written module is
  -- the normal reason to be here
  local reloaded, failed = {}, {}
  for _, module in ipairs(modules) do
    if configs[module] ~= nil then
      local ok, err = pcall(function() require('gdev.' .. module).setup(configs[module]) end)
      table.insert(ok and reloaded or failed, ok and module or ('%s (%s)'):format(module, err))
    end
  end

  -- The umbrella exports a global too, and nothing above replaces it
  if had_umbrella then _G.Gdev = require('gdev') end

  local written = vim.fn.fnamemodify(path, ':t')
  if #failed > 0 then
    vim.notify(('(gdev) reload after %s failed: %s'):format(written, table.concat(failed, ', ')), vim.log.levels.ERROR)
  end
  if #reloaded > 0 then
    vim.notify(('(gdev) reloaded %s after %s'):format(table.concat(reloaded, ', '), written), vim.log.levels.INFO)
  end
end

-- Matched here rather than through an autocommand path pattern, which compares
-- against the buffer name as typed: a repository reached through a symlink, or
-- opened with a relative path, would silently never fire.
vim.api.nvim_create_autocmd('BufWritePost', {
  group = vim.api.nvim_create_augroup('GdevDevReload', {}),
  pattern = '*.lua',
  desc = 'Reload gdev.nvim modules on write',
  callback = function(args)
    local path = vim.fs.normalize(vim.fn.fnamemodify(args.match, ':p'))
    if vim.startswith(path, watched) or vim.startswith(vim.fs.normalize(vim.fn.resolve(path)), watched) then
      reload(path)
    end
  end,
})
