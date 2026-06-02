-- Render C++ keywords/attributes as short aliases via inline virt_text +
-- concealment. The original text stays in the file (this is purely visual).
-- The `$` prefix signals the rendered form is a shorthand, not real C++.
--   static_cast       -> $sc
--   dynamic_cast      -> $dc
--   reinterpret_cast  -> $rc
--   const_cast        -> $cc
--   noexcept          -> $ne
--   [[nodiscard]]     -> $nd

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_aliases'

local ALIASES = {
  { 'static_cast', '$sc' },
  { 'dynamic_cast', '$dc' },
  { 'reinterpret_cast', '$rc' },
  { 'const_cast', '$cc' },
  { 'noexcept', '$ne' },
  { '[[nodiscard]]', '$nd' },
}

local function is_word_char(c)
  return c and c:match '[%w_]' ~= nil
end

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if ft ~= 'c' and ft ~= 'cpp' and ft ~= 'cuda' then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    for _, alias in ipairs(ALIASES) do
      local keyword, replacement = alias[1], alias[2]
      local start_pos = 1
      while true do
        local s, e = line:find(keyword, start_pos, true)
        if not s then
          break
        end
        local before = s > 1 and line:sub(s - 1, s - 1) or nil
        local after = e < #line and line:sub(e + 1, e + 1) or nil
        if not is_word_char(before) and not is_word_char(after) then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row - 1, s - 1, {
            end_col = e,
            conceal = '',
            virt_text = { { replacement, 'Comment' } },
            virt_text_pos = 'inline',
          })
        end
        start_pos = e + 1
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_aliases', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'TextChangedI' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
end

return M
