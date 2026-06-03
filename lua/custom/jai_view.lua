-- Read-mode that re-renders C/C++/CUDA variable declarations in a JAI-like
-- syntax. View-only (extmark conceal + inline virt_text). ON by default for
-- c/cpp/cuda buffers; toggle per-buffer with :JaiView.
--
--   int x{7}        ->  x: int = 7
--   int x{}         ->  x: int
--   T name{init}    ->  name: T = init
--   auto x = e      ->  x := e          (or x: <deduced> = e when clangd has it)
--   auto& x = e     ->  x := &e
--   auto* x = e     ->  x := e          (pointer-ness folded into the value)
--
-- Deduced types come from clangd's inlay hints (requested directly here, not
-- via the built-in renderer) and are placed between the `:` and `=`, dimmed via
-- DansInlayType. `_` declarations get no type hint.
--
-- Leading `mut` / `mut_unchecked` / `cpy` markers and `[[maybe_unused]]` are
-- preserved as a prefix; leading `const` is dropped (it's the hidden default,
-- same as the const concealment in config/autocmds.lua).
--
-- Reveal is cursor-line driven: the line the cursor sits on shows the real C++
-- (no overlay, no type hint); every other line shows the JAI overlay. Moving
-- the cursor flips the line you leave back to JAI and reveals the one you land
-- on. Mode-agnostic (insert mode has no special effect).

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_jai_view'
local enabled = {}
local hint_type = {} -- bufnr -> { [row0] = "int *" } from clangd Type inlay hints
local show_hints = false -- deduced-type hints off by default (toggle with :InlineHints)

-- Experimental: render a lambda-assigned-to-auto as a function-style decl,
--   const auto f = [cap](params) -> R   ->   lambda f(cap, params) -> R
-- (intro line only; the body keeps its own indentation). Toggle :LambdaView.
local lambda_render = true
local LAMBDA_KEYWORD = 'lambda'
-- Divider between a lambda's capture list and its params, shown whenever there
-- are params: lambda f(& : int x); no capture -> lambda f(: int x); no params
-- -> lambda f(&).
local LAMBDA_CAP_SEP = ':'

-- Range-for binding sigil position: true -> `vertex&` (after the name), false ->
-- `&vertex` (before it). const is hidden; a non-const binding shows `mut`.
local FOR_REF_SUFFIX = true

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

-- Marker word -> highlight group, shared with cpp_markers.lua.
local MARKER_HL = {
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
  cpy = 'DansMarkerCpy',
}

-- Peel leading attributes/markers. `const`/`constexpr`/`inline` and the (now
-- source-removed) `mut`/`mut_unchecked` are dropped; `cpy` and `[[maybe_unused]]`
-- are kept as a prefix. mut is re-inferred from non-const in build_chunks.
local function split_markers(s)
  local prefix = ''
  local rest = s
  while true do
    local matched = false

    local after_const = rest:match '^const%s+(.*)$'
    if after_const then
      rest = after_const
      matched = true
    end

    if not matched then
      local after_inline = rest:match '^inline%s+(.*)$'
      if after_inline then
        rest = after_inline
        matched = true
      end
    end

    if not matched then
      -- mut / mut_unchecked are dropped (re-inferred from non-const, not a
      -- source token anymore). mut_unchecked first: it's a prefix of mut.
      local after_mut = rest:match '^mut_unchecked%s+(.*)$' or rest:match '^mut%s+(.*)$'
      if after_mut then
        rest = after_mut
        matched = true
      end
    end

    if not matched then
      local after_mu = rest:match '^%[%[maybe_unused%]%]%s+(.*)$'
      if after_mu then
        prefix = prefix .. '[[maybe_unused]] '
        rest = after_mu
        matched = true
      end
    end

    if not matched then
      for _, mk in ipairs(MARKERS) do
        local after = rest:match('^' .. mk .. '%s+(.*)$')
        if after then
          prefix = prefix .. mk .. ' '
          rest = after
          matched = true
          break
        end
      end
    end

    if not matched then
      break
    end
  end
  return prefix, rest
end

local function looks_like_type(t)
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

-- Marker keywords that should pop wherever they appear in an expression
-- (e.g. `copy(x)` in a value), so the overlay matches the matchadd coloring on
-- real text.
local EXPR_MARKERS = {
  copy = 'DansMarkerCpy',
  cpy = 'DansMarkerCpy',
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
}

