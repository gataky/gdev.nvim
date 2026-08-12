--- *gdev.docs* Godot class reference
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Shows a Godot class page without leaving Neovim: name it, or put the
---   cursor on it. See |GdevDocs.open()|.
--- - Three renderers -- a floating window, a reusable split, or the class page
---   on the website in your browser.
--- - Converts the documentation's reStructuredText source to Markdown, so the
---   page reads as text rather than as markup.
--- - Caches what it fetched, so a class you keep coming back to costs one
---   request per session.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.docs').setup({})` (replace
--- `{}` with your `config` table). It will create global Lua table `GdevDocs`
--- which you can use for scripting or manually (with `:lua GdevDocs.*`).
---
--- See |GdevDocs.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevdocs_config` which should have same structure as
--- `GdevDocs.config`.
---
--- # Where the pages come from ~
---
--- Two different places, and it is worth knowing which is which.
---
--- The `'float'` and `'buffer'` renderers read the *source* of the class page:
--- `classes/class_<name>.rst` under `config.source_base_url`, which defaults to
--- the `godot-docs` repository at `config.source_ref`. Fetching is |curl| over
--- |vim.system()|, bounded by `config.timeout_ms`.
---
--- The `'browser'` renderer opens the *published* page on
--- `docs.godotengine.org` for `config.language` and `config.version` instead,
--- through |vim.ui.open()|. It needs nothing fetched, which is why it is also
--- the only `config.fallback_renderer` that can recover a failed fetch --
--- being offline, being behind a proxy, or naming a class that does not exist.
---
--- Both URLs are built from the symbol alone (lowercased, spaces removed), so
--- there is no index to download and nothing to keep in sync. |GdevDocs.get_url()|
--- returns them without fetching anything.
---
--- # Caching ~
---
--- Converted pages are kept in memory, keyed by source URL and evicted least
--- recently used at `config.cache.max_entries`. Because the key is the whole
--- URL, pointing `source_ref` or `source_base_url` somewhere else invalidates
--- nothing and re-fetches everything -- which is what you want when you switch
--- to a `4.3` branch of the docs. Setting `cache.enabled = false` in `setup()`
--- also drops whatever was already cached.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevdocs_disable` (globally) or
--- `vim.b.gdevdocs_disable` (for a buffer) to `true`. |GdevDocs.get_url()| and
--- |GdevDocs.status()| keep answering while disabled, since neither touches
--- the screen, and |GdevDocs.close()| keeps working so a window that is
--- already open can always be shut.
---@tag GdevDocs

-- Module definition ==========================================================
local GdevDocs = {}
local H = require('gdev.util').new('docs', GdevDocs)

-- Sphinx-to-Markdown conversion, internal and pure. See 'lua/gdev/rst.lua'.
local Rst = require('gdev.rst')

