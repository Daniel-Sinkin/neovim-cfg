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
local P = require 'custom.dans_frontend_cpp.parse'

local function is_hpp(buf)
  return vim.api.nvim_buf_get_name(buf):sub(-4) == '.hpp'
end

-- The frontend view of one opener line (function signature / class / namespace),
-- for a fold's gray label. Reconstructing it from the live conceal/virt extmarks
-- is unreliable -- a fold off the rendered window (cursor +/- 40) has no marks --
-- so re-apply the same transforms purely: drop the trailing `{`, hide the prefixes
-- the frontend conceals (inline/static, the std::/dans:: scopes, the glfw/vk/vma/gl
-- library prefixes), and the leading const. The whole foldtext is already gray, so
-- param `const`s that stay (grayed in the buffer too) read correctly.
local function signature_label(first)
  local s = first:gsub('%s*{%s*$', '') -- trailing opener brace
  s = s:gsub('^%s+', '')
  s = s:gsub('%f[%w]inline%s+', '')
  s = s:gsub('%f[%w]static%s+', '')
  s = P.strip_glfw(s)
  s = s:gsub('%f[%w]std::ranges::views::', '')
  s = s:gsub('%f[%w]std::ranges::', '')
  s = s:gsub('%f[%w]std::views::', '')
  s = s:gsub('%f[%w]std::', '')
  s = s:gsub('%f[%w]dans::', '')
  s = s:gsub('^const%s+', '')
  s = s:gsub('%s+$', '')
  if s == '' then
    return nil
  end
  return s
end