-- Single-word C++ aliases ($sc, $dc, ...) reused from cpp_aliases so casts in
-- jai-rendered value expressions read the same as on non-overlaid lines. This
-- overlay conceals the whole source line, so cpp_aliases defers here (its inline
-- alias would be orphaned); without this the casts rendered verbatim. Built
-- lazily and cached from cpp_aliases.ALIASES, keeping only identifier-shaped
-- keywords (`[[nodiscard]]` is dropped -- it can't occur inside a value).
local expr_aliases_cache = nil
local function expr_aliases()
  if expr_aliases_cache then
    return expr_aliases_cache
  end
  local map = {}
  local ok, aliases = pcall(function()
    return require('custom.cpp_aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      if a[1]:match '^[%a_][%w_]*$' then
        map[a[1]] = { a[2], a[3] or 'Comment' } -- { replacement, highlight }
      end
    end
  end
  if next(map) then
    expr_aliases_cache = map
  end
  return map
end

-- Split `text` into chunks: string literals colored green (contents untouched),
-- namespace qualifiers grayed/hidden, cast keywords aliased, marker/Vk/SDL/macro
-- words colored. Mirrors the raw-line matchadd coloring inside the overlay.
local function colorize(text)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local q = text:find('"', i, true)
    local s, e = text:find('[%a_][%w_]*', i)
    if q and (not s or q <= s) then
      -- String literal: emit the gap before it, then consume "..." (with escapes)
      -- as one green chunk so nothing inside gets recolored or concealed.
      if q > i then
        out[#out + 1] = { text:sub(i, q - 1), 'Normal' }
      end
      local j = q + 1
      while j <= n do
        local c = text:sub(j, j)
        if c == '\\' then
          j = j + 2
        elseif c == '"' then
          j = j + 1
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = { text:sub(q, j - 1), 'DansString' }
      i = j
    elseif s then
      if s > i then
        out[#out + 1] = { text:sub(i, s - 1), 'Normal' }
      end
      local word = text:sub(s, e)
      if text:sub(e + 1, e + 2) == '::' then
        -- Namespace qualifier: hide std::/dans:: and gray the rest.
        if word ~= 'std' and word ~= 'dans' then
          out[#out + 1] = { word .. '::', 'DansNamespace' }
        end
        i = e + 3
      else
        local alias = expr_aliases()[word]
        if alias then
          out[#out + 1] = { alias[1], alias[2] }
        elseif word:match '^Vk' or word:match '^VK_' or word:match '^vk%u' then
          out[#out + 1] = { word, 'DansVulkan' } -- Vk*/VK_*/vk*, matches cpp_markers
        elseif word:match '^SDL_' then
          out[#out + 1] = { word, 'DansSDL' }
        elseif word:match '^[A-Z][A-Z0-9_]+$' then
          out[#out + 1] = { word, 'DansMacro' } -- other all-caps macro
        else
          out[#out + 1] = { word, EXPR_MARKERS[word] or 'Normal' }
        end
        i = e + 1
      end
    else
      out[#out + 1] = { text:sub(i), 'Normal' }
      break
    end
  end
  return out
end

-- Whether all (), [], {} on the line are closed. An unbalanced line is the
-- opener of a multi-line statement (e.g. `const auto x = foo(`), not a complete
-- declaration, so it must render raw.
local function is_balanced(s)
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
local function parse_lambda(expr)
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

-- Highlight for a type in declaration position: Vulkan types (Vk*/VK_*) keep
-- their purple even here, so a type doesn't flip blue<->purple as the cursor
-- enters/leaves its line; everything else is the blue inlay-type color.
local function type_hl(t)
  if t:match '^Vk' or t:match '^VK_' then
    return 'DansVulkan'
  end
  if t:match '^SDL_' then
    return 'DansSDL'
  end
  return 'DansInlayType'
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
local function parse_for(core)
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
  return { is_const = is_const, sigil = sigil, name = vim.trim(name), iter = iter, tail = tail }
end

-- Render pointer-type `*` as `^` (type positions only). `&` is left alone.
local function ptr(s)
  return POINTER_CARET and (s:gsub('%*', '^')) or s
end

-- Strip the parts of a type the view hides: leading constexpr/inline and the
-- std::/dans:: qualifiers, and render pointer `*` as `^`. Shared by build_chunks
-- and the alignment pass (so column widths match).
local function strip_type(typ)
  return ptr((typ:gsub('^constexpr%s+', ''):gsub('^inline%s+', ''):gsub('std::', ''):gsub('dans::', '')))
end

-- For an explicit-type brace declaration (`T name{init}`), return the rendered
-- name and type strings, else nil. Mirrors build_chunks' explicit branch so the
-- alignment pass measures exactly what gets rendered.
local function field_dims(line)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  local code = body:match '^(.-)%s*//.*$' or body
  local had_semi = code:match ';%s*$' ~= nil
  local _, core = split_markers((code:gsub(';%s*$', '')))
  local typ, nm = core:match '^(.-)%s+([%w_]+)%s*{.*}$'
  if not (nm and had_semi and looks_like_type(typ)) then
    -- no-brace reference/pointer member: `T& name` / `T* name`
    typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
    if not (typ and nm and had_semi and looks_like_type(typ)) then
      return nil
    end
  end
  return nm, strip_type(typ)
end

-- Map row0 -> { nw, tw } so a run of consecutive explicit-type brace
-- declarations aligns its `:` (after the name) and `=`/`;` (after the type).
-- Singleton runs get no entry (nothing to align).
local function compute_align(lines, offset)
  offset = offset or 0
  local map = {}
  local i, n = 1, #lines
  while i <= n do
    local block = {}
    while i <= n do
      local nm, ty = field_dims(lines[i])
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
local function decl_kind(bufnr, row0)
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
local function is_iife(bufnr, row0)
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

-- Build the virt_text chunk list for a parsed declaration, or nil if `core`
-- isn't a recognized declaration form. `align` (optional) is { nw, tw } column
-- widths to pad the name/type to. `was_const` + (bufnr,row0) drive the inferred
-- `mut` on non-const locals.
local function build_chunks(prefix, core, had_semi, type_hint, align, was_const, bufnr, row0)
  local semi = had_semi and ';' or ''
  -- Lazy (treesitter): only the branches that infer mut pay for it, and only on
  -- lines that actually render (non-decls return before reaching a branch).
  local _local
  local function is_local()
    if _local == nil then
      _local = decl_kind(bufnr, row0) == 'local'
    end
    return _local
  end

  local forp = parse_for(core)

  -- structured binding: auto [a, b] = expr  ->  [a, b] := expr (no per-element
  -- type hints; clangd's binding hints aren't reliable enough).
  local sb_sigil, sb_binds, sb_expr = core:match '^auto([&*]?)%s*%[(.-)%]%s*=%s*(.+)$'

  local sigil, name, expr = core:match '^auto([&*]?)%s+([%w_]+)%s*=%s*(.+)$'
  local typ, nm, init
  if not forp and not sb_binds and not name then
    typ, nm, init = core:match '^(.-)%s+([%w_]+)%s*{(.*)}$'
    -- A brace-init declaration is a terminated statement; require the `;`.
    -- Without it this is a continuation / constructor temporary in an argument
    -- list (e.g. `local_ray, Aabb{.min = a}`), where `local_ray,` is not a type.
    if not (nm and had_semi and looks_like_type(typ)) then
      -- No-brace reference/pointer member: `T& name` / `T* name` (a struct
      -- reference can't be brace-defaulted). The sigil must touch the type, so
      -- bitwise/multiply statements like `a & b;` aren't grabbed.
      typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
      init = ''
      if not (typ and nm and had_semi and looks_like_type(typ)) then
        return nil
      end
    end
  end

  local chunks = {}
  local function add(text, hl)
    if text ~= '' then
      chunks[#chunks + 1] = { text, hl or 'Normal' }
    end
  end
  -- Append value text, coloring marker keywords inside it.
  local function add_value(text)
    for _, c in ipairs(colorize(text)) do
      chunks[#chunks + 1] = c
    end
  end
  -- Append a type, graying each `^` pointer marker (DansPointer) while the rest
  -- keeps its type color. type_hl keys off the leading token (Vk*/SDL_*/...), so
  -- compute it once on the whole string and reuse it for the non-`^` segments.
  local function add_type(typ)
    local hl = type_hl(typ)
    local i = 1
    while true do
      local c = typ:find('%^', i)
      if not c then
        add(typ:sub(i), hl)
        break
      end
      add(typ:sub(i, c - 1), hl)
      add('^', 'DansPointer')
      i = c + 1
    end
  end

  -- dev::Defer _{[cap] { body }}  ->  Jai-style `defer body`: a scope-exit guard
  -- where the Defer type, throwaway name, capture, and wrapping braces are all
  -- ceremony. One statement renders inline (`defer f();`); several keep a block
  -- (`defer { a(); b(); }`). Matched before the generic explicit-type branch.
  do
    local dtyp, dinit = core:match '^([%w_:]+)%s+[%w_]+%s*(%b{})$'
    if dtyp and had_semi and (dtyp == 'Defer' or dtyp:match '::Defer$') then
      local inner = dinit:sub(2, -2)
      local body = inner:match '^%s*%b[]%s*{(.*)}%s*$' or inner:match '^%s*%b[]%s*%b()%s*{(.*)}%s*$'
      if body then
        body = vim.trim(body)
        add('defer ', 'DansLambda')
        if body:gsub(';%s*$', ''):find ';' then
          add '{ '
          add_value(body)
          add ' }'
        else
          add_value(body)
        end
        return chunks
      end
    end
  end

  if prefix ~= '' then
    add(prefix, MARKER_HL[prefix:match '^(%S+)'] or 'Normal')
  end

  if forp then
    add 'for ('
    if not forp.is_const then
      add('mut ', 'DansMarkerMut')
    end
    if FOR_REF_SUFFIX then
      add(forp.name)
      add(ptr(forp.sigil))
    else
      add(ptr(forp.sigil))
      add(forp.name)
    end
    add ' : '
    add_value(forp.iter)
    add ')'
    if forp.tail ~= '' then
      add(' ' .. forp.tail)
    end
  elseif sb_binds then
    if not is_balanced(sb_expr) then
      return nil
    end
    if is_local() and not was_const then
      add('mut ', 'DansMarkerMut')
    end
    if sb_sigil == '&' then
      add('ref ', 'DansRef')
    end
    add('[' .. sb_binds .. '] := ')
    add_value(sb_expr)
    add(semi)
  elseif name then
    local cap, params, rest = parse_lambda(expr)
    if lambda_render and cap ~= nil and is_iife(bufnr, row0) then
      -- IIFE: `auto x = [&]() -> T {...}()`. x is the *result* (type T), not a
      -- lambda. Render the multi-line intro as `x: T =` (body + }(); stay raw).
      -- Single-line/deduced-return IIFEs have their body on this line, so leave
      -- them raw rather than truncate.
      local rettype = rest and rest:match '^%->%s*(.+)$'
      if not rettype then
        return nil
      end
      if is_local() and not was_const then
        add('mut ', 'DansMarkerMut')
      end
      add(name .. ': ')
      local rt = strip_type(rettype)
      add_type(rt)
      add ' ='
    elseif lambda_render and cap ~= nil then
      local has_cap = cap ~= ''
      local has_params = params ~= nil and params ~= ''
      add(LAMBDA_KEYWORD .. ' ', 'DansLambda')
      add(name)
      add '('
      if has_cap then
        add_value(cap)
      end
      if has_params then
        -- ` : ` after a capture, `: ` without one (no leading space).
        add(has_cap and (' ' .. LAMBDA_CAP_SEP .. ' ') or (LAMBDA_CAP_SEP .. ' '))
        add_value(params)
      end
      add ')'
      if rest ~= nil and rest ~= '' then
        add ' '
        add_value(rest)
      end
      add(semi)
    elseif not is_balanced(expr) then
      return nil -- incomplete RHS (multi-line opener), leave raw
    else
      -- non-const local -> inferred mut (prefix; auto-forms aren't in alignment
      -- blocks so this doesn't shift any aligned column).
      if is_local() and not was_const then
        add('mut ', 'DansMarkerMut')
      end
      if type_hint and name ~= '_' then
        add(name .. ': ')
        add_type(ptr(type_hint))
        add ' = '
        add_value(expr)
        add(semi)
      else
        -- Reference binding: `ref` marker (Rust `ref`/`ref mut`) instead of
        -- gluing `&` to the value, where it would read as address-of the first
        -- operand on a compound RHS. `mut` (added above) precedes it: `mut ref`.
        if sigil == '&' then
          add('ref ', 'DansRef')
        end
        add(name .. ' := ')
        add_value(expr)
        add(semi)
      end
    end
  else
    -- Explicit type: colored the same blue as the deduced hints (DansInlayType);
    -- written and deduced types are treated alike. std:: stripped. `constexpr`
    -- becomes JAI's constant binding -- `name: T : value` (a `:` in place of the
    -- `=`), since `::` / `: T :` is how JAI spells a compile-time constant.
    local is_constexpr = typ:match '^constexpr%s+' ~= nil
    local shown_typ = strip_type(typ)
    add(nm)
    if align then
      add(string.rep(' ', math.max(0, align.nw - vim.fn.strwidth(nm))))
    end
    add ': '
    -- Pointers/references carry meaningful constness, so always mark it: `const`
    -- (grayed) for a const pointee/referent, `mut` otherwise. Plain value types
    -- keep the const-hidden default and only get `mut` on a non-const local
    -- (value members/globals aren't marked -- would be noise). constexpr counts
    -- as const. Placed after the colon like `-> mut T&` so names stay aligned.
    if shown_typ:find('[%^&]') then
      if was_const then
        add('const ', 'DansConst')
      elseif not is_constexpr then
        add('mut ', 'DansMarkerMut')
      end
    elseif not was_const and not is_constexpr and is_local() then
      add('mut ', 'DansMarkerMut')
    end
    add_type(shown_typ)
    if init ~= '' then
      -- Pad the type only when there's an initializer, so the `=` aligns across
      -- the block; a no-init line's `;` stays at its natural end position.
      if align then
        add(string.rep(' ', math.max(0, align.tw - vim.fn.strwidth(shown_typ))))
      end
      add(is_constexpr and ' : ' or ' = ')
      add_value(init)
    end
    add(semi)
  end

  return chunks
end

-- Returns (start_col, chunks) for the overlay, or nil if the line isn't a
-- transformable declaration. `type_hint` is the deduced type for this line.
local function render_line(line, type_hint, align, bufnr, row0)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  -- Peel a trailing line comment so it doesn't defeat the `;` / `}` end anchors
  -- in build_chunks; it's re-appended to the overlay so it stays visible.
  local code, cws, comment = body:match '^(.-)(%s*)(//.*)$'
  if not code then
    code, cws, comment = body, '', ''
  end
  local had_semi = code:match ';%s*$' ~= nil
  local core_in = (code:gsub(';%s*$', ''))
  -- const or constexpr (both hidden, both suppress the inferred mut).
  local was_const = (core_in:match '^const%f[%A]' or core_in:match '^constexpr%f[%A]') ~= nil
  local prefix, core = split_markers(core_in)
  local chunks = build_chunks(prefix, core, had_semi, type_hint, align, was_const, bufnr, row0)
  if not chunks then
    return nil
  end
  if comment ~= '' then
    chunks[#chunks + 1] = { cws .. comment, 'Comment' }
  end
  return #indent, chunks
end

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function cursor_row0(bufnr)
  if bufnr == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
end

local function type_for(bufnr, row0)
  if not show_hints then
    return nil
  end
  local m = hint_type[bufnr]
  return m and m[row0] or nil
end

-- Set of rows to show raw (no overlay): the cursor line, or the whole visual
-- selection while in a visual mode. Reveal is cursor/selection driven.
local function reveal_set(bufnr)
  local cur = cursor_row0(bufnr)
  if cur == nil then
    return {}
  end
  local m = vim.fn.mode():sub(1, 1)
  if m == 'v' or m == 'V' or m == string.char(22) then
    local vstart = vim.fn.getpos('v')[2] - 1
    local lo, hi = math.min(cur, vstart), math.max(cur, vstart)
    local set = {}
    for r = lo, hi do
      set[r] = true
    end
    return set
  end
  return { [cur] = true }
end

-- Only the on-screen lines (+ margin) are overlaid, so a big file isn't
-- re-rendered whole on every edit / scroll / cursor move (was ~52 ms per
-- keystroke on a 5700-line file). Off-screen overlays aren't visible; they're
-- (re)placed as lines scroll in (WinScrolled). Reveal (cursor line raw) falls
-- out of recomputing reveal_set each refresh.
local VISIBLE_MARGIN = 40
local function visible_range(bufnr)
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return 0, vim.api.nvim_buf_line_count(bufnr)
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  return math.max(0, vim.fn.line 'w0' - 1 - VISIBLE_MARGIN), math.min(n, vim.fn.line 'w$' + VISIBLE_MARGIN)
end

local function refresh(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  clear(bufnr)
  local set = reveal_set(bufnr)
  local s0, e0 = visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  local align = compute_align(lines, s0)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    if not set[row0] then
      local start_col, chunks = render_line(line, type_for(bufnr, row0), align[row0], bufnr, row0)
      if start_col then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, start_col, {
          end_col = #line,
          conceal = '',
          virt_text = chunks,
          virt_text_pos = 'overlay',
        })
      end
    end
  end
end

-- Request Type inlay hints from clangd directly (not the built-in renderer, so
-- nothing renders at end-of-line), cache the deduced type per row, re-render.
local function fetch_hints(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local clients = vim.lsp.get_clients { bufnr = bufnr, method = 'textDocument/inlayHint' }
  if #clients == 0 then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = 0, character = 0 },
      ['end'] = { line = math.max(0, n - 1), character = 0 },
    },
  }
  vim.lsp.buf_request_all(bufnr, 'textDocument/inlayHint', params, function(results)
    if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    -- Keep only the leftmost Type hint per line: that's the declarator's type,
    -- not e.g. a lambda's return-type hint placed further right on the line.
    local per_line = {}
    for _, res in pairs(results or {}) do
      for _, hint in ipairs((res or {}).result or {}) do
        if hint.kind == 1 and hint.position then -- 1 = Type
          local label = hint.label
          if type(label) == 'table' then
            local s = ''
            for _, part in ipairs(label) do
              s = s .. (part.value or '')
            end
            label = s
          end
          local t = tostring(label or ''):gsub('^%s*:%s*', ''):gsub('%s+$', '')
          local line = hint.position.line
          local char = hint.position.character
          if per_line[line] == nil or char < per_line[line].char then
            per_line[line] = { char = char, type = t }
          end
        end
      end
    end
    local map = {}
    for line, info in pairs(per_line) do
      -- const is the hidden default and std::/dans:: are hidden everywhere; drop
      -- them from the deduced type so it matches the rest of the view.
      local t = info.type:gsub('^const%s+', ''):gsub('std::', ''):gsub('dans::', '')
      -- Lambdas render as "(lambda at ...)" — useless noise; the lambda is
      -- written inline, so show no type (matches how functions read).
      if t ~= '' and not t:find('lambda', 1, true) then
        map[line] = t
      end
    end
    hint_type[bufnr] = map
    refresh(bufnr)
  end)
end

local function enable(bufnr)
  enabled[bufnr] = true
  vim.opt_local.conceallevel = 2
  -- Empty: cursor line is raw WYSIWYG, driven by cursor position not mode.
  vim.opt_local.concealcursor = ''
  refresh(bufnr)
  fetch_hints(bufnr)
end

local function disable(bufnr)
  enabled[bufnr] = nil
  hint_type[bufnr] = nil
  clear(bufnr)
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if enabled[bufnr] then
    disable(bufnr)
  else
    enable(bufnr)
  end
end

-- Toggle the deduced-type inlay hints (global) while keeping the jai overlay.
function M.toggle_hints()
  show_hints = not show_hints
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('JAI type hints ' .. (show_hints and 'on' or 'off'), vim.log.levels.INFO)
end

-- Toggle the experimental lambda-as-function rendering (global).
function M.toggle_lambda()
  lambda_render = not lambda_render
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('JAI lambda view ' .. (lambda_render and 'on' or 'off'), vim.log.levels.INFO)
end

-- Whether the JAI overlay is currently active for this buffer.
function M.is_enabled(bufnr)
  return enabled[bufnr] == true
end

-- Whether a line is one the overlay rewrites. Lets other view modules
-- (cpp_aliases) defer so they don't double-render on top of the full-line
-- overlay (which orphans their inline virt_text to the end of the line).
function M.covers(line)
  return (render_line(line, nil)) ~= nil
end

function M.setup()
  vim.api.nvim_create_user_command('JaiView', M.toggle, { desc = 'Toggle JAI-style declaration view' })
  vim.api.nvim_create_user_command('InlineHints', M.toggle_hints, { desc = 'Toggle deduced-type inline hints' })
  vim.api.nvim_create_user_command('LambdaView', M.toggle_lambda, { desc = 'Toggle lambda-as-function rendering' })

  local group = vim.api.nvim_create_augroup('ds_jai_view', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      enable(ev.buf)
    end,
  })
  -- One visible-range refresh for everything: edits, scrolling (WinScrolled),
  -- and the cursor/selection reveal (CursorMoved / ModeChanged recompute
  -- reveal_set). Cheap because it only touches on-screen lines.
  vim.api.nvim_create_autocmd(
    { 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI', 'ModeChanged', 'WinScrolled' },
    {
      group = group,
      callback = function(ev)
        refresh(ev.buf)
      end,
    }
  )
  -- Refresh deduced types: BufEnter/InsertLeave plus CursorHold (a natural
  -- debounce for the async clangd response after edits).
  vim.api.nvim_create_autocmd({ 'BufEnter', 'InsertLeave', 'CursorHold' }, {
    group = group,
    callback = function(ev)
      fetch_hints(ev.buf)
    end,
  })
end

return M
