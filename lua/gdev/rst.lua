-- reStructuredText to Markdown, for the class reference Godot publishes as
-- Sphinx sources. Consumed by 'gdev.docs', which fetches the `.rst` and shows
-- what comes back in a Neovim buffer.
--
-- Not a feature module: no `setup()`, no global table, no vimdoc, no config.
-- It is separate from 'gdev.docs' because it is the one wholly pure part of
-- that pipeline, and 'tests/test_rst.lua' can then work through the conversion
-- case by case instead of through a window. Keeping it out of `GdevDocs` is
-- deliberate too: the output is a reading aid whose exact shape will keep
-- changing, which is not something a documented public API should promise.
--
-- The dialect handled is Godot's, not all of reStructuredText: headings, grid
-- tables, code blocks, admonitions, and the roles and substitutions the class
-- reference generator emits. Anything else degrades to its own text rather
-- than to an error -- a page that renders imperfectly beats one that does not
-- render at all.
--
-- Plain comments on purpose: `---` would put this internal module into the
-- generated vimdoc alongside the user-facing ones.
local Rst = {}
local H = {}

-- Convert a whole document. Returns `''` for anything that is not a string, so
-- a failed fetch needs no special case at the call site.
Rst.to_markdown = function(text)
  if type(text) ~= 'string' then
    return ''
  end

  local lines = vim.split((text:gsub('\r\n', '\n')), '\n', { plain = true })
  return table.concat(H.tidy(H.convert(lines)), '\n')
end

-- Inline markup of a single line: substitutions, escapes, roles and literals.
-- Separate from the block conversion because headings, paragraphs, list items
-- and table cells all need exactly this, and most of the interesting cases are
-- here rather than in the block structure.
Rst.inline = function(text)
  if type(text) ~= 'string' or text == '' then
    return ''
  end

  text = Rst.substitute(text)

  -- An escaped space joins markup to what follows it and is not a character:
  -- `**add_child**\ (\ node\: ...` is one call signature, not three words
  text = text:gsub('\\ ', '')
  text = text:gsub('\\(%p)', '%1')

  -- The self-link every generated definition ends with points at the anchor we
  -- just dropped, so it says nothing here
  text = text:gsub('%s*:ref:`\240\159\148\151%s*<[^`>]*>`', '')

  text = text:gsub('``([^`]+)``', '`%1`')

  -- Cross references keep their label and lose their target: the target is a
  -- Sphinx anchor, not a URL, so there is nothing to link to from here
  text = text:gsub(':ref:`([^`<]-)%s*<[^`>]*>`', '`%1`')
  text = text:gsub(':ref:`([^`]+)`', '`%1`')
  text = text:gsub(':doc:`([^`<]-)%s*<[^`>]*>`', '%1')
  text = text:gsub(':doc:`([^`]+)`', '%1')
  text = text:gsub(':abbr:`([^`]-)%s*%(([^`]-)%)`', '%1 (%2)')
  for _, role in ipairs(H.literal_roles) do
    text = text:gsub(':' .. role .. ':`([^`]+)`', '`%1`')
  end

  -- External links do have a URL, and Markdown can carry it
  text = text:gsub('`([^`<]-)%s*<([^`>]+)>`__?', '[%1](%2)')
  text = text:gsub('`([^`]+)`__?', '%1')

  return vim.trim(text)
end

-- Replace the substitutions the class reference defines in every file's
-- preamble. Applied before a table row is split, because `|const|` otherwise
-- takes the cell delimiter with it.
Rst.substitute = function(text)
  return (text:gsub('|([%a_]+)|', function(name)
    return H.substitutions[name]
  end))
end

-- Helper data ================================================================
-- Underline character to heading level, in the order Sphinx conventionally
-- nests them and the class reference actually uses them
H.headings = { ['='] = '#', ['-'] = '##', ['~'] = '###', ['^'] = '####', ['"'] = '#####' }

H.substitutions = {
  bitfield = 'BitField',
  const = 'const',
  constructor = 'constructor',
  operator = 'operator',
  static = 'static',
  vararg = 'vararg',
  virtual = 'virtual',
  void = 'void',
}

