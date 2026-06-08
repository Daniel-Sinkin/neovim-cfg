-- Render C++ keywords/attributes as short aliases via inline virt_text +
-- concealment. The original text stays in the file (this is purely visual).
-- The `$` prefix signals the rendered form is a shorthand, not real C++.
--   static_cast       -> $sc
--   dynamic_cast      -> $dc
--   reinterpret_cast  -> $rc
--   const_cast        -> $cc
--   noexcept          -> $ne
--   [[nodiscard]]     -> $nd
--   static_assert     -> $as
--   VK_NULL_HANDLE    -> nullptr  (in the Vulkan color; a clearer disambiguator than {})

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_aliases'
local vu = require 'custom.dans_frontend_cpp.util'

-- { keyword, replacement, highlight? }  -- highlight defaults to 'Comment'.
local ALIASES = {
  -- casts collapse to the long $Xcast form (the obfuscated view); both $sc and
  -- $scast expand back to static_cast (the short forms are expand-only atoms in
  -- cpp_type_snippets). dynamic_cast keeps $dc (no $dcast requested).
  { 'static_cast', '$scast' },
  { 'dynamic_cast', '$dc' },
  { 'reinterpret_cast', '$rcast' },
  { 'const_cast', '$ccast' },
  { 'noexcept', '$ne' },
  { '[[nodiscard]]', '$nd' },
  { '[[maybe_unused]]', '' }, -- '' = hidden entirely (incl one trailing space)
  { 'static_assert', '$sa' },
  { 'std::runtime_error', '$re' },
  { 'std::unique_ptr', '$up' },
  { 'std::shared_ptr', '$sp' },
  { 'VK_NULL_HANDLE', 'nullptr', 'DansVulkan' },
}

-- Exposed so arrow_align.lua can mirror these widths when it computes the
-- rendered arrow column (each alias shrinks its keyword to the replacement).
M.ALIASES = ALIASES

local function is_word_char(c)
  return c and c:match '[%w_]' ~= nil
end

-- Whether byte column col0 (0-based) sits inside a "..." string or a // comment,
-- so aliases stay out of non-code text. Naive (ignores raw strings, escaped
-- quotes, char literals), but enough for this.
local function in_string_or_comment(line, col0)
  local cstart = line:find('//', 1, true)
  if cstart and col0 >= cstart - 1 then
    return true
  end
  local i = 1
  while true do
    local s = line:find('"', i)
    if not s then
      return false
    end
    local e = line:find('"', s + 1)
    if not e then
      return false
    end
    if col0 >= s - 1 and col0 < e then
      return true
    end
    i = e + 1
  end
end

