-- Shared test helpers. Copy to 'tests/helpers.lua' once when scaffolding the
-- test suite; per-module test files `dofile()` it. Adapted from
-- 'mini.nvim/tests/helpers.lua' (MIT).
local Helpers = {}

-- Add extra expectations
Helpers.expect = vim.deepcopy(MiniTest.expect)

Helpers.expect.match = MiniTest.new_expectation('string matching', function(str, pattern)
  return str:find(pattern) ~= nil
end, function(str, pattern)
  return string.format('Pattern: %s\nObserved string: %s', vim.inspect(pattern), str)
end)

Helpers.expect.no_match = MiniTest.new_expectation('no string matching', function(str, pattern)
  return str:find(pattern) == nil
end, function(str, pattern)
  return string.format('Pattern: %s\nObserved string: %s', vim.inspect(pattern), str)
end)

-- Monkey-patch `MiniTest.new_child_neovim` with helpful wrappers
Helpers.new_child_neovim = function()
  local child = MiniTest.new_child_neovim()

  local prevent_hanging = function(method)
    if not child.is_blocked() then
      return
    end
    error(string.format('Can not use `child.%s` because child process is blocked.', method))
  end

  child.setup = function()
    child.restart({ '-u', 'scripts/minimal_init.lua' })
    child.bo.readonly = false
  end

  child.set_lines = function(arr, start, finish)
    prevent_hanging('set_lines')
    if type(arr) == 'string' then
      arr = vim.split(arr, '\n')
    end
    child.api.nvim_buf_set_lines(0, start or 0, finish or -1, false, arr)
  end

  child.get_lines = function(start, finish)
    prevent_hanging('get_lines')
    return child.api.nvim_buf_get_lines(0, start or 0, finish or -1, false)
  end

  child.set_cursor = function(line, column, win_id)
    prevent_hanging('set_cursor')
    child.api.nvim_win_set_cursor(win_id or 0, { line, column })
  end

  child.get_cursor = function(win_id)
    prevent_hanging('get_cursor')
    return child.api.nvim_win_get_cursor(win_id or 0)
  end

  child.set_size = function(lines, columns)
    prevent_hanging('set_size')
    if type(lines) == 'number' then
      child.o.lines = lines
    end
    if type(columns) == 'number' then
      child.o.columns = columns
    end
  end

  -- Work with 'gdev.nvim' modules:
  -- - `gdev_load` - load module with "normal" table config.
  -- - `gdev_unload` - unload module and revert common side effects.
  child.gdev_load = function(name, config)
    local lua_cmd = ([[require('gdev.%s').setup(...)]]):format(name)
    child.lua(lua_cmd, { config })
  end

  child.gdev_unload = function(name)
    local tbl_name = 'Gdev' .. name:sub(1, 1):upper() .. name:sub(2)

    child.lua(([[package.loaded['gdev.%s'] = nil]]):format(name))
    child.lua(('_G["%s"] = nil'):format(tbl_name))
    if child.fn.exists('#' .. tbl_name) == 1 then
      child.api.nvim_del_augroup_by_name(tbl_name)
    end
  end

  child.expect_screenshot = function(opts, path)
    MiniTest.expect.reference_screenshot(child.get_screenshot(), path, opts)
  end

  -- Poke child's event loop to make it up to date
  child.poke_eventloop = function()
    child.api.nvim_eval('1')
  end

  return child
end

-- Create a function that forwards its arguments to a global function inside a
-- child process and returns the output
Helpers.forward_lua = function(child, fun_str)
  return function(...)
    return child.lua_get(fun_str .. '(...)', { ... })
  end
end

-- Detect environment. Time and retry constants are scaled because CI runners
-- (especially macOS) are markedly slower than local machines.
Helpers.is_ci = function()
  return os.getenv('CI') ~= nil
end
Helpers.is_macos = function()
  return vim.fn.has('mac') == 1
end
Helpers.is_linux = function()
  return vim.fn.has('linux') == 1
end

Helpers.skip_in_ci = function(msg)
  if Helpers.is_ci() then
    MiniTest.skip(msg or 'Does not test properly in CI')
  end
end

Helpers.get_time_const = function(delay)
  local coef = 1
  if Helpers.is_ci() then
    if Helpers.is_linux() then
      coef = 2
    end
    if Helpers.is_macos() then
      coef = 15
    end
  end
  return coef * delay
end

Helpers.get_n_retry = function(n)
  local coef = 1
  if Helpers.is_ci() then
    if Helpers.is_linux() then
      coef = 2
    end
    if Helpers.is_macos() then
      coef = 4
    end
  end
  return coef * n
end

Helpers.sleep = function(ms, child)
  vim.uv.sleep(math.max(ms, 1))
  if child ~= nil then
    child.poke_eventloop()
  end
end

return Helpers
