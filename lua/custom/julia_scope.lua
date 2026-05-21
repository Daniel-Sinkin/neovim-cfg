-- Scope highlighting + block text objects for Julia.
-- Mirrors the C/C++ enclosing-brace plugin: Julia has no `{ }` scopes, so the
-- "scope" is the keyword..end construct (function/if/struct/for/...).
--
-- Highlights the enclosing opener keyword and its matching `end`, plus the
-- bracket delimiters within that scope. For `if`, only the keyword of the
-- branch the cursor sits in is highlighted (`if`/`elseif`/`else`) together
-- with `end`. Also provides `ib`/`ab` text objects so `yib`/`dib`/`vib`
-- copy/wipe a Julia scope the way they do in C/C++.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_julia_scope'

local function set_highlights()
  vim.api.nvim_set_hl(0, 'JuliaScopeKeyword', { link = 'MatchParen' })
  vim.api.nvim_set_hl(0, 'JuliaInnerDelimiter', { link = 'DiagnosticInfo' })
end

-- Captures that mark regions for spell/conceal rather than coloring.
local SKIP_CAPTURE = { spell = true, nospell = true, conceal = true, none = true }

-- Flatten Julia treesitter highlighting to monochrome, keeping only comments
-- colored (mirrors the aggressive C/C++ monochrome treatment). Scope and
-- bracket coloring come from extmarks, which draw on top and are unaffected.
local function set_mono()
  local ok, q = pcall(vim.treesitter.query.get, 'julia', 'highlights')
  if not ok or not q or not q.captures then
    return
  end
  for _, name in ipairs(q.captures) do
    if not SKIP_CAPTURE[name] and name:sub(1, 1) ~= '_' then
      local hl = '@' .. name .. '.julia'
      if name == 'comment' or name:match '^comment%.' then
        vim.api.nvim_set_hl(0, hl, { link = 'Comment' })
      else
        vim.api.nvim_set_hl(0, hl, { link = 'Normal' })
      end
    end
  end
end

-- Keywords that open a block terminated by `end`. `mutable struct` is handled
-- separately (first token `mutable`, second token `struct`).
local OPENERS = {
  ['function'] = true,
  ['macro'] = true,
  ['if'] = true,
  ['for'] = true,
  ['while'] = true,
  ['let'] = true,
  ['begin'] = true,
  ['quote'] = true,
  ['struct'] = true,
  ['module'] = true,
  ['baremodule'] = true,
  ['try'] = true,
}

local MAX_SCAN = 5000
local MAX_FILE = 20000

---Precompute per (1-indexed) line: indent width, first/second token, and
---whether the line starts inside a triple-quoted string (docstring).
local function scan_lines(lines)
  local info = {}
  local in_tstring = false
  for idx, line in ipairs(lines) do
    local started_in_string = in_tstring
    local count = 0
    for _ in line:gmatch '"""' do
      count = count + 1
    end
    if count % 2 == 1 then
      in_tstring = not in_tstring
    end
    local indent = #(line:match '^%s*' or '')
    local first = line:match '^%s*([%a_][%w_]*)'
    local second
    if first then
      second = line:match '^%s*[%a_][%w_]*%s+([%a_][%w_]*)'
    end
    info[idx] = { indent = indent, first = first, second = second, str = started_in_string }
  end
  return info
end

local function is_opener(li)
  if li.str or not li.first then
    return false
  end
  if OPENERS[li.first] then
    return true
  end
  return li.first == 'mutable' and li.second == 'struct'
end

local function is_end(li)
  return li.first == 'end' and not li.str
end

