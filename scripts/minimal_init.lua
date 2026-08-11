-- Add project root to 'runtimepath' to be able to use 'lua' files
vim.cmd([[let &rtp.=','.getcwd()]])

-- Set up 'mini.test' only when calling headless Neovim (like with `make test`)
if #vim.api.nvim_list_uis() == 0 then
  vim.cmd('set rtp+=deps/mini.nvim')
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
