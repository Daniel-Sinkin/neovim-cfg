-- Scope highlighting + block text objects for Julia.
-- Mirrors the C/C++ enclosing-brace plugin: Julia has no `{ }` scopes, so the
-- "scope" is the keyword..end construct (function/if/struct/module/let/...).
--
-- Block matching counts openers vs `end`, not indentation: a `module` body is
-- conventionally unindented, so indentation cannot tell a module's `end` apart
-- from a nested function's `end`. Opener keywords are detected at bracket
-- depth 0 anywhere on a statement line (not just the first token), so a block
-- keyword used as an expression - `x = let ... end` - still counts; `a[end]`
-- indexing and `[expr for x in ...]` comprehensions sit at depth > 0 and stay
-- harmless.
--
-- Highlights the enclosing opener keyword and its matching `end`, plus the
-- bracket delimiters within that scope. For `if`, only the keyword of the
-- branch the cursor sits in is highlighted (`if`/`elseif`/`else`) with `end`.
-- `ib`/`ab` text objects select that scope - except when the cursor is inside
-- `(...)`, where they select the paren contents instead (like `ib` in C/C++).

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_julia_scope'

local function set_highlights()
  -- current scope keyword..end
  vim.api.nvim_set_hl(0, 'JuliaScopeKeyword', { link = 'MatchParen' })
  -- parent scope keyword..end - the cyan also used for inner delimiters, so a
  -- nested current/parent pair reads apart
  vim.api.nvim_set_hl(0, 'JuliaParentScope', { link = 'DiagnosticInfo' })
  vim.api.nvim_set_hl(0, 'JuliaInnerDelimiter', { link = 'DiagnosticInfo' })
end

-- Captures that mark regions for spell/conceal rather than coloring.
local SKIP_CAPTURE = { spell = true, nospell = true, conceal = true, none = true }

-- Flatten Julia treesitter highlighting to monochrome, keeping comments and
-- docstrings (`"""..."""`) gray (mirrors the aggressive C/C++ monochrome
-- treatment). Scope and bracket coloring come from extmarks, which draw on
-- top and are unaffected.
local function set_mono()
  local ok, q = pcall(vim.treesitter.query.get, 'julia', 'highlights')
  if not ok or not q or not q.captures then
    return
  end
  for _, name in ipairs(q.captures) do
    if not SKIP_CAPTURE[name] and name:sub(1, 1) ~= '_' then
      local hl = '@' .. name .. '.julia'
      if name == 'comment' or name:match '^comment%.' or name == 'string.documentation' then
        vim.api.nvim_set_hl(0, hl, { link = 'Comment' })
      else
        vim.api.nvim_set_hl(0, hl, { link = 'Normal' })
      end
    end
  end
end

-- Reserved keywords that open a block terminated by `end`. All are reserved
-- words (never identifiers), so detecting them anywhere at bracket depth 0 is
-- safe. `mutable struct` is handled separately (`mutable` is NOT reserved, so
-- it must not be scanned for - only matched as the first token before
-- `struct`).
local OPENER_WORDS = {
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
  ['do'] = true,
}

local MAX_SCAN = 5000
local MAX_FILE = 20000

---Scan a line's code (comment stripped) starting at bracket depth
---`start_depth`, tracking brackets and "..." strings. Returns: whether a bare
---`end` word sits at statement level (depth 0); the first opener keyword found
---at depth 0 and its 1-indexed byte position (or nil); the bracket depth at
---line end.
local function scan_code(line, start_depth)
  local hash = line:find('#', 1, true)
  if hash then
    line = line:sub(1, hash - 1)
  end
  local depth = start_depth
  local in_str = false
  local i, n = 1, #line
  local bare_end = false
  local open_kw, open_pos = nil, nil
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
      depth = depth > 0 and depth - 1 or 0
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
        elseif not open_kw and OPENER_WORDS[w] and line:sub(s - 1, s - 1) ~= ':' then
          -- the `:` guard skips `:if`, `:let`, ... used as Symbols
          open_kw, open_pos = w, s
        end
      end
    else
      i = i + 1
    end
  end
  return bare_end, open_kw, open_pos, depth
end

