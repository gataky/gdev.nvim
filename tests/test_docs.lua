local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config)
  child.gdev_load('docs', config)
end
local unload_module = function()
  child.gdev_unload('docs')
end
local type_keys = function(...)
  return child.type_keys(...)
end

-- Time constants scaled for CI (see `helpers.get_time_const`)
local wait_timeout = helpers.get_time_const(5000)

-- Fetching is asynchronous, so assertions wait for the effect rather than for
-- a fixed delay. `vim.wait()` runs the child's event loop, which is what lets
-- the `vim.system()` callback and the `vim.schedule()` inside it happen.
local wait_for = function(cond)
  local code = ('(vim.wait(%d, function() return %s end, 5))'):format(wait_timeout, cond)
  eq(child.lua_get(code), true)
end

local wait_for_docs = function()
  wait_for('_G.docs_win() ~= nil')
end

-- Nothing here touches the network. The documentation source is a fixture tree
-- under 'tests/dir-docs/site' fetched over `file://`, which `curl` supports,
-- plus a writable copy in a temporary directory for the cases that need a page
-- to change between two lookups.
local install_fixtures = function()
  child.lua([[
    _G.site = 'file://' .. vim.fs.normalize(vim.fn.fnamemodify('tests/dir-docs/site', ':p'))

    _G.dir = vim.fn.tempname()
    vim.fn.mkdir(_G.dir .. '/classes', 'p')
    _G.tmp_site = 'file://' .. _G.dir
    _G.write_page = function(slug, body)
      local title = slug:sub(1, 1):upper() .. slug:sub(2)
      local lines = { title, string.rep('=', #title), '', body }
      vim.fn.writefile(lines, ('%s/classes/class_%s.rst'):format(_G.dir, slug))
    end

    _G.opened = nil
    vim.ui.open = function(url)
      _G.opened = url
      return {}
    end

    -- `nvim_echo()` with no history leaves nothing in `:messages` to read back
    _G.echoes = {}
    vim.api.nvim_echo = function(chunks) table.insert(_G.echoes, chunks[1][1]) end

    _G.notifications = {}
    vim.notify = function(msg, level) table.insert(_G.notifications, { msg = msg, level = level }) end
    _G.last_message = function() return (_G.notifications[#_G.notifications] or {}).msg end

    -- The documentation window is found by what it shows rather than through
    -- the module's own state, which is private
    _G.docs_win = function()
      for _, win_id in ipairs(vim.api.nvim_list_wins()) do
        local buf_id = vim.api.nvim_win_get_buf(win_id)
        local first = (vim.api.nvim_buf_get_lines(buf_id, 0, 1, false))[1] or ''
        if vim.startswith(first, 'Docs: ') then return win_id end
      end
    end
    _G.docs_buf = function()
      local win_id = _G.docs_win()
      return win_id ~= nil and vim.api.nvim_win_get_buf(win_id) or nil
    end
    _G.docs_lines = function()
      local buf_id = _G.docs_buf()
      return buf_id == nil and {} or vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
    end
    _G.docs_text = function() return table.concat(_G.docs_lines(), '\n') end
    _G.docs_config = function() return vim.api.nvim_win_get_config(_G.docs_win()) end
  ]])
end

local site = function()
  return child.lua_get('_G.site')
end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.set_size(24, 80)
      install_fixtures()
      -- Every case reads its pages from the fixture tree unless it says otherwise
      load_module({ source_base_url = site() })
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevDocs)'), 'table')

  -- User commands
  eq(child.fn.exists(':GdevDocs'), 2)
  eq(child.fn.exists(':GdevDocsFloat'), 2)
  eq(child.fn.exists(':GdevDocsBuffer'), 2)
  eq(child.fn.exists(':GdevDocsBrowser'), 2)
  eq(child.fn.exists(':GdevDocsCursor'), 2)
end

T['setup()']['creates `config` field'] = function()
  unload_module()
  load_module()

  eq(child.lua_get('type(_G.GdevDocs.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevDocs.config.renderer'), 'float')
  eq(child.lua_get('GdevDocs.config.fallback_renderer'), 'browser')
  eq(child.lua_get('GdevDocs.config.missing_symbol_feedback'), 'message')
  eq(child.lua_get('GdevDocs.config.version'), 'stable')
  eq(child.lua_get('GdevDocs.config.language'), 'en')
  eq(child.lua_get('GdevDocs.config.source_ref'), 'master')
  eq(child.lua_get('GdevDocs.config.source_base_url'), vim.NIL)
  eq(child.lua_get('GdevDocs.config.timeout_ms'), 10000)
  eq(child.lua_get('GdevDocs.config.cache'), { enabled = true, max_entries = 64 })
  eq(child.lua_get('GdevDocs.config.float'), { width = 0.8, height = 0.8, border = 'rounded' })
  eq(child.lua_get('GdevDocs.config.buffer'), { position = 'right', size = 0.4 })
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({
    renderer = 'buffer',
    fallback_renderer = false,
    missing_symbol_feedback = 'notify',
    version = '4.3',
    language = 'de',
    source_ref = '4.3',
    source_base_url = 'file:///docs',
    timeout_ms = 500,
    cache = { max_entries = 8 },
    float = { border = 'single' },
    buffer = { position = 'bottom', size = 0.5 },
  })

  eq(child.lua_get('GdevDocs.config.renderer'), 'buffer')
  eq(child.lua_get('GdevDocs.config.fallback_renderer'), false)
  eq(child.lua_get('GdevDocs.config.missing_symbol_feedback'), 'notify')
  eq(child.lua_get('GdevDocs.config.version'), '4.3')
  eq(child.lua_get('GdevDocs.config.language'), 'de')
  eq(child.lua_get('GdevDocs.config.source_base_url'), 'file:///docs')
  eq(child.lua_get('GdevDocs.config.timeout_ms'), 500)
  -- Untouched keys keep their defaults
  eq(child.lua_get('GdevDocs.config.cache'), { enabled = true, max_entries = 8 })
  eq(child.lua_get('GdevDocs.config.float'), { width = 0.8, height = 0.8, border = 'single' })
  eq(child.lua_get('GdevDocs.config.buffer'), { position = 'bottom', size = 0.5 })
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function()
      load_module(config)
    end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')

  expect_config_error({ renderer = 'popup' }, 'renderer', 'float')
  expect_config_error({ renderer = false }, 'renderer', 'float')
  expect_config_error({ fallback_renderer = 'float' }, 'fallback_renderer', 'browser')
  expect_config_error({ fallback_renderer = true }, 'fallback_renderer', 'browser')
  expect_config_error({ missing_symbol_feedback = 'echo' }, 'missing_symbol_feedback', 'message')

  expect_config_error({ version = 1 }, 'version', 'string')
  expect_config_error({ language = 1 }, 'language', 'string')
  expect_config_error({ source_ref = 1 }, 'source_ref', 'string')
  expect_config_error({ source_base_url = 1 }, 'source_base_url', 'string')
  expect_config_error({ timeout_ms = 'a' }, 'timeout_ms', 'number')

  expect_config_error({ cache = 'a' }, 'cache', 'table')
  expect_config_error({ cache = { enabled = 'a' } }, 'cache.enabled', 'boolean')
  expect_config_error({ cache = { max_entries = 'a' } }, 'cache.max_entries', 'number')
  expect_config_error({ cache = { max_entries = 0 } }, 'cache.max_entries', 'number')

  expect_config_error({ float = 'a' }, 'float', 'table')
  expect_config_error({ float = { width = 'a' } }, 'float.width', 'number')
  expect_config_error({ float = { width = 0 } }, 'float.width', 'number')
  expect_config_error({ float = { height = 1.5 } }, 'float.height', 'number')
  expect_config_error({ float = { border = 1 } }, 'float.border', 'string')

  expect_config_error({ buffer = 'a' }, 'buffer', 'table')
  expect_config_error({ buffer = { position = 'left' } }, 'buffer.position', 'right')
  expect_config_error({ buffer = { size = 0 } }, 'buffer.size', 'number')
end

T['setup()']['drops the cache when it is turned off'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()
  eq(child.lua_get('GdevDocs.status().cache.entries'), 1)

  load_module({ source_base_url = site(), cache = { enabled = false } })
  eq(child.lua_get('GdevDocs.status().cache.entries'), 0)
end

T['setup()']['trims the cache to a lowered `max_entries`'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()
  child.lua('GdevDocs.open("Sprite2D")')
  wait_for('GdevDocs.status().cache.entries == 2')

  load_module({ source_base_url = site(), cache = { max_entries = 1 } })
  eq(child.lua_get('GdevDocs.status().cache.entries'), 1)
end

T['open()'] = new_set()

T['open()']['works'] = function()
  eq(child.lua_get('GdevDocs.open("Node")'), true)
  wait_for_docs()

  local lines = child.lua_get('_G.docs_lines()')
  eq(lines[1], 'Docs: https://docs.godotengine.org/en/stable/classes/class_node.html')
  eq(lines[2], '')
  eq(lines[3], '# Node')
  eq(child.lua_get('vim.bo[_G.docs_buf()].filetype'), 'markdown')
  eq(child.lua_get('vim.bo[_G.docs_buf()].modifiable'), false)
end

T['open()']['renders in a floating window by default'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  local win_config = child.lua_get('_G.docs_config()')
  eq(win_config.relative, 'editor')
  -- 80 columns and 24 lines at the default fractions
  eq(win_config.width, 64)
  eq(win_config.height, 19)
  eq(win_config.border[1], '╭')
  eq(win_config.title[1][1], ' Godot docs: Node ')

  -- The window is focused: it is opened to be read
  eq(child.lua_get('vim.api.nvim_get_current_win() == _G.docs_win()'), true)
end

T['open()']['respects `float` config'] = function()
  child.lua('GdevDocs.open("Node", { float = { width = 0.5, height = 0.5, border = "single" } })')
  wait_for_docs()

  local win_config = child.lua_get('_G.docs_config()')
  eq(win_config.width, 40)
  eq(win_config.height, 12)
  eq(win_config.border[1], '┌')
end

T['open()']['still opens a float in a tiny editor'] = function()
  -- A fraction of a small editor rounds down to nothing, and
  -- `nvim_open_win()` refuses a window of no size
  child.set_size(8, 12)
  child.lua('GdevDocs.open("Node", { float = { width = 0.05, height = 0.1 } })')
  wait_for_docs()

  eq(child.lua_get('_G.docs_config().width'), 3)
  eq(child.lua_get('_G.docs_config().height'), 3)
end

T['open()']['omits the title of a borderless float'] = function()
  -- `nvim_open_win()` refuses a title without a border
  child.lua('GdevDocs.open("Node", { float = { border = "none" } })')
  wait_for_docs()

  eq(child.lua_get('_G.docs_config().title'), vim.NIL)
end

T['open()']['renders in a split'] = new_set({
  parametrize = { { 'right' }, { 'bottom' }, { 'current' } },
}, {
  test = function(position)
    local code =
      'GdevDocs.open("Node", { renderer = "buffer", buffer = { position = %s, size = 0.5 } })'
    child.lua(code:format(vim.inspect(position)))
    wait_for_docs()

    eq(child.lua_get('_G.docs_config().relative'), '')
    eq(child.lua_get('#vim.api.nvim_list_wins()'), position == 'current' and 1 or 2)
    if position == 'right' then
      eq(child.lua_get('vim.api.nvim_win_get_width(_G.docs_win())'), 40)
    end
    if position == 'bottom' then
      eq(child.lua_get('vim.api.nvim_win_get_height(_G.docs_win())'), 12)
    end

    eq(child.lua_get('vim.api.nvim_buf_get_name(_G.docs_buf())'), 'gdev://docs/node')
    eq(child.lua_get('vim.bo[_G.docs_buf()].buftype'), 'nofile')

    -- Focused wherever it went: a page is opened to be read and scrolled
    eq(child.lua_get('vim.api.nvim_get_current_win() == _G.docs_win()'), true)
  end,
})

T['open()']['reuses one split for every symbol'] = function()
  child.lua('GdevDocs.open("Node", { renderer = "buffer" })')
  wait_for_docs()
  local first = child.lua_get('_G.docs_buf()')

  -- Back to editing, which is where the next lookup comes from
  child.cmd('wincmd p')

  child.lua('GdevDocs.open("Sprite2D", { renderer = "buffer" })')
  wait_for('_G.docs_text():find("Sprite2D", 1, true) ~= nil')

  eq(child.lua_get('_G.docs_buf()'), first)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
  eq(child.lua_get('vim.api.nvim_buf_get_name(_G.docs_buf())'), 'gdev://docs/sprite2d')
  -- The existing split is focused again rather than merely refilled
  eq(child.lua_get('vim.api.nvim_get_current_win() == _G.docs_win()'), true)
end

T['open()']['replaces a float instead of stacking on it'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  child.lua('GdevDocs.open("Sprite2D")')
  wait_for('_G.docs_text():find("Sprite2D", 1, true) ~= nil')

  eq(child.lua_get('#vim.api.nvim_list_wins()'), 2)
end

T['open()']['opens the website in the browser'] = function()
  eq(child.lua_get('GdevDocs.open("Node", { renderer = "browser" })'), true)

  -- Nothing is fetched: the browser renderer needs no source
  eq(child.lua_get('_G.opened'), 'https://docs.godotengine.org/en/stable/classes/class_node.html')
  eq(child.lua_get('_G.docs_win()'), vim.NIL)
  eq(child.lua_get('GdevDocs.status().cache.entries'), 0)
end

T['open()']['reports a browser that will not open'] = function()
  child.lua('vim.ui.open = function() return nil, "no handler" end')
  child.lua('GdevDocs.open("Node", { renderer = "browser" })')

  expect.match(child.lua_get('_G.last_message()'), 'could not open.*no handler')
end

T['open()']['takes the symbol from the word under the cursor'] = function()
  child.set_lines({ 'var body: Sprite2D' })
  child.set_cursor(1, 12)

  child.lua('GdevDocs.open()')
  wait_for_docs()

  expect.match(child.lua_get('_G.docs_text()'), '# Sprite2D')
end

T['open()']['prefers an explicit symbol to the one under the cursor'] = function()
  child.set_lines({ 'Sprite2D' })
  child.set_cursor(1, 0)

  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  expect.match(child.lua_get('_G.docs_text()'), '# Node')
end

T['open()']['reports having nothing to look up'] = function()
  child.set_lines({ '' })

  eq(child.lua_get('GdevDocs.open("")'), false)
  expect.match(child.lua_get('_G.echoes[1]'), 'no symbol given and none under the cursor')
end

T['open()']['validates arguments'] = function()
  expect.error(function()
    child.lua('GdevDocs.open(1)')
  end, 'symbol.*string')
end

T['open()']['falls back to the browser when the source can not be fetched'] = function()
  eq(child.lua_get('GdevDocs.open("Nonexistent")'), true)
  wait_for('_G.opened ~= nil')

  eq(
    child.lua_get('_G.opened'),
    'https://docs.godotengine.org/en/stable/classes/class_nonexistent.html'
  )
  eq(child.lua_get('_G.docs_win()'), vim.NIL)
end

T['open()']['treats an empty page as a failure'] = function()
  -- `curl` is perfectly happy to fetch nothing at all
  child.lua('GdevDocs.open("Empty")')
  wait_for('_G.opened ~= nil')

  eq(child.lua_get('_G.opened'), 'https://docs.godotengine.org/en/stable/classes/class_empty.html')
end

T['open()']['reports a missing fetcher'] = function()
  child.lua('vim.env.PATH = ""')
  child.lua('GdevDocs.open("Node", { fallback_renderer = false })')

  wait_for('_G.echoes[1] ~= nil')
  expect.match(child.lua_get('_G.echoes[1]'), '`curl` is not executable')
end

T['open()']['reports an unknown symbol when there is no fallback'] = new_set({
  parametrize = { { 'message' }, { 'notify' } },
}, {
  test = function(mode)
    local code =
      'GdevDocs.open("Nonexistent", { fallback_renderer = false, missing_symbol_feedback = %s })'
    child.lua(code:format(vim.inspect(mode)))

    local reported = mode == 'message' and '_G.echoes[1]' or '_G.last_message()'
    wait_for(('%s ~= nil'):format(reported))
    expect.match(child.lua_get(reported), 'no documentation for `Nonexistent`')
    eq(child.lua_get('_G.opened'), vim.NIL)

    if mode == 'notify' then
      eq(child.lua_get('_G.notifications[1].level'), child.lua_get('vim.log.levels.WARN'))
    end
  end,
})

T['open()']['respects `vim.b.gdevdocs_config`'] = function()
  child.lua('vim.b.gdevdocs_config = { renderer = "browser" }')
  child.lua('GdevDocs.open("Node")')

  eq(child.lua_get('_G.opened'), 'https://docs.godotengine.org/en/stable/classes/class_node.html')
end

T['open()']['respects `config.timeout_ms`'] = function()
  eq(child.lua_get('GdevDocs.status().renderer'), 'float')

  -- The deadline reaches `curl` in seconds, not milliseconds
  child.lua([[
    _G.argv = nil
    local system = vim.system
    vim.system = function(cmd, opts, on_exit)
      _G.argv = cmd
      return system(cmd, opts, on_exit)
    end
  ]])
  child.lua('GdevDocs.open("Node", { timeout_ms = 2500 })')
  wait_for_docs()

  eq(child.lua_get('_G.argv[3]'), '--max-time')
  eq(child.lua_get('_G.argv[4]'), '2.500')
end

T['open()']['respects `vim.g.gdevdocs_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(scope)
    child.lua(('vim.%s.gdevdocs_disable = true'):format(scope))

    eq(child.lua_get('GdevDocs.open("Node")'), false)
    eq(child.lua_get('_G.docs_win()'), vim.NIL)
    eq(child.lua_get('_G.opened'), vim.NIL)
  end,
})

T['close()'] = new_set()

T['close()']['closes the floating window'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  eq(child.lua_get('GdevDocs.close()'), true)
  eq(child.lua_get('_G.docs_win()'), vim.NIL)
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
end

T['close()']['is what `q` does in the documentation buffer'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  type_keys('q')
  eq(child.lua_get('_G.docs_win()'), vim.NIL)
end

T['close()']['restores what the only window was showing'] = function()
  child.set_lines({ 'local text' })
  local original = child.lua_get('vim.api.nvim_get_current_buf()')

  child.lua('GdevDocs.open("Node", { renderer = "buffer", buffer = { position = "current" } })')
  wait_for_docs()
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)

  -- Closing the last window is an error, so the buffer goes back instead
  eq(child.lua_get('GdevDocs.close()'), true)
  eq(child.lua_get('vim.api.nvim_get_current_buf()'), original)
  eq(child.get_lines(), { 'local text' })
end

T['close()']['does nothing when no window is open'] = function()
  eq(child.lua_get('GdevDocs.close()'), false)
end

T['close()']['works while disabled'] = function()
  -- A disabled module must not be able to strand a window it opened
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  child.lua('vim.g.gdevdocs_disable = true')
  eq(child.lua_get('GdevDocs.close()'), true)
  eq(child.lua_get('_G.docs_win()'), vim.NIL)
end

T['get_url()'] = new_set()

T['get_url()']['works'] = function()
  unload_module()
  load_module()

  eq(child.lua_get('GdevDocs.get_url("Node2D")'), {
    symbol = 'Node2D',
    slug = 'node2d',
    source = 'https://raw.githubusercontent.com/godotengine/godot-docs/master/classes/class_node2d.rst',
    page = 'https://docs.godotengine.org/en/stable/classes/class_node2d.html',
  })
end

T['get_url()']['slugs a symbol the way the generator does'] = function()
  unload_module()
  load_module()

  eq(child.lua_get('GdevDocs.get_url("@GDScript").slug'), '@gdscript')
  eq(child.lua_get('GdevDocs.get_url("  Animated Sprite2D  ").slug'), 'animatedsprite2d')
  eq(child.lua_get('GdevDocs.get_url("  Node  ").symbol'), 'Node')
end

T['get_url()']['respects config'] = function()
  eq(
    child.lua_get('GdevDocs.get_url("Node", { source_ref = "4.3", source_base_url = "" }).source'),
    'https://raw.githubusercontent.com/godotengine/godot-docs/4.3/classes/class_node.rst'
  )
  eq(
    child.lua_get('GdevDocs.get_url("Node", { language = "de", version = "4.3" }).page'),
    'https://docs.godotengine.org/de/4.3/classes/class_node.html'
  )

  -- A configured base URL keeps its shape whether or not it ends in a slash
  eq(
    child.lua_get('GdevDocs.get_url("Node", { source_base_url = "file:///docs/" }).source'),
    'file:///docs/classes/class_node.rst'
  )
end

T['get_url()']['respects `vim.b.gdevdocs_config`'] = function()
  child.lua('vim.b.gdevdocs_config = { version = "4.2" }')

  expect.match(child.lua_get('GdevDocs.get_url("Node").page'), '/en/4%.2/')
end

T['get_url()']['takes the symbol from the word under the cursor'] = function()
  child.set_lines({ 'extends Node2D' })
  child.set_cursor(1, 8)

  eq(child.lua_get('GdevDocs.get_url().slug'), 'node2d')
end

T['get_url()']['reports nothing to look up'] = function()
  child.set_lines({ '' })

  eq(child.lua_get('GdevDocs.get_url("")'), vim.NIL)
end

T['get_url()']['validates arguments'] = function()
  expect.error(function()
    child.lua('GdevDocs.get_url(1)')
  end, 'symbol.*string')
end

T['get_url()']['works while disabled'] = function()
  child.lua('vim.g.gdevdocs_disable = true')

  eq(child.lua_get('GdevDocs.get_url("Node").slug'), 'node')
end

T['status()'] = new_set()

T['status()']['works'] = function()
  unload_module()
  load_module()

  eq(child.lua_get('GdevDocs.status()'), {
    renderer = 'float',
    fallback_renderer = 'browser',
    source_url = 'https://raw.githubusercontent.com/godotengine/godot-docs/master',
    page_url = 'https://docs.godotengine.org/en/stable',
    curl = true,
    cache = { enabled = true, entries = 0, max_entries = 64 },
  })
end

T['status()']['reports a missing fetcher'] = function()
  child.lua('vim.env.PATH = ""')

  eq(child.lua_get('GdevDocs.status().curl'), false)
end

T['status()']['respects `vim.b.gdevdocs_config`'] = function()
  child.lua('vim.b.gdevdocs_config = { renderer = "browser", source_base_url = "file:///docs" }')

  eq(child.lua_get('GdevDocs.status().renderer'), 'browser')
  eq(child.lua_get('GdevDocs.status().source_url'), 'file:///docs')
end

T['status()']['works while disabled'] = function()
  child.lua('vim.g.gdevdocs_disable = true')

  eq(child.lua_get('GdevDocs.status().renderer'), 'float')
end

T['the cache'] = new_set({
  hooks = {
    pre_case = function()
      unload_module()
      load_module({ source_base_url = child.lua_get('_G.tmp_site') })
      child.lua('_G.write_page("alpha", "First version.")')
    end,
  },
})

T['the cache']['answers a second lookup without fetching'] = function()
  child.lua('GdevDocs.open("Alpha")')
  wait_for_docs()
  expect.match(child.lua_get('_G.docs_text()'), 'First version%.')

  child.lua('_G.write_page("alpha", "Second version.")')
  child.lua('GdevDocs.close()')

  -- A cache hit renders synchronously, so this needs no waiting at all
  child.lua('GdevDocs.open("Alpha")')
  expect.match(child.lua_get('_G.docs_text()'), 'First version%.')
end

T['the cache']['is ignored by a lookup that turns it off'] = function()
  -- Turning the cache off for one call is how a page is forced to refresh
  child.lua('GdevDocs.open("Alpha")')
  wait_for_docs()

  child.lua('_G.write_page("alpha", "Second version.")')
  child.lua('GdevDocs.close()')

  child.lua('GdevDocs.open("Alpha", { cache = { enabled = false } })')
  wait_for('_G.docs_text():find("Second version.", 1, true) ~= nil')
end

T['the cache']['refetches when it is disabled'] = function()
  child.lua('GdevDocs.open("Alpha", { cache = { enabled = false } })')
  wait_for_docs()

  child.lua('_G.write_page("alpha", "Second version.")')
  child.lua('GdevDocs.close()')

  child.lua('GdevDocs.open("Alpha", { cache = { enabled = false } })')
  wait_for('_G.docs_text():find("Second version.", 1, true) ~= nil')
  eq(child.lua_get('GdevDocs.status().cache.entries'), 0)
end

T['the cache']['evicts the least recently used entry'] = function()
  child.lua('_G.write_page("beta", "Beta body.")')
  child.lua('_G.write_page("gamma", "Gamma body.")')

  local open = function(symbol, body)
    child.lua(('GdevDocs.open(%s, { cache = { max_entries = 2 } })'):format(vim.inspect(symbol)))
    wait_for(('_G.docs_text():find(%s, 1, true) ~= nil'):format(vim.inspect(body)))
    child.lua('GdevDocs.close()')
  end

  open('Alpha', 'First version.')
  open('Beta', 'Beta body.')
  open('Gamma', 'Gamma body.')
  eq(child.lua_get('GdevDocs.status({ cache = { max_entries = 2 } }).cache.entries'), 2)

  child.lua('_G.write_page("alpha", "Second version.")')
  child.lua('_G.write_page("gamma", "Gamma rewritten.")')

  -- The oldest of the three is gone and is fetched again
  open('Alpha', 'Second version.')

  -- The newest is still there, so the rewritten file is not read
  child.lua('GdevDocs.open("Gamma", { cache = { max_entries = 2 } })')
  expect.match(child.lua_get('_G.docs_text()'), 'Gamma body%.')
end

T['the cache']['keys entries by source URL'] = function()
  child.lua('GdevDocs.open("Alpha")')
  wait_for_docs()
  child.lua('GdevDocs.close()')

  -- Pointing at another tree invalidates nothing and finds nothing
  child.lua('GdevDocs.open("Alpha", { source_base_url = _G.site })')
  wait_for('_G.opened ~= nil')
  eq(child.lua_get('GdevDocs.status().cache.entries'), 1)
end

T['user commands'] = new_set()

T['user commands']['dispatch the configured renderer'] = function()
  child.cmd('GdevDocs Node')
  wait_for_docs()

  eq(child.lua_get('_G.docs_config().relative'), 'editor')
end

T['user commands']['dispatch each renderer'] = new_set({
  parametrize = { { 'GdevDocsFloat' }, { 'GdevDocsBuffer' } },
}, {
  test = function(command)
    -- The default renderer is a float, so the buffer command has to override it
    child.cmd(command .. ' Node')
    wait_for_docs()

    eq(child.lua_get('_G.docs_config().relative'), command == 'GdevDocsFloat' and 'editor' or '')
  end,
})

T['user commands']['open the browser'] = function()
  child.cmd('GdevDocsBrowser Node')

  eq(child.lua_get('_G.opened'), 'https://docs.godotengine.org/en/stable/classes/class_node.html')
end

T['user commands']['read the word under the cursor'] = function()
  child.set_lines({ 'extends Sprite2D' })
  child.set_cursor(1, 8)

  child.cmd('GdevDocsCursor')
  wait_for_docs()
  expect.match(child.lua_get('_G.docs_text()'), '# Sprite2D')

  -- `:GdevDocsCursor` takes no argument, unlike every other command here
  expect.error(function()
    child.cmd('GdevDocsCursor Node')
  end, 'E488')
end

T['rendering'] = new_set()

T['rendering']['sets window options for reading'] = function()
  child.lua('GdevDocs.open("Node")')
  wait_for_docs()

  local win_id = child.lua_get('_G.docs_win()')
  eq(child.lua_get(('vim.wo[%d].wrap'):format(win_id)), true)
  eq(child.lua_get(('vim.wo[%d].linebreak'):format(win_id)), true)
  eq(child.lua_get(('vim.wo[%d].number'):format(win_id)), false)
  eq(child.lua_get(('vim.wo[%d].signcolumn'):format(win_id)), 'no')
  eq(child.get_cursor(win_id), { 1, 0 })
end

T['rendering']['returns to the top of a replaced page'] = function()
  child.lua('GdevDocs.open("Node", { renderer = "buffer" })')
  wait_for_docs()
  child.set_cursor(8, 0, child.lua_get('_G.docs_win()'))

  child.lua('GdevDocs.open("Sprite2D", { renderer = "buffer" })')
  wait_for('_G.docs_text():find("Sprite2D", 1, true) ~= nil')

  eq(child.get_cursor(child.lua_get('_G.docs_win()')), { 1, 0 })
end

T['rendering']['looks like a documentation window'] = function()
  -- The one case that asserts the window as a whole rather than through the
  -- API. The float is left alone on screen over the empty startup buffer, so
  -- nothing but the border, the title and the converted page is captured.
  --
  -- Attributes are ignored on purpose: the buffer is 'markdown', and which of
  -- Neovim's bundled highlighting applies to it is a runtime file that differs
  -- across 0.11.7, stable and nightly. Geometry is asserted through
  -- `nvim_win_get_config()` above, where it belongs.
  child.set_size(20, 72)
  child.lua('GdevDocs.open("Sprite2D")')
  wait_for_docs()

  child.expect_screenshot({ ignore_attr = true })
end

return T
