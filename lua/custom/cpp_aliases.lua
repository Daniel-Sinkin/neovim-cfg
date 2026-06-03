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

-- { keyword, replacement, highlight? }  -- highlight defaults to 'Comment'.
local ALIASES = {
  { 'static_cast', '$sc' },
  { 'dynamic_cast', '$dc' },
  { 'reinterpret_cast', '$rc' },
  { 'const_cast', '$cc' },
  { 'noexcept', '$ne' },
  { '[[nodiscard]]', '$nd' },
  { 'static_assert', '$as' },
  { 'VK_NULL_HANDLE', '{}', 'DansVulkan' },
}

-- Exposed so hpp_arrow_align.lua can mirror these widths when it computes the
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

local function cursor_row0(bufnr)
  if bufnr == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
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

  -- Skip the cursor line: concealcursor is empty for these buffers, so the real
  -- text shows there; the inline alias virt_text would otherwise double up with
  -- it (e.g. `$scstatic_cast`). Re-hidden once the cursor leaves the line.
  local cur = cursor_row0(bufnr)

  -- Defer to jai_view on lines it rewrites: it draws a full-line overlay there,
  -- which would orphan our inline alias to the end of the line.
  local jai_ok, jai = pcall(require, 'custom.jai_view')
  local jai_on = jai_ok and jai.is_enabled(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    if row - 1 ~= cur and not (jai_on and jai.covers(line)) then
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
          if not is_word_char(before) and not is_word_char(after) and not in_string_or_comment(line, s - 1) then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row - 1, s - 1, {
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
        if rtyp:match '&%s*$' and not rtyp:match '^const%f[%A]' then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row - 1, #pre + #ws, {
            virt_text = { { 'mut ', 'DansMarkerMut' } },
            virt_text_pos = 'inline',
          })
        end
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_aliases', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
end

return M
