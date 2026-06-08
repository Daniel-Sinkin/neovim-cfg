-- Headless spec for the function-param flip colors (ds_cpp_aliases virt_text):
-- types blue/green, mut red, constrained-auto concept-cyan.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/param_flip_spec.lua" -c "qa!"

local pass, fail, fails = 0, 0, {}
local function ok(d, c)
  if c then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  '// top', -- cursor parks here so the signature renders
  'void f(int x, Bar& rw, const Foo& ro, std::string_view s, SizeLike auto n);',
})
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd 'doautocmd FileType'
vim.cmd 'doautocmd BufEnter'

local ans = vim.api.nvim_get_namespaces()['ds_cpp_aliases']
local chunks = {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ans, { 1, 0 }, { 1, -1 }, { details = true })) do
  for _, c in ipairs(m[4].virt_text or {}) do
    chunks[#chunks + 1] = c
  end
end
local function has(text, hl)
  for _, c in ipairs(chunks) do
    if c[1] == text and c[2] == hl then
      return true
    end
  end
  return false
end

ok('param name is Normal', has('x', 'Normal'))
ok('colon is Normal', has(': ', 'Normal'))
ok('value type blue (int)', has('int', 'DansInlayType'))
ok('non-const ref gets mut (red)', has('mut ', 'DansMarkerMut'))
ok('non-const ref type blue (Bar&)', has('Bar&', 'DansInlayType'))
ok('std::string_view green', has('string_view', 'DansString'))
ok('constrained-auto concept-colored', has('~SizeLike', 'DansConcept'))
-- a const ref keeps its const (no mut), colored as the type
ok('const ref has no separate mut on ro', not has('mut Foo', 'DansMarkerMut'))

local report = { string.format('param_flip_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
