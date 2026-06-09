-- Scope highlighting + a unified bracket text object for C/C++/CUDA.
--
-- The "current scope" is the innermost delimiter pair of ANY kind -- `()`, `[]`
-- or `{}` -- that strictly encloses the cursor (or that the cursor sits on). Its
-- two delimiters are painted orange (DansScopeActive). The cursor's enclosing
-- scopes form a single linear chain outward (parent, grandparent, ...); the
-- nearest `depth` of them are painted blue (DansScopeParent). Siblings and inner
-- descendants are deliberately NOT colored -- coloring a sibling reproduces the
-- parent's inner set, which collapses the in-C vs in-A distinction that the chain
-- exists to show.
--
--   depth = 0   only the active pair (orange), no blue
--   depth = 1   + immediate parent (the default)
--   depth = N   + N ancestors up the chain
--
-- `ib`/`ab` are remapped to that innermost pair, dispatching to the matching
-- native text object (`i(`/`i[`/`i{`), so a yank/change/delete grabs exactly the
-- orange pair -- yib is always what the orange marks, regardless of bracket kind.
--
-- Scope is derived by bracket matching, not indentation: C's grammar nests
-- brackets rigidly, so the innermost unmatched open before the cursor (skipping
-- string / char / comment literals via treesitter) is the scope opener, and its
-- type-matching close is the scope end. The underlying buffer text is the ground
-- truth; this never reads the frontend overlay.
--
--   :DansScopeDepth [n]   set the ancestor (blue) depth; no arg prints it

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'
local ns = vim.api.nvim_create_namespace 'ds_cpp_scope'

local CPP_FT = { c = true, cpp = true, cuda = true }
local OPEN = { ['('] = true, ['['] = true, ['{'] = true }
local CLOSE = { [')'] = true, [']'] = true, ['}'] = true }
local MATCH = { ['('] = ')', ['['] = ']', ['{'] = '}' }
local INNER = { ['('] = 'i(', ['['] = 'i[', ['{'] = 'i{' }
local AROUND = { ['('] = 'a(', ['['] = 'a[', ['{'] = 'a{' }

-- Ancestor (blue) depth. 0 = active pair only; 1 = + immediate parent (default).
M.depth = (type(vim.g.dans_scope_depth) == 'number') and vim.g.dans_scope_depth or 1

-- A per-call line reader, cached so a back/forward scan touches each row once.
local function liner(bufnr)
  local cache = {}
  return function(r)
    local v = cache[r]
    if v == nil then
      v = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or false
      cache[r] = v
    end
    return v or nil
  end
end

