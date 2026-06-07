-- Headless spec for the C/C++ frontend view layer (view / parse / render).
-- Run:  nvim --headless --cmd "set noswapfile" -c "luafile tests/frontend_spec.lua" -c "qa!"
-- Each case wraps body lines in a function ('fn'), a struct ('struct'), or none
-- ('top'); the cursor sits on line 1 (the wrapper) so body lines aren't revealed.
-- expect[i] is the rendered frontend overlay for body line i, or false for "no overlay"
-- (raw). Prints a PASS/FAIL summary; failures show expected vs actual.

local jns = vim.api.nvim_create_namespace 'ds_frontend_view'
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
run('local static constexpr', 'fn', { 'static constexpr usize n{4};' }, { 'static n: usize : 4;' })
run('local inline constexpr', 'fn', { 'inline constexpr f32 k{2.0f};' }, { 'k: f32 : 2.0f;' })

-- ===================== auto bindings =====================
run('auto local', 'fn', { 'auto a = foo();' }, { 'mut a := foo();' })
run('const auto local', 'fn', { 'const auto a = foo();' }, { 'a := foo();' })
run('auto& ref', 'fn', { 'auto& r = x;' }, { 'mut r& := x;' })
run('const auto& ref', 'fn', { 'const auto& r = x;' }, { 'r& := x;' })
run('auto* ptr', 'fn', { 'auto* p = &x;' }, { 'mut p^ := &x;' })
run('const auto* ptr', 'fn', { 'const auto* s = get();' }, { 's^ := get();' })
run('const auto* glfw', 'fn', { 'const auto* p = glfwGetVersionString();' }, { 'p^ := GetVersionString();' })
run('auto&& fwd (raw)', 'fn', { 'auto&& z = f();' }, { false })

-- ===================== pointers / references =====================
run('local pointer', 'fn', { 'int* p{};' }, { 'p: mut int^;' })
run('local const pointer', 'fn', { 'const char* s{};' }, { 's: CString;' })

-- ===================== casts inside values =====================
run('static_cast value', 'fn', { 'auto v = static_cast<int>(y);' }, { 'mut v := $scast<int>(y);' })

-- ===================== lambdas =====================
run('lambda cap+params', 'fn', { 'const auto f = [&](int a) { return a; };' }, { 'lambda f(& : int a) { return a; };' })
run('lambda no cap/params', 'fn', { 'auto g = []() { run(); };' }, { 'lambda g() { run(); };' })
run('lambda copy cap', 'fn', { 'const auto h = [=](int n) { return n; };' }, { 'lambda h(= : int n) { return n; };' })

-- ===================== structured bindings =====================
run('structured binding', 'fn', { 'auto [a, b] = pair;' }, { 'mut a, b := pair;' })
run('structured ref binding', 'fn', { 'const auto& [k, v] = *it;' }, { 'k&, v& := *it;' })
run('structured mut ref binding', 'fn', { 'auto& [xpos, ypos] = *res;' }, { 'mut xpos&, ypos& := *res;' })

-- ===================== range-for =====================
run('for const ref', 'fn', { 'for (const auto& v : items)' }, { 'for (v& : items)' })
run('for mut ref', 'fn', { 'for (auto& m : items)' }, { 'for (mut m& : items)' })
run('for mut value', 'fn', { 'for (auto x : xs)' }, { 'for (mut x : xs)' })
run('for fwd ref', 'fn', { 'for (auto&& elem : range)' }, { 'for (mut elem&& : range)' })
run('for const value', 'fn', { 'for (const auto x : xs)' }, { 'for (x : xs)' })
run('for c-style (raw)', 'fn', { 'for (int i = 0; i < n; ++i)' }, { false })

