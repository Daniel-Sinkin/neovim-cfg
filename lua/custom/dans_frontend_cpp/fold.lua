-- Folding, all collapsing to a single gray `+-- N lines:` line. Everywhere
-- (c/cpp/cuda): contract scopes (`{ // Expects ... }` / `{ // Ensures }`) and
-- `///` doc-comment runs. In .hpp additionally an outline fold (treesitter):
-- functions, classes/structs/enums, and anonymous / `detail` namespaces -- so a
-- header opens as a collapsed table of contents. Named non-detail namespaces are
-- left open (their members fold individually). foldmethod=expr; folds nest.
-- Folds are manual: they stay closed while you move or scroll; <CR> on a closed
-- fold (or a left click on it) opens one level. Opened folds stay open until you
-- switch files -- BufEnter re-folds, so a fold state never persists across a file
-- change.

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'

local function is_hpp(buf)
  return vim.api.nvim_buf_get_name(buf):sub(-4) == '.hpp'
end

-- Contract scopes: each `{ // Expects` / `{ // Ensures` brace-matched to its `}`,
-- returned as inclusive 1-based {start, end} line ranges. Brace matching is naive
-- (counts `{`/`}` literally), fine for these assert-only blocks.
local function contract_ranges(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match '^%s*{%s*//%s*[Ee]xpects' or lines[i]:match '^%s*{%s*//%s*[Ee]nsures' then
      local depth, j = 0, i
      while j <= #lines do
        for ch in lines[j]:gmatch '[{}]' do
          depth = depth + (ch == '{' and 1 or -1)
        end
        if depth <= 0 then
          break
        end
        j = j + 1
      end
      if j > i and j <= #lines then
        out[#out + 1] = { i, j }
        i = j + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end

-- `///` doc runs of 2+ consecutive lines, as inclusive 1-based ranges.
local function doc_ranges(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match '^%s*///' then
      local j = i
      while j <= #lines and lines[j]:match '^%s*///' do
        j = j + 1
      end
      if j - i >= 2 then
        out[#out + 1] = { i, j - 1 }
      end
      i = j
    else
      i = i + 1
    end
  end
  return out
end

-- .hpp outline (treesitter): function/class/struct/enum definitions, plus
-- anonymous and `detail` namespaces. Named non-detail namespaces are skipped so
-- they stay open. Returns inclusive 1-based ranges. All failure paths return {}.
local function outline_ranges(buf)
  local out = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'cpp')
  if not ok or not parser then
    return out
  end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees or not trees[1] then
    return out
  end
  local ok3, q = pcall(vim.treesitter.query.parse, 'cpp', [[
    (namespace_definition) @ns
    (function_definition) @fn
    (class_specifier) @def
    (struct_specifier) @def
    (enum_specifier) @def
  ]])
  if not ok3 or not q then
    return out
  end
  for id, node in q:iter_captures(trees[1]:root(), buf, 0, -1) do
    local cap = q.captures[id]
    local keep = true
    -- functions fold only the body `{ ... }`, so the signature line stays visible
    -- and greppable by name; everything else folds the whole construct.
    local rnode = node
    if cap == 'fn' then
      rnode = node:field('body')[1]
      keep = rnode ~= nil
    elseif cap == 'ns' then
      local name = node:field('name')[1]
      if name then
        keep = vim.treesitter.get_node_text(name, buf):find('detail', 1, true) ~= nil
      end
    end
    if keep then
      local s, _, e, ec = rnode:range()
      if ec == 0 then
        e = e - 1 -- node ends at col 0 of the following line; last real line is e-1
      end
      if e > s then
        out[#out + 1] = { s + 1, e + 1 }
      end
    end
  end
  return out
end

-- Per-line fold descriptors from a set of inclusive ranges: '>N' where a range
-- starts (N = nesting depth there), '<N' where one ends, 'N' inside, '0' outside.
-- Explicit '>'/'<' (rather than bare depth) keeps adjacent same-level blocks from
-- merging into one fold.
local function ranges_to_levels(ranges, n)
  local depth, starts, ends = {}, {}, {}
  for i = 1, n do
    depth[i], starts[i], ends[i] = 0, 0, 0
  end
  for _, r in ipairs(ranges) do
    local s, e = r[1], r[2]
    if s >= 1 and e <= n and e >= s then
      starts[s] = starts[s] + 1
      ends[e] = ends[e] + 1
      for L = s, e do
        depth[L] = depth[L] + 1
      end
    end
  end
  local out = {}
  for i = 1, n do
    if starts[i] > 0 then
      out[i] = '>' .. depth[i]
    elseif ends[i] > 0 then
      out[i] = '<' .. depth[i]
    else
      out[i] = tostring(depth[i])
    end
  end
  return out
end

-- Regex-only fold levels (contracts + `///` runs). Used by the spec and by the
-- foldexpr for non-.hpp buffers; .hpp adds the treesitter outline in the foldexpr.
function M.compute_fold_levels(lines)
  local ranges = contract_ranges(lines)
  for _, r in ipairs(doc_ranges(lines)) do
    ranges[#ranges + 1] = r
  end
  return ranges_to_levels(ranges, #lines)
end

-- Cached per buffer + changedtick: the foldexpr is called per line, so compute
-- the whole map once per change and look up by line.
local cache = {}
function _G.dans_cpp_foldexpr()
  local buf = vim.api.nvim_get_current_buf()
  if not vu.module_enabled(buf, 'fold') then
    return '0'
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ranges = contract_ranges(lines)
    for _, r in ipairs(doc_ranges(lines)) do
      ranges[#ranges + 1] = r
    end
    if is_hpp(buf) then
      for _, r in ipairs(outline_ranges(buf)) do
        ranges[#ranges + 1] = r
      end
    end
    c = { tick = tick, levels = ranges_to_levels(ranges, #lines) }
    cache[buf] = c
  end
  return c.levels[vim.v.lnum] or '0'
end

-- Folded display: a single gray `<indent>+-- N lines:` line on a normal
-- background (no banded Folded highlight, no echoed first-line content), so a
-- closed contract block reads as quiet auxiliary text rather than a loud band.
function _G.dans_cpp_foldtext()
  local start = vim.v.foldstart
  local first = vim.api.nvim_buf_get_lines(0, start - 1, start, false)[1] or ''
  local indent = first:match '^%s*' or ''
  local n = vim.v.foldend - start + 1
  -- label, in priority order: the heading/first line of a `///` doc run; the
  -- contract kind (Expects / Ensures); otherwise the opener line itself (function
  -- signature / class / namespace), trailing `{` and surrounding space stripped.
  local label
  local doc = first:match '^%s*///%s?(.*)'
  if doc then
    doc = doc:gsub('^#+%s*', '')
    if doc ~= '' then
      label = doc
    end
  end
  if not label then
    label = first:match '^%s*{%s*//%s*(%a+)'
  end
  if not label then
    label = first:gsub('%s*{%s*$', ''):gsub('^%s+', '')
    if label == '' then
      label = nil
    end
  end
  return indent .. '+-- ' .. n .. ' lines:' .. (label and (' ' .. label) or '')
end

-- Folded's gray-on-normal definition lives in highlights.lua now; re-assert it
-- (and the rest of the frontend groups) on setup + ColorScheme via this wrapper.
local function set_fold_hl()
  require('custom.dans_frontend_cpp.highlights').apply()
end

-- Re-fold a buffer to all-closed (the manual-open default). Folds only ever open
-- via <CR> / click, so re-closing on BufEnter is what makes opened folds not
-- persist across a file change.
local cpp_ft = { c = true, cpp = true, cuda = true }
local function refold()
  if not cpp_ft[vim.bo.filetype] then return end
  if not vu.module_enabled(vim.api.nvim_get_current_buf(), 'fold') then return end
  if vim.wo.foldmethod ~= 'expr' then return end
  pcall(vim.cmd, 'normal! zM')
end

-- Recompute folds for a buffer after a :DansFrontend toggle: `zx` re-evaluates the
-- (now guarded) foldexpr; when the module is on, `zM` then starts it fully folded
-- (manual-open model), when off the foldexpr returns 0 so everything is open.
function M.refresh(bufnr)
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  pcall(vim.cmd, 'normal! zx')
  if vu.module_enabled(bufnr, 'fold') then
    pcall(vim.cmd, 'normal! zM')
  end
end

function M.setup()
  set_fold_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_fold', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function()
      vim.opt_local.foldmethod = 'expr'
      vim.opt_local.foldexpr = 'v:lua.dans_cpp_foldexpr()'
      vim.opt_local.foldtext = 'v:lua.dans_cpp_foldtext()'
      vim.opt_local.fillchars:append 'fold: '
      vim.opt_local.foldenable = true
      vim.opt_local.foldlevel = 0 -- everything starts folded
      -- Manual open: <CR> on a closed fold (or a left click on it) opens one
      -- level; movement and scrolling never open. Buffer-local so other filetypes
      -- (quickfix's <CR>, etc.) keep their behavior.
      vim.keymap.set('n', '<CR>', function()
        return vim.fn.foldclosed '.' ~= -1 and 'zo' or '<CR>'
      end, { buffer = true, expr = true, desc = 'Open fold under cursor, else <CR>' })
      vim.keymap.set('n', '<LeftRelease>', function()
        if vim.fn.foldclosed '.' ~= -1 then
          vim.cmd 'normal! zo'
        end
      end, { buffer = true, desc = 'Open the fold under the click' })
    end,
  })
  -- Re-fold on returning to a file so an opened fold never persists across a file
  -- change. Replaces the old open-the-cursor's-fold-on-every-CursorMoved behavior.
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = refold })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_fold_hl })
end

return M
