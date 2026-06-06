-- Chunk building for the dans-cpp-frontend declaration view: turn a parsed declaration line
-- into the list of { text, highlight } pieces the overlay draws. Depends on
-- parse for the structural analysis; holds the render-side config (the
-- lambda-as-function rendering toggle and the cosmetic separators).

local P = require 'custom.dans_frontend_cpp.parse'

local M = {}

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

-- Marker word -> highlight group, shared with markers.lua. Only `cpy` can
-- still appear as a real prefix (mut/mut_unchecked are source-removed), but the
-- mut entries stay so an inferred-mut prefix colors correctly.
local MARKER_HL = {
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
  cpy = 'DansMarkerCpy',
}

-- Marker keywords that should pop wherever they appear in an expression
-- (e.g. `copy(x)` in a value), so the overlay matches the matchadd coloring on
-- real text.
local EXPR_MARKERS = {
  copy = 'DansMarkerCpy',
  cpy = 'DansMarkerCpy',
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
}

-- All-caps stdlib tokens that aren't user macros worth coloring -- left normal.
local MACRO_DENY = { FILE = true, SEEK_SET = true, SEEK_CUR = true, SEEK_END = true, EOF = true, NULL = true }

-- Single-word C++ aliases ($sc, $dc, ...) reused from aliases so casts in
-- frontend-rendered value expressions read the same as on non-overlaid lines. This
-- overlay conceals the whole source line, so aliases defers here (its inline
-- alias would be orphaned); without this the casts rendered verbatim. Built
-- lazily and cached from aliases.ALIASES, keeping only identifier-shaped
-- keywords (`[[nodiscard]]` is dropped -- it can't occur inside a value).
local expr_aliases_cache = nil
local function expr_aliases()
  if expr_aliases_cache then
    return expr_aliases_cache
  end
  local map = {}
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
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

-- Index of the `>` matching the `<` at 1-based `open` (nested `<>` balanced), or
-- nil. Used to bound a cast's template args.
local function match_angle(s, open)
  local depth = 0
  for j = open, #s do
    local c = s:sub(j, j)
    if c == '<' then
      depth = depth + 1
    elseif c == '>' then
      depth = depth - 1
      if depth == 0 then
        return j
      end
    end
  end
  return nil
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
        if word == 'std' or word == 'dans' then
          -- std::/dans:: hidden; std::move / std::forward keep a red flag (the
          -- ownership-transfer points -- the source is left moved-from).
          local mv = word == 'std' and (text:match('^move%f[%W]', e + 3) or text:match('^forward%f[%W]', e + 3))
          if mv then
            out[#out + 1] = { mv, 'DansMarkerMut' }
            i = e + 3 + #mv
          else
            i = e + 3
            if word == 'std' then
              -- swallow std::ranges:: / std::ranges::views:: / std::views:: too,
              -- so ranges algorithms / views render at their bare name (matches
              -- the matchadd conceals on raw lines).
              while true do
                local seg = text:sub(i)
                local q2 = seg:match '^ranges::' or seg:match '^views::'
                if not q2 then
                  break
                end
                i = i + #q2
              end
            end
          end
        elseif word:match '^LLDB_' or word:match '^SB%u' or word == 'StateType' then
          -- LLDB class used as a qualifier (SBTarget::...): keep the class orange.
          out[#out + 1] = { word, 'DansLLDB' }
          out[#out + 1] = { '::', 'DansNamespace' }
          i = e + 3
        else
          -- Other namespace qualifier: gray it.
          out[#out + 1] = { word .. '::', 'DansNamespace' }
          i = e + 3
        end
      else
        local alias = expr_aliases()[word]
        if alias then
          out[#out + 1] = { alias[1], alias[2] }
        elseif word:match '^Vk' or word:match '^VK_' or word:match '^vk%u' then
          out[#out + 1] = { word, 'DansVulkan' } -- Vk*/VK_*/vk*, matches markers
        elseif word:match '^SDL_' or word:match '^GLFW' or word:match '^glfw%u' then
          out[#out + 1] = { word, 'DansSDL' } -- SDL_*/GLFW*/glfw*, matches markers
        elseif word:match '^LLDB_' or word:match '^SB%u' or word == 'StateType' then
          out[#out + 1] = { word, 'DansLLDB' } -- LLDB_*/SB*/StateType, matches markers
        elseif word:match '^[A-Z][A-Z0-9_]+$' and not MACRO_DENY[word] then
          out[#out + 1] = { word, 'DansMacro' } -- other all-caps macro
        else
          out[#out + 1] = { word, EXPR_MARKERS[word] or 'Normal' }
        end
        i = e + 1
        -- A cast's template args are a type, so every `*` inside is a pointer:
        -- emit it as a grayed `^`. The value path is otherwise blind to
        -- pointer-vs-multiply, but inside `_cast<...>` it's unambiguous.
        if alias and word:match '_cast$' and text:sub(i, i) == '<' then
          local close = match_angle(text, i)
          if close then
            out[#out + 1] = { '<', 'Normal' }
            local inner, pos = text:sub(i + 1, close - 1), 1
            while true do
              local star = inner:find('*', pos, true)
              if not star then
                vim.list_extend(out, colorize(inner:sub(pos)))
                break
              end
              if star > pos then
                vim.list_extend(out, colorize(inner:sub(pos, star - 1)))
              end
              out[#out + 1] = { '^', 'Normal' }
              pos = star + 1
            end
            out[#out + 1] = { '>', 'Normal' }
            i = close + 1
          end
        end
      end
    else
      out[#out + 1] = { text:sub(i), 'Normal' }
      break
    end
  end
  return out
end

-- Whether the type has a pointer/reference declarator at top level (`Foo^`,
-- `Foo&`), as opposed to a `^`/`&` buried in template args (`pair<int&, V>`,
-- `function<void(int&)>`) which does NOT make the variable a pointer/reference.
-- Drives the const/mut marking on the type, so it must not be fooled by nesting.
local function top_level_ptr_ref(t)
  local depth = 0
  for i = 1, #t do
    local c = t:sub(i, i)
    if c == '<' or c == '(' or c == '[' then
      depth = depth + 1
    elseif c == '>' or c == ')' or c == ']' then
      depth = depth - 1
    elseif (c == '^' or c == '&') and depth == 0 then
      return true
    end
  end
  return false
end

-- Highlight for a type in declaration position: Vulkan types (Vk*/VK_*) keep
-- their purple even here, so a type doesn't flip blue<->purple as the cursor
-- enters/leaves its line; everything else is the blue inlay-type color.
local function type_hl(t)
  if t:match '^Vk' or t:match '^VK_' then
    return 'DansVulkan'
  end
  if t:match '^SDL_' or t:match '^GLFW' then
    return 'DansSDL'
  end
  if t:match '^LLDB_' or t:match '^SB%u' or t == 'StateType' then
    return 'DansLLDB'
  end
  return 'DansInlayType'
end

-- Render a type string into { text, hl } chunks for virt_text *outside* the
-- overlay (the trailing-return reorder): strip_type cleans it (std::/dans::,
-- optional->?, *->^), the caret stays Normal/gray like add_type, and type_hl
-- colors the rest. Exposed for the pointer module.
function M.type_chunks(t)
  local shown = P.strip_type(t)
  local hl = type_hl(shown)
  local out, i = {}, 1
  while true do
    local c = shown:find('%^', i)
    if not c then
      if i <= #shown then
        out[#out + 1] = { shown:sub(i), hl }
      end
      break
    end
    if c > i then
      out[#out + 1] = { shown:sub(i, c - 1), hl }
    end
    out[#out + 1] = { '^', 'Normal' }
    i = c + 1
  end
  return out
end

-- Build the virt_text chunk list for a parsed declaration, or nil if `core`
-- isn't a recognized declaration form. `align` (optional) is { nw, tw } column
-- widths to pad the name/type to. `was_const` + (bufnr,row0) drive the inferred
-- `mut` on non-const locals.
local function build_chunks(prefix, core, had_semi, type_hint, align, was_const, is_constexpr, bufnr, row0)
  -- Classic (non-trailing) function declarations are reordered to trailing form
  -- by the pointer module's decoration pass, not overlaid -- bail so they aren't
  -- mangled as a `name: T(args)` paren-init variable.
  if P.classic_function(bufnr, row0) then
    return nil
  end
  local semi = had_semi and ';' or ''
  -- Lazy (treesitter): only the branches that infer mut pay for it, and only on
  -- lines that actually render (non-decls return before reaching a branch).
  local _local
  local function is_local()
    if _local == nil then
      _local = P.decl_kind(bufnr, row0) == 'local'
    end
    return _local
  end

  local forp = P.parse_for(core)
  local iflet = P.parse_if_let(core)

  -- structured binding: auto [a, b] = expr  ->  a, b := expr (no per-element
  -- type hints; clangd's binding hints aren't reliable enough).
  local sb_sigil, sb_binds, sb_expr = core:match '^auto([&*]?)%s*%[(.-)%]%s*=%s*(.+)$'

  local sigil, name, expr = core:match '^auto([&*]?)%s+([%w_]+)%s*=%s*(.+)$'
  local typ, nm, init, paren
  if not forp and not iflet and not sb_binds and not name then
    typ, nm, init = core:match '^(.-)%s+([%w_]+)%s*{(.*)}$'
    -- A brace-init declaration is a terminated statement; require the `;`.
    -- Without it this is a continuation / constructor temporary in an argument
    -- list (e.g. `local_ray, Aabb{.min = a}`), where `local_ray,` is not a type.
    if not (nm and had_semi and P.looks_like_type(typ)) then
      -- paren-init `T name(args)` (ctor call), kept as `name: T(args)` since paren
      -- and brace init differ in meaning. The most-vexing-parse (function decl vs
      -- variable) is semantic, so only accept args that look like a value.
      local ptyp, pnm, pargs = core:match '^(.-)%s+([%w_]+)%s*%((.+)%)$'
      if ptyp and pnm and had_semi and P.looks_like_type(ptyp) and (pargs:find('[%.%d(]') or pargs:find('::')) then
        typ, nm, init, paren = ptyp, pnm, nil, pargs
      else
        -- No-brace reference/pointer member: `T& name` / `T* name` (a struct
        -- reference can't be brace-defaulted). The sigil must touch the type, so
        -- bitwise/multiply statements like `a & b;` aren't grabbed.
        typ, nm = core:match '^(.-[%w_>][&*]+)%s*([%w_]+)$'
        init = ''
        if not (typ and nm and had_semi and P.looks_like_type(typ)) then
          return nil
        end
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
  local function add_type(t)
    local hl = type_hl(t)
    local i = 1
    while true do
      local c = t:find('%^', i)
      if not c then
        add(t:sub(i), hl)
        break
      end
      add(t:sub(i, c - 1), hl)
      add('^', 'Normal')
      i = c + 1
    end
  end

  -- dev::Defer _{[cap] { body }}  ->  Odin-style `defer body`: a scope-exit guard
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

  if iflet then
    -- if (const auto x = e; COND)  ->  if let x := e[; COND]. A bare truthiness
    -- check (COND == x) is dropped; a real test (`x == 0`) is kept after `;`.
    add 'if let '
    add(iflet.name)
    add ' := '
    add_value(iflet.rhs)
    if iflet.cond ~= iflet.name then
      add '; '
      add_value(iflet.cond)
    end
    if iflet.tail ~= '' then
      add(' ' .. iflet.tail)
    end
  elseif forp then
    add 'for ('
    if not forp.is_const then
      add('mut ', 'DansMarkerMut')
    end
    if FOR_REF_SUFFIX then
      add(forp.name)
      add(P.ptr(forp.sigil))
    else
      add(P.ptr(forp.sigil))
      add(forp.name)
    end
    add ' : '
    add_value(forp.iter)
    add ')'
    if forp.tail ~= '' then
      add(' ' .. forp.tail)
    end
  elseif sb_binds then
    if not P.is_balanced(sb_expr) then
      return nil
    end
    if is_local() and not was_const then
      add('mut ', 'DansMarkerMut')
    end
    add(sb_binds)
    if sb_sigil == '&' then
      add('&')
    end
    add(' := ')
    add_value(sb_expr)
    add(semi)
  elseif name then
    local cap, params, rest = P.parse_lambda(expr)
    if lambda_render and cap ~= nil and P.is_iife(bufnr, row0) then
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
      add_type(P.strip_type(rettype))
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
    elseif not P.is_balanced(expr) then
      return nil -- incomplete RHS (multi-line opener), leave raw
    else
      -- non-const local -> inferred mut (prefix; auto-forms aren't in alignment
      -- blocks so this doesn't shift any aligned column).
      if is_local() and not was_const then
        add('mut ', 'DansMarkerMut')
      end
      if type_hint and name ~= '_' then
        add(name .. ': ')
        add_type(P.ptr(type_hint))
        add ' = '
        add_value(expr)
        add(semi)
      else
        -- Reference binding: a `&` suffix on the name (matches the range-for
        -- `v&` style) rather than a `ref` keyword or gluing `&` to the value.
        add(name)
        if sigil == '&' then
          add('&')
        end
        add(' := ')
        add_value(expr)
        add(semi)
      end
    end
  else
    -- Explicit type: colored the same blue as the deduced hints (DansInlayType);
    -- written and deduced types are treated alike. std:: stripped. `constexpr`
    -- becomes Odin's constant binding -- `name: T : value` (a `:` in place of the
    -- `=`), since `::` / `: T :` is how frontend spells a compile-time constant.
    local shown_typ = P.strip_type(typ)
    local sp_inner, sp_kind = P.smart_ptr(shown_typ)
    local disp_typ = sp_inner and (sp_inner .. '^') or shown_typ
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
    if sp_inner then
      -- smart pointer: `T^` with the caret colored by ownership (unique = mut red,
      -- shared = cpy yellow); a raw pointer's caret stays normal text.
      add_type(sp_inner)
      add('^', sp_kind == 'unique' and 'DansMarkerMut' or 'DansMarkerCpy')
    else
      if top_level_ptr_ref(shown_typ) then
        if was_const then
          add('const ', 'Normal')
        elseif not is_constexpr then
          add('mut ', 'DansMarkerMut')
        end
      elseif not was_const and not is_constexpr and is_local() then
        add('mut ', 'DansMarkerMut')
      end
      add_type(shown_typ)
    end
    if paren then
      -- paren-init `T name(args)`: keep the parens (ctor call, not assignment).
      add '('
      add_value(paren)
      add ')'
    elseif init ~= '' then
      -- Pad the type only when there's an initializer, so the `=` aligns across
      -- the block; a no-init line's `;` stays at its natural end position.
      if align then
        add(string.rep(' ', math.max(0, align.tw - vim.fn.strwidth(disp_typ))))
      end
      add(is_constexpr and ' : ' or ' = ')
      local dpairs = P.designated_pairs(init)
      if dpairs then
        -- aggregate designated init: fold each `.field = value` like cpp_designated
        -- does on raw lines -- `field=value`, or just `field` when the value's last
        -- access already matches the field (`.center = cfg.center` -> `center`).
        for i, p in ipairs(dpairs) do
          if i > 1 then
            add ', '
          end
          add(p.field, 'DansHint')
          if P.access_tail(p.value) ~= p.field then
            add '='
            add_value(p.value)
          end
        end
      else
        add_value(init)
      end
    end
    add(semi)
  end

  return chunks
end

-- Returns (start_col, chunks) for the overlay, or nil if the line isn't a
-- transformable declaration. `type_hint` is the deduced type for this line.
function M.render_line(line, type_hint, align, bufnr, row0)
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
  -- split_markers peels and reports const/constexpr (both hidden; const-ness
  -- suppresses the inferred mut, constexpr also renders as a `:` constant binding).
  local prefix, core, was_const, is_constexpr = P.split_markers(core_in)
  local chunks = build_chunks(prefix, core, had_semi, type_hint, align, was_const, is_constexpr, bufnr, row0)
  if not chunks then
    return nil
  end
  if comment ~= '' then
    chunks[#chunks + 1] = { cws .. comment, 'Comment' }
  end
  return #indent, chunks
end

-- Flip the lambda-as-function rendering; returns the new state. view owns
-- the user command and re-renders open buffers.
function M.toggle_lambda()
  lambda_render = not lambda_render
  return lambda_render
end

return M