-- Roles whose content is code-like and reads best as a Markdown code span
H.literal_roles =
  { 'code', 'command', 'file', 'guilabel', 'kbd', 'literal', 'math', 'menuselection' }

-- Directives holding source code, mapped to nothing more than a fence
H.code_directives = { code = true, ['code-block'] = true, ['code-tab'] = true, codeblock = true }

-- Directives that become a Markdown alert
H.admonitions = {
  attention = true,
  caution = true,
  danger = true,
  deprecated = true,
  error = true,
  hint = true,
  important = true,
  note = true,
  seealso = true,
  tip = true,
  warning = true,
}

-- Directives whose body is navigation or presentation rather than prose. Every
-- other unknown directive keeps its body: dropping `.. container::` would lose
-- real text, while keeping a `.. toctree::` would gain a list of file names.
H.dropped_directives = { figure = true, image = true, index = true, raw = true, toctree = true }

-- Helper functionality =======================================================
-- Blocks ---------------------------------------------------------------------
H.convert = function(lines)
  local out, i = {}, 1
  while i <= #lines do
    i = H.block(out, lines, i)
  end
  return out
end

-- Convert the block starting at `i` and return the index after it. Every branch
-- advances, so the caller cannot loop.
H.block = function(out, lines, i)
  local line = lines[i]

  if H.is_blank(line) then
    out[#out + 1] = ''
    return i + 1
  end

  if H.is_underline(lines[i + 1], line) then
    local marker = lines[i + 1]:sub(1, 1)
    out[#out + 1] = ('%s %s'):format(H.headings[marker], Rst.inline(line))
    out[#out + 1] = ''
    return i + 2
  end

  if H.is_transition(line) then
    out[#out + 1] = '---'
    out[#out + 1] = ''
    return i + 1
  end

  if H.directive_name(line) ~= nil then
    return H.directive(out, lines, i)
  end

  -- Comments, anchors and substitution definitions: everything else spelled
  -- `.. `, together with whatever is indented under it
  if line:match('^%s*%.%.%s') ~= nil or vim.trim(line) == '..' then
    local _, next_i = H.indented_block(lines, i + 1, H.indent_of(line))
    return next_i
  end

  if H.is_field(line) then
    return i + 1
  end

  -- A table starts at a rule, never at a row: a lone `|...|` line is far more
  -- likely to be a signature carrying substitutions than a malformed table
  if H.is_table_rule(line) then
    return H.grid_table(out, lines, i)
  end

  if H.list_item(line) ~= nil then
    return H.list(out, lines, i)
  end

  return H.paragraph(out, lines, i)
end

H.directive = function(out, lines, i)
  local name, argument = H.directive_name(lines[i])
  local body, next_i = H.indented_block(lines, i + 1, H.indent_of(lines[i]))
  body = H.strip_options(body)

  if H.code_directives[name] then
    out[#out + 1] = '```' .. argument:match('^%S*')
    vim.list_extend(out, body)
    out[#out + 1] = '```'
    out[#out + 1] = ''
  elseif H.admonitions[name] then
    H.admonition(out, name, argument, body)
  elseif not H.dropped_directives[name] then
    -- `.. table::` and `.. tabs::` hold the content underneath them, and an
    -- unknown directive is likelier to be one of those than to be noise
    vim.list_extend(out, H.convert(body))
  end

  return next_i
end

H.admonition = function(out, name, argument, body)
  -- `.. deprecated:: 4.2` carries its version on the directive line, and it is
  -- a statement of its own rather than the first words of the body
  if argument ~= '' then
    table.insert(body, 1, '')
    table.insert(body, 1, argument)
  end

  local content = H.tidy(H.convert(body))
  out[#out + 1] = ('> [!%s]'):format(name:upper())
  for _, line in ipairs(content) do
    out[#out + 1] = line == '' and '>' or ('> ' .. line)
  end
  out[#out + 1] = ''
end

-- Grid tables become Markdown tables, including the ones the class reference
-- writes indented inside a `.. table::`. Cells wrapped over several source
-- rows are joined, so a row is whatever sits between two `+---+` rules.
H.grid_table = function(out, lines, i)
  local rows, pending = {}, nil
  local flush = function()
    if pending ~= nil then
      rows[#rows + 1] = pending
    end
    pending = nil
  end

  while i <= #lines do
    local line = lines[i]
    if H.is_table_rule(line) then
      flush()
    elseif H.is_table_row(line) then
      local cells = H.split_row(line)
      if pending == nil then
        pending = cells
      else
        for column, cell in ipairs(cells) do
          pending[column] = vim.trim((pending[column] or '') .. ' ' .. cell)
        end
      end
    else
      break
    end
    i = i + 1
  end
  flush()

  vim.list_extend(out, H.format_table(rows))
  return i
end

H.split_row = function(line)
  -- Substitutions first: `|const|` marks half the methods in the reference and
  -- carries the very character the row is split on
  local inner = Rst.substitute(vim.trim(line)):gsub('^|', ''):gsub('|$', '')

  local cells = {}
  for cell in (inner .. '|'):gmatch('(.-)|') do
    cells[#cells + 1] = Rst.inline(vim.trim(cell))
  end
  return cells
end

-- The class reference's tables have no header row -- they are lists of
-- properties, methods or constants. Markdown has no way to say that, so the
-- first row is promoted: it still reads as data, which is the best of the
-- available lies.
H.format_table = function(rows)
  if #rows == 0 then
    return {}
  end

  local columns = 0
  for _, row in ipairs(rows) do
    columns = math.max(columns, #row)
  end

  local separator = {}
  for column = 1, columns do
    separator[column] = '---'
  end

  local render = function(row)
    local cells = {}
    for column = 1, columns do
      cells[column] = row[column] or ''
    end
    return '| ' .. table.concat(cells, ' | ') .. ' |'
  end

  local out = { render(rows[1]), render(separator) }
  for index = 2, #rows do
    out[#out + 1] = render(rows[index])
  end
  out[#out + 1] = ''
  return out
end

H.list = function(out, lines, i)
  while i <= #lines do
    local marker, rest = H.list_item(lines[i])
    if marker == nil then
      break
    end

    local text, next_i = H.continuation(lines, i + 1, rest)
    out[#out + 1] = ('%s %s'):format(marker, Rst.inline(text))
    i = next_i
  end

  out[#out + 1] = ''
  return i
end

H.paragraph = function(out, lines, i)
  local parts, start = {}, i

  while i <= #lines do
    if i > start and H.starts_block(lines, i) then
      break
    end
    parts[#parts + 1] = vim.trim(lines[i])
    i = i + 1
  end

  local text = Rst.inline(table.concat(parts, ' '))
  if text ~= '' then
    out[#out + 1] = text
    out[#out + 1] = ''
  end
  return i
end

-- Lines belonging to whatever sits at indent `base`: everything indented
-- deeper, dedented by the first body line's own indent so code keeps its
-- shape. Blank lines inside are kept, the ones around it are not.
H.indented_block = function(lines, from, base)
  local i = from
  while lines[i] ~= nil and H.is_blank(lines[i]) do
    i = i + 1
  end

  if lines[i] == nil then
    return {}, from
  end
  local indent = H.indent_of(lines[i])
  if indent <= base then
    return {}, from
  end

  local body, last = {}, 0
  while i <= #lines do
    local line = lines[i]
    if H.is_blank(line) then
      body[#body + 1] = ''
    elseif H.indent_of(line) >= indent then
      body[#body + 1] = line:sub(indent + 1)
      last = #body
    else
      break
    end
    i = i + 1
  end

  for index = #body, last + 1, -1 do
    body[index] = nil
  end
  return body, i
end

-- A directive's options (`:widths: auto`) sit between it and its body
H.strip_options = function(body)
  local first = 1
  while body[first] ~= nil and H.is_field(body[first]) do
    first = first + 1
  end
  while body[first] ~= nil and H.is_blank(body[first]) do
    first = first + 1
  end

  return vim.list_slice(body, first)
end

-- Text of a list item continued on the following indented lines
H.continuation = function(lines, from, text)
  local i = from
  while i <= #lines do
    local line = lines[i]
    if H.is_blank(line) or H.indent_of(line) == 0 or H.starts_block(lines, i) then
      break
    end
    text = text .. ' ' .. vim.trim(line)
    i = i + 1
  end
  return text, i
end

-- Collapse the runs of blank lines the block conversion leaves behind, and
-- trim trailing whitespace -- but not inside a fence, where both are content.
H.tidy = function(lines)
  local out, fenced = {}, false

  for _, line in ipairs(lines) do
    if not fenced then
      line = (line:gsub('%s+$', ''))
    end
    if line:match('^```') ~= nil then
      fenced = not fenced
    end
    if fenced or line ~= '' or (#out > 0 and out[#out] ~= '') then
      out[#out + 1] = line
    end
  end

  return H.trim_blanks(out)
end

H.trim_blanks = function(lines)
  while #lines > 0 and lines[1] == '' do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == '' do
    lines[#lines] = nil
  end
  return lines
end

-- Predicates -----------------------------------------------------------------
H.is_blank = function(line)
  return line == nil or line:match('^%s*$') ~= nil
end

H.indent_of = function(line)
  return #(line:match('^%s*'))
end

-- A title is underlined by a run of one punctuation character at least as long
-- as the title itself; anything shorter is Sphinx's own error case.
--
-- Spelled without a back-reference on purpose. `'^([=~^"-])%1+$'` is the
-- obvious pattern and matches nothing at all: Lua back-references cannot carry
-- a quantifier, so the `+` there is a literal plus sign.
H.is_underline = function(under, title)
  if under == nil or title == nil or vim.trim(title) == '' then
    return false
  end

  local marker = under:sub(1, 1)
  if H.headings[marker] == nil then
    return false
  end

  local run = vim.trim(under)
  if #run < 2 or run:match('^' .. vim.pesc(marker) .. '+$') == nil then
    return false
  end

  return #run >= #vim.trim(title)
end

-- A rule on its own is a section separator, not an underline: the class
-- reference puts one between the summary tables and the descriptions.
H.is_transition = function(line)
  return line:match('^%-%-%-+%s*$') ~= nil
end

H.directive_name = function(line)
  local name, argument = line:match('^%s*%.%.%s+([%w_%+%-]+)::%s*(.*)$')
  if name == nil then
    return nil
  end
  return name:lower(), vim.trim(argument)
end

-- `:github_url: hide` is a field, `:ref:`Node<class_Node>`` is a role: the
-- backtick is what tells them apart.
H.is_field = function(line)
  if line == nil then
    return false
  end
  return line:match('^%s*:[%w_%+%-%.]+:%s*$') ~= nil
    or line:match('^%s*:[%w_%+%-%.]+:%s+[^`]') ~= nil
end

H.is_table_rule = function(line)
  return line ~= nil and line:match('^%s*%+[%-=+]+%+%s*$') ~= nil
end

-- Both ends, not just the leading bar: half the method signatures in the class
-- reference start with a `|void|` or `|const|` substitution.
H.is_table_row = function(line)
  return line ~= nil and line:match('^%s*|.*|%s*$') ~= nil
end

H.list_item = function(line)
  local bullet, rest = line:match('^%s*([%-%*%+])%s+(.*)$')
  if bullet ~= nil then
    return '-', rest
  end

  local number, numbered = line:match('^%s*(%d+[%.%)])%s+(.*)$')
  if number ~= nil then
    return number, numbered
  end
end

H.starts_block = function(lines, i)
  local line = lines[i]
  return H.is_blank(line)
    or H.is_underline(lines[i + 1], line)
    or H.is_transition(line)
    or line:match('^%s*%.%.%s') ~= nil
    or vim.trim(line) == '..'
    or H.is_field(line)
    or H.is_table_rule(line)
    or H.is_table_row(line)
    or H.list_item(line) ~= nil
end

return Rst
