-- Space-triggered, composable C++ type shorthand for c/cpp/cuda. Type a
-- `$`-token and press <Space>: the token before the cursor is expanded to a
-- std:: type. Unlike a LuaSnip autosnippet it does NOT fire mid-token, so the
-- pieces compose -- `$?$str` waits for the space, then becomes
-- std::optional<std::string>.
--
-- Two call syntaxes for the same templates: prefix sigils `$um$K$V` (outer to
-- inner, so `$<$?$int` reads vector-of-optional-of-int) and explicit parens
-- `$um(K, V)` (whitespace-stripped, clearer arg count). Arity is enforced -- a
-- one-arg `$um` does nothing, since unordered_map takes two. A segment that isn't
-- a known atom is the literal inner type (`$?$Foo`); a bare unknown `$token` is
-- removed.
--
--   $str / $sv / $rv / $ra -> std::string / string_view / ranges::views / ranges
--   $?              -> std::nullopt   ($?$ / $?(T) give the optional)
--   $?$int / $?(int) -> std::optional<int>
--   $< / $> / $arr / $um -> the bare template name (std::vector / array / ...)
--   $<$Foo / $>(Foo) -> std::vector<Foo>          (vector is `<`, alias `>`)
--   $^$Foo / $up$Foo / $sp$Foo -> std::unique_ptr<Foo> / shared_ptr<Foo>
--   $um$K$V / $um(K, V) -> std::unordered_map<K, V>
--   $map$K$V / $arr$T$N -> std::map<K, V> / std::array<T, N>
--   $sc$u32 / $sc(u32) -> static_cast<u32>   (also $rc / $cc / $dc casts)
--   $<T, S>         -> template <typename T, typename S>  (angle form, closing >)
--   relations (concept ~-notation), prefix or infix:
--   $~> / $~=       -> std::convertible_to / std::same_as
--   $~>$T$S / $T$~>$S / $~>(T, S) -> std::convertible_to<T, S>
--   $~>$T          -> std::convertible_to<T,        (open, fill the 2nd arg)
--   $T$~>          -> std::convertible_to<T, $>      (literal $ fails the build)
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

local unpack = table.unpack or unpack

-- Templates: `$head` with a fixed arity. 0 operands -> the bare form; exactly
-- `arity` operands -> the `fmt`; any other count is rejected (so `$um$K`, one arg
-- for a two-arg map, does nothing -- proper usage is forced). Both call syntaxes
-- expand the same entry: prefix sigils `$um$K$V` and parens `$um(K, V)`.
--   tbare: the bare form when a `$` follows but no operand is given -- `$?` is the
--   value std::nullopt, but `$?$` (templated, no arg) is std::optional.
local TEMPLATES = {
  ['?'] = { bare = 'std::nullopt', tbare = 'std::optional', arity = 1, fmt = 'std::optional<%s>' },
  ['<'] = { bare = 'std::vector', arity = 1, fmt = 'std::vector<%s>' },
  ['>'] = { bare = 'std::vector', arity = 1, fmt = 'std::vector<%s>' }, -- `$>` alias for vector
  ['^'] = { bare = 'std::unique_ptr', arity = 1, fmt = 'std::unique_ptr<%s>' },
  up = { bare = 'std::unique_ptr', arity = 1, fmt = 'std::unique_ptr<%s>' },
  sp = { bare = 'std::shared_ptr', arity = 1, fmt = 'std::shared_ptr<%s>' },
  um = { bare = 'std::unordered_map', arity = 2, fmt = 'std::unordered_map<%s, %s>' },
  map = { bare = 'std::map', arity = 2, fmt = 'std::map<%s, %s>' },
  arr = { bare = 'std::array', arity = 2, fmt = 'std::array<%s, %s>' },
  sc = { bare = 'static_cast', arity = 1, fmt = 'static_cast<%s>' },
  rc = { bare = 'reinterpret_cast', arity = 1, fmt = 'reinterpret_cast<%s>' },
  cc = { bare = 'const_cast', arity = 1, fmt = 'const_cast<%s>' },
}

-- Binary concept relations, infix-capable: `$~>` -> std::convertible_to. The
-- operand forms are handled in expand_relation and the paren branch.
local RELATIONS = { ['~>'] = 'std::convertible_to', ['~='] = 'std::same_as' }

