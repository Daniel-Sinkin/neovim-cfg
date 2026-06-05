-- Parsing and treesitter classification for the dans-cpp-frontend declaration view. Pure
-- analysis: from declaration text (and optionally a buffer position) it returns
-- structured data or measurements -- no rendering, no module state. Used by
-- render (chunk building) and view (alignment / reveal).

local M = {}

-- Render pointer *types* with `^` (Pascal/Odin style). Only in type positions
-- the overlay parses; `*` for multiply and deref in expressions is untouched.
local POINTER_CARET = true

local STMT_KEYWORDS = {
  ['return'] = true,
  ['if'] = true,
  ['else'] = true,
  ['for'] = true,
  ['while'] = true,
  ['switch'] = true,
  ['case'] = true,
  ['do'] = true,
  ['throw'] = true,
  ['delete'] = true,
  ['using'] = true,
  ['namespace'] = true,
  ['template'] = true,
  ['struct'] = true,
  ['class'] = true,
  ['enum'] = true,
  ['typedef'] = true,
  ['def'] = true,
  ['co_return'] = true,
  ['co_await'] = true,
  ['co_yield'] = true,
  ['static_assert'] = true,
}

local MARKERS = { 'cpy' }

-- Peel leading attributes/markers. `const`/`constexpr`/`inline` and the (now
-- source-removed) `mut`/`mut_unchecked` are dropped; `cpy` and `[[maybe_unused]]`
-- are kept as a prefix. mut is re-inferred from non-const in build_chunks.
-- Returns prefix, rest, is_const, is_constexpr. Leading cv/storage specifiers in
-- ANY order are peeled and hidden: const/constexpr drive the rendering
-- (const-ness hides const + suppresses the inferred mut; constexpr additionally
-- renders as a `:` constant binding); static/inline/thread_local/extern/constinit
-- are pure storage noise. `mut`/`mut_unchecked` are dropped (re-inferred from
-- non-const, no longer a source token); `cpy` and `[[maybe_unused]]` are kept as
-- a visible prefix.
function M.split_markers(s)
  local prefix = ''
  local rest = s
  local is_const, is_constexpr = false, false
  while true do
    local matched = false

    -- const must be tried before the storage group; constexpr before const so a
    -- bare `const ` (with trailing space) and `constexpr ` don't shadow it (they
    -- can't anyway -- `^const%s+` won't match `constexpr` -- but keep it clear).
    local after = rest:match '^constexpr%s+(.*)$'
    if after then
      rest, is_const, is_constexpr, matched = after, true, true, true
    end

    if not matched then
      after = rest:match '^const%s+(.*)$'
      if after then
        rest, is_const, matched = after, true, true
      end
    end

    if not matched then
      -- static / thread_local are kept as a shown prefix: meaningful storage
      -- duration worth seeing (thread_local especially is rare and notable).
      after = rest:match '^static%s+(.*)$'
      if after then
        prefix, rest, matched = prefix .. 'static ', after, true
      end
    end
    if not matched then
      after = rest:match '^thread_local%s+(.*)$'
      if after then
        prefix, rest, matched = prefix .. 'thread_local ', after, true
      end
    end
    if not matched then
      -- inline / extern / constinit: pure noise, hidden.
      after = rest:match '^inline%s+(.*)$' or rest:match '^extern%s+(.*)$' or rest:match '^constinit%s+(.*)$'
      if after then
        rest, matched = after, true
      end
    end

    if not matched then
      local after_mut = rest:match '^mut_unchecked%s+(.*)$' or rest:match '^mut%s+(.*)$'
      if after_mut then
        rest, matched = after_mut, true
      end
    end

    if not matched then
      local after_mu = rest:match '^%[%[maybe_unused%]%]%s+(.*)$'
      if after_mu then
        prefix = prefix .. '[[maybe_unused]] '
        rest, matched = after_mu, true
      end
    end

    if not matched then
      for _, mk in ipairs(MARKERS) do
        local a = rest:match('^' .. mk .. '%s+(.*)$')
        if a then
          prefix = prefix .. mk .. ' '
          rest, matched = a, true
          break
        end
      end
    end

    if not matched then
      break
    end
  end
  return prefix, rest, is_const, is_constexpr
end

function M.looks_like_type(t)
  if t == '' then
    return false
  end
  if t:match '[%(%)%[%]{}=;]' then
    return false
  end
  if t:find('->', 1, true) then
    return false
  end
  local first = t:match '^([%w_]+)'
  if first and STMT_KEYWORDS[first] then
    return false
  end
  return true