-- ===================== defer =====================
run('defer single', 'fn', { 'DANS_DEFER([] { cleanup(); });' }, { 'defer cleanup();' })
run('defer block', 'fn', { 'DANS_DEFER([] { a(); b(); });' }, { 'defer { a(); b(); }' })
run('defer multiline', 'fn', { 'DANS_DEFER([] {', '    a();', '});' }, { 'defer {', false, '}' })

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
run('member glfw pointer', 'struct', { 'GLFWwindow* window_{};' }, { 'window_: mut window^;' })
run('member const pointer', 'struct', { 'const Foo* cptr{};' }, { 'cptr: const Foo^;' })
run('member array', 'struct', { 'std::array<f32, 3> arr{};' }, { 'arr: [3]f32;' })
run('member nested template', 'struct', { 'std::vector<std::pair<int, int>> v{};' }, { 'v: vector<pair<int, int>>;' })
run('member ref-in-template', 'struct', { 'std::pair<int&, int> pr{};' }, { 'pr: pair<int&, int>;' })
run('member unique_ptr', 'struct', { 'std::unique_ptr<Foo> up{};' }, { 'up: Foo^;' })
run('member shared_ptr', 'struct', { 'std::shared_ptr<Foo> sp{};' }, { 'sp: Foo^;' })
run('member unique_ptr deleter', 'struct', { 'std::unique_ptr<Foo, FooDeleter> p{};' }, { 'p: Foo^, FooDeleter~;' })
run('member unique_ptr nested deleter', 'struct', { 'std::unique_ptr<std::pair<int, int>> p{};' }, { 'p: pair<int, int>^;' })
run('member glfw type (overlay strips prefix)', 'struct', { 'GLFWwindow win{};' }, { 'win: window;' })
run('member glfw unique_ptr deleter', 'struct', { 'std::unique_ptr<GLFWwindow, WindowDeleter> w{};' }, { 'w: window^, WindowDeleter~;' })
run('member optional', 'struct', { 'std::optional<int> o{};' }, { 'o: int?;' })
run('member vulkan null', 'struct', { 'VkBuffer buf{VK_NULL_HANDLE};' }, { 'buf: Buffer = {};' })
run('member static constexpr', 'struct', { 'static constexpr usize cap{16};' }, { 'static cap: usize : 16;' })

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
run('optional ref member', 'struct', { 'std::optional<int>& o;' }, { 'o: mut int?&;' })
run('optional const ref member', 'struct', { 'const std::optional<int>& o;' }, { 'o: const int?&;' })
run('optional ptr member', 'struct', { 'std::optional<int>* o{};' }, { 'o: mut int?^;' })
run('designated decl pun', 'fn', { 'const Ray r{.origin = origin, .direction = direction};' }, { 'r: Ray = origin, direction;' })
run('designated member-access pun', 'fn', { 'const Ray r{.center = cfg.center};' }, { 'r: Ray = center;' })
run('designated non-pun', 'fn', { 'const Cfg c{.width = 800, .height = h};' }, { 'c: Cfg = width=800, height=h;' })
run('ranges value', 'fn', { 'auto a = std::ranges::transform(xs, fn);' }, { 'mut a := transform(xs, fn);' })
run('views value', 'fn', { 'auto a = std::ranges::views::filter(xs, p);' }, { 'mut a := filter(xs, p);' })
run('for destructure', 'fn', { 'for (const auto& [k, v] : items)' }, { 'for (k, v& : items)' })
run('if let bare', 'fn', { 'if (const auto res = find(x); res)' }, { 'if let res := find(x)' })
run('if let with brace', 'fn', { 'if (const auto p = lookup(k); p) {' }, { 'if let p := lookup(k) {' })
run('if let has_value drop', 'fn', { 'if (auto res = from_glfw_get_window_pos(); res.has_value())' }, { 'if let res := from_glfw_get_window_pos()' })
run('if let iterator drop', 'fn', { 'if (auto it = m.find(x); it != m.end())' }, { 'if let it := m.find(x)' })
run('if let value-cmp drop', 'fn', { 'if (const auto res = find(x); res == 0)' }, { 'if let res := find(x)' })
run('if let independent cond kept', 'fn', { 'if (auto res = f(); ready)' }, { 'if let res := f(); ready' })
run('if let compound && kept', 'fn', { 'if (auto res = f(); res.has_value() && ready)' }, { 'if let res := f(); res.has_value() && ready' })
run('if let compound and-keyword kept', 'fn', { 'if (auto res = m.find(k); res != m.end() and res->ok)' }, { 'if let res := m.find(k); res != m.end() and res->ok' })
run('static thread_local', 'fn', { 'static thread_local std::mt19937_64 engine{std::random_device{}()};' }, { 'static thread_local engine: mut mt19937_64 = random_device{}();' })
run('if plain (raw)', 'fn', { 'if (ready) {' }, { false })
run('std move value', 'fn', { 'auto y = std::move(x);' }, { 'mut y := move(x);' })
run('std forward value', 'fn', { 'auto y = std::forward<T>(x);' }, { 'mut y := forward<T>(x);' })
run('cast pointer arg', 'fn', { 'auto y = reinterpret_cast<u8*>(p);' }, { 'mut y := $rcast<u8^>(p);' })
run('cast nested pointer', 'fn', { 'auto z = static_cast<std::vector<int*>>(v);' }, { 'mut z := $scast<vector<int^>>(v);' })
run('paren init', 'fn', { 'std::vector<stbtt_bakedchar> out(config.codepoint_count);' }, { 'out: mut vector<stbtt_bakedchar>(config.codepoint_count);' })
run('paren init digit', 'fn', { 'Buffer buf(1024);' }, { 'buf: mut Buffer(1024);' })
run('function decl raw', 'fn', { 'Foo make(Bar);' }, { false })

