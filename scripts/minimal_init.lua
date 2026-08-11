-- Add project root to 'runtimepath' to be able to use 'lua' files
vim.cmd([[let &rtp.=','.getcwd()]])

-- Set up 'mini.test' only when calling headless Neovim (like with `make test`)
if #vim.api.nvim_list_uis() == 0 then
  -- Make the runtime hermetic before anything is required. This machine's own
  -- Neovim config is on 'runtimepath' even under `--noplugin`, so a locally
  -- installed mini.nvim shadows `deps/mini.nvim` and local runs end up testing
  -- a different version than CI does. User 'after' and 'ftplugin' directories
  -- would likewise leak into buffer options and reference screenshots.
  local user_dirs = { vim.fn.stdpath('config'), vim.fn.stdpath('data') .. '/site' }
  local is_user_dir = function(dir)
    return vim.iter(user_dirs):any(function(user_dir) return vim.startswith(dir, user_dir) end)
  end
  vim.opt.rtp = vim.tbl_filter(function(dir) return not is_user_dir(dir) end, vim.opt.rtp:get())
  vim.o.packpath = ''

  -- Prepended, so the pinned copy wins over any other on 'runtimepath'
  vim.cmd('set rtp^=deps/mini.nvim')
  require('mini.test').setup()

  -- Pin everything that reference screenshots capture. Neovim's default
  -- colorscheme and 'rulerformat'/'statusline' output drift between versions,
  -- which would make `child.expect_screenshot()` fail on the CI version matrix
  -- for reasons unrelated to the code under test.
  vim.o.background = 'dark'
  require('mini.hues').setup({ background = '#11262d', foreground = '#c0c8cc', autoadjust = false })
  vim.g.colors_name = 'gdev-test-scheme'
  vim.o.termguicolors = true
  vim.o.ruler = false
  vim.o.rulerformat = '%='
  vim.o.statusline = '%<%f %l,%c%V'
end