end

-- Whether all (), [], {} on the line are closed. An unbalanced line is the
-- opener of a multi-line statement (e.g. `const auto x = foo(`), not a complete
-- declaration, so it must render raw.
function M.is_balanced(s)
  local depth = 0
  for ch in s:gmatch '[%(%)%[%]{}]' do
    if ch == '(' or ch == '[' or ch == '{' then
      depth = depth + 1
    else
      depth = depth - 1
    end
    if depth < 0 then
      return false
    end
  end
  return depth == 0
end

-- Parse a lambda RHS `[cap](params) rest` (rest = "-> R", "{...}", "{", "" with
-- the brace on the next line, "mutable -> R", ...). Returns (cap, params, rest)
-- or nil. The no-params form `[cap]{...}` returns params=nil. Only matches when
-- the expression starts with `[`, which in valid C++ means a lambda.
function M.parse_lambda(expr)
  local cap, params, rest = expr:match '^%[(.-)%]%s*%((.-)%)%s*(.*)$'
  if cap ~= nil then
    return cap, params, rest
  end
  local cap2, rest2 = expr:match '^%[(.-)%]%s*(.*)$'
  if cap2 ~= nil and rest2:match '^{' then
    return cap2, nil, rest2
  end
  return nil
end

-- The lone `:` of a range-based for (skipping `::` qualifiers).
local function for_colon(s)
  local i = 1
  while true do
    local c = s:find(':', i, true)
    if not c then
      return nil
    end
    if s:sub(c - 1, c - 1) ~= ':' and s:sub(c + 1, c + 1) ~= ':' then
      return c
    end
    i = c + 1
  end
end

-- Parse `for (BINDING : ITER) TAIL` where BINDING is `[const] auto[&*] name`.
-- Returns a table or nil. const is hidden; a missing const surfaces as `mut`.
-- C-style fors (no `:`) and explicit-type bindings (no `auto`) return nil.
function M.parse_for(core)
  local inside, tail = core:match '^for%s*%((.+)%)%s*(.*)$'
  if not inside then
    return nil
  end
  local c = for_colon(inside)
  if not c then
    return nil
  end
  local binding = vim.trim(inside:sub(1, c - 1))
  local iter = vim.trim(inside:sub(c + 1))
  local is_const = binding:match '^const%f[%A]' ~= nil
  local sigil, name = binding:gsub('^const%s+', ''):match '^auto%s*([&*]?)%s*(.+)$'
  if not name then
    return nil
  end
  name = vim.trim(name):gsub('^%[%s*(.-)%s*%]$', '%1') -- destructured binding -> bare list
  return { is_const = is_const, sigil = sigil, name = name, iter = iter, tail = tail }
end

-- `if (const auto NAME = RHS; NAME) TAIL` -> { name, rhs, tail } for an `if let`
-- render, else nil. Only the truthiness-on-the-bound-name form (the condition is
-- exactly the declared name); anything else (e.g. `it != end()`) is left raw so
-- the real test is never hidden.
function M.parse_if_let(core)
  local inside, tail = core:match '^if%s*%((.+)%)%s*(.*)$'
  if not inside then
    return nil
  end
  local semi = inside:find(';', 1, true)
  if not semi then
    return nil
  end
  local init = vim.trim(inside:sub(1, semi - 1))
  local cond = vim.trim(inside:sub(semi + 1))
  local name, rhs = init:match '^const%s+auto%s+([%w_]+)%s*=%s*(.+)$'
  if not name then
    name, rhs = init:match '^auto%s+([%w_]+)%s*=%s*(.+)$'
  end
  if not name then
    return nil
  end
  -- `cond` kept so the caller can show a real test (`res == 0`); a bare
  -- truthiness check (`cond == name`) is redundant and gets dropped.
  return { name = name, rhs = rhs, cond = cond, tail = tail }
end

-- Render pointer-type `*` as `^` (type positions only). `&` is left alone.
function M.ptr(s)
  return POINTER_CARET and (s:gsub('%*', '^')) or s
end

-- Strip the parts of a type the view hides: leading constexpr/inline and the
-- std::/dans:: qualifiers, and render pointer `*` as `^`. Shared by build_chunks
-- and the alignment pass (so column widths match).
function M.strip_type(typ)
  local t = typ:gsub('^constexpr%s+', ''):gsub('^inline%s+', ''):gsub('std::', ''):gsub('dans::', '')
  -- std::optional<T> -> T?, keeping any trailing ref/ptr after the `?`:
  -- optional<T>& -> T?&, optional<T>* -> T?^ (once M.ptr rewrites the star).
  t = t:gsub('^optional<(.+)>%s*([&*]*)$', '%1?%2')
  return M.ptr(t)