---Precompute per (1-indexed) line: indent, first token, whether the line
---starts inside a triple-quoted string, and its block role:
---  kind = 'open'   line opens a block (depth +1)
---         'close'  line is a bare `end` (depth -1)
---         'single' opens and closes on the same line (depth 0, ignored)
---         'plain'  no effect
---For 'open' lines, `okw`/`ocol` give the keyword to highlight and its column.
local function scan_lines(lines)
  local info = {}
  local in_tstring = false
  local depth = 0 -- cumulative bracket depth carried across lines
  for idx, line in ipairs(lines) do
    local started_in_string = in_tstring
    local started_in_bracket = depth > 0

    local quotes = select(2, line:gsub('"""', ''))
    if quotes % 2 == 1 then
      in_tstring = not in_tstring
    end

    if started_in_string then
      -- a line that starts inside a triple string is not code
      info[idx] = { str = true, kind = 'plain', indent = 0 }
    else
      local bare_end, open_kw, open_pos, new_depth = scan_code(line, depth)
      depth = new_depth
      local indent = #(line:match '^%s*' or '')

      if started_in_bracket then
        -- a continuation line inside a multi-line bracketed expression (e.g.
        -- the `for` of a `[expr for x in ...]` comprehension): its tokens are
        -- not statement-level keywords, so do not treat them as block words.
        info[idx] = { str = false, kind = 'plain', indent = indent }
      else
        local first = line:match '^%s*([%a_][%w_]*)'
        local second = first and line:match '^%s*[%a_][%w_]*%s+([%a_][%w_]*)' or nil

        local kind, okw, ocol = 'plain', nil, nil
        if first == 'end' then
          kind = 'close'
        elseif first == 'mutable' and second == 'struct' then
          -- `mutable` is not reserved; only the first-token form is a block
          kind = bare_end and 'single' or 'open'
          okw, ocol = 'mutable', indent
        elseif open_kw then
          kind = bare_end and 'single' or 'open'
          okw, ocol = open_kw, open_pos - 1
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

---The scope that immediately encloses the scope opened at row `r` / closed at
---`e` - i.e. the parent. Same module/baremodule skip as find_enclosing.
local function find_parent(info, r, e)
  local stop = math.max(1, r - MAX_SCAN)
  for pr = r - 1, stop, -1 do
    local li = info[pr]
    if li and li.kind == 'open' then
      local pe = match_end(info, pr)
      if pe and pe >= e and li.okw ~= 'module' and li.okw ~= 'baremodule' then
        return pr, pe, li
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

local function hl_keyword(bufnr, row, col, end_col, group)
  vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, col, {
    end_col = end_col,
    hl_group = group,
    priority = 200,
  })
end

---Highlight a scope's opener keyword and its matching `end` in `group`. For an
---`if`, the branch keyword whose section contains `branch_cur` is used.
local function hl_scope(bufnr, info, lines, r, e, li, group, branch_cur)
  if li.okw == 'if' then
    local brow = if_branch_row(info, r, e, branch_cur)
    if brow == r then
      hl_keyword(bufnr, r, li.ocol, li.ocol + #li.okw, group)
    else
      local bi = info[brow]
      hl_keyword(bufnr, brow, bi.indent, bi.indent + #bi.first, group)
    end
  elseif li.okw == 'mutable' then
    local ss = lines[r]:find('struct', 1, true) or (li.ocol + 1)
    hl_keyword(bufnr, r, li.ocol, ss - 1 + 6, group)
  else
    hl_keyword(bufnr, r, li.ocol, li.ocol + #li.okw, group)
  end
  hl_keyword(bufnr, e, info[e].indent, info[e].indent + 3, group)
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

  -- Current scope: opener keyword + matching `end`.
  hl_scope(bufnr, info, lines, r, e, li, 'JuliaScopeKeyword', cur)

  -- Parent scope, in the dimmer cyan, so two nested levels read apart.
  local pr, pe, pli = find_parent(info, r, e)
  if pr then
    hl_scope(bufnr, info, lines, pr, pe, pli, 'JuliaParentScope', r)
  end

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

---`ib`/`ab` text object. Inside `(...)` it selects the paren contents
---(charwise), like `ib` in C/C++; otherwise it selects the enclosing Julia
---keyword scope (linewise).
function M.select_block(around)
  -- Innermost enclosing `(...)` wins, mirroring C/C++ where `ib` is the paren.
  local op = vim.fn.searchpairpos('(', '', ')', 'nbW')
  local cp = vim.fn.searchpairpos('(', '', ')', 'nW')
  if op[1] > 0 and cp[1] > 0 then
    local sl, sc, el, ec
    if around then
      sl, sc, el, ec = op[1], op[2], cp[1], cp[2]
    else
      sl, sc, el, ec = op[1], op[2] + 1, cp[1], cp[2] - 1
      if sl > el or (sl == el and sc > ec) then
        -- empty () : select the parens themselves
        sl, sc, el, ec = op[1], op[2], cp[1], cp[2]
      end
    end
    if vim.fn.mode():match '[vV\22]' then
      vim.api.nvim_feedkeys(esc, 'nx', false)
    end
    vim.cmd(('normal! %dG%d|v%dG%d|'):format(sl, sc, el, ec))
    return
  end

  -- Otherwise: the enclosing keyword scope, selected linewise.
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
