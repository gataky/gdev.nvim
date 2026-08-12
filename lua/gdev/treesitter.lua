--- *gdev.treesitter* Treesitter for Godot files
---
--- MIT License Copyright (c) 2026 gdev.nvim authors

--- Features:
--- - Teaches Neovim the Godot file names it does not recognize on its own, so
---   `.gdshaderinc` and `project.godot` get a filetype like every other Godot
---   file.
--- - Starts |vim.treesitter| highlighting in Godot buffers whose parser is
---   installed, and leaves the rest on regular syntax highlighting rather than
---   erroring. See |GdevTreesitter.attach()|.
--- - Resolves the parser a filetype should use, which matters for `gdresource`:
---   the same grammar ships as `gdresource` and as `godot_resource` depending on
---   where it came from. The winner is registered with
---   |vim.treesitter.language.register()| so `vim.treesitter.get_parser()`,
---   |vim.treesitter.foldexpr()| and `:InspectTree` all agree.
--- - Optional treesitter folding.
--- - |GdevTreesitter.parser_status()| reports which Godot parsers are missing.
---
--- # Setup ~
---
--- This module needs a setup with `require('gdev.treesitter').setup({})`
--- (replace `{}` with your `config` table). It will create global Lua table
--- `GdevTreesitter` which you can use for scripting or manually (with
--- `:lua GdevTreesitter.*`).
---
--- See |GdevTreesitter.config| for `config` structure and default values.
---
--- You can override runtime config settings locally to buffer inside
--- `vim.b.gdevtreesitter_config` which should have same structure as
--- `GdevTreesitter.config`.
---
--- # Filetypes ~
---
--- Neovim already detects `.gd`, `.gdshader`, `.tscn` and `.tres`. Added here:
---
--- - `.gdshaderinc` as `gdshader`
--- - `project.godot` as `gdresource`
---
--- Deliberately short. Godot's generated files (`.import`, `.escn`) are left
--- alone: they are rarely edited by hand, and claiming an extension as broad as
--- `.import` for every project on the machine is not this plugin's business.
--- Anything added here loses to a `vim.filetype.add()` call of your own, since
--- the later registration wins.
---
--- # Parsers ~
---
--- This module does not install anything. Neovim ships no parser installer and
--- no Godot grammars, so `gdscript`, `gdshader` and `gdresource` parsers have to
--- be on 'runtimepath' under `parser/<lang>.so`, put there by 'nvim-treesitter',
--- a package manager, or the `tree-sitter` CLI.
---
--- Queries matter as much as parsers. A parser with no `highlights.scm` on
--- 'runtimepath' loads without complaint and highlights nothing, which looks
--- exactly like this module doing nothing. |GdevTreesitter.parser_status()|
--- reports parsers; `:InspectTree` is the quickest way to tell a missing query
--- from a missing parser.
---
--- # Disabling ~
---
--- To disable, set `vim.g.gdevtreesitter_disable` (globally) or
--- `vim.b.gdevtreesitter_disable` (for a buffer) to `true`.
---@tag GdevTreesitter

-- Module definition ==========================================================
local GdevTreesitter = {}
local H = require('gdev.util').new('treesitter', GdevTreesitter)

--- Module setup
---
---@param config table|nil Module config table. See |GdevTreesitter.config|.
---
---@usage >lua
---   require('gdev.treesitter').setup() -- use default config
---   -- OR
---   require('gdev.treesitter').setup({}) -- replace {} with your config table
--- <
GdevTreesitter.setup = function(config)
  -- Export module
  _G.GdevTreesitter = GdevTreesitter

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Define behavior
  H.register_filetypes()
  H.create_autocommands()

  -- Godot buffers open before `setup()` ran never see the `FileType` event
  H.attach_open_buffers()
end