--- Module setup
---
---@param config table|nil Module config table. See |GdevDocs.config|.
---
---@usage >lua
---   require('gdev.docs').setup() -- use default config
---   -- OR
---   require('gdev.docs').setup({}) -- replace {} with your config table
--- <
GdevDocs.setup = function(config)
  -- Export module
  _G.GdevDocs = GdevDocs

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.create_user_commands()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevDocs.config = {
  -- How `:GdevDocs` shows a page: `'float'`, `'buffer'` or `'browser'`
  renderer = 'float',

  -- What to do when the documentation source can not be fetched. `'browser'`
  -- is the only renderer that can recover, since it needs nothing fetched;
  -- `false` reports the failure per `missing_symbol_feedback` instead.
  fallback_renderer = 'browser',

  -- How a symbol that resolves to nothing is reported: `'message'` echoes,
  -- `'notify'` goes through |vim.notify()|
  missing_symbol_feedback = 'message',

  -- Documentation version and language, as they appear in a
  -- `docs.godotengine.org` URL
  version = 'stable',
  language = 'en',

  -- Git ref of `godotengine/godot-docs` the reStructuredText source is read
  -- from. Ignored when `source_base_url` is set.
  source_ref = 'master',

  -- Base URL of the documentation source tree. `nil` builds it from
  -- `source_ref`; set it to a local checkout (`file:///path/to/godot-docs`)
  -- to read the pages offline.
  source_base_url = nil,

  -- How long a single fetch may take, in milliseconds
  timeout_ms = 10000,

  -- In-memory cache of converted pages, evicted least recently used
  cache = {
    enabled = true,
    max_entries = 64,
  },

  -- Floating window, sized as a fraction of the editor and centered in it.
  -- `border` takes anything |nvim_open_win()| accepts.
  float = {
    width = 0.8,
    height = 0.8,
    border = 'rounded',
  },

  -- Split used by the `'buffer'` renderer. `position` is `'right'`,
  -- `'bottom'` or `'current'` (reuse the window you are in); `size` is a
  -- fraction of the editor.
  buffer = {
    position = 'right',
    size = 0.4,
  },
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Show the documentation for a symbol
---
--- `symbol` is a class name -- `'Node2D'`, `'@GDScript'`. Omitted or empty, it
--- is taken from the word under the cursor, which is what makes `:GdevDocs`
--- with no argument useful in a script buffer.
---
--- Everything after that is asynchronous: the fetch happens in the background
--- and the window appears when it answers, so this returning `true` means the
--- lookup started rather than that a page exists. A failure surfaces later,
--- through `config.fallback_renderer` or `config.missing_symbol_feedback`.
---
---@param symbol string|nil Class to look up, or `nil` for the word under the cursor.
---@param opts table|nil Options overriding `GdevDocs.config` for this call.
---   `{ renderer = 'browser' }` is what the per-renderer commands pass.
---
---@return boolean Whether a lookup was started.
GdevDocs.open = function(symbol, opts)
  if H.is_disabled() then return false end

  H.check_type('symbol', symbol, 'string', true)

  local config = H.get_config(opts)
  local urls = H.urls(H.resolve_symbol(symbol), config)
  if urls == nil then
    H.feedback('no symbol given and none under the cursor', config)
    return false
  end

  -- The website needs nothing fetched, and asking for a page that does not
  -- exist is answered better by the docs site's own search than by us
  if config.renderer == 'browser' then
    H.open_browser(urls.page)
    return true
  end

  local cached = H.cache_get(urls.source, config)
  if cached ~= nil then
    H.render(urls, cached, config)
    return true
  end

  H.fetch(urls.source, config, function(text, err)
    local markdown = Rst.to_markdown(text)
    if markdown == '' then return H.recover(urls, err, config) end

    H.render(urls, H.cache_put(urls.source, markdown, config), config)
  end)

  return true
end

--- Close the documentation window
---
--- Deliberately keeps working while the module is disabled, and is what the
--- `q` mapping in a documentation buffer calls: disabling a module must not be
--- able to strand a window it opened. When the documentation took over the
--- only window (`buffer.position = 'current'`), that window goes back to what
--- it was showing rather than being closed.
---
---@return boolean Whether a window was closed.
GdevDocs.close = function()
  local win_id = H.docs.win_id
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then return false end

  H.docs.win_id = nil

  if #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, win_id, true)
    return true
  end

  local previous = H.docs.prev_buf
  if previous == nil or not vim.api.nvim_buf_is_valid(previous) then previous = vim.api.nvim_create_buf(true, false) end
  vim.api.nvim_win_set_buf(win_id, previous)
  return true
end

--- URLs a symbol resolves to
---
--- Pure: builds both URLs without fetching anything, so it is safe to call
--- from a mapping, a statusline or |:checkhealth|, and keeps answering while
--- the module is disabled. Resolves `symbol` exactly as |GdevDocs.open()|
--- does, cursor word included.
---
---@param symbol string|nil Class to look up, or `nil` for the word under the cursor.
---@param opts table|nil Options overriding `GdevDocs.config` for this call.
---
---@return table|nil `{ symbol = string, slug = string, source = string, page = string }`,
---   where `source` is the reStructuredText fetched by the `'float'` and
---   `'buffer'` renderers and `page` the website page opened by `'browser'`.
---   `nil` when no symbol resolves.
GdevDocs.get_url = function(symbol, opts)
  H.check_type('symbol', symbol, 'string', true)

  return H.urls(H.resolve_symbol(symbol), H.get_config(opts))
end

--- Report what a lookup would use
---
--- Pure and side-effect free, and keeps answering while the module is
--- disabled, since that is when it gets asked.
---
---@param opts table|nil Options overriding `GdevDocs.config` for this call.
---
---@return table `{ renderer, fallback_renderer, source_url, page_url, curl, cache }`,
---   where the two URLs are the base of each tree rather than any one page,
---   `curl` says whether the fetcher is executable, and `cache` is
---   `{ enabled, entries, max_entries }`.
GdevDocs.status = function(opts)
  local config = H.get_config(opts)

  return {
    renderer = config.renderer,
    fallback_renderer = config.fallback_renderer,
    source_url = H.source_base(config),
    page_url = H.page_base(config),
    curl = vim.fn.executable(H.fetcher) == 1,
    cache = {
      enabled = config.cache.enabled,
      entries = vim.tbl_count(H.cache.entries),
      max_entries = config.cache.max_entries,
    },
  }
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevDocs.config)