---Matching `end` of the opener at row `r` (indent `indent`): the first line
---below at the same indent whose first token is `end`. Relies on conventional
---Julia indentation, which sidesteps the `a[end]` indexing pitfall entirely.
local function match_end(info, r, indent)
  local last = math.min(#info, r + MAX_SCAN)
  for k = r + 1, last do
    local li = info[k]
    if is_end(li) then
      if li.indent == indent then
        return k
      end
      if li.indent < indent then
        return nil
      end
    end
  end
  return nil
end

---Innermost opener..end block containing the cursor (1-indexed rows).
local function find_enclosing(info, cur)
  local stop = math.max(1, cur - MAX_SCAN)
  for r = cur, stop, -1 do
    local li = info[r]
    if li and is_opener(li) then
      local e = match_end(info, r, li.indent)
      if e and e >= cur then
        return r, e, li
      end
    end
  end
  return nil
end

---For an `if` block, the branch keyword row whose section contains the cursor.
local function if_branch_row(info, r, e, indent, cur)
  local row = r
  for k = r + 1, e - 1 do
    local li = info[k]
    if li and not li.str and li.indent == indent and (li.first == 'elseif' or li.first == 'else') then
      if k <= cur then
        row = k
      else
        break
      end
    end
  end
  return row
end

local function hl_keyword(bufnr, row, col, end_col)
  vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, col, {
    end_col = end_col,
    hl_group = 'JuliaScopeKeyword',
    priority = 200,
  })
end

local function update(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= 'julia' then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines > MAX_FILE then
    return
  end
  local info = scan_lines(lines)
  local cur = vim.api.nvim_win_get_cursor(0)[1]

  local r, e, li = find_enclosing(info, cur)
  if not r then
    return
  end

  -- Opener keyword.
  if li.first == 'if' then
    local brow = if_branch_row(info, r, e, li.indent, cur)
    local bi = info[brow]
    hl_keyword(bufnr, brow, bi.indent, bi.indent + #bi.first)
  elseif li.first == 'mutable' then
    local ss = lines[r]:find('struct', 1, true)
    hl_keyword(bufnr, r, li.indent, (ss or li.indent + 1) - 1 + 6)
  else
    hl_keyword(bufnr, r, li.indent, li.indent + #li.first)
  end

  -- Matching `end`.
  hl_keyword(bufnr, e, info[e].indent, info[e].indent + 3)

  -- Bracket delimiters within the scope.
  if (e - r) <= 3000 then
    for k = r, e do
      if not info[k].str then
        local line = lines[k]
        for col = 1, #line do
          local ch = line:sub(col, col)
          if ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}' then
            vim.api.nvim_buf_set_extmark(bufnr, ns, k - 1, col - 1, {
              end_col = col,
              hl_group = 'JuliaInnerDelimiter',
              priority = 150,
            })
          end
        end
      end
    end
  end
end

local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

---`ib`/`ab` text object: select the enclosing Julia scope linewise.
function M.select_block(around)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines > MAX_FILE then
    return
  end
  local info = scan_lines(lines)
  local cur = vim.api.nvim_win_get_cursor(0)[1]

  local r, e = find_enclosing(info, cur)
  if not r then
    return
  end

  local sline, eline
  if around then
    sline, eline = r, e
  else
    sline, eline = r + 1, e - 1
    if sline > eline then
      sline, eline = r, e
    end
  end

  if vim.fn.mode():match '[vV\22]' then
    vim.api.nvim_feedkeys(esc, 'nx', false)
  end
  vim.cmd(('normal! %dGV%dG'):format(sline, eline))
end

function M.setup()
  set_highlights()
  set_mono()

  local group = vim.api.nvim_create_augroup('ds-julia-scope', { clear = true })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      update(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      set_highlights()
      set_mono()
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'julia',
    callback = function(ev)
      set_mono()
      vim.keymap.set({ 'x', 'o' }, 'ib', function()
        M.select_block(false)
      end, { buffer = ev.buf, desc = 'inner Julia scope' })
      vim.keymap.set({ 'x', 'o' }, 'ab', function()
        M.select_block(true)
      end, { buffer = ev.buf, desc = 'around Julia scope' })
    end,
  })
end

return M