--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
GdevTreesitter.config = {
  -- Whether to start treesitter highlighting in Godot buffers
  highlight = true,

  -- Whether to fold Godot buffers with |vim.treesitter.foldexpr()|. Off by
  -- default: it claims 'foldmethod' and 'foldexpr' in every window showing the
  -- buffer, needs a `folds.scm` query to do anything, and displaces the
  -- indent-based folding Neovim's bundled `gdscript` ftplugin already sets up.
  fold = false,
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Start treesitter in a Godot buffer
---
--- Called for every Godot buffer on |FileType|; useful directly only when
--- driving a buffer this module has not seen.
---
--- A buffer that already has a highlighter is left alone, whether this module
--- started it or something else did. Starting twice would register a second
--- highlighter against the same parser without tearing down the first.
---
---@param buf_id integer|nil Buffer handle, or 0 / `nil` for current buffer.
---
---@return string|nil Parser language that was started, or `nil` when the buffer
---   is not a Godot buffer or its parser is not installed.
GdevTreesitter.attach = function(buf_id)
  if H.is_disabled() then
    return nil
  end

  buf_id = H.validate_buf_id(buf_id)

  local lang = H.resolve_lang(vim.bo[buf_id].filetype)
  if lang == nil then
    return nil
  end

  local config = H.get_config(nil, buf_id)
  if config.highlight and not H.has_highlighter(buf_id) then
    pcall(vim.treesitter.start, buf_id, lang)
  end
  if config.fold then
    H.enable_folding(buf_id)
  end

  return lang
end

--- Report which Godot parsers are installed
---
--- Answers "why is this file not highlighted": a `false` here means no parser on
--- 'runtimepath', which no amount of configuration fixes. Note that a `true`
--- says nothing about queries — see the parser notes in |GdevTreesitter|.
---
---@return table Map of Godot filetype to `{ lang = string, available = boolean }`,
---   where `lang` is the parser in use or, when unavailable, the one to install.
GdevTreesitter.parser_status = function()
  local status = {}
  for filetype, candidates in pairs(H.lang_candidates) do
    local lang = H.resolve_lang(filetype)
    status[filetype] = { lang = lang or candidates[1], available = lang ~= nil }
  end
  return status
end

-- Helper data ================================================================
-- Module default config
H.default_config = vim.deepcopy(GdevTreesitter.config)

-- Godot files Neovim does not detect by itself. Deliberately short; see the
-- filetype notes in the module header for what is left out and why.
H.filetypes = {
  extension = { gdshaderinc = 'gdshader' },
  filename = { ['project.godot'] = 'gdresource' },
}

-- Parsers that can handle each Godot filetype, best first. `gdresource` has two
-- spellings in the wild: nvim-treesitter publishes the grammar as
-- `godot_resource`, while a parser built straight from the grammar repository is
-- usually named for the filetype.
H.lang_candidates = {
  gdscript = { 'gdscript' },
  gdshader = { 'gdshader' },
  gdresource = { 'gdresource', 'godot_resource' },
}

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('highlight', config.highlight, 'boolean')
  H.check_type('fold', config.fold, 'boolean')

  return config
end

H.apply_config = function(config)
  GdevTreesitter.config = config
end

H.register_filetypes = function()
  vim.filetype.add(vim.deepcopy(H.filetypes))
end

H.create_autocommands = function()
  local gr = vim.api.nvim_create_augroup('GdevTreesitter', {})

  vim.api.nvim_create_autocmd('FileType', {
    group = gr,
    pattern = vim.tbl_keys(H.lang_candidates),
    callback = function(args)
      GdevTreesitter.attach(args.buf)
    end,
    desc = 'Start treesitter in Godot buffers',
  })
end

H.attach_open_buffers = function()
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf_id) then
      GdevTreesitter.attach(buf_id)
    end
  end
end

-- Parsers --------------------------------------------------------------------
H.resolve_lang = function(filetype)
  local candidates = H.lang_candidates[filetype]
  if candidates == nil then
    return nil
  end

  -- An existing registration wins: someone pointing a Godot filetype at their
  -- own parser build should not be second-guessed. `get_lang()` echoes the
  -- filetype back when nothing is registered, which the candidates cover anyway.
  local order = {}
  local registered = vim.treesitter.language.get_lang(filetype)
  if registered ~= nil and registered ~= filetype then
    table.insert(order, registered)
  end
  vim.list_extend(order, candidates)

  for _, lang in ipairs(order) do
    if H.has_parser(lang) then
      -- Point the filetype at the parser that exists, so the rest of
      -- |vim.treesitter| resolves the same language without being told
      if registered ~= lang then
        vim.treesitter.language.register(lang, filetype)
      end
      return lang
    end
  end

  return nil
end

-- `language.add()` is documented as the way to check for a parser before
-- enabling treesitter features: it reports failure by returning `nil` instead of
-- raising, and caches what it loads, so calling it per buffer stays cheap.
H.has_parser = function(lang)
  local ok, added = pcall(vim.treesitter.language.add, lang)
  return ok and added ~= nil and added ~= false
end

H.has_highlighter = function(buf_id)
  -- No public predicate exists for this, and tracking it here would miss
  -- highlighting somebody else started, which is the case worth detecting
  local ok, active = pcall(function()
    return vim.treesitter.highlighter.active[buf_id]
  end)
  return ok and active ~= nil
end

H.enable_folding = function(buf_id)
  -- 'foldmethod' and 'foldexpr' are window options, so there is no buffer-scoped
  -- set: every window currently showing the buffer has to be told
  for _, win_id in ipairs(vim.fn.win_findbuf(buf_id)) do
    vim.api.nvim_set_option_value('foldmethod', 'expr', { win = win_id })
    vim.api.nvim_set_option_value('foldexpr', 'v:lua.vim.treesitter.foldexpr()', { win = win_id })
  end
end

return GdevTreesitter