-- The one documentation window, and the buffer the split renderer reuses.
-- `prev_buf` is what `buffer.position = 'current'` displaced, so closing can
-- put it back.
H.docs = {
  buf_id = nil,
  win_id = nil,
  prev_buf = nil,
}

-- Converted pages by source URL. `clock` orders them for eviction: a counter
-- rather than a timestamp, because two lookups can share a nanosecond.
H.cache = {
  entries = {},
  clock = 0,
}

H.fetcher = 'curl'

-- Buffer names are unique, which is what lets a reloaded module find the
-- buffer its previous incarnation created instead of colliding with it
H.buf_prefix = 'gdev://docs/'

-- Floor on a window's size, in cells. Small on purpose: a configured fraction
-- should be honored rather than quietly replaced by a nicer number.
H.min_size = 3

H.renderers = { 'browser', 'buffer', 'float' }

H.fallback_renderers = { 'browser', false }

H.feedback_modes = { 'message', 'notify' }

H.positions = { 'bottom', 'current', 'right' }

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_one_of('renderer', config.renderer, H.renderers)
  H.check_one_of('fallback_renderer', config.fallback_renderer, H.fallback_renderers)
  H.check_one_of('missing_symbol_feedback', config.missing_symbol_feedback, H.feedback_modes)
  H.check_type('version', config.version, 'string')
  H.check_type('language', config.language, 'string')
  H.check_type('source_ref', config.source_ref, 'string')
  H.check_type('source_base_url', config.source_base_url, 'string', true)
  H.check_type('timeout_ms', config.timeout_ms, 'number')
  H.check_type('cache', config.cache, 'table')
  H.check_type('cache.enabled', config.cache.enabled, 'boolean')
  H.check_positive('cache.max_entries', config.cache.max_entries)
  H.check_type('float', config.float, 'table')
  H.check_fraction('float.width', config.float.width)
  H.check_fraction('float.height', config.float.height)
  H.check_border('float.border', config.float.border)
  H.check_type('buffer', config.buffer, 'table')
  H.check_one_of('buffer.position', config.buffer.position, H.positions)
  H.check_fraction('buffer.size', config.buffer.size)

  return config
end

H.check_one_of = function(field, value, allowed)
  if vim.tbl_contains(allowed, value) then return end
  local quoted = vim.tbl_map(vim.inspect, allowed)
  H.error(('`%s` should be one of %s, not %s'):format(field, table.concat(quoted, ', '), vim.inspect(value)))