-- First balanced (...) group -- the parameter list -- as 1-based open/close byte
-- positions, or nil. Skips the call operator's own `()` (`operator()(args)`) so
-- the args are found, not the empty operator parens; the trailing const after
-- the real `)` is then detected too. (operator[] / operator== have no `(` in the
-- name, so the scan isn't fooled by them.)
local function balanced_parens(line)
  local from = 1
  local _, op_e = line:find 'operator%s*%(%s*%)'
  if op_e then
    from = op_e + 1
  end
  local open = line:find('(', from, true)
  if not open then
    return nil
  end
  local depth = 0
  for i = open, #line do
    local c = line:sub(i, i)
    if c == '(' then
      depth = depth + 1
    elseif c == ')' then
      depth = depth - 1
      if depth == 0 then
        return open, i
      end
    end
  end
  return nil
end

-- Split an arg-list body on top-level commas. Returns { {text, from} } with
-- `from` the 1-based offset of the arg within `s`.
local function split_args(s)
  local args, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '(' or c == '<' or c == '[' or c == '{' then
      depth = depth + 1
    elseif c == ')' or c == '>' or c == ']' or c == '}' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      args[#args + 1] = { text = s:sub(start, i - 1), from = start }
      start = i + 1
    end
  end
  args[#args + 1] = { text = s:sub(start), from = start }
  return args
end

-- ===================== concept / type-trait rendering =====================
-- One mechanism renders a template `Keyword<...>` in a compact `~`-notation. `~`
-- reads as "the concept sigil" (otherwise only destructors / bitwise-not, so it's
-- free) and everything injected here is colored DansConcept. Each row of CONCEPTS
-- is string-matched exactly -- a hardcoded whitelist, no inference. Emit shapes:
--
--   infix  Keyword<A, B>   -> A ~> B / A ~= B   convertible_to, same_as
--   fixed  Keyword<A>      -> A ~> <rhs>        CharLike -> A ~> char (rhs baked)
--   suffix Keyword<A>      -> A<sym>            ValueOf -> A~value, RefOf -> A~&
--   uname  Keyword<A>      -> A~Keyword         input_range<R> -> R~input_range
--   call   Keyword<F, R..> -> F(R..)            invocable / invoke_result_t
--
-- The relation operators ` ~> ` / ` ~= ` are spaced; the postfix ~value / ~& /
-- ~name are tight. A relation is BRACKETED when an operand is itself compound (a
-- nested concept / template, i.e. contains `<`): convertible_to<ValueOf<R>, X> ->
-- (R~value ~> X). Nesting falls out because each occurrence is concealed/injected
-- independently. static_assert lines are skipped wholesale by the caller.
local CONCEPT_HL = 'DansConcept'
-- the std concepts that render as a tight postfix `A~name`.
local UNARY_CONCEPTS = {
  'input_range', 'output_range', 'forward_range', 'bidirectional_range',
  'random_access_range', 'contiguous_range', 'sized_range', 'common_range',
  'viewable_range', 'range', 'view', 'integral', 'signed_integral',
  'unsigned_integral', 'floating_point', 'regular', 'semiregular', 'movable',
  'copyable', 'default_initializable', 'equality_comparable', 'totally_ordered',
}
local CONCEPTS = {
  { kw = 'convertible_to', kind = 'infix', op = '~>' },
  { kw = 'same_as', kind = 'infix', op = '~=' },
  { kw = 'invocable', kind = 'call' }, -- T(S): callable with S
  { kw = 'invoke_result_t', kind = 'call', suffix = '->' }, -- T(S)->: the call's result type
  { kw = 'CharLike', kind = 'fixed', op = '~>', rhs = 'char' },
  { kw = 'BoolLike', kind = 'fixed', op = '~>', rhs = 'bool' },
  { kw = 'IntLike', kind = 'fixed', op = '~>', rhs = 'int' },
  { kw = 'StringLike', kind = 'fixed', op = '~>', rhs = 'string_view' },
  { kw = 'ValueOf', kind = 'suffix', sym = '~value' },
  { kw = 'RefOf', kind = 'suffix', sym = '~&' },
  { kw = 'iter_value_t', kind = 'suffix', sym = '~value' },
  { kw = 'range_value_t', kind = 'suffix', sym = '~value' },
  { kw = 'iter_reference_t', kind = 'suffix', sym = '~&' },
  { kw = 'range_reference_t', kind = 'suffix', sym = '~&' },
}
for _, kw in ipairs(UNARY_CONCEPTS) do
  CONCEPTS[#CONCEPTS + 1] = { kw = kw, kind = 'uname', sym = '~' .. kw }
end

-- the concept keywords with a dedicated spec above -- a user concept by one of
-- these names (unlikely) is left to its special spec, not the generic uname pass.
local STATIC_KW = {}
for _, s in ipairs(CONCEPTS) do
  STATIC_KW[s.kw] = true
end

-- User-defined concept names (`concept NAME = ...`) in the buffer, so a usage
-- `NAME<T>` renders T~NAME like the std unary concepts. Cached per changedtick.
local uc_cache = {}
local function user_concepts(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = uc_cache[bufnr]
  if c and c.tick == tick then
    return c.set
  end
  local set = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local name = line:match '^%s*concept%s+([%w_]+)'
    if name and not STATIC_KW[name] then
      set[name] = true
    end
  end
  uc_cache[bufnr] = { tick = tick, set = set }
  return set
end

local function hide(bufnr, row0, s0, e0)
  if e0 > s0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s0, { end_col = e0, conceal = '' })
  end
end
local function hide_inject(bufnr, row0, s0, e0, text)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s0, {
    end_col = e0,
    conceal = '',
    virt_text = { { text, CONCEPT_HL } },
    virt_text_pos = 'inline',
  })
end

-- 1-based inclusive [start, end] of a trimmed arg within the line. `open` is the
-- 1-based column of the `<`; arg.from is the 1-based offset inside the `<...>` body.
local function arg_span(open, arg)
  local lead = #(arg.text:match '^%s*' or '')
  local s = open + arg.from + lead
  return s, s + #vim.trim(arg.text) - 1
end

-- Find the next `kw<...>` whose `kw` starts at a word boundary and isn't in a
-- string/comment. Returns ms (kw start), open (`<`), close (`>`), args, next-from.
local function find_concept(line, kw, from)
  while true do
    local ms, me = line:find(kw .. '%s*<', from)
    if not ms then
      return nil
    end
    from = me + 1
    local before = ms > 1 and line:sub(ms - 1, ms - 1) or nil
    if not is_word_char(before) and not in_string_or_comment(line, ms - 1) then
      local depth, close = 0, nil
      for i = me, #line do
        local c = line:sub(i, i)
        if c == '<' then
          depth = depth + 1
        elseif c == '>' then
          depth = depth - 1
          if depth == 0 then
            close = i
            break
          end
        end
      end
      if close then
        return ms, me, close, split_args(line:sub(me + 1, close - 1)), from
      end
    end
  end
end

-- A relation is bracketed only when it is NOT at the highest scope: either nested
-- inside another concept's `<...>` (an unbalanced `<` precedes it) or it's one
-- conjunct of an `and`/`or` constraint on the line. A relation that is the whole
-- expression stays unbracketed (`T ~= int`, `T~& ~> char`).
local function depth_before(line, pos)
  local d = 0
  for i = 1, pos - 1 do
    local c = line:sub(i, i)
    if c == '<' then
      d = d + 1
    elseif c == '>' then
      d = d - 1
    end
  end
  return d
end

local function render_concept(bufnr, row0, line, spec, has_conj)
  local from = 1
  while true do
    local ms, open, close, args, nxt = find_concept(line, spec.kw, from)
    if not ms then
      return
    end
    from = nxt
    local kind = spec.kind
    local nested = has_conj or depth_before(line, ms) > 0
    if kind == 'infix' and #args == 2 then
      local a_s, a_e = arg_span(open, args[1])
      local b_s, b_e = arg_span(open, args[2])
      local br = nested
      if br then
        hide_inject(bufnr, row0, ms - 1, a_s - 1, '(')
      else
        hide(bufnr, row0, ms - 1, a_s - 1)
      end
      hide_inject(bufnr, row0, a_e, b_s - 1, ' ' .. spec.op .. ' ')
      if br then
        hide_inject(bufnr, row0, b_e, close, ')')
      else
        hide(bufnr, row0, b_e, close)
      end
    elseif kind == 'fixed' and #args == 1 then
      local a_s, a_e = arg_span(open, args[1])
      local br = nested
      if br then
        hide_inject(bufnr, row0, ms - 1, a_s - 1, '(')
      else
        hide(bufnr, row0, ms - 1, a_s - 1)
      end
      hide_inject(bufnr, row0, a_e, close, ' ' .. spec.op .. ' ' .. spec.rhs .. (br and ')' or ''))
    elseif (kind == 'suffix' or kind == 'uname') and #args == 1 then
      local a_s, a_e = arg_span(open, args[1])
      hide(bufnr, row0, ms - 1, a_s - 1)
      hide_inject(bufnr, row0, a_e, close, spec.sym)
    elseif kind == 'call' and #args >= 1 then
      -- F(args): F kept, parens concept-colored, args keep their own colors.
      local f_s, f_e = arg_span(open, args[1])
      local tail = ')' .. (spec.suffix or '') -- invoke_result_t -> `)->`
      hide(bufnr, row0, ms - 1, f_s - 1)
      if #args == 1 then
        hide_inject(bufnr, row0, f_e, close, '(' .. tail)
      else
        local b_s = arg_span(open, args[2])
        local _, last_e = arg_span(open, args[#args])
        hide_inject(bufnr, row0, f_e, b_s - 1, '(')
        hide_inject(bufnr, row0, last_e, close, tail)
      end
    end
    -- arity mismatch: leave verbatim (no extmarks)
  end
end

local function concepts(bufnr, row0, line)
  -- a line with a top-level `and`/`or` is a constraint conjunction, so every
  -- relation on it is a sub-term and gets bracketed.
  local has_conj = line:match '%f[%a]and%f[%A]' ~= nil or line:match '%f[%a]or%f[%A]' ~= nil
  for _, spec in ipairs(CONCEPTS) do
    render_concept(bufnr, row0, line, spec, has_conj)
  end
  -- user-defined concepts: NAME<T> -> T~NAME (the same unary postfix).
  for name in pairs(user_concepts(bufnr)) do
    render_concept(bufnr, row0, line, { kw = name, kind = 'uname', sym = '~' .. name }, has_conj)
  end
end

-- Template header compaction: `template <typename V>` -> `<V>`, `template
-- <typename T, usize N>` -> `<T, usize N>`. Conceals the `template ` keyword and
-- the `typename`/`class` param kinds. When the next line defines a concept, the
-- header instead reads `concept<...>` (the `concept` keyword is dropped from the
-- def line by concept_def_line below). The introduced param names get the concept
-- color. Scoped to a line opening with `template`, so a dependent `typename T::x`
-- elsewhere is safe.
local function template_header(bufnr, row0, line)
  local indent = line:match '^(%s*)template%s*<'
  if not indent or in_string_or_comment(line, #indent) then
    return
  end
  local lt = line:find('<', #indent + 1, true)
  local depth, close = 0, nil
  for i = lt, #line do
    local c = line:sub(i, i)
    if c == '<' then
      depth = depth + 1
    elseif c == '>' then
      depth = depth - 1
      if depth == 0 then
        close = i
        break
      end
    end
  end
  if not close then
    return
  end
  local nextl = vim.api.nvim_buf_get_lines(bufnr, row0 + 1, row0 + 2, false)[1] or ''
  if nextl:match '^%s*concept%f[%A]' then
    hide_inject(bufnr, row0, #indent, lt - 1, 'concept') -- `template ` -> `concept`
  else
    hide(bufnr, row0, #indent, lt - 1) -- conceal `template ` (keep the `<`)
  end
  for _, kw in ipairs { 'typename', 'class' } do
    local j = lt
    while true do
      local s, e = line:find('%f[%w]' .. kw .. '%s+', j)
      if not s or s > close then
        break
      end
      hide(bufnr, row0, s - 1, e) -- conceal `typename ` / `class `
      j = e + 1
    end
  end
  -- color each introduced param name (the last identifier before a default) in the
  -- concept color, so the template parameters read as parameters.
  for _, arg in ipairs(split_args(line:sub(lt + 1, close - 1))) do
    local atext = arg.text:gsub('%s*=.*$', '')
    local name, name_off
    for off, id in atext:gmatch '()([%a_][%w_]*)' do
      name, name_off = id, off
    end
    if name then
      local col = lt + arg.from + name_off - 2 -- 0-based col of the name
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, col, { end_col = col + #name, hl_group = CONCEPT_HL, priority = 200 })
    end
  end
end

-- A concept definition line whose previous line is a template header: drop the
-- `concept ` keyword (the params moved up into `concept<...>`), so
-- `template <typename T>` / `concept CharLike = ...` reads `concept<T>` /
-- `CharLike = ...`.
local function concept_def_line(bufnr, row0, line)
  if row0 == 0 then
    return
  end
  local indent = line:match '^(%s*)concept%s'
  if not indent then
    return
  end
  local prev = vim.api.nvim_buf_get_lines(bufnr, row0 - 1, row0, false)[1] or ''
  if not prev:match '^%s*template%s*<' then
    return
  end
  local _, e = line:find '^%s*concept%s+'
  hide(bufnr, row0, #indent, e) -- conceal `concept ` (keep the concept name)
end

-- ImGui's assert macros read as their std spelling, grayed like a real assert:
-- IM_STATIC_ASSERT -> static_assert, IM_ASSERT -> assert, IM_ASSERT_USER_ERROR ->
-- assert_user_error. (Strip IM_, lowercase the rest.) Other IM_* keep the bordeaux
-- coloring from markers; only these asserts are reworded.
local function imgui_asserts(bufnr, row0, line)
  local i = 1
  while true do
    local s, e, tok = line:find('(IM_[%u][%u%d_]*)', i)
    if not s then
      return
    end
    i = e + 1
    local before = s > 1 and line:sub(s - 1, s - 1) or nil
    if (tok == 'IM_STATIC_ASSERT' or tok:match '^IM_ASSERT') and not is_word_char(before) and not in_string_or_comment(line, s - 1) then
      local repl = tok:gsub('^IM_', ''):lower()
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
        end_col = e,
        conceal = '',
        virt_text = { { repl, 'DansAssert' } },
        virt_text_pos = 'inline',
      })
    end
  end
end

-- 0-based byte columns where a `mut ` should be injected before a function arg:
-- a non-const *reference* parameter. mut marks a mutable reference; whether a
-- by-value arg is a copy is the user's call via cpy, independent of mut -- so a
-- by-value param never qualifies, even when its default value contains a `*`
-- (`T eps = a * b`) or its type nests `&`/`*` in template args
-- (`std::function<void(int&)>`). Pointers don't get mut either. Only on
-- trailing-return decls (a `->` follows the parens). Exposed for arrow_align.
function M.arg_mut_cols(line)
  local open, close = balanced_parens(line)
  if not open or not line:sub(close + 1):find('->', 1, true) then
    return {}
  end
  -- A top-level `&` in the type (default stripped, template/paren/brace groups
  -- skipped) marks a reference parameter.
  local function is_ref_param(typ)
    local depth = 0
    local i = 1
    while i <= #typ do
      local c = typ:sub(i, i)
      if c == '<' or c == '(' or c == '[' or c == '{' then
        depth = depth + 1
      elseif c == '>' or c == ')' or c == ']' or c == '}' then
        depth = depth - 1
      elseif c == '&' and depth == 0 then
        if typ:sub(i + 1, i + 1) == '&' then
          i = i + 1 -- `&&` is an rvalue ref; mut on an rvalue ref is meaningless, skip
        else
          return true -- single `&`: an lvalue reference parameter
        end
      end
      i = i + 1
    end
    return false
  end
  local cols = {}
  for _, arg in ipairs(split_args(line:sub(open + 1, close - 1))) do
    local lead = #(arg.text:match '^%s*' or '')
    local body = arg.text:sub(lead + 1)
    local typ = body:gsub('%s*=.*$', '') -- drop the default value
    if typ ~= '' and not typ:match '^const%f[%A]' and is_ref_param(typ) then
      cols[#cols + 1] = open + arg.from + lead - 1 -- 0-based column of the arg start
    end
  end
  return cols
end

-- 0-based column right after the param `)` of a NON-const member function (where
-- the trailing `const`/`mut` sits), or nil. Member functions only -- a free
-- function has no receiver const. Needs treesitter to tell a member function
-- from a free one / a data member. Exposed for arrow_align.
function M.member_mut_col(line, bufnr, row0)
  if not bufnr or not row0 then
    return nil
  end
  local open, close = balanced_parens(line)
  if not open then
    return nil
  end
  if line:sub(close):match '^%)%s*const%f[%A]' then
    return nil -- already a const member function
  end
  if line:match '%f[%w]static%f[%A]' then
    return nil -- static member function: no receiver
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, open - 1 } })
  if not ok or not node then
    return nil
  end
  local is_member, is_func = false, false
  while node do
    local t = node:type()
    if t == 'field_declaration' then
      is_member = true
    elseif t == 'function_declarator' then
      is_func = true
    end
    node = node:parent()
  end
  if not (is_member and is_func) then
    return nil
  end
  -- 0-based column right after `)` (close is its 1-based position). Placing the
  -- marker here -- not at the first following token -- keeps it ahead of a
  -- `noexcept` that aliases renders as `$ne` at that token's own column.
  return close
end

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if not vu.is_cpp(ft) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'aliases') then
    return
  end

  -- skip.skip hides our inline aliases on the cursor line (concealcursor shows
  -- the real text there, so the virt_text would otherwise double up like
  -- `$scstatic_cast`), on diagnostic lines, and on lines the view overlay
  -- already rewrites (it would orphan our alias to the end of the line).
  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    if not skip.skip(row0, line) then
      -- concept / type-trait `~`-notation (same_as -> ~=, convertible_to -> ~>,
      -- RefOf/ValueOf/CharLike/..., invocable -> ~(...)). Before the generic loop.
      concepts(bufnr, row0, line)
      -- template headers -> compact `<...>` / `concept<...>` (drop template /
      -- typename / class, color the params); concept def lines drop `concept `.
      template_header(bufnr, row0, line)
      concept_def_line(bufnr, row0, line)
      -- ImGui assert macros -> their std spelling, grayed.
      imgui_asserts(bufnr, row0, line)
      for _, alias in ipairs(ALIASES) do
        local keyword, replacement, hl = alias[1], alias[2], alias[3] or 'Comment'
        local start_pos = 1
        while true do
          local s, e = line:find(keyword, start_pos, true)
          if not s then
            break
          end
          local before = s > 1 and line:sub(s - 1, s - 1) or nil
          local after = e < #line and line:sub(e + 1, e + 1) or nil
          -- the templated static_assert<...> is handled above, not as `$sa`.
          local templated_sa = keyword == 'static_assert' and after == '<'
          if not is_word_char(before) and not is_word_char(after) and not in_string_or_comment(line, s - 1) and not templated_sa then
            if replacement == '' then
              -- hide entirely: conceal the keyword plus one trailing space (if any)
              -- so the following token doesn't shift, and inject nothing.
              local ec = (line:sub(e + 1, e + 1) == ' ') and e + 1 or e
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, { end_col = ec, conceal = '' })
            else
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
                end_col = e,
                conceal = '',
                virt_text = { { replacement, hl } },
                virt_text_pos = 'inline',
              })
            end
          end
          start_pos = e + 1
        end
      end

      -- Inject `mut` before a non-const reference return type (`-> T&`): the
      -- mutability can't be annotated in the return position. A const ref shows
      -- as bare `T&` (const is hidden), so the marker's presence is the
      -- mut/const distinction. Colored like the mut/mut_unchecked markers.
      local pre, ws = line:match '^(.-%->)(%s*)'
      if pre then
        local rtyp = line:sub(#pre + #ws + 1):gsub('%s*[{;].*$', ''):gsub('%s*$', '')
        if rtyp:match '&%s*$' and not rtyp:match '&&%s*$' and not rtyp:match '^const%f[%A]' then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, #pre + #ws, {
            virt_text = { { 'mut ', 'DansMarkerMut' } },
            virt_text_pos = 'inline',
          })
        end
      end

      -- Inject `mut` before each non-const reference/pointer parameter (the
      -- source token is gone; the frontend shows it). arrow_align mirrors
      -- these widths via M.arg_mut_cols so header arrows stay aligned.
      for _, col0 in ipairs(M.arg_mut_cols(line)) do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, col0, {
          virt_text = { { 'mut ', 'DansMarkerMut' } },
          virt_text_pos = 'inline',
        })
      end

      -- Inject `mut` right after the param `)` of a non-const member function
      -- (where the trailing `const` would sit). Leading-space ` mut` so it reads
      -- `) mut ...` and always lands before any following token -- in particular
      -- before a `noexcept`, which is rendered as `$ne` at its own later column.
      local mcol = M.member_mut_col(line, bufnr, row0)
      if mcol then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, mcol, {
          virt_text = { { ' mut', 'DansMarkerMut' } },
          virt_text_pos = 'inline',
        })
      end
    end
  end
end

M.refresh = refresh

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_aliases', { clear = true })
  vu.on_decorate(group, { 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI', 'DiagnosticChanged' }, refresh)
end

return M