-- std::move / forward must render red (DansMarkerMut); the text suite can't see hl
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'auto fn() -> void', '{', '    auto y = std::move(x);', '}' })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local m = vim.api.nvim_buf_get_extmarks(b, jns, { 2, 0 }, { 2, -1 }, { details = true })
  local hl
  for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
    if c[1] == 'move' then
      hl = c[2]
    end
  end
  if hl == 'DansMarkerMut' then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  std::move color: move hl = ' .. tostring(hl)
  end
end

-- ===================== designated init (conceal + inline pad) =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'auto fn() -> void', '{',
    '    const auto m = Metrics{',
    '        .x = a,',
    '        .width = b,',
    '        .same = same,',
    '    };',
    '    render({.x = 1, .y = 2});',
    '}',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local dns = vim.api.nvim_create_namespace 'ds_cpp_designated'
  -- displayed text: apply conceals (hide) and inline virt_text (insert), then trim.
  local function display(row0)
    local line = vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1] or ''
    local hidden, inserts, hint = {}, {}, false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, dns, { row0, 0 }, { row0, -1 }, { details = true })) do
      local d = m[4]
      if d.conceal ~= nil and d.end_col then
        for c = m[3], d.end_col - 1 do
          hidden[c] = true
        end
      end
      if d.virt_text and d.virt_text_pos == 'inline' then
        local t = ''
        for _, ch in ipairs(d.virt_text) do
          t = t .. ch[1]
        end
        inserts[m[3]] = (inserts[m[3]] or '') .. t
      end
      if d.hl_group == 'DansHint' then
        hint = true
      end
    end
    local s = {}
    for c = 0, #line do
      if inserts[c] then
        s[#s + 1] = inserts[c]
      end
      if c < #line and not hidden[c] then
        s[#s + 1] = line:sub(c + 1, c + 1)
      end
    end
    return (table.concat(s):gsub('^%s+', '')), hint
  end
  local function chk(desc, got, exp)
    if got == exp then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = string.format('FAIL  %s\n        exp: %s\n        got: %s', desc, tostring(exp), tostring(got))
    end
  end
  local d3, hint3 = display(3)
  chk('designated align narrow', d3, 'x     = a,')
  chk('designated align wide', display(4), 'width = b,')
  chk('designated pun', display(5), 'same,')
  chk('designated single-line tight', display(7), 'render({x=1, y=2});')
  chk('designated field hint color', hint3, true)
end

-- ===================== caret / const colors =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'struct S', '{',
    '    Foo* raw{};',
    '    std::unique_ptr<Foo> uni{};',
    '    std::shared_ptr<Foo> sha{};',
    '    const Foo* cst{};',
    '    std::unique_ptr<Foo, Del> del{};',
    '};',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local function chunk_hl(row0, txt)
    local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
    for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
      if c[1] == txt then
        return c[2]
      end
    end
  end
  local function chk(d, g, e)
    if g == e then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  ' .. d .. '  got ' .. tostring(g)
    end
  end
  chk('raw caret normal', chunk_hl(2, '^'), 'Normal')
  chk('unique caret mut', chunk_hl(3, '^'), 'DansMarkerMut')
  chk('shared caret cpy', chunk_hl(4, '^'), 'DansMarkerCpy')
  chk('const ptr normal', chunk_hl(5, 'const '), 'Normal')
  chk('deleter caret mut', chunk_hl(6, '^'), 'DansMarkerMut')
  chk('deleter tilde mut', chunk_hl(6, '~'), 'DansMarkerMut')
end

-- ===================== string type color =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'struct S', '{',
    '    std::string name{};',
    '    std::string& ref;',
    '};',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function() vim.treesitter.get_parser(b, 'cpp'):parse() end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  local function chunk_hl(row0, txt)
    local m = vim.api.nvim_buf_get_extmarks(b, jns, { row0, 0 }, { row0, -1 }, { details = true })
    for _, c in ipairs(m[1] and m[1][4].virt_text or {}) do
      if c[1] == txt then
        return c[2]
      end
    end
  end
  local function chk2(d, g, e)
    if g == e then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  ' .. d .. '  got ' .. tostring(g)
    end
  end
  chk2('std::string type green', chunk_hl(2, 'string'), 'DansString')
  chk2('std::string& ref green', chunk_hl(3, 'string&'), 'DansString')
  local found = false
  for _, m in ipairs(vim.fn.getmatches()) do
    if m.group == 'DansString' and tostring(m.pattern):find('std::string', 1, true) then
      found = true
    end
  end
  chk2('std::string raw matchadd', found, true)
end

-- ===================== fold levels (Expects / Ensures blocks) =====================
do
  local fl = require('custom.dans_frontend_cpp.fold').compute_fold_levels
  local levels = fl({
    'def f() -> void', '{',
    '    {  // Expects', '        assert(a > 0);', '    }',
    '    do_work();',
    '    {  // Ensures', '        assert(b);', '    }',
    '}',
  })
  local exp = { '0', '0', '>1', '1', '<1', '0', '>1', '1', '<1', '0' }
  local ok = true
  for i = 1, #exp do
    if levels[i] ~= exp[i] then
      ok = false
    end
  end
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  fold levels: ' .. table.concat(levels, ',')
  end
end

-- ===================== golden regression (real dans-vk fixtures) =====================
-- Render frozen first-party files end to end and diff against committed snapshots.
-- Regenerate intentionally with tests/golden/update.lua, then review the diff.
do
  local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
  local ok, R = pcall(dofile, here .. 'golden/render.lua')
  if not ok then
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  golden: render.lua failed to load: ' .. tostring(R)
  else
    local gdir = here .. 'golden/'
    for _, name in ipairs(vim.fn.readdir(gdir .. 'fixtures')) do
      local got = R.render_file(gdir .. 'fixtures/' .. name)
      local ef = io.open(gdir .. 'expected/' .. name .. '.txt', 'r')
      if not ef then
        fail = fail + 1
        fails[#fails + 1] = 'FAIL  golden ' .. name .. ': no expected snapshot (run update.lua)'
      else
        local exp_src = ef:read('*a'):gsub('\r\n', '\n'):gsub('\r', '\n')
        ef:close()
        local exp = vim.split(exp_src, '\n', { plain = true })
        if exp[#exp] == '' then
          exp[#exp] = nil
        end
        local bad
        for i = 1, math.max(#got, #exp) do
          if got[i] ~= exp[i] then
            bad = i
            break
          end
        end
        if bad then
          fail = fail + 1
          fails[#fails + 1] = string.format('FAIL  golden %s:%d\n        exp: %s\n        got: %s', name, bad, tostring(exp[bad]), tostring(got[bad]))
        else
          pass = pass + 1
        end
      end
    end
  end
end

-- ===================== module toggles (:DansFrontend <module>) =====================
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    'int* gp();', -- top-level decl: pointer `*`->`^` fires (raw, not overlaid)
    'void fn()',
    '{',
    '    int x{7};', -- overlaid by the view
    '}',
  })
  vim.bo[b].filetype = 'cpp'
  vim.api.nvim_set_current_buf(b)
  pcall(function()
    vim.treesitter.get_parser(b, 'cpp'):parse()
  end)
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- cursor off both decorated lines
  vim.cmd 'doautocmd FileType'
  vim.cmd 'doautocmd BufEnter'
  vim.cmd 'doautocmd CursorMoved'

  local function count(nsname)
    local id = vim.api.nvim_get_namespaces()[nsname]
    return id and #vim.api.nvim_buf_get_extmarks(b, id, 0, -1, {}) or 0
  end
  local function chk(desc, cond)
    if cond then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = 'FAIL  toggle: ' .. desc
    end
  end

  chk('view on by default', count 'ds_frontend_view' > 0)
  chk('pointer on by default', count 'ds_cpp_pointer' > 0)
  vim.cmd 'DansFrontend pointer'
  chk('pointer off clears its marks', count 'ds_cpp_pointer' == 0)
  chk('toggling pointer leaves view alone', count 'ds_frontend_view' > 0)
  vim.cmd 'DansFrontend pointer'
  chk('pointer back on', count 'ds_cpp_pointer' > 0)
  vim.cmd 'DansFrontend view'
  chk('view off clears its overlay', count 'ds_frontend_view' == 0)
  vim.cmd 'DansFrontend view'
  chk('view back on', count 'ds_frontend_view' > 0)
end

-- ===================== report =====================
local report = { string.format('frontend_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
