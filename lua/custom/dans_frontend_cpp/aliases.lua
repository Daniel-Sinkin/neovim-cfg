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
--   VK_NULL_HANDLE    -> {}  (in the Vulkan color)

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
  { '[[maybe_unused]]', '$mu' },
  { 'static_assert', '$sa' },
  { 'std::runtime_error', '$re' },
  { 'std::unique_ptr', '$up' },
  { 'std::shared_ptr', '$sp' },
  { 'VK_NULL_HANDLE', '{}', 'DansVulkan' },
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
-- is string-matched exactly -- a hardcoded whitelist, no inference from a concept's
-- definition. Three emit shapes:
--
--   infix   Keyword<A, B>      -> A<sym>B     convertible_to<V,T> -> V~>T
--                                             same_as<A,B>        -> A~=B
--   suffix  Keyword<A>         -> A<sym>      RefOf<T>            -> T~&
--                                             ValueOf<T>          -> T~value
--                                             CharLike<T>         -> T~>char   (sym
--                                             bakes in the fixed RHS)
--   call    Keyword<F, R...>   -> F~(R...)    invocable<S,T>      -> S~(T)
--
-- No spaces around the symbols. Nesting falls out for free: each occurrence is
-- concealed/injected independently, so CharLike<RefOf<R>> renders RefOf<R> -> R~&
-- and then CharLike<...> -> R~&~>char. static_assert lines are skipped wholesale
-- by the caller, so this never fires inside one. CharLike/BoolLike/IntLike/
-- StringLike are the only fixed-RHS aliases recognized (per the whitelist).
local CONCEPT_HL = 'DansConcept'
local CONCEPTS = {
  { kw = 'convertible_to', kind = 'infix', sym = '~>' },
  { kw = 'same_as', kind = 'infix', sym = '~=' },
  { kw = 'invocable', kind = 'call' },
  { kw = 'CharLike', kind = 'suffix', sym = '~>char' },
  { kw = 'BoolLike', kind = 'suffix', sym = '~>bool' },
  { kw = 'IntLike', kind = 'suffix', sym = '~>int' },
  { kw = 'StringLike', kind = 'suffix', sym = '~>string_view' },
  { kw = 'ValueOf', kind = 'suffix', sym = '~value' },
  { kw = 'RefOf', kind = 'suffix', sym = '~&' },
  -- raw std value/reference traits, same notation as the ValueOf/RefOf aliases.
  { kw = 'iter_value_t', kind = 'suffix', sym = '~value' },
  { kw = 'range_value_t', kind = 'suffix', sym = '~value' },
  { kw = 'iter_reference_t', kind = 'suffix', sym = '~&' },
  { kw = 'range_reference_t', kind = 'suffix', sym = '~&' },
}

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

local function render_concept(bufnr, row0, line, spec)
  local from = 1
  while true do
    local ms, open, close, args, nxt = find_concept(line, spec.kw, from)
    if not ms then
      return
    end
    from = nxt
    if spec.kind == 'infix' and #args == 2 then
      local a_s, a_e = arg_span(open, args[1])
      local b_s, b_e = arg_span(open, args[2])
      hide(bufnr, row0, ms - 1, a_s - 1)
      hide_inject(bufnr, row0, a_e, b_s - 1, spec.sym)
      hide(bufnr, row0, b_e, close)
    elseif spec.kind == 'suffix' and #args == 1 then
      local a_s, a_e = arg_span(open, args[1])
      hide(bufnr, row0, ms - 1, a_s - 1)
      hide_inject(bufnr, row0, a_e, close, spec.sym)
    elseif spec.kind == 'call' and #args >= 1 then
      local f_s, f_e = arg_span(open, args[1])
      hide(bufnr, row0, ms - 1, f_s - 1)
      if #args == 1 then
        hide_inject(bufnr, row0, f_e, close, '~()')
      else
        local b_s = arg_span(open, args[2])
        local _, last_e = arg_span(open, args[#args])
        hide_inject(bufnr, row0, f_e, b_s - 1, '~(')
        hide_inject(bufnr, row0, last_e, close, ')')
      end
    end
    -- arity mismatch: leave the call verbatim (no extmarks)
  end
end

local function concepts(bufnr, row0, line)
  for _, spec in ipairs(CONCEPTS) do
    render_concept(bufnr, row0, line, spec)
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
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s - 1, {
              end_col = e,
              conceal = '',
              virt_text = { { replacement, hl } },
              virt_text_pos = 'inline',
            })
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
