-- Space-triggered, composable C++ type shorthand for c/cpp/cuda. Type a
-- `$`-token and press <Space>: the token before the cursor is expanded to a
-- std:: type. Unlike a LuaSnip autosnippet it does NOT fire mid-token, so the
-- pieces compose -- `$str$?` waits for the space, then becomes
-- std::optional<std::string>.
--
--   $str            -> std::string
--   $sv             -> std::string_view
--   $rv             -> std::ranges::views
--   $ra             -> std::ranges
--   $?              -> std::nullopt               (bare; $T? gives the type)
--   $int?  / $Foo$? -> std::optional<int>          (glued or split sigil)
--   $Foo^           -> std::unique_ptr<Foo>
--   $Foo<           -> std::vector<Foo>
--   $str$?          -> std::optional<std::string>  (wrappers compose)
--   $K$V$um         -> std::unordered_map<K, V>
--   $K$V$map        -> std::map<K, V>
--   $T$N$arr        -> std::array<T, N>
--   $copy / $copya / $move / $movea / $constr / $destr
--                   -> the matching special member of the enclosing class, e.g.
--                      $copy -> X(const X&), $copya -> def operator=(const X&) -> X&
--                      (inverse of the special_members view collapse)
--   $invalid<Space> -> (deleted)                   ($ isn't valid C++; unresolved
--                                                   $-blocks are removed)
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
  -- short cast forms. The long $scast/$rcast/$ccast come from aliases.ALIASES
  -- (which is also what the view collapses static_cast etc. to); both expand.
  sc = 'static_cast',
  rc = 'reinterpret_cast',
  cc = 'const_cast',
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
      if key and ATOM[key] == nil then
        ATOM[key] = a[1]
      end
    end
  end
end

-- Unary postfix wrappers (sigil -> inner -> type).
local WRAP = {
  ['?'] = function(x)
    return 'std::optional<' .. x .. '>'
  end,
  ['^'] = function(x)
    return 'std::unique_ptr<' .. x .. '>'
  end,
  ['<'] = function(x)
    return 'std::vector<' .. x .. '>'
  end,
}
-- A wrapper sigil with no operand: bare `$?` is the empty-optional value
-- std::nullopt (there's no use for a bare `std::optional`; `$T?` gives the type).
local BARE = { ['?'] = 'std::nullopt' }

-- Binary combinators: $word -> (a, b) -> type.
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
-- token. Split on the sigil into segments, peel a trailing wrap sigil off each,
-- and fold a value stack left to right. `transformed` guards against a lone
-- `$Ident` (no atom/op) silently collapsing to a bare `Ident`.
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
  for _, seg in ipairs(segs) do
    if COMBINE[seg] then
      local b, a = table.remove(stack), table.remove(stack)
      if not a then
        return nil
      end
      stack[#stack + 1] = COMBINE[seg](a, b)
      transformed = true
    else
      local core, sig = seg, nil
      local last = seg:sub(-1)
      if WRAP[last] then
        core, sig = seg:sub(1, -2), last
      end
      if core ~= '' then
        if not core:match '^[%w_:]+$' then
          return nil
        end
        if ATOM[core] then
          stack[#stack + 1] = ATOM[core]
          transformed = true
        else
          stack[#stack + 1] = core
        end
      end
      if sig then
        if #stack > 0 then
          local v = table.remove(stack)
          stack[#stack + 1] = WRAP[sig](v)
        elseif BARE[sig] then
          stack[#stack + 1] = BARE[sig]
        else
          return nil
        end
        transformed = true
      end
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
  constr = function(x)
    return x .. '()'
  end,
  destr = function(x)
    return '~' .. x .. '()'
  end,
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
      vim.keymap.set('i', '<Space>', on_space, { buffer = ev.buf, desc = 'Expand $type shorthand or insert space' })
    end,
  })
end

return M
