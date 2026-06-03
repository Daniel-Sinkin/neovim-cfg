-- Render a pointer-type `*` as `^` (Pascal/Odin style), syntax-aware via
-- treesitter: only the `*` of a pointer *declarator* is concealed to `^`, so
-- multiplication (`a * b`) and dereference (`*p`) keep their `*`. Uses an
-- extmark conceal (cchar `^`), so it respects concealcursor -- the cursor line
-- shows the real `*` -- and is width-neutral (one cell for one cell), so the
-- arrow alignment is unaffected.
--
-- Variable-declaration lines are left to jai_view's overlay (which renders `^`
-- via strip_type); this handles everything else -- chiefly function signatures
-- (`auto f(T* x) -> U*`), where the params/return aren't jai-rendered.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_pointer'

-- `*` tokens that are part of a pointer type (named and abstract declarators).
local QUERY = [[
  (pointer_declarator "*" @star)
  (abstract_pointer_declarator "*" @star)
]]

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if ft ~= 'c' and ft ~= 'cpp' and ft ~= 'cuda' then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return
  end
  local okq, query = pcall(vim.treesitter.query.parse, parser:lang(), QUERY)
  if not okq or not query then
    return
  end

  -- Defer on lines jai_view overlays (it renders `^` itself); concealing the
  -- raw `*` there would fight the full-line overlay.
  local jai_ok, jai = pcall(require, 'custom.jai_view')
  local jai_on = jai_ok and jai.is_enabled(bufnr)

  for _, node in query:iter_captures(trees[1]:root(), bufnr, 0, -1) do
    local sr, sc, er, ec = node:range()
    if sr == er then -- a `*` is single-line
      local skip = false
      if jai_on then
        local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1]
        skip = line ~= nil and jai.covers(line)
      end
      if not skip then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, {
          end_col = ec,
          conceal = '^',
        })
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_pointer', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
end

return M
