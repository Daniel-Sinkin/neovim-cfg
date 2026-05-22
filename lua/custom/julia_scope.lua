-- Scope highlighting + block text objects for Julia.
-- Mirrors the C/C++ enclosing-brace plugin: Julia has no `{ }` scopes, so the
-- "scope" is the keyword..end construct (function/if/struct/module/for/...).
--
-- Block matching is done by counting openers vs `end`, not by indentation:
-- a `module` body is conventionally unindented, so indentation cannot tell a
-- module's `end` apart from a nested function's `end`. Only first-token
-- keywords (and bare `do`) count, which keeps `a[end]` indexing harmless.
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

-- First-token keywords that open a block terminated by `end`. `mutable struct`
-- is handled separately (first token `mutable`, second token `struct`).
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

---Scan a line's code (comment stripped) tracking bracket depth and "..."
---strings. Returns whether a bare `end` word sits at depth 0, and the
---1-indexed byte position of a bare `do` word at depth 0 (or nil).
local function scan_code(line)
  local hash = line:find('#', 1, true)
  if hash then
    line = line:sub(1, hash - 1)
  end
  local depth = 0
  local in_str = false
  local i, n = 1, #line
  local bare_end = false
  local do_pos = nil
  while i <= n do
    local c = line:sub(i, i)
    if in_str then
      if c == '\\' then
        i = i + 1
      elseif c == '"' then
        in_str = false
      end
      i = i + 1
    elseif c == '"' then
      in_str = true
      i = i + 1
    elseif c == '(' or c == '[' or c == '{' then
      depth = depth + 1
      i = i + 1
    elseif c == ')' or c == ']' or c == '}' then
      depth = depth - 1
      i = i + 1
    elseif c:match '[%a_]' then
      local s = i
      while i <= n and line:sub(i, i):match '[%w_!]' do
        i = i + 1
      end
      if depth == 0 then
        local w = line:sub(s, i - 1)
        if w == 'end' then
          bare_end = true
        elseif w == 'do' and not do_pos then
          do_pos = s
        end
      end
    else
      i = i + 1
    end
  end
  return bare_end, do_pos
end

---Precompute per (1-indexed) line: indent, first/second token, whether the
---line starts inside a triple-quoted string, and its block role:
---  kind = 'open'   line opens a block (depth +1)
---         'close'  line is a bare `end` (depth -1)
---         'single' opens and closes on the same line (depth 0, ignored)
---         'plain'  no effect
---For 'open' lines, `okw`/`ocol` give the keyword to highlight and its column.
local function scan_lines(lines)
  local info = {}
  local in_tstring = false
  for idx, line in ipairs(lines) do
    if in_tstring then
      -- a line that starts inside a triple string is not code
      local quotes = select(2, line:gsub('"""', ''))
      if quotes % 2 == 1 then
        in_tstring = false
      end
      info[idx] = { str = true, kind = 'plain', indent = 0 }
    else
      local quotes = select(2, line:gsub('"""', ''))
      if quotes % 2 == 1 then
        in_tstring = true
      end

      local indent = #(line:match '^%s*' or '')
      local first = line:match '^%s*([%a_][%w_]*)'
      local second = first and line:match '^%s*[%a_][%w_]*%s+([%a_][%w_]*)' or nil
      local bare_end, do_pos = scan_code(line)

      local first_opener = first ~= nil
        and (OPENERS[first] or (first == 'mutable' and second == 'struct'))
      local opens = first_opener or (do_pos ~= nil)

      local kind, okw, ocol = 'plain', nil, nil
      if first == 'end' then
        kind = 'close'
      elseif opens and bare_end then
        kind = 'single'
      elseif opens then
        kind = 'open'
        if first_opener then
          okw, ocol = first, indent
        else
          okw, ocol = 'do', do_pos - 1
        end
      end

      info[idx] = {
        str = false,
        indent = indent,
        first = first,
        kind = kind,
        okw = okw,
        ocol = ocol,
      }
    end
  end
  return info
end

---Matching `end` of the opener at row `r`: count nested openers vs `end`.
local function match_end(info, r)
  local depth = 1
  local last = math.min(#info, r + MAX_SCAN)
  for k = r + 1, last do
    local li = info[k]
    if not li.str then
      if li.kind == 'open' then
        depth = depth + 1
      elseif li.kind == 'close' then
        depth = depth - 1
        if depth == 0 then
          return k
        end
      end
    end
  end
  return nil
end

---Innermost opener..end block containing the cursor (1-indexed rows).
---`module`/`baremodule` are still counted (so the `end` tally stays balanced)
---but never returned as a scope: highlighting a whole module is not useful.
local function find_enclosing(info, cur)
  local stop = math.max(1, cur - MAX_SCAN)
  for r = cur, stop, -1 do
    local li = info[r]
    if li and li.kind == 'open' then
      local e = match_end(info, r)
      if e and e >= cur and li.okw ~= 'module' and li.okw ~= 'baremodule' then
        return r, e, li
      end
    end
  end
  return nil
end

---For an `if` block, the branch keyword row whose section contains the cursor.
---`elseif`/`else` count only when they sit directly inside this `if`.
local function if_branch_row(info, r, e, cur)
  local row = r
  local depth = 1
  for k = r + 1, e - 1 do
    local li = info[k]
    if not li.str then
      if li.kind == 'open' then
        depth = depth + 1
      elseif li.kind == 'close' then
        depth = depth - 1
      elseif depth == 1 and (li.first == 'elseif' or li.first == 'else') then
        if k <= cur then
          row = k
        else
          break
        end
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
  if li.okw == 'if' then
    local brow = if_branch_row(info, r, e, cur)
    local bi = info[brow]
    hl_keyword(bufnr, brow, bi.indent, bi.indent + #bi.first)
  elseif li.okw == 'mutable' then
    local ss = lines[r]:find('struct', 1, true) or (li.ocol + 1)
    hl_keyword(bufnr, r, li.ocol, ss - 1 + 6)
  else
    hl_keyword(bufnr, r, li.ocol, li.ocol + #li.okw)
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