end

-- A std smart-pointer type (after strip_type already removed std::): returns the
-- inner type and 'unique'/'shared', else nil. Lets the view render
-- `unique_ptr<T>` / `shared_ptr<T>` as `T^` with an ownership-colored caret.
function M.smart_ptr(t)
  local inner = t:match '^unique_ptr<(.+)>$'
  if inner then
    return inner, 'unique'
  end
  inner = t:match '^shared_ptr<(.+)>$'
  if inner then
    return inner, 'shared'
  end
  return nil
end

-- For an explicit-type brace declaration (`T name{init}`), return the rendered
-- name and type strings, else nil. Mirrors build_chunks' explicit branch so the
-- alignment pass measures exactly what gets rendered.
function M.field_dims(line)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  local code = body:match '^(.-)%s*//.*$' or body
  local had_semi = code:match ';%s*$' ~= nil
  local _, core = M.split_markers((code:gsub(';%s*$', '')))
  local typ, nm = core:match '^(.-)%s+([%w_]+)%s*{.*}$'
  if not (nm and had_semi and M.looks_like_type(typ)) then
    -- no-brace reference/pointer member: `T& name` / `T* name`
    typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
    if not (typ and nm and had_semi and M.looks_like_type(typ)) then
      return nil
    end
  end
  local disp = M.strip_type(typ)
  local inner, kind = M.smart_ptr(disp)
  if inner then
    disp = inner .. '^'
  end
  return nm, disp
end

-- Map row0 -> { nw, tw } so a run of consecutive explicit-type brace
-- declarations aligns its `:` (after the name) and `=`/`;` (after the type).
-- Singleton runs get no entry (nothing to align).
function M.compute_align(lines, offset)
  offset = offset or 0
  local map = {}
  local i, n = 1, #lines
  while i <= n do
    local block = {}
    while i <= n do
      local nm, ty = M.field_dims(lines[i])
      if not nm then
        break
      end
      block[#block + 1] = { row0 = offset + i - 1, nw = vim.fn.strwidth(nm), tw = vim.fn.strwidth(ty) }
      i = i + 1
    end
    if #block >= 2 then
      local nw, tw = 0, 0
      for _, b in ipairs(block) do
        nw = math.max(nw, b.nw)
        tw = math.max(tw, b.tw)
      end
      for _, b in ipairs(block) do
        map[b.row0] = { nw = nw, tw = tw }
      end
    end
    if #block == 0 then
      i = i + 1
    end
  end
  return map
end

-- Classify the declaration on a line via treesitter: 'member' (struct/class
-- field), 'local' (function-body variable), 'param', 'global' (file/namespace
-- scope), or nil. mut is inferred only on non-const locals; keyed on the
-- enclosing scope (not just `declaration`, which also covers namespace globals).
-- Cheap (node lookup + ancestor walk); guarded since the tree may be mid-parse.
function M.decl_kind(bufnr, row0)
  if not bufnr then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  if not line then
    return nil
  end
  local col = #(line:match '^%s*' or '')
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col } })
  if not ok or not node then
    return nil
  end
  while node do
    local t = node:type()
    if t == 'field_declaration' then
      return 'member'
    elseif t == 'parameter_declaration' or t == 'optional_parameter_declaration' then
      return 'param'
    elseif t == 'function_definition' or t == 'compound_statement' then
      return 'local' -- inside a function body
    elseif t == 'namespace_definition' or t == 'translation_unit' then
      return 'global' -- file / namespace scope, not a function local
    end
    node = node:parent()
  end
  return nil
end

-- Whether the declaration on this line initializes from an immediately-invoked
-- lambda (IIFE): `auto x = [&]{...}()`. Treesitter sees the init as a
-- call_expression (vs a plain lambda_expression for a binding). The caller has
-- already confirmed the line's RHS is a lambda, so call_expression => IIFE.
function M.is_iife(bufnr, row0)
  if not bufnr then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  if not line then
    return false
  end
  local col = #(line:match '^%s*' or '')
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col } })
  if not ok or not node then
    return false
  end
  while node and node:type() ~= 'declaration' do
    node = node:parent()
  end
  if not node then
    return false
  end
  for child in node:iter_children() do
    if child:type() == 'init_declarator' then
      local last
      for c in child:iter_children() do
        last = c
      end
      return last ~= nil and last:type() == 'call_expression'
    end
  end
  return false
end

return M
