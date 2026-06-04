-- Headless spec for the C/C++ JAI view layer (jai_view / jai_parse / jai_render).
-- Run:  nvim --headless --cmd "set noswapfile" -c "luafile tests/jai_spec.lua" -c "qa!"
-- Each case wraps body lines in a function ('fn'), a struct ('struct'), or none
-- ('top'); the cursor sits on line 1 (the wrapper) so body lines aren't revealed.
-- expect[i] is the rendered jai overlay for body line i, or false for "no overlay"
-- (raw). Prints a PASS/FAIL summary; failures show expected vs actual.

local jns = vim.api.nvim_create_namespace 'ds_jai_view'
local pass, fail, fails = 0, 0, {}

local function overlay(b, row0)
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
  if #m == 0 then
    return nil
  end
  local s = {}
  for _, c in ipairs(m[1][4].virt_text or {}) do
    s[#s + 1] = c[1]
  end
  return table.concat(s, '')
end

local function run(desc, ctx, body, expect)
  local lines, off = {}, 0
  if ctx == 'fn' then
    lines, off = { 'auto fn() -> void', '{' }, 2
  elseif ctx == 'struct' then
    lines, off = { 'struct S', '{' }, 2
  else
    lines, off = { '// top' }, 1
  end
  for _, l in ipairs(body) do
    lines[#lines + 1] = l
  end
  if ctx == 'fn' then
    lines[#lines + 1] = '}'
  elseif ctx == 'struct' then
    lines[#lines + 1] = '};'
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  for i, exp in pairs(expect) do
    local got = overlay(b, off + i - 1)
    local ok = (exp == false) and (got == nil) or (got == exp)
    if ok then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  %s\n        src: %s\n        exp: %s\n        got: %s', desc, body[i], exp == false and '<raw>' or exp, got == nil and '<raw>' or got)
    end
  end
end

-- ===================== value declarations (locals -> mut) =====================
run('local value int', 'fn', { 'int x{7};' }, { 'x: mut int = 7;' })
run('local value float', 'fn', { 'f32 y{1.0f};' }, { 'y: mut f32 = 1.0f;' })
run('local value empty-init', 'fn', { 'Vec2 p{};' }, { 'p: mut Vec2;' })
run('local const', 'fn', { 'const int x{7};' }, { 'x: int = 7;' })
run('local constexpr', 'fn', { 'constexpr int x{7};' }, { 'x: int : 7;' })
run('local static constexpr', 'fn', { 'static constexpr usize n{4};' }, { 'n: usize : 4;' })
run('local inline constexpr', 'fn', { 'inline constexpr f32 k{2.0f};' }, { 'k: f32 : 2.0f;' })

-- ===================== auto bindings =====================
run('auto local', 'fn', { 'auto a = foo();' }, { 'mut a := foo();' })
run('const auto local', 'fn', { 'const auto a = foo();' }, { 'a := foo();' })
run('auto& ref', 'fn', { 'auto& r = x;' }, { 'mut ref r := x;' })
run('const auto& ref', 'fn', { 'const auto& r = x;' }, { 'ref r := x;' })
run('auto* ptr', 'fn', { 'auto* p = &x;' }, { 'mut p := &x;' })
run('auto&& fwd (raw)', 'fn', { 'auto&& z = f();' }, { false })

-- ===================== pointers / references =====================
run('local pointer', 'fn', { 'int* p{};' }, { 'p: mut int^;' })
run('local const pointer', 'fn', { 'const char* s{};' }, { 's: const char^;' })

-- ===================== casts inside values =====================
run('static_cast value', 'fn', { 'auto v = static_cast<int>(y);' }, { 'mut v := $sc<int>(y);' })

-- ===================== lambdas =====================
run('lambda cap+params', 'fn', { 'const auto f = [&](int a) { return a; };' }, { 'lambda f(& : int a) { return a; };' })
run('lambda no cap/params', 'fn', { 'auto g = []() { run(); };' }, { 'lambda g() { run(); };' })
run('lambda copy cap', 'fn', { 'const auto h = [=](int n) { return n; };' }, { 'lambda h(= : int n) { return n; };' })

-- ===================== structured bindings =====================
run('structured binding', 'fn', { 'auto [a, b] = pair;' }, { 'mut a, b := pair;' })
run('structured ref binding', 'fn', { 'const auto& [k, v] = *it;' }, { 'ref k, v := *it;' })

-- ===================== range-for =====================
run('for const ref', 'fn', { 'for (const auto& v : items)' }, { 'for (v& : items)' })
run('for mut ref', 'fn', { 'for (auto& m : items)' }, { 'for (mut m& : items)' })
run('for mut value', 'fn', { 'for (auto x : xs)' }, { 'for (mut x : xs)' })
run('for const value', 'fn', { 'for (const auto x : xs)' }, { 'for (x : xs)' })
run('for c-style (raw)', 'fn', { 'for (int i = 0; i < n; ++i)' }, { false })

-- ===================== defer =====================
run('defer single', 'fn', { 'dev::Defer _{[&]{ cleanup(); }};' }, { 'defer cleanup();' })
run('defer block', 'fn', { 'dev::Defer _{[&]{ a(); b(); }};' }, { 'defer { a(); b(); }' })

-- ===================== non-declarations (raw) =====================
run('return stmt', 'fn', { 'return x;' }, { false })
run('call stmt', 'fn', { 'foo(a, b);' }, { false })
run('assign stmt', 'fn', { 'x = y + z;' }, { false })
run('if opener', 'fn', { 'if (cond) {' }, { false })
run('multiline opener', 'fn', { 'auto big = compute(' }, { false })

-- ===================== members (no mut on value) =====================
run('member value', 'struct', { 'int x{7};' }, { 'x: int = 7;' })
run('member empty', 'struct', { 'Vec2 pos{};' }, { 'pos: Vec2;' })
run('member pointer', 'struct', { 'Foo* ptr{};' }, { 'ptr: mut Foo^;' })
run('member const pointer', 'struct', { 'const Foo* cptr{};' }, { 'cptr: const Foo^;' })
run('member array', 'struct', { 'std::array<f32, 3> arr{};' }, { 'arr: array<f32, 3>;' })
run('member nested template', 'struct', { 'std::vector<std::pair<int, int>> v{};' }, { 'v: vector<pair<int, int>>;' })
run('member ref-in-template', 'struct', { 'std::pair<int&, int> pr{};' }, { 'pr: pair<int&, int>;' })
run('member unique_ptr', 'struct', { 'std::unique_ptr<Foo> up{};' }, { 'up: Foo🔒;' })
run('member shared_ptr', 'struct', { 'std::shared_ptr<Foo> sp{};' }, { 'sp: Foo🔗;' })
run('member optional', 'struct', { 'std::optional<int> o{};' }, { 'o: int?;' })
run('member vulkan null', 'struct', { 'VkBuffer buf{VK_NULL_HANDLE};' }, { 'buf: VkBuffer = {};' })
run('member static constexpr', 'struct', { 'static constexpr usize cap{16};' }, { 'cap: usize : 16;' })

-- ===================== alignment block =====================
run('aligned members', 'struct', {
  'Vec2 position{};',
  'Color fill{white};',
  'Foo* ptr{};',
}, {
  'position: Vec2;',
  'fill    : Color = white;',
  'ptr     : mut Foo^;',
})

-- ===================== top-level (raw) =====================
run('include', 'top', { '#include <vector>' }, { false })
run('using alias (raw)', 'top', { 'using Vec3 = glm::vec3;' }, { false })

-- ===================== more edge cases =====================
run('multi declarator (raw)', 'fn', { 'int a, b;' }, { false })
run('multi init (raw)', 'fn', { 'int a = 1, b = 2;' }, { false })
run('function pointer (raw)', 'fn', { 'void (*fp)(int){};' }, { false })
run('string init', 'fn', { 'std::string s{"hi"};' }, { 's: mut string = "hi";' })
run('bool init', 'fn', { 'bool ok{true};' }, { 'ok: mut bool = true;' })
run('negative init', 'fn', { 'int x{-1};' }, { 'x: mut int = -1;' })
run('ternary value', 'fn', { 'auto x = a ? b : c;' }, { 'mut x := a ? b : c;' })
run('dans-namespaced type', 'fn', { 'dans::Foo f{};' }, { 'f: mut Foo;' })
run('glm-namespaced type', 'fn', { 'glm::vec3 v{};' }, { 'v: mut glm::vec3;' })
run('ref member', 'struct', { 'Foo& m;' }, { 'm: mut Foo&;' })
run('const ref member', 'struct', { 'const Foo& m;' }, { 'm: const Foo&;' })
run('trailing comment', 'fn', { 'int x{7}; // count' }, { 'x: mut int = 7; // count' })

-- ===================== new features =====================
run('optional local', 'fn', { 'std::optional<Foo> o{};' }, { 'o: mut Foo?;' })
run('optional pointer', 'struct', { 'std::optional<int> o{};' }, { 'o: int?;' })
run('for destructure', 'fn', { 'for (const auto& [k, v] : items)' }, { 'for (k, v& : items)' })
run('if let', 'fn', { 'if (const auto res = find(x); res)' }, { 'if let res := find(x)' })
run('if let with brace', 'fn', { 'if (const auto p = lookup(k); p) {' }, { 'if let p := lookup(k) {' })
run('if plain (raw)', 'fn', { 'if (ready) {' }, { false })

-- ===================== report =====================
local report = { string.format('jai_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
