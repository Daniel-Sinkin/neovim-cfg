-- Headless spec for the $-type-snippet expander (cpp_type_snippets.M.expand).
-- Pure string-in / string-out, so no buffer is needed. Run:
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/type_snippets_spec.lua" -c "qa!"

local S = require 'custom.cpp_type_snippets'
local pass, fail, fails = 0, 0, {}

local function eq(token, expect)
  local got = S.expand(token)
  if got == expect then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', token, tostring(expect), tostring(got))
  end
end

-- atoms
eq('$str', 'std::string')
eq('$sv', 'std::string_view')
eq('$ra', 'std::ranges')
eq('$rv', 'std::ranges::views')

-- bare optional sigil
eq('$?', 'std::nullopt')

-- prefix unary wrappers (outer-to-inner)
eq('$?$int', 'std::optional<int>')
eq('$?$str', 'std::optional<std::string>')
eq('$?$sdfgfd', 'std::optional<sdfgfd>')
eq('$^$Foo', 'std::unique_ptr<Foo>')
eq('$<$str', 'std::vector<std::string>')
eq('$<$Foo', 'std::vector<Foo>')

-- nested wrappers, outer first
eq('$<$?$int', 'std::vector<std::optional<int>>')
eq('$?$<$str', 'std::optional<std::vector<std::string>>')
eq('$<$<$int', 'std::vector<std::vector<int>>')

-- smart pointers: `^`/`up` (unique) and `sp` (shared) -- wrap + bare form
eq('$up', 'std::unique_ptr')
eq('$^', 'std::unique_ptr')
eq('$sp', 'std::shared_ptr')
eq('$up$int', 'std::unique_ptr<int>')
eq('$^$int', 'std::unique_ptr<int>')
eq('$sp$int', 'std::shared_ptr<int>')
eq('$up$str', 'std::unique_ptr<std::string>')
eq('$<$^$int', 'std::vector<std::unique_ptr<int>>')

-- binary combinators (prefix)
eq('$um$K$V', 'std::unordered_map<K, V>')
eq('$map$K$V', 'std::map<K, V>')
eq('$arr$T$N', 'std::array<T, N>')
eq('$um$str$<$int', 'std::unordered_map<std::string, std::vector<int>>')

-- casts: short + long spellings wrap the type; bare form is the keyword
eq('$sc$u32', 'static_cast<u32>')
eq('$rc$int', 'reinterpret_cast<int>')
eq('$cc$Bar', 'const_cast<Bar>')
eq('$dc$Foo', 'dynamic_cast<Foo>')
eq('$scast$u32', 'static_cast<u32>')
eq('$rcast$u8', 'reinterpret_cast<u8>')
eq('$ccast$T', 'const_cast<T>')
eq('$sc', 'static_cast')
eq('$rc', 'reinterpret_cast')
eq('$cc', 'const_cast')
eq('$dc', 'dynamic_cast')
eq('$sc$?$int', 'static_cast<std::optional<int>>')

-- rejected: bare unknown identifier (nonsense)
eq('$sdfgfd', nil)
eq('$Foo', nil)
eq('$int', nil)
eq('$', nil)

-- bare templates expand to the plain template name (like $arr -> std::array)
eq('$<', 'std::vector')
eq('$>', 'std::vector')
eq('$arr', 'std::array')
eq('$um', 'std::unordered_map')

-- arity is enforced: a one-arg `$um` / two-arg-needed does nothing
eq('$um$K', nil)
eq('$arr$T', nil)

-- $> is a vector alias (prefix + paren)
eq('$>$Foo', 'std::vector<Foo>')

-- paren call form: whitespace-stripped, arity-checked, $-args recurse
eq('$arr(T, N)', 'std::array<T, N>')
eq('$um(K, V)', 'std::unordered_map<K, V>')
eq('$>(T)', 'std::vector<T>')
eq('$?(int)', 'std::optional<int>')
eq('$>($?(int))', 'std::vector<std::optional<int>>')
eq('$sc(u32)', 'static_cast<u32>')
eq('$um(K)', nil) -- wrong arity
eq('$arr(A, B, C)', nil) -- wrong arity

-- $? value vs template: bare is nullopt, templated/with-arg is optional
eq('$?', 'std::nullopt')
eq('$?$', 'std::optional')
eq('$?$T', 'std::optional<T>')

-- relations: bare / prefix / infix / sentinel
eq('$~>', 'std::convertible_to')
eq('$~=', 'std::same_as')
eq('$~>$T$S', 'std::convertible_to<T, S>')
eq('$T$~>$S', 'std::convertible_to<T, S>')
eq('$T$~=$S', 'std::same_as<T, S>')
eq('$~>$T', 'std::convertible_to<T, ')
eq('$T$~>', 'std::convertible_to<T, $>')
eq('$~>(A, B)', 'std::convertible_to<A, B>')

-- angle template form: $<T, S> -> template <typename T, typename S>
eq('$<T>', 'template <typename T>')
eq('$<T, S>', 'template <typename T, typename S>')
eq('$<T, usize N>', 'template <typename T, usize N>')
-- vector forms unaffected (no closing > = the wrapper)
eq('$<', 'std::vector')
eq('$<$Foo', 'std::vector<Foo>')
eq('$<(Foo)', 'std::vector<Foo>')

-- old postfix forms no longer expand (committed to prefix, no order-guessing)
eq('$str$?', nil)
eq('$Foo<', nil)
eq('$int?', nil)
eq('$K$V$um', nil)

-- old postfix forms no longer expand (committed to prefix, no order-guessing)
eq('$str$?', nil)
eq('$Foo<', nil)
eq('$int?', nil)
eq('$K$V$um', nil)

-- trigger: both <Space> and <S-Space> fire the expansion (Neovide sends a
-- distinct <S-Space>, which a bare <Space> map would miss).
do
  local function expand_via(lhs)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].filetype = 'cpp'
    vim.api.nvim_set_current_buf(b)
    vim.cmd 'doautocmd FileType'
    local keys = vim.api.nvim_replace_termcodes('i$str' .. lhs .. '<Esc>', true, false, true)
    vim.api.nvim_feedkeys(keys, 'x', false)
    return vim.api.nvim_get_current_line()
  end
  local function chk(desc, got)
    if got == 'std::string ' then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  %s\n        got: %q', desc, got)
    end
  end
  chk('<Space> expands $str', expand_via '<Space>')
  chk('<S-Space> expands $str', expand_via '<S-Space>')
end

local report = { string.format('type_snippets_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