-- 0-arg atoms: $word -> expansion. Type shorthands below, plus the view-layer
-- alias table (aliases.ALIASES) -- the SAME EXPR<->$A pairs that collapse
-- `noexcept` to `$ne`, etc. -- so collapse and expansion stay one idea. A `_cast`
-- alias becomes a 1-arg template; up/sp/casts already live in TEMPLATES.
local ATOM = {
  str = 'std::string',
  sv = 'std::string_view',
  rv = 'std::ranges::views',
  ra = 'std::ranges',
  -- $mu still types the attribute even though the frontend now hides it (so it's
  -- no longer importable from aliases.ALIASES, where its replacement is '').
  mu = '[[maybe_unused]]',
}
do
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      local key = type(a[2]) == 'string' and a[2]:match '^%$([%w_]+)$'
      if key and ATOM[key] == nil and not TEMPLATES[key] then
        if type(a[1]) == 'string' and a[1]:match '_cast$' then
          TEMPLATES[key] = { bare = a[1], arity = 1, fmt = a[1] .. '<%s>' }
        else
          ATOM[key] = a[1]
        end
      end
    end
  end
end

-- Split an arg-list body on top-level commas (depth-aware over <>, (), [], {}).
local function split_commas(s)
  local args, depth, start = {}, 0, 1
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '(' or c == '<' or c == '[' or c == '{' then
      depth = depth + 1
    elseif c == ')' or c == '>' or c == ']' or c == '}' then
      depth = depth - 1
    elseif c == ',' and depth == 0 then
      args[#args + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  args[#args + 1] = s:sub(start)
  return args
end

-- A relation operand: a single segment that's a known atom or a bare identifier.
local function expand_operand(seg)
  if ATOM[seg] then
    return ATOM[seg]
  end
  if seg:match '^[%w_:]+$' then
    return seg
  end
  return nil
end
local function operands(segs, lo, hi)
  local out = {}
  for i = lo, hi do
    local e = expand_operand(segs[i])
    if not e then
      return nil
    end
    out[#out + 1] = e
  end
  return out
end

-- A relation `~>` / `~=` at segment `idx`. Left/right operand counts pick a form:
--   $~>       convertible_to            $~>$T   convertible_to<T,   (open)
--   $~>$T$S   convertible_to<T, S>      $T$~>$S convertible_to<T, S> (infix)
--   $T$~>     convertible_to<T, $>  (the literal $ fails the build, flagging the
--                                    missing operand)
local function expand_relation(segs, idx)
  local name = RELATIONS[segs[idx]]
  local L = operands(segs, 1, idx - 1)
  local R = operands(segs, idx + 1, #segs)
  if not L or not R then
    return nil
  end
  local nl, nr = #L, #R
  if nl == 0 and nr == 0 then
    return name
  elseif nl == 0 and nr == 1 then
    return name .. '<' .. R[1] .. ', '
  elseif nl == 0 and nr == 2 then
    return name .. '<' .. R[1] .. ', ' .. R[2] .. '>'
  elseif nl == 1 and nr == 1 then
    return name .. '<' .. L[1] .. ', ' .. R[1] .. '>'
  elseif nl == 1 and nr == 0 then
    return name .. '<' .. L[1] .. ', $>'
  end
  return nil
end

-- Prefix / Polish fold of the segments (right to left), so each template wraps
-- the operand(s) to its right -- the outer-to-inner nesting (`$<$?$int` ->
-- vector(optional(int))). A template pops exactly its arity; a wrong count
-- rejects. `templated` (a trailing `$`) turns a bare `$?$` into the template.
local function expand_fold(segs, templated)
  local stack, transformed = {}, false
  for i = #segs, 1, -1 do
    local seg = segs[i]
    local t = TEMPLATES[seg]
    if t then
      if #stack >= t.arity then
        local args = {}
        for _ = 1, t.arity do
          args[#args + 1] = table.remove(stack)
        end
        stack[#stack + 1] = string.format(t.fmt, unpack(args))
      elseif #stack == 0 then
        stack[#stack + 1] = (templated and t.tbare) or t.bare
      else
        return nil -- wrong operand count for this template
      end
      transformed = true
    elseif ATOM[seg] then
      stack[#stack + 1] = ATOM[seg]
      transformed = true
    elseif seg:match '^[%w_:]+$' then
      stack[#stack + 1] = seg -- literal inner type
    else
      return nil
    end
  end
  if #stack ~= 1 or not transformed then
    return nil
  end
  return stack[1]
end

-- The paren call form `$head(a, b, ...)`: whitespace-stripped, arity-checked, and
-- each `$`-arg recursively expanded (so `$>($?(int))` nests).
local function expand_paren(head, argstr)
  local t, rel = TEMPLATES[head], RELATIONS[head]
  if not t and not rel then
    return nil
  end
  local args = {}
  for _, a in ipairs(split_commas(argstr)) do
    a = vim.trim(a)
    if a ~= '' then
      if a:sub(1, #SIGIL) == SIGIL then
        local ex = M.expand(a)
        if not ex then
          return nil
        end
        args[#args + 1] = ex
      else
        args[#args + 1] = a
      end
    end
  end
  if rel then
    if #args == 0 then
      return rel
    elseif #args == 2 then
      return rel .. '<' .. args[1] .. ', ' .. args[2] .. '>'
    end
    return nil
  end
  if #args == 0 then
    return t.bare
  elseif #args == t.arity then
    return string.format(t.fmt, unpack(args))
  end
  return nil
end

-- Evaluate a `$`-token to its C++ expansion, or nil if it isn't a valid DSL
-- token. The paren form `$head(...)` is tried first; otherwise the token is split
-- on the sigil and dispatched to the relation handler (a `~>`/`~=` segment is
-- present) or the Polish fold (templates + atoms). A bare unknown `$Ident` folds
-- to nil and is removed rather than left as `Ident`.
function M.expand(token)
  if token:sub(1, #SIGIL) ~= SIGIL then
    return nil
  end
  -- angle form `$<T, S>` -> `template <typename T, typename S>`: each bare
  -- identifier becomes a `typename` param, a multi-token arg (e.g. `usize N`) is
  -- kept verbatim. (`$<` without a closing `>` is still the vector wrapper below.)
  local targs = token:match('^' .. SIGIL_PAT .. '<(.-)>$')
  if targs then
    local parts = {}
    for _, a in ipairs(split_commas(targs)) do
      a = vim.trim(a)
      if a ~= '' then
        parts[#parts + 1] = a:match '^[%a_][%w_]*$' and ('typename ' .. a) or a
      end
    end
    if #parts == 0 then
      return nil
    end
    return 'template <' .. table.concat(parts, ', ') .. '>'
  end
  local head, argstr = token:match('^' .. SIGIL_PAT .. '([%w_?<>%^~=]+)%((.*)%)$')
  if head then
    return expand_paren(head, argstr)
  end
  local segs = vim.split(token:sub(#SIGIL + 1), SIGIL, { plain = true })
  -- a trailing empty segment is a dangling `$` (`$?$`) -- "templated, no arg".
  local templated = false
  if segs[#segs] == '' then
    templated = true
    table.remove(segs)
  end
  if #segs == 0 then
    return nil
  end
  for i, seg in ipairs(segs) do
    if RELATIONS[seg] then
      return expand_relation(segs, i)
    end
  end
  return expand_fold(segs, templated)
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
  -- paren form `$head(...)` ending at the cursor: balanced parens, so it may hold
  -- spaces / commas the run scan below would stop at. Tried first.
  local paren = before:match('(' .. SIGIL_PAT .. '[%w_?<>%^~=]+%b())$')
  if paren then
    local pbs = col - #paren
    if not in_string(line, pbs) then
      local ptext = M.expand(paren)
      return { action = ptext and 'expand' or 'remove', bs = pbs, text = ptext }
    end
  end
  -- angle template form `$<T, S>` ending at the cursor (holds commas/spaces too).
  -- Requires a closing `>`, so the bare `$<` vector wrapper still goes to the run
  -- scan below.
  local angle = before:match('(' .. SIGIL_PAT .. '<[^<>]*>)$')
  if angle then
    local abs = col - #angle
    if not in_string(line, abs) then
      local atext = M.expand(angle)
      return { action = atext and 'expand' or 'remove', bs = abs, text = atext }
    end
  end
  -- sigil form: the trailing run of snippet chars (incl the relation `~>=` and `>`).
  local run = before:match '([%w_$?<>^~=]*)$'
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
