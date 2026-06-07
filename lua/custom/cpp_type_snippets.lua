-- Space-triggered, composable C++ type shorthand for c/cpp/cuda. Type a
-- `$`-token and press <Space>: the token before the cursor is expanded to a
-- std:: type. Unlike a LuaSnip autosnippet it does NOT fire mid-token, so the
-- pieces compose -- `$?$str` waits for the space, then becomes
-- std::optional<std::string>.
--
-- Nesting is OUTER-TO-INNER (prefix): the wrapper / container comes first and
-- the contained type follows, the same order the expansion brackets in. So
-- `$<$?$int` reads vector-of-optional-of-int -> std::vector<std::optional<int>>.
-- A segment whose name isn't a known atom is taken literally, so any type can be
-- the inner one (`$?$int`, `$?$Foo`, `$?$sdfgfd`). The only thing rejected is a
-- bare unknown `$token` on its own: it isn't a type, so it's removed.
--
--   $str            -> std::string
--   $sv             -> std::string_view
--   $rv             -> std::ranges::views
--   $ra             -> std::ranges
--   $?              -> std::nullopt                 (bare; $?$T gives the optional)
--   $?$int          -> std::optional<int>
--   $?$str          -> std::optional<std::string>
--   $?$sdfgfd       -> std::optional<sdfgfd>        (unknown inner -> literal)
--   $^$Foo / $up$Foo -> std::unique_ptr<Foo>   (`^` / `up` alias)
--   $sp$Foo          -> std::shared_ptr<Foo>
--   $^ / $up / $sp   -> bare smart-ptr template name
--   $<$Foo           -> std::vector<Foo>       (vector is `<`)
--   $<$?$int        -> std::vector<std::optional<int>>
--   $um$K$V         -> std::unordered_map<K, V>
--   $map$K$V        -> std::map<K, V>
--   $arr$T$N        -> std::array<T, N>
--   $sc$u32         -> static_cast<u32>        (cast wraps the type; add `(x)`)
--   $rc$T / $cc$T / $dc$T
--                   -> reinterpret_cast<T> / const_cast<T> / dynamic_cast<T>
--   $sc / $rc / $cc / $dc -> the bare cast keyword
--   $copy / $copya / $move / $movea
--                   -> the matching special member of the enclosing class, e.g.
--                      $copy -> X(const X&), $copya -> def operator=(const X&) -> X&
--                      (inverse of the special_members view collapse; the default
--                      ctor/dtor are no longer collapsed, so they have no $form)
--   $sdfgfd<Space>  -> (deleted)                    (bare unknown $token isn't a
--                                                    type; unresolved $-blocks go)
-- `$` inside a string is left alone. A block must end at the cursor, so `$sa(`
-- (trailing non-snippet char) does nothing.
--
-- This is the inverse of the dans_frontend_cpp view: type the short form, store
-- real C++, read it back short (the frontend hides std:: and shows optional<T>
-- as T?, unique_ptr<T> as T^, ...).

local M = {}

-- Prefix. Reachable alternatives if you ever want to swap: '§', '%'. Everything
-- keys off this one constant.
local SIGIL = '$'
local SIGIL_PAT = vim.pesc(SIGIL)

-- Smart-pointer wrappers, the single source of truth spread into WRAP (the
-- wrapping form) and BARE (the no-operand form) below. Each works prefix
-- (`$^$int` -> unique_ptr<int>) and bare as the plain template (`$^` / `$up` ->
-- unique_ptr). `^` and `up` are aliases for unique_ptr; `sp` is shared_ptr (no
-- sigil). Kept out of ATOM so the bare atom doesn't shadow the wrapper.
local SMART_PTR = {
  ['^'] = 'std::unique_ptr',
  up = 'std::unique_ptr',
  sp = 'std::shared_ptr',
}

-- Casts wrap a type in <...>: `$sc$u32` -> static_cast<u32>; bare `$sc` ->
-- static_cast. Short forms here; the long $scast/$rcast/$ccast and $dc come from
-- aliases.ALIASES (any expansion ending in `_cast`) and fold in the same way.
-- Kept out of ATOM so the bare atom doesn't shadow the wrapper.
local CAST = {
  sc = 'static_cast',
  rc = 'reinterpret_cast',
  cc = 'const_cast',
}

-- 0-arg atoms: $word -> expansion. Two sources, one mechanism:
--   * the type shorthands below (expansion-only conveniences), and
--   * the view-layer alias table (aliases.ALIASES) -- the SAME EXPR<->$A pairs
--     that collapse `reinterpret_cast` to `$rc`, `noexcept` to `$ne`, etc.
-- Importing them here makes collapse and expansion one idea: the view renders
-- EXPR as $A, and typing `$A<Space>` writes EXPR back. A new alias added there
-- becomes expandable here automatically -- nothing to keep in sync.
local ATOM = {
  str = 'std::string',
  sv = 'std::string_view',
  rv = 'std::ranges::views',
  ra = 'std::ranges',
}
do
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      -- keep only the `$word` aliases (skip e.g. VK_NULL_HANDLE -> `{}`); the
      -- type shorthands above win on any name clash.
      local key = type(a[2]) == 'string' and a[2]:match '^%$([%w_]+)$'
      -- skip the smart-pointer / cast keys: they're wrappers, not 0-arg atoms.
      if key and ATOM[key] == nil and not SMART_PTR[key] and not CAST[key] then
        if type(a[1]) == 'string' and a[1]:match '_cast$' then
          CAST[key] = a[1] -- $scast/$rcast/$ccast/$dc -> a wrapping cast
        else
          ATOM[key] = a[1]
        end
      end
    end
  end