-- Nearest unmatched OPEN bracket strictly left of (fromr, fromc), i.e. the opener
-- that encloses the gap just before that position. All bracket kinds share one
-- counter (valid C nests cleanly); literals are skipped. Returns r, c, char.
local function enclosing_open(getline, bufnr, fromr, fromc)
  local skip = 0
  for r = fromr, 0, -1 do
    local line = getline(r)
    if line then
      local startc = (r == fromr) and (fromc - 1) or (#line - 1)
      for c = startc, 0, -1 do
        local ch = line:sub(c + 1, c + 1)
        if (OPEN[ch] or CLOSE[ch]) and not vu.in_literal(bufnr, r, c) then
          if CLOSE[ch] then
            skip = skip + 1
          elseif skip > 0 then
            skip = skip - 1
          else
            return r, c, ch
          end
        end
      end
    end
  end
  return nil
end

-- Type-matching close for the open at (or_, oc). One shared counter: every open
-- deepens, every close unwinds, the depth-0 close is the match. Literals skipped.
local function match_close(getline, bufnr, or_, oc)
  local depth = 0
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  for r = or_, last do
    local line = getline(r)
    if line then
      local startc = (r == or_) and oc or 0
      for c = startc, #line - 1 do
        local ch = line:sub(c + 1, c + 1)
        if (OPEN[ch] or CLOSE[ch]) and not vu.in_literal(bufnr, r, c) then
          if OPEN[ch] then
            depth = depth + 1
          else
            depth = depth - 1
            if depth == 0 then
              return r, c, ch
            end
          end
        end
      end
    end
  end
  return nil
end

-- Matching open for a close at (cr, cc) -- the mirror of match_close, scanning back.
local function match_open(getline, bufnr, cr, cc)
  local depth = 0
  for r = cr, 0, -1 do
    local line = getline(r)
    if line then
      local startc = (r == cr) and cc or (#line - 1)
      for c = startc, 0, -1 do
        local ch = line:sub(c + 1, c + 1)
        if (OPEN[ch] or CLOSE[ch]) and not vu.in_literal(bufnr, r, c) then
          if CLOSE[ch] then
            depth = depth + 1
          else
            depth = depth - 1
            if depth == 0 then
              return r, c, ch
            end
          end
        end
      end
    end
  end
  return nil
end

-- Innermost pair enclosing (row, col). If the cursor sits on a bracket, that
-- bracket's pair wins (matching native ib/% feel); otherwise the nearest enclosing
-- open and its match. Returns { or_, oc, cr, cc, ch } (0-based) or nil.
local function innermost_at(getline, bufnr, row, col)
  local line = getline(row) or ''
  local cur = line:sub(col + 1, col + 1)
  local or_, oc, ch
  if OPEN[cur] and not vu.in_literal(bufnr, row, col) then
    or_, oc, ch = row, col, cur
  elseif CLOSE[cur] and not vu.in_literal(bufnr, row, col) then
    or_, oc, ch = match_open(getline, bufnr, row, col)
  else
    or_, oc, ch = enclosing_open(getline, bufnr, row, col)
  end
  if not or_ then
    return nil
  end
  local cr, cc = match_close(getline, bufnr, or_, oc)
  if not cr then
    return nil
  end
  return { or_ = or_, oc = oc, cr = cr, cc = cc, ch = ch }
end

-- The cursor's scope chain, innermost first: the active pair plus up to `want - 1`
-- ancestors. Each ancestor is the opener enclosing the previous opener.
local function pair_chain(getline, bufnr, row, col, want)
  local out = {}
  local p = innermost_at(getline, bufnr, row, col)
  while p do
    out[#out + 1] = p
    if #out >= want then
      break
    end
    local nor, noc = enclosing_open(getline, bufnr, p.or_, p.oc)
    if not nor then
      break
    end
    local ncr, ncc = match_close(getline, bufnr, nor, noc)
    if not ncr then
      break
    end
    -- The opener char is read off the source line; its kind implies the close.
    p = { or_ = nor, oc = noc, cr = ncr, cc = ncc, ch = (getline(nor) or ''):sub(noc + 1, noc + 1) }
  end
  return out
end

-- Public: the innermost pair around (row, col) in `bufnr`, or nil. For tests and
-- the text-object dispatch.
function M.innermost(bufnr, row, col)
  return innermost_at(liner(bufnr), bufnr, row, col)
end

-- Public: the scope chain (innermost first), capped at `want`. For tests.
function M.pair_chain(bufnr, row, col, want)
  return pair_chain(liner(bufnr), bufnr, row, col, want or (M.depth + 1))
end

local function paint(bufnr, p, hl, prio)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, p.or_, p.oc, { end_col = p.oc + 1, hl_group = hl, priority = prio })
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, p.cr, p.cc, { end_col = p.cc + 1, hl_group = hl, priority = prio })
end

local function update(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  if not CPP_FT[vim.bo[bufnr].filetype] then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- Parse so in_literal has a fresh tree (cheap; no-op if already current).
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok and parser then
    pcall(function()
      parser:parse()
    end)
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local chain = pair_chain(liner(bufnr), bufnr, pos[1] - 1, pos[2], M.depth + 1)
  for i, p in ipairs(chain) do
    if i == 1 then
      paint(bufnr, p, 'DansScopeActive', 200)
    else
      paint(bufnr, p, 'DansScopeParent', 150)
    end
  end
end

M.refresh = update

-- ib/ab -> the innermost pair, by dispatching to the matching native text object
-- so the selection (and thus yib/cib/dib/vib) is exactly the orange pair. expr
-- mapping: in operator-pending `dib` becomes `d` + `i(`/`i[`/`i{`. With the cursor
-- in no pair it returns <Esc>, cancelling the pending operator instead of hanging.
local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
local function dispatch(map)
  return function()
    local bufnr = vim.api.nvim_get_current_buf()
    local pos = vim.api.nvim_win_get_cursor(0)
    local p = innermost_at(liner(bufnr), bufnr, pos[1] - 1, pos[2])
    return (p and map[p.ch]) or ESC
  end
end

local function set_keymaps(bufnr)
  local opts = { buffer = bufnr, expr = true, silent = true }
  vim.keymap.set({ 'x', 'o' }, 'ib', dispatch(INNER), vim.tbl_extend('force', opts, { desc = 'inner scope (any bracket)' }))
  vim.keymap.set({ 'x', 'o' }, 'ab', dispatch(AROUND), vim.tbl_extend('force', opts, { desc = 'around scope (any bracket)' }))
end

local function set_highlights()
  -- Active pair: the orange the enclosing-brace highlighter has always used.
  vim.api.nvim_set_hl(0, 'DansScopeActive', { link = 'MatchParen' })
  -- Ancestor chain: the muted blue, distinct from the orange.
  vim.api.nvim_set_hl(0, 'DansScopeParent', { link = 'DiagnosticInfo' })
end

function M.setup()
  set_highlights()
  local group = vim.api.nvim_create_augroup('ds_cpp_scope', { clear = true })

  -- Recolor on cursor move / edit / buffer enter. Routed through the frontend's
  -- debounced decorate event so a scroll burst recomputes once.
  vu.on_decorate(group, { 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, update)

  -- Buffer-local text objects on c/cpp/cuda only; other filetypes keep native ib/ab.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      set_keymaps(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })

  vim.api.nvim_create_user_command('DansScopeDepth', function(a)
    local arg = vim.trim(a.args or '')
    if arg == '' then
      vim.notify('scope ancestor depth = ' .. M.depth, vim.log.levels.INFO)
      return
    end
    local n = tonumber(arg)
    if not n or n < 0 or n ~= math.floor(n) then
      vim.notify('DansScopeDepth: need a non-negative integer', vim.log.levels.WARN)
      return
    end
    M.depth = n
    local b = vim.api.nvim_get_current_buf()
    if CPP_FT[vim.bo[b].filetype] then
      update(b)
    end
    vim.notify('scope ancestor depth = ' .. n, vim.log.levels.INFO)
  end, { nargs = '?', desc = 'Set the scope ancestor (blue) coloring depth' })
end

return M
