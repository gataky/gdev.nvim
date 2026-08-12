local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
local load_module = function(config)
  child.gdev_load('treesitter', config)
end
local unload_module = function()
  child.gdev_unload('treesitter')
end

-- Stubs installed in the child.
--
-- No Godot parser is installed in the test runtime and one cannot be faked: the
-- loader looks for a `tree_sitter_<lang>` symbol, so a bundled parser renamed to
-- `gdshader.so` fails to load. Positive paths therefore stub `vim.treesitter`
-- itself, the same way the LSP suite stubs `vim.lsp`. The negative paths below
-- run unstubbed, which is what keeps the stubs honest.
local install_stubs = function()
  child.lua([[
    _G.started, _G.registered = {}, {}

    -- Report the given parsers as installed, nothing else
    _G.stub_parsers = function(langs)
      local installed = {}
      for _, lang in ipairs(langs) do installed[lang] = true end
      vim.treesitter.language.add = function(lang) return installed[lang] and true or nil end
    end

    _G.stub_start = function()
      vim.treesitter.start = function(buf_id, lang) table.insert(_G.started, { buf = buf_id, lang = lang }) end
    end

    -- Neovim's own ftplugins call `vim.treesitter.start()` with no arguments
    -- (help, lua, markdown and query do), so assertions filter down to the calls
    -- this module makes, which always name both the buffer and the language.
    _G.starts = function()
      return vim.tbl_filter(function(call) return call.lang ~= nil end, _G.started)
    end

    -- Records registrations and keeps the real effect, so `get_lang()` reflects
    -- them the way it would in a real session
    _G.stub_register = function()
      local real_register = vim.treesitter.language.register
      vim.treesitter.language.register = function(lang, filetype)
        table.insert(_G.registered, { lang = lang, filetype = filetype })
        real_register(lang, filetype)
      end
    end

    _G.stub_all = function(langs)
      _G.stub_parsers(langs or { 'gdscript', 'gdshader' })
      _G.stub_start()
      _G.stub_register()
    end

    _G.fake_highlighter = function(buf_id) vim.treesitter.highlighter.active[buf_id] = {} end

    -- Assigning 'filetype' fires `FileType`, which the module hooks, so the
    -- recorders are cleared to leave a clean slate for the call under test
    _G.new_buf = function(filetype)
      local buf_id = vim.api.nvim_create_buf(true, false)
      vim.bo[buf_id].filetype = filetype
      _G.started, _G.registered = {}, {}
      return buf_id
    end
  ]])
end

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
      install_stubs()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(1),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.GdevTreesitter)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#GdevTreesitter'), 1)
end

T['setup()']['teaches Neovim the Godot files it misses'] = new_set({
  parametrize = {
    { 'helpers.gdshaderinc', 'gdshader' },
    { 'project.godot', 'gdresource' },
  },
}, {
  test = function(filename, expected)
    eq(child.lua_get('vim.filetype.match({ filename = ... })', { filename }), expected)
  end,
})

T['setup()']['leaves the filetypes Neovim already knows'] = new_set({
  parametrize = {
    { 'script.gd', 'gdscript' },
    { 'shader.gdshader', 'gdshader' },
    { 'scene.tscn', 'gdresource' },
  },
}, {
  test = function(filename, expected)
    eq(child.lua_get('vim.filetype.match({ filename = ... })', { filename }), expected)
  end,
})

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.GdevTreesitter.config)'), 'table')

  -- Check default values
  eq(child.lua_get('GdevTreesitter.config.highlight'), true)
  eq(child.lua_get('GdevTreesitter.config.fold'), false)
end

T['setup()']['respects `config` argument'] = function()
  unload_module()
  load_module({ highlight = false, fold = true })

  eq(child.lua_get('GdevTreesitter.config.highlight'), false)
  eq(child.lua_get('GdevTreesitter.config.fold'), true)
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(function()
      load_module(config)
    end, vim.pesc(name) .. '.*' .. vim.pesc(target_type))
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ highlight = 'a' }, 'highlight', 'boolean')
  expect_config_error({ fold = 'a' }, 'fold', 'boolean')
end

T['setup()']['attaches buffers that are already open'] = function()
  -- Lazy-loaded setups run after the first Godot file is open, so those buffers
  -- never see the `FileType` event
  unload_module()
  child.cmd('edit tests/dir-treesitter/script.gd')
  eq(child.bo.filetype, 'gdscript')

  child.lua('_G.stub_all()')
  load_module()

  eq(child.lua_get('#_G.starts()'), 1)
  eq(child.lua_get('_G.starts()[1].lang'), 'gdscript')
end

T['attach()'] = new_set()

T['attach()']['works'] = function()
  child.lua([[
    _G.stub_all()
    _G.buf = _G.new_buf('gdscript')
  ]])

  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), 'gdscript')
  eq(child.lua_get('_G.starts()'), { { buf = child.lua_get('_G.buf'), lang = 'gdscript' } })
end

T['attach()']['ignores buffers that are not Godot buffers'] = function()
  child.lua([[
    _G.stub_all({ 'gdscript', 'lua' })
    _G.buf = _G.new_buf('lua')
  ]])

  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), vim.NIL)
  eq(child.lua_get('_G.starts()'), {})
end

T['attach()']['returns `nil` when the parser is missing'] = function()
  -- Unstubbed: the test runtime genuinely has no Godot parser
  child.lua('_G.buf = _G.new_buf("gdscript")')

  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), vim.NIL)
end