end

-- Unary prefix wrappers: the sigil (or word) applies to the operand that follows
-- it. The smart pointers (^/up/sp) are folded in from SMART_PTR so the wrapping
-- and bare forms stay in sync.
local WRAP = {
  ['?'] = function(x)
    return 'std::optional<' .. x .. '>'
  end,
  ['<'] = function(x)
    return 'std::vector<' .. x .. '>'
  end,
}
for key, ty in pairs(SMART_PTR) do
  WRAP[key] = function(x)
    return ty .. '<' .. x .. '>'
  end
end
-- A wrapper with no operand: bare `$?` is the empty-optional value std::nullopt;
-- a bare smart pointer (`$^` / `$up` / `$sp`) is its plain template name. (There
-- is no bare `std::optional` / `std::vector`; `$?$T` / `$<$T` give those.)
local BARE = { ['?'] = 'std::nullopt' }
for key, ty in pairs(SMART_PTR) do
  BARE[key] = ty
end
-- Casts wrap their operand (`$sc$u32` -> static_cast<u32>) and bare to the plain
-- keyword (`$sc` -> static_cast). CAST is fully populated by now (literal short
-- forms + the `_cast` aliases imported above).
for key, name in pairs(CAST) do
  WRAP[key] = function(x)
    return name .. '<' .. x .. '>'
  end
  BARE[key] = name
end

-- Binary combinators, also prefix: $word consumes the next two operands.
-- `$um$K$V` -> std::unordered_map<K, V> (first operand is the left bracket slot).
local COMBINE = {
  um = function(a, b)
    return 'std::unordered_map<' .. a .. ', ' .. b .. '>'
  end,
  map = function(a, b)
    return 'std::map<' .. a .. ', ' .. b .. '>'
  end,
  arr = function(a, b)
    return 'std::array<' .. a .. ', ' .. b .. '>'
  end,
}