end

H.check_fraction = function(field, value)
  if type(value) == 'number' and 0 < value and value <= 1 then return end
  H.error(('`%s` should be a number between 0 and 1, not %s'):format(field, vim.inspect(value)))
end

H.check_positive = function(field, value)
  if type(value) == 'number' and value >= 1 then return end
  H.error(('`%s` should be a number of at least 1, not %s'):format(field, vim.inspect(value)))
end

-- |nvim_open_win()| takes a border style by name or as an array of characters,
-- and both are worth allowing through
H.check_border = function(field, value)
  if type(value) == 'string' or type(value) == 'table' then return end
  H.error(('`%s` should be a string or table, not %s'):format(field, type(value)))
end

H.apply_config = function(config)
  GdevDocs.config = config

  -- Turning the cache off should also free what it holds, and lowering
  -- `max_entries` should take effect now rather than at the next lookup
  if not config.cache.enabled then H.cache.entries = {} end
  H.cache_trim(config.cache.max_entries)
end

H.create_user_commands = function()
  local open = function(renderer)
    return function(data) GdevDocs.open(data.args, renderer ~= nil and { renderer = renderer } or nil) end
  end
  local command = function(name, callback, opts)
    vim.api.nvim_create_user_command(name, callback, vim.tbl_extend('force', { nargs = '?' }, opts))
  end

  command('GdevDocs', open(nil), { desc = 'Open Godot class documentation' })
  command('GdevDocsFloat', open('float'), { desc = 'Open Godot class documentation in a floating window' })
  command('GdevDocsBuffer', open('buffer'), { desc = 'Open Godot class documentation in a split' })
  command('GdevDocsBrowser', open('browser'), { desc = 'Open Godot class documentation in the browser' })
  command('GdevDocsCursor', function() GdevDocs.open() end, {
    nargs = 0,
    desc = 'Open Godot class documentation for the word under the cursor',
  })
end

-- Symbols and URLs -----------------------------------------------------------
H.resolve_symbol = function(symbol)
  local resolved = vim.trim(symbol or '')
  if resolved ~= '' then return resolved end

  return vim.trim(vim.fn.expand('<cword>'))
end

-- Godot's generator lowercases the class name and strips spaces to get a file
-- name, so `@GDScript` really is `class_@gdscript.rst`
H.slug = function(symbol) return (symbol:lower():gsub('%s+', '')) end

H.urls = function(symbol, config)
  if symbol == '' then return nil end

  local slug = H.slug(symbol)
  return {
    symbol = symbol,
    slug = slug,
    source = ('%s/classes/class_%s.rst'):format(H.source_base(config), slug),
    page = ('%s/classes/class_%s.html'):format(H.page_base(config), slug),
  }
end

H.source_base = function(config)
  local base = config.source_base_url
  if type(base) == 'string' and base ~= '' then return (base:gsub('/+$', '')) end

  return ('https://raw.githubusercontent.com/godotengine/godot-docs/%s'):format(config.source_ref)
end

H.page_base = function(config) return ('https://docs.godotengine.org/%s/%s'):format(config.language, config.version) end

-- Fetching -------------------------------------------------------------------
-- Calls back with the fetched text, or with `nil` and a reason. Both happen on
-- the main loop, so the callback may touch buffers.
H.fetch = function(url, config, on_done)
  if vim.fn.executable(H.fetcher) ~= 1 then
    return on_done(nil, ('`%s` is not executable, and is what fetches the documentation'):format(H.fetcher))
  end

  -- Two timeouts for one deadline: `--max-time` lets curl fail with a message
  -- of its own, and |vim.system()|'s kills a curl that ignores it
  local argv = { H.fetcher, '-fsSL', '--max-time', ('%.3f'):format(config.timeout_ms / 1000), url }
  local ok, err = pcall(vim.system, argv, { text = true, timeout = config.timeout_ms }, function(out)
    vim.schedule(function()
      local text = out.stdout or ''
      if out.code == 0 and text ~= '' then return on_done(text) end
      on_done(nil, H.fetch_error(out, url))
    end)
  end)

  -- |vim.system()| raises rather than returning when the command cannot be
  -- spawned at all, which the probe above should have prevented
  if not ok then on_done(nil, tostring(err)) end