T['attach()']['resolves the parser a filetype ships under'] = function()
  -- The `gdresource` grammar is published as `godot_resource` by nvim-treesitter.
  -- The buffer is made before any parser exists, so the `FileType` attach finds
  -- nothing and the registration below belongs to the call under test.
  child.lua([[
    _G.buf = _G.new_buf('gdresource')
    _G.stub_all({ 'godot_resource' })
  ]])

  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), 'godot_resource')

  -- Registered, so the rest of `vim.treesitter` resolves it without being told
  eq(child.lua_get('_G.registered'), { { lang = 'godot_resource', filetype = 'gdresource' } })
  eq(child.lua_get('vim.treesitter.language.get_lang("gdresource")'), 'godot_resource')
end

T['attach()']['prefers a parser someone else registered'] = function()
  child.lua([[
    _G.stub_all({ 'gdscript', 'my_gdscript' })
    vim.treesitter.language.register('my_gdscript', 'gdscript')
    _G.registered = {}
    _G.buf = _G.new_buf('gdscript')
  ]])

  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), 'my_gdscript')

  -- Already pointing at that parser, so nothing needed re-registering
  eq(child.lua_get('_G.registered'), {})
end

T['attach()']['leaves an existing highlighter alone'] = function()
  child.lua([[
    _G.stub_all()
    _G.buf = _G.new_buf('gdscript')
    _G.fake_highlighter(_G.buf)
  ]])

  -- Still reports the language, but starting again would attach a second
  -- highlighter to the same parser without tearing down the first
  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), 'gdscript')
  eq(child.lua_get('_G.starts()'), {})
end

T['attach()']['respects `config.highlight`'] = function()
  unload_module()
  load_module({ highlight = false })
  install_stubs()

  child.lua([[
    _G.stub_all()
    _G.buf = _G.new_buf('gdscript')
  ]])

  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), 'gdscript')
  eq(child.lua_get('_G.starts()'), {})
end

T['attach()']['respects `config.fold`'] = function()
  unload_module()
  load_module({ fold = true })
  install_stubs()

  child.lua('_G.stub_all()')
  child.cmd('edit tests/dir-treesitter/script.gd')

  eq(child.wo.foldmethod, 'expr')
  eq(child.wo.foldexpr, 'v:lua.vim.treesitter.foldexpr()')
end

T['attach()']['leaves folding alone by default'] = function()
  child.lua('_G.stub_all()')
  child.cmd('edit tests/dir-treesitter/script.gd')

  expect.no_equality(child.wo.foldexpr, 'v:lua.vim.treesitter.foldexpr()')
end

T['attach()']['respects `vim.b.gdevtreesitter_config`'] = function()
  child.lua([[
    _G.stub_all()
    _G.buf = _G.new_buf('gdscript')
    vim.b[_G.buf].gdevtreesitter_config = { highlight = false }
  ]])

  -- Read off the attached buffer, which is not the current one here
  eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), 'gdscript')
  eq(child.lua_get('_G.starts()'), {})
end

T['attach()']['validates arguments'] = function()
  expect.error(function()
    child.lua('GdevTreesitter.attach("a")')
  end, '`buf_id`.*valid buffer id')
end

T['attach()']['respects `vim.{g,b}.gdevtreesitter_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child.lua([[
      _G.stub_all()
      _G.buf = _G.new_buf('gdscript')
    ]])
    child[var_type].gdevtreesitter_disable = true

    eq(child.lua_get('GdevTreesitter.attach(_G.buf)'), vim.NIL)
    eq(child.lua_get('_G.starts()'), {})
  end,
})

T['parser_status()'] = new_set()

T['parser_status()']['names the parser to install when it is missing'] = function()
  -- Unstubbed: nothing Godot is installed in the test runtime
  local status = child.lua_get('GdevTreesitter.parser_status()')

  eq(status.gdscript, { lang = 'gdscript', available = false })
  eq(status.gdshader, { lang = 'gdshader', available = false })
  eq(status.gdresource, { lang = 'gdresource', available = false })
end

T['parser_status()']['reports the parser in use'] = function()
  child.lua('_G.stub_all({ "gdscript", "godot_resource" })')

  local status = child.lua_get('GdevTreesitter.parser_status()')
  eq(status.gdscript, { lang = 'gdscript', available = true })
  eq(status.gdresource, { lang = 'godot_resource', available = true })
  eq(status.gdshader, { lang = 'gdshader', available = false })
end

T['parser_status()']['still answers while disabled'] = function()
  -- Diagnostics have to keep working when the module is switched off, since
  -- that is when they get asked. `:checkhealth gdev` relies on this.
  child.lua('_G.stub_all({ "gdscript" })')
  child.g.gdevtreesitter_disable = true

  eq(child.lua_get('GdevTreesitter.parser_status().gdscript.available'), true)
end

-- Integration tests ==========================================================
T['FileType'] = new_set()

T['FileType']['starts treesitter in Godot buffers'] = new_set({
  parametrize = {
    { 'tests/dir-treesitter/script.gd', 'gdscript' },
    { 'tests/dir-treesitter/shader.gdshader', 'gdshader' },
    { 'tests/dir-treesitter/helpers.gdshaderinc', 'gdshader' },
    { 'tests/dir-treesitter/scene.tscn', 'gdresource' },
  },
}, {
  test = function(path, lang)
    child.lua('_G.stub_all({ "gdscript", "gdshader", "gdresource" })')
    child.cmd('edit ' .. path)

    eq(child.lua_get('#_G.starts()'), 1)
    eq(child.lua_get('_G.starts()[1].lang'), lang)
  end,
})

T['FileType']['stays quiet for other filetypes'] = function()
  child.lua('_G.stub_all({ "gdscript", "lua" })')
  child.cmd('edit tests/dir-treesitter/../helpers.lua')

  eq(child.lua_get('_G.starts()'), {})
end

return T