-- Evaluate a `$`-token to its C++ expansion, or nil if it isn't a valid DSL
-- token. Split on the sigil into segments; each is a unary wrapper (?/^/<), a
-- binary combinator (um/map/arr), a 0-arg atom (str/sv/...), or a bare
-- identifier taken literally (int, Foo, sdfgfd). Fold the value stack RIGHT TO
-- LEFT so every operator wraps the operand(s) to its right -- prefix / Polish
-- order, i.e. the outer-to-inner nesting (`$<$?$int` -> vector(optional(int))).
-- `transformed` guards a lone `$Ident` (no atom/op): a bare unknown $token isn't
-- a type, so it collapses to nil and is removed rather than left as `Ident`.
function M.expand(token)
  if token:sub(1, #SIGIL) ~= SIGIL then
    return nil
  end
  local segs = {}
  for seg in (token .. SIGIL):gmatch('(.-)' .. SIGIL_PAT) do
    segs[#segs + 1] = seg
  end
  table.remove(segs, 1) -- the empty piece before the leading sigil
  if #segs == 0 then
    return nil
  end

  local stack, transformed = {}, false
  for i = #segs, 1, -1 do
    local seg = segs[i]
    if WRAP[seg] then
      -- wrap the operand to the right; with nothing to wrap, fall back to the
      -- bare value (`$?` -> std::nullopt) or reject. Pop into a local first: a
      -- `stack[#stack+1] = f(table.remove(stack))` would read `#stack` before the
      -- pop and land the result in the wrong slot.
      if #stack > 0 then
        local inner = table.remove(stack)
        stack[#stack + 1] = WRAP[seg](inner)
      elseif BARE[seg] then
        stack[#stack + 1] = BARE[seg]
      else
        return nil
      end
      transformed = true
    elseif COMBINE[seg] then
      local a = table.remove(stack)
      local b = table.remove(stack)
      if not b then
        return nil -- needs two operands to its right
      end
      stack[#stack + 1] = COMBINE[seg](a, b)
      transformed = true
    elseif seg:match '^[%w_:]+$' then
      -- a known atom expands; any other identifier is the literal inner type.
      -- A literal on its own is not a transform (see `transformed`).
      if ATOM[seg] then
        stack[#stack + 1] = ATOM[seg]
        transformed = true
      else
        stack[#stack + 1] = seg
      end
    else
      return nil -- not a sigil, a combinator, or an identifier
    end
  end

  if #stack ~= 1 or not transformed then
    return nil
  end
  return stack[1]
end

-- Naive "is byte column col0 inside a "..." string on this line": odd count of
-- unescaped quotes before it. `$` is valid C++ only inside a string, so a `$`
-- there is left completely alone.
local function in_string(line, col0)
  local n, i = 0, 1
  while i <= col0 do
    local c = line:sub(i, i)
    if c == '\\' then
      i = i + 2
    elseif c == '"' then
      n, i = n + 1, i + 1
    else
      i = i + 1
    end
  end
  return n % 2 == 1
end

-- Special-member shorthands: $copy etc. -> the signature for the enclosing class
-- X (the inverse of dans_frontend_cpp.special_members, which collapses these back
-- to $copy). X is supplied by the caller (treesitter), so these are handled in
-- resolve rather than the pure M.expand.
local SPECIAL = {
  copy = function(x)
    return x .. '(const ' .. x .. '&)'
  end,
  copya = function(x)
    return 'def operator=(const ' .. x .. '&) -> ' .. x .. '&'
  end,
  move = function(x)
    return x .. '(' .. x .. '&&)'
  end,
  movea = function(x)
    return 'def operator=(' .. x .. '&&) -> ' .. x .. '&'
  end,
}

-- Name of the class/struct whose member area the cursor is in, or nil (nil inside
-- a method body, so $copy only fires where special members are declared).
local function enclosing_class_name()
  local okp, parser = pcall(vim.treesitter.get_parser, 0)
  if okp and parser then
    pcall(function()
      parser:parse()
    end)
  end
  local ok, node = pcall(vim.treesitter.get_node)
  if not ok then
    return nil
  end
  while node do
    local nt = node:type()
    if nt == 'compound_statement' or nt == 'function_definition' then
      return nil
    end
    if nt == 'class_specifier' or nt == 'struct_specifier' then
      local nm = node:field('name')[1]
      return nm and vim.treesitter.get_node_text(nm, 0) or nil
    end
    node = node:parent()
  end
  return nil
end

-- Decide what pressing <Space> should do at 0-based cursor `col` on `line`. The
-- token is the trailing run of snippet chars ENDING at the cursor (identifiers,
-- the `$` separator, and the sigils `?`/`^`/`<`), taken from its first `$`. `$`
-- is never valid C++ outside a string, so such a block is always a snippet:
--   { 'expand', bs, text } -> replace the block [bs,col) with text + a space
--   { 'remove', bs }       -> the block didn't resolve -> delete it (and the space)
--   nil                    -> no `$`-block ends here -> just insert a space
-- A trailing non-snippet char (e.g. `$sa(`) means no block ends at the cursor,
-- so nothing fires. Exposed for headless tests.
function M.resolve(line, col, class_fn)
  local before = line:sub(1, col)
  local run = before:match '([%w_$?<^]*)$' -- snippet chars ending at the cursor
  if run == '' then
    return nil
  end
  local p = run:find(SIGIL, 1, true)
  if not p then
    return nil
  end
  local bs = col - #run + p - 1 -- 0-based col of the first `$`
  if in_string(line, bs) then
    return nil
  end
  local block = run:sub(p)
  -- class-name-dependent special members ($copy etc.); class_fn (treesitter) is
  -- only called when one matches, so a normal space pays nothing for it.
  local sm = SPECIAL[block:sub(#SIGIL + 1)]
  if sm then
    local x = class_fn and class_fn()
    if x then
      return { action = 'expand', bs = bs, text = sm(x) }
    end
    return { action = 'remove', bs = bs } -- $copy outside a class is garbage
  end
  local text = M.expand(block)
  if text then
    return { action = 'expand', bs = bs, text = text }
  end
  return { action = 'remove', bs = bs }
end

local function on_space()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local line = vim.api.nvim_get_current_line()
  local r = M.resolve(line, col, enclosing_class_name)
  if not r then
    vim.api.nvim_buf_set_text(0, row, col, row, col, { ' ' })
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 1 })
  elseif r.action == 'expand' then
    -- replace the block (it ends at the cursor) and keep the space (iabbrev style)
    vim.api.nvim_buf_set_text(0, row, r.bs, row, col, { r.text .. ' ' })
    vim.api.nvim_win_set_cursor(0, { row + 1, r.bs + #r.text + 1 })
  else -- a `$block` that didn't resolve is garbage ($ isn't valid C++): delete it
    -- and the triggering space with it (clean removal).
    vim.api.nvim_buf_set_text(0, row, r.bs, row, col, { '' })
    vim.api.nvim_win_set_cursor(0, { row + 1, r.bs })
  end
end

function M.setup()
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('ds_cpp_type_dsl', { clear = true }),
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      -- Map <Space> AND <S-Space>: in a GUI (Neovide) Shift+Space is a distinct
      -- key, so a bare <Space> map misses it and a held shift swallows the
      -- expansion. Both route to the same handler (expand a $-block, else insert
      -- a plain space).
      for _, lhs in ipairs { '<Space>', '<S-Space>' } do
        vim.keymap.set('i', lhs, on_space, { buffer = ev.buf, desc = 'Expand $type shorthand or insert space' })
      end
    end,
  })
end

return M
