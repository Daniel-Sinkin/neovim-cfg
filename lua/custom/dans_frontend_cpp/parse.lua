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

-- Parse `for (BINDING : ITER) TAIL` where BINDING is `[const] auto[&*]* name`
-- (the sigil run is `&`, `&&` for a forwarding ref, or `*`). Returns a table or
-- nil. const is hidden; a missing const surfaces as `mut`.
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
  local sigil, name = binding:gsub('^const%s+', ''):match '^auto%s*([&*]*)%s*(.+)$'
  if not name then
    return nil
  end
  name = vim.trim(name):gsub('^%[%s*(.-)%s*%]$', '%1') -- destructured binding -> bare list
  return { is_const = is_const, sigil = sigil, name = name, iter = iter, tail = tail }
end

-- `if (auto NAME = RHS; COND) TAIL` (NAME bound with `[const] auto`) ->
-- { name, rhs, cond, tail } for an `if let` render, else nil. COND is returned
-- raw; the render drops it when it's a validity check on NAME and shows it
-- otherwise.
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
  -- `cond` returned raw; the render decides whether to show it (it drops any
  -- condition that checks the binding -- `res`, `res.has_value()`, ...).
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
  -- std::expected<T, E> -> T?E (value, then `?`, then the error arm), keeping any
  -- trailing ref/ptr. Split at the top-level comma so a templated arm
  -- (expected<vector<int>, Error>) isn't broken on its inner comma.
  local exp_inner, exp_sig = t:match '^expected<(.+)>%s*([&*]*)$'
  if exp_inner then
    local depth = 0
    for i = 1, #exp_inner do
      local c = exp_inner:sub(i, i)
      if c == '<' or c == '(' or c == '[' then
        depth = depth + 1
      elseif c == '>' or c == ')' or c == ']' then
        depth = depth - 1
      elseif c == ',' and depth == 0 then
        t = vim.trim(exp_inner:sub(1, i - 1)) .. '?' .. vim.trim(exp_inner:sub(i + 1)) .. exp_sig
        break
      end
    end
  end
  -- std::array<T, N> -> [N]T (Odin array syntax). Split at the top-level comma so
  -- a templated element (array<pair<int, int>, 3>) isn't broken.
  local inner = t:match '^array<(.+)>$'
  if inner then
    local depth = 0
    for i = 1, #inner do
      local c = inner:sub(i, i)
      if c == '<' or c == '(' or c == '[' then
        depth = depth + 1
      elseif c == '>' or c == ')' or c == ']' then
        depth = depth - 1
      elseif c == ',' and depth == 0 then
        t = '[' .. vim.trim(inner:sub(i + 1)) .. ']' .. vim.trim(inner:sub(1, i - 1))
        break
      end
    end
  end
  -- const char* (an immutable C string) -> CString, wherever it appears -- incl
  -- nested in a template (vector<const char*> -> vector<CString>). A top-level
  -- const-char* member is handled in build_chunks (the const is peeled there, so
  -- it never reaches here with the const attached); this catches the nested ones
  -- the overlay would otherwise leave as `const char^`. Extra pointer levels are
  -- kept (const char** -> CString*, then M.ptr -> CString^). Runs before M.ptr so
  -- it can match the `*` while it is still a star.
  t = t:gsub('const%s+char%s*(%*+)', function(stars)
    return 'CString' .. stars:sub(2)
  end)
  return M.ptr(t)
end

-- Drop a library prefix from a type token for the overlay, matching the raw-line
-- conceals in markers.lua: GLFWwindow -> window, glfwFoo -> Foo, GLFW_X -> X, and
-- VkResult -> Result, VK_X -> X. Only the prefix; the caller computes the library
-- color BEFORE calling this so it survives. `%f[%w]` anchors to a token start so an
-- embedded prefix isn't touched.
function M.strip_glfw(t)
  t = t:gsub('%f[%w]GLFW_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]GLFW([a-z])', '%1')
  t = t:gsub('%f[%w]glfw([A-Z])', '%1')
  -- longer DebugUtils sub-prefix first, then the generic Vk/VK_
  t = t:gsub('%f[%w]VK_DEBUG_UTILS_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]VkDebugUtils([A-Z])', '%1')
  t = t:gsub('%f[%w]VK_([A-Z0-9])', '%1')
  t = t:gsub('%f[%w]Vk([A-Z])', '%1')
  -- lowercase vk functions (vkCreateInstance -> CreateInstance), like glfw. The
  -- `[%w_]` frontier treats `_` as a word char (matching the raw-line `\<vk`
  -- conceal), so an embedded `PFN_vkCreateX` keeps its vk rather than becoming
  -- `PFN_CreateX`.
  t = t:gsub('%f[%w_]vk([A-Z])', '%1')
  return t
end

-- Trailing identifier of a *pure* member-access chain (`cfg.center` -> "center",
-- `obj->p` -> "p", `center` -> "center"), or nil if `v` is anything else (a call,
-- index, operator, literal). Drives the designated-init pun: `.center = cfg.center`
-- collapses to `center` because the last access already matches the field name.
function M.access_tail(v)
  local norm = vim.trim(v):gsub('%s*%->%s*', '.'):gsub('%s*%.%s*', '.')
  if norm:match '^[%a_][%w_]*$' or norm:match '^[%a_][%w_]*%.[%w_.]*[%w_]$' then
    return norm:match '([%w_]+)$'
  end
  return nil