end

H.fetch_error = function(out, url)
  local reported = vim.trim(out.stderr or '')
  if reported ~= '' then return reported end
  if out.code == 0 then return ('%s is empty'):format(url) end

  return ('%s exited with %d fetching %s'):format(H.fetcher, out.code, url)
end

-- What a failed or empty fetch turns into: the browser when it can recover the
-- page, and a report when nothing can
H.recover = function(urls, err, config)
  if config.fallback_renderer == 'browser' then return H.open_browser(urls.page) end

  H.feedback(('no documentation for `%s` (%s)'):format(urls.symbol, err or 'nothing was returned'), config)
end

-- Rendering ------------------------------------------------------------------
H.render = function(urls, markdown, config)
  local lines = H.page_lines(urls, markdown)

  if config.renderer == 'buffer' then return H.open_split(urls, lines, config) end
  H.open_float(urls, lines, config)
end

-- The website URL goes above the page rather than below it: a class page is
-- thousands of lines long and `q` closes it, so anything at the end is never
-- seen. It is the page URL rather than the source one because it is the one a
-- reader can act on; |GdevDocs.get_url()| has both.
H.page_lines = function(urls, markdown)
  return vim.split(('Docs: %s\n\n'):format(urls.page) .. markdown, '\n', { plain = true })
end

H.open_browser = function(url)
  local ok, err = vim.ui.open(url)
  if ok == nil then H.notify(('could not open %s: %s'):format(url, err or 'no handler'), 'ERROR') end
end

H.open_float = function(urls, lines, config)
  -- A second float would stack on top of the first
  H.close_float()

  local buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = 'wipe'
  H.fill(buf_id, lines)

  local win_id = vim.api.nvim_open_win(buf_id, true, H.float_config(urls.symbol, config.float))
  H.docs.win_id, H.docs.prev_buf = win_id, nil
  H.window_options(win_id)
end

H.open_split = function(urls, lines, config)
  local buf_id = H.docs_buf()
  H.fill(buf_id, lines)

  -- Names are unique, so a rename can collide with a documentation buffer left
  -- behind by a previous incarnation of this module
  pcall(vim.api.nvim_buf_set_name, buf_id, H.buf_prefix .. urls.slug)

  local win_id = H.reusable_win()
  if win_id == nil then
    H.close_float()
    win_id = H.split_win(config.buffer)
  end

  vim.api.nvim_win_set_buf(win_id, buf_id)
  vim.api.nvim_set_current_win(win_id)
  H.docs.win_id = win_id
  H.window_options(win_id)
end

H.docs_buf = function()
  local buf_id = H.docs.buf_id
  if buf_id ~= nil and vim.api.nvim_buf_is_valid(buf_id) then return buf_id end

  buf_id = H.find_buf(H.buf_prefix)
  if buf_id == nil then
    buf_id = vim.api.nvim_create_buf(false, true)
    vim.bo[buf_id].buftype = 'nofile'
    vim.bo[buf_id].bufhidden = 'hide'
    vim.bo[buf_id].swapfile = false
  end

  H.docs.buf_id = buf_id
  return buf_id
end

H.find_buf = function(prefix)
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.startswith(vim.api.nvim_buf_get_name(buf_id), prefix) then return buf_id end
  end
end