-- Contract / grouping scopes: each `{ // Expects` / `{ // Ensures` / `{ // Asserts`
-- brace-matched to its `}`, returned as inclusive 1-based {start, end} line ranges.
-- Brace matching is naive (counts `{`/`}` literally), fine for these assert-only
-- blocks. `{ // Asserts }` lets you group assertions the same way Expects groups
-- preconditions.
local function contract_ranges(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match '^%s*{%s*//%s*[Ee]xpects' or lines[i]:match '^%s*{%s*//%s*[Ee]nsures' or lines[i]:match '^%s*{%s*//%s*[Aa]sserts' then
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

-- Runs of 2+ contiguous `static_assert(...)` lines, as inclusive 1-based ranges --
-- a block of compile-time checks folds to one line like a `///` doc run. Single
-- static_asserts (and runtime assert(...), which never matches) are left alone.
local function static_assert_ranges(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match '^%s*static_assert%s*%(' then
      local j = i
      while j <= #lines and lines[j]:match '^%s*static_assert%s*%(' do
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

-- Direct-member counts per folding namespace (start-line 1-based -> {fn,st,en}),
-- filled by outline_ranges and read by the foldtext for the count annotation.
local ns_member_counts = {}

-- The enclosing scope of `node`: the nearest ancestor that is a namespace, the
-- file, a class/struct, or a function. Used to tell a direct namespace/file member
-- from one nested inside a class (a method) or another def.
local SCOPE_TYPES = {
  namespace_definition = true,
  translation_unit = true,
  class_specifier = true,
  struct_specifier = true,
  function_definition = true,
}
local function nearest_scope(node)
  local p = node:parent()
  while p do
    if SCOPE_TYPES[p:type()] then
      return p
    end
    p = p:parent()
  end
end
local function node_key(node)
  -- type + full range: a translation_unit and a first-line namespace both start at
  -- 0:0, so start alone collides; the end and type disambiguate.
  local sr, sc, er, ec = node:range()
  return node:type() .. ':' .. sr .. ':' .. sc .. ':' .. er .. ':' .. ec
end

-- .hpp outline (treesitter): function/class/struct/enum definitions, plus
-- anonymous and `detail` namespaces. Named non-detail namespaces are skipped so
-- they stay open. A def that is the ONLY thing in its namespace / the file isn't
-- folded -- no point making you unfold a one-thing scope twice. Returns inclusive
-- 1-based ranges. All failure paths return {}.
local function outline_ranges(buf)
  local out = {}
  ns_member_counts[buf] = {}
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
    (initializer_list) @data
    (switch_statement) @sw
  ]])
  if not ok3 or not q then
    return out
  end
  local function add_range(node)
    local s, _, e, ec = node:range()
    if ec == 0 then
      e = e - 1 -- node ends at col 0 of the following line; last real line is e-1
    end
    if e > s then
      out[#out + 1] = { s + 1, e + 1 }
    end
  end
  local function kind_of(node)
    local t = node:type()
    if t == 'function_definition' then
      return 'fn'
    elseif t == 'enum_specifier' then
      return 'en'
    end
    return 'st' -- class_specifier / struct_specifier
  end

  -- pass 1: count direct members per scope (defs AND nested namespaces, for the
  -- sole-member rule) and per-kind def counts per scope (for the label).
  local scope_count, scope_kinds = {}, {}
  local defs, ns_fold, extras = {}, {}, {}
  for id, node in q:iter_captures(trees[1]:root(), buf, 0, -1) do
    local cap = q.captures[id]
    local sc = nearest_scope(node)
    local key = sc and node_key(sc) or nil
    if cap == 'data' or cap == 'sw' then
      -- arrays / switches always fold (never sole-member-gated). A namespace/file-
      -- level array still COUNTS as a thing in that scope, so a lone function next
      -- to a big data table isn't treated as the scope's sole member.
      extras[#extras + 1] = node
      if cap == 'data' and sc and (sc:type() == 'namespace_definition' or sc:type() == 'translation_unit') then
        scope_count[key] = (scope_count[key] or 0) + 1
      end
    elseif cap == 'ns' then
      if key then
        scope_count[key] = (scope_count[key] or 0) + 1
      end
      local name = node:field('name')[1]
      local fold = (not name) or (vim.treesitter.get_node_text(name, buf):find('detail', 1, true) ~= nil)
      if fold then
        ns_fold[#ns_fold + 1] = node
      end
    else
      -- count membership in ANY scope (namespace, file, class, struct, function) so
      -- the sole-member rule also opens a one-method class and a one-thing file.
      if key then
        scope_count[key] = (scope_count[key] or 0) + 1
        local k = scope_kinds[key] or { fn = 0, st = 0, en = 0 }
        scope_kinds[key] = k
        k[kind_of(node)] = k[kind_of(node)] + 1
      end
      defs[#defs + 1] = { node = node, key = key }
    end
  end

  -- pass 2: fold namespaces (recording member counts), defs (except a sole member),
  -- then the always-fold extras (arrays / switches).
  for _, node in ipairs(ns_fold) do
    add_range(node)
    local s = node:range()
    ns_member_counts[buf][s + 1] = scope_kinds[node_key(node)] or { fn = 0, st = 0, en = 0 }
  end
  for _, d in ipairs(defs) do
    if not (d.key and scope_count[d.key] == 1) then
      add_range(d.node)
    end
  end
  for _, node in ipairs(extras) do
    add_range(node)
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
  for _, r in ipairs(static_assert_ranges(lines)) do
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
    for _, r in ipairs(static_assert_ranges(lines)) do
      ranges[#ranges + 1] = r
    end
    -- platform-dead `#if` branches fold (and gray, via ppif's own extmarks), in
    -- every c/cpp/cuda buffer -- not just headers.
    for _, r in ipairs(require('custom.dans_frontend_cpp.ppif').inactive_ranges(lines)) do
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
    -- outline folds (function / class / namespace): the frontend-rendered opener.
    label = signature_label(first)
    -- a folded namespace shows what's inside: ": 2 function : 1 struct : 3 enum"
    -- (zero counts omitted, enum last).
    local counts = ns_member_counts[vim.api.nvim_get_current_buf()]
    local c = counts and counts[start]
    if label and c then
      local parts = {}
      if c.fn > 0 then
        parts[#parts + 1] = c.fn .. ' function'
      end
      if c.st > 0 then
        parts[#parts + 1] = c.st .. ' struct'
      end
      if c.en > 0 then
        parts[#parts + 1] = c.en .. ' enum'
      end
      if #parts > 0 then
        label = label .. ' : ' .. table.concat(parts, ' : ')
      end
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