end

-- Split a designated-init body (`.a = x, .b = y`) into { {field, value}, ... } on
-- top-level commas, or nil if any element isn't `.field = value`. Lets the value
-- renderer fold designated inits the same way cpp_designated does on raw lines.
function M.designated_pairs(body)
  local out = {}
  local depth, start = 0, 1
  local function push(chunk)
    local field, value = chunk:match '^%s*%.([%w_]+)%s*=%s*(.-)%s*$'
    if not field then
      return false
    end
    out[#out + 1] = { field = field, value = value }
    return true
  end
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == '(' or c == '[' or c == '{' or c == '<' then
      depth = depth + 1
    elseif c == ')' or c == ']' or c == '}' or c == '>' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      if not push(body:sub(start, i - 1)) then
        return nil
      end
      start = i + 1
    end
  end
  if not push(body:sub(start)) then
    return nil
  end
  return #out > 0 and out or nil
end

-- Whether `row0` is a single-line function declaration (return type BEFORE the
-- name, e.g. `bool f(args)` -- including the most-vexing-parse `vector<T> v(n)`
-- that the C++ grammar reads as a function). Used only to BAIL: such lines render
-- raw instead of being mangled into a `name: T(args)` paren-init variable. nil for
-- trailing-return functions, constructors/destructors, non-functions, and
-- multi-line decls. A cheap text pre-check gates the treesitter walk.
function M.classic_function(bufnr, row0)
  if not bufnr then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  if not line or not line:match '[%w_]+%s*%b()' then
    return nil -- no `ident(...)` at all -> can't be a function decl
  end
  local col = #(line:match '^%s*' or '')
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col } })
  if not ok or not node then
    return nil
  end
  while node and node:type() ~= 'declaration' and node:type() ~= 'field_declaration' do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local tfield = node:field('type')[1]
  local dtor = node:field('declarator')[1]
  if not tfield or not dtor or tfield:type() == 'placeholder_type_specifier' then
    return nil -- no return type, or `auto` (deduced / trailing-return)
  end
  local fnode = dtor
  if dtor:type() == 'pointer_declarator' then
    fnode = dtor:field('declarator')[1]
  elseif dtor:type() == 'reference_declarator' then
    fnode = dtor:field('declarator')[1]
  end
  if not fnode or fnode:type() ~= 'function_declarator' then
    return nil
  end
  local _, _, fe_row = fnode:range()
  if fe_row ~= row0 then
    return nil -- single-line declarations only
  end
  return true
end

-- Whether line `row0` is the `});` that closes a `DANS_DEFER(...)` call -- the
-- nearest call_expression enclosing the line's closing `}` is named DANS_DEFER.
-- Lets the view render that closer as a bare `}` (its opener became `defer {`).
function M.defer_close(bufnr, row0)
  if not bufnr then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  local bcol = line and line:find('}', 1, true)
  if not bcol then
    return false
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, bcol - 1 } })
  if not ok or not node then
    return false
  end
  while node do
    if node:type() == 'call_expression' then
      local fn = node:field('function')[1]
      return fn ~= nil and vim.treesitter.get_node_text(fn, bufnr) == 'DANS_DEFER'
    end
    node = node:parent()
  end
  return false
end

-- Split `s` at the first top-level comma (templates/parens/brackets balanced):
-- returns (first, rest) or (s, nil) if there is none. Used to peel a smart
-- pointer's custom deleter off the pointee type without being fooled by the
-- commas inside a nested template like `pair<int, int>`.
local function split_first_arg(s)
  local depth = 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '<' or c == '(' or c == '[' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      return vim.trim(s:sub(1, i - 1)), vim.trim(s:sub(i + 1))
    end
  end
  return s, nil
end

-- A std smart-pointer type (after strip_type already removed std::): returns the
-- pointee type, 'unique'/'shared', and a custom deleter (or nil), else nil. Lets
-- the view render `unique_ptr<T>` as `T^` with an ownership-colored caret, and
-- `unique_ptr<T, Del>` as `T^, Del~` -- the caret on the pointee, a `~` tying the
-- deleter to it (instead of the caret landing on the deleter).
function M.smart_ptr(t)
  local inner = t:match '^unique_ptr<(.+)>$'
  local kind
  if inner then
    kind = 'unique'
  else
    inner = t:match '^shared_ptr<(.+)>$'
    if not inner then
      return nil
    end
    kind = 'shared'
  end
  local pointee, deleter = split_first_arg(inner)
  return pointee, kind, deleter
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
  local _, core, was_const = M.split_markers((code:gsub(';%s*$', '')))
  local typ, nm = core:match '^(.-)%s+([%w_]+)%s*{.*}$'
  if not (nm and had_semi and M.looks_like_type(typ)) then
    -- no-brace reference/pointer member: `T& name` / `T* name`
    typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
    if not (typ and nm and had_semi and M.looks_like_type(typ)) then
      return nil
    end
  end
  local disp = M.strip_type(typ)
  local inner, _, deleter = M.smart_ptr(disp)
  if inner then
    disp = deleter and (inner .. '^, ' .. deleter .. '~') or (inner .. '^')
  elseif was_const and disp:match '^char%^+$' then
    -- `const char*`(*) renders as `CString`(^); the alignment width must match
    -- what's shown, not the stripped `char^`.
    disp = 'CString' .. (disp:gsub('^char%^', ''))
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