H.fill = function(buf_id, lines)
  vim.bo[buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  vim.bo[buf_id].modifiable = false
  vim.bo[buf_id].modified = false
  vim.bo[buf_id].filetype = 'markdown'

  H.map('n', 'q', '<Cmd>lua GdevDocs.close()<CR>', { buffer = buf_id, desc = 'Close the Godot documentation' })
end

H.split_win = function(opts)
  -- `'current'` shows the page in the window the cursor is in, which is what
  -- it was chosen for; remembering what was there is what lets `q` undo it
  if opts.position == 'current' then
    local win_id = vim.api.nvim_get_current_win()
    H.docs.prev_buf = vim.api.nvim_win_get_buf(win_id)
    return win_id
  end

  local vertical = opts.position == 'right'
  local editor = vertical and vim.o.columns or vim.o.lines
  local win_config = { split = vertical and 'right' or 'below', win = -1 }
  win_config[vertical and 'width' or 'height'] = math.max(math.floor(editor * opts.size), H.min_size)

  H.docs.prev_buf = nil
  return vim.api.nvim_open_win(H.docs_buf(), true, win_config)
end

H.reusable_win = function()
  local win_id = H.docs.win_id
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then return nil end
  if vim.api.nvim_win_get_config(win_id).relative ~= '' then return nil end

  return win_id
end

H.close_float = function()
  local win_id = H.docs.win_id
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then return end
  if vim.api.nvim_win_get_config(win_id).relative == '' then return end

  pcall(vim.api.nvim_win_close, win_id, true)
  H.docs.win_id = nil
end

H.float_config = function(symbol, opts)
  local width = math.min(math.max(math.floor(vim.o.columns * opts.width), H.min_size), vim.o.columns)
  local height = math.min(math.max(math.floor(vim.o.lines * opts.height), H.min_size), vim.o.lines)

  local win_config = {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = opts.border,
  }

  -- |nvim_open_win()| refuses a title on a borderless window
  if opts.border ~= 'none' then
    win_config.title, win_config.title_pos = (' Godot docs: %s '):format(symbol), 'center'
  end

  return win_config
end

-- Documentation is prose: wrapped at word boundaries, with nothing in the
-- gutter and no cursor line, because nothing here acts on the cursor's line.
H.window_options = function(win_id)
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then return end

  local wo = vim.wo[win_id]
  wo.wrap, wo.linebreak, wo.number, wo.relativenumber = true, true, false, false
  wo.signcolumn, wo.cursorline, wo.list, wo.spell = 'no', false, false, false
  vim.api.nvim_win_set_cursor(win_id, { 1, 0 })
end

-- Caching --------------------------------------------------------------------
H.cache_get = function(key, config)
  if not config.cache.enabled then return nil end

  local entry = H.cache.entries[key]
  if entry == nil then return nil end

  H.cache.clock = H.cache.clock + 1
  entry.used = H.cache.clock
  return entry.value
end

H.cache_put = function(key, value, config)
  if not config.cache.enabled then return value end

  H.cache.clock = H.cache.clock + 1
  H.cache.entries[key] = { value = value, used = H.cache.clock }
  H.cache_trim(config.cache.max_entries)

  return value
end

H.cache_trim = function(max_entries)
  local count = vim.tbl_count(H.cache.entries)

  while count > max_entries do
    local oldest, oldest_used
    for key, entry in pairs(H.cache.entries) do
      if oldest_used == nil or entry.used < oldest_used then
        oldest, oldest_used = key, entry.used
      end
    end
    if oldest == nil then return end

    H.cache.entries[oldest] = nil
    count = count - 1
  end
end

-- Feedback -------------------------------------------------------------------
-- Same prefix |H.notify()| uses; `nvim_echo()` does not go through it
H.prefix = '(gdev.docs) '

H.feedback = function(message, config)
  if config.missing_symbol_feedback == 'notify' then return H.notify(message, 'WARN') end

  vim.api.nvim_echo({ { H.prefix .. message, 'WarningMsg' } }, false, {})
end

return GdevDocs
