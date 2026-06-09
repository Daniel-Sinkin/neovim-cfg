-- Headless spec for the C/C++ scope bracket-matcher (custom.dans_frontend_cpp.scope).
-- Validates the worked example end to end: the innermost any-bracket pair at each
-- cursor position, the $5 line-start case that must resolve to the lambda body
-- (not the span braces), the in-string parens that must be skipped, and the
-- ancestor chain used for the blue depth coloring.
--   nvim --headless --cmd "set noswapfile" -c "luafile tests/scope_spec.lua" -c "qa!"

local S = require 'custom.dans_frontend_cpp.scope'
local pass, fail, fails = 0, 0, {}

local function ok(d, cond, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = 'FAIL  ' .. d .. (extra and ('  (' .. extra .. ')') or '')
  end
end

-- The worked example. $-markers removed; the $5 `return` is intentionally at
-- column 0 (the reported bug: yib there grabbed the span, not the lambda body).
local lines = {
  '{', -- 0   $1 outermost
  '        auto const glfw_extensions = []', -- 1   $2 in the []
  '        {', -- 2   $3 lambda body open
  '            u32 glfw_count{0};', -- 3
  '            CZString* raw_glfw_extensions = glfwGetRequiredInstanceExtensions(&glfw_count);', -- 4
  '            if (not raw_glfw_extensions) DANS_PANIC("Got no GLFW Extensions (no Vulkan loader?)");', -- 5   $4 in if-parens
  'return std::span{raw_glfw_extensions, static_cast<usize>(glfw_count)};', -- 6   $5 col 0, $6 at static_cast
  '        }();', -- 7   lambda body close
  '}', -- 8
}

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
vim.bo[b].filetype = 'cpp'
vim.api.nvim_set_current_buf(b)
pcall(function()
  vim.treesitter.get_parser(b, 'cpp'):parse()
end)

-- 0-based col of the first occurrence of a literal substring on `row`.
local function colof(row, sub)
  local s = lines[row + 1]:find(sub, 1, true)
  return s and (s - 1) or -1
end

-- { desc, row, col, open_row, close_row, char }
local cases = {
  { '$1 outermost braces', 1, 0, 0, 8, '{' },
  { '$2 lambda capture [] (cursor on ])', 1, #lines[2] - 1, 1, 1, '[' },
  { '$3 lambda body braces', 3, 12, 2, 7, '{' },
  { '$4 if-condition parens', 5, colof(5, 'raw_glfw_extensions'), 5, 5, '(' },
  { '$5 line-start resolves to lambda body, NOT span', 6, 0, 2, 7, '{' },
  { '$6 span initializer braces', 6, colof(6, 'static_cast'), 6, 6, '{' },
}

for _, c in ipairs(cases) do
  local p = S.innermost(b, c[2], c[3])
  if not p then
    ok(c[1], false, 'no pair found')
  else
    local got = string.format('open r%d close r%d %q', p.or_, p.cr, p.ch)
    local want = string.format('open r%d close r%d %q', c[4], c[5], c[6])
    ok(c[1], p.or_ == c[4] and p.cr == c[5] and p.ch == c[6], 'want ' .. want .. ' got ' .. got)
  end
end

-- Ancestor chain at $4 (in the if-parens): active = the parens, parent = the
-- lambda body ($3), grandparent = the outermost ($1). Drives the blue depth knob.
do
  local chain = S.pair_chain(b, 5, colof(5, 'raw_glfw_extensions'), 3)
  ok('chain[1] active = if-parens', chain[1] and chain[1].ch == '(' and chain[1].or_ == 5, chain[1] and chain[1].ch or 'nil')
  ok('chain[2] parent = lambda body', chain[2] and chain[2].or_ == 2 and chain[2].cr == 7, chain[2] and ('open r' .. chain[2].or_) or 'nil')
  ok('chain[3] grandparent = outermost', chain[3] and chain[3].or_ == 0 and chain[3].cr == 8, chain[3] and ('open r' .. chain[3].or_) or 'nil')
end

-- Depth knob: pair_chain caps at `want`, so depth 0 -> 1 pair, depth 1 -> 2.
do
  local one = S.pair_chain(b, 5, colof(5, 'raw_glfw_extensions'), 1)
  ok('depth 0 yields only the active pair', #one == 1, '#=' .. #one)
end

local report = { string.format('scope_spec: %d passed, %d failed', pass, fail) }
for _, f in ipairs(fails) do
  report[#report + 1] = f
end
print(table.concat(report, '\n'))
