-- Treesitter-driven C/C++ type decorations (off the cursor line):
--
--   1. pointer-type `*` -> `^` (Pascal/Odin style). Only the `*` of a pointer
--      *declarator* is rewritten, so multiplication (`a * b`) and dereference
--      (`*p`) keep their `*`. The `*` is concealed and `^` shown as normal-color
--      inline virt_text (width-neutral).
--   2. a leading `const` is concealed on a *value* declaration (const is the
--      hidden default) but kept on a *pointer/reference* one, where the
--      const-vs-mut distinction is meaningful.
--
-- Both skip variable-declaration lines that jai_view overlays (it renders these
-- itself), so this mainly covers function signatures and other raw decls.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_pointer'

local PTR_QUERY = [[
  (pointer_declarator "*" @star)
  (abstract_pointer_declarator "*" @star)
]]

local CONST_QUERY = [[
  (declaration (type_qualifier) @const)
  (field_declaration (type_qualifier) @const)
]]

local function cursor_row0(bufnr)
  if bufnr == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
end

-- Whether a declaration declares a pointer or reference (so a leading const
-- qualifies a pointee/referent and should stay visible).
local function declares_ptr_ref(decl)
  for child in decl:iter_children() do
    local t = child:type()
    if t == 'pointer_declarator' or t == 'reference_declarator' then
      return true
    end
    if t == 'init_declarator' then
      for c in child:iter_children() do
        local ct = c:type()
        if ct == 'pointer_declarator' or ct == 'reference_declarator' then
          return true
        end
      end
    end
  end
  return false
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

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return
  end
  local root = trees[1]:root()
  local lang = parser:lang()

  local cur = cursor_row0(bufnr)
  local jai_ok, jai = pcall(require, 'custom.jai_view')
  local jai_on = jai_ok and jai.is_enabled(bufnr)
  local function covered(row0)
    if not jai_on then
      return false
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
    return line ~= nil and jai.covers(line)
  end

  -- 1. pointer `*` -> `^` (virt_text, skip the cursor line so the real `*` shows)
  local okp, pq = pcall(vim.treesitter.query.parse, lang, PTR_QUERY)
  if okp and pq then
    for _, node in pq:iter_captures(root, bufnr, 0, -1) do
      local sr, sc, _, ec = node:range()
      if sr ~= cur and not covered(sr) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, {
          end_col = ec,
          conceal = '',
          virt_text = { { '^', 'Normal' } },
          virt_text_pos = 'inline',
        })
      end
    end
  end

  -- 2. leading `const` on a value declaration -> concealed (cchar-less; the
  -- conceal respects concealcursor, so the cursor line still shows it). Pointer/
  -- reference declarations keep their const (DansConst grays it).
  local okc, cq = pcall(vim.treesitter.query.parse, lang, CONST_QUERY)
  if okc and cq then
    for _, node in cq:iter_captures(root, bufnr, 0, -1) do
      local sr, sc, _, ec = node:range()
      if not covered(sr) and vim.treesitter.get_node_text(node, bufnr) == 'const' then
        local decl = node:parent()
        if decl and not declares_ptr_ref(decl) then
          local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ''
          if sc == #(line:match '^%s*' or '') then -- leading const only
            local k = ec
            while k < #line and line:sub(k + 1, k + 1):match '%s' do
              k = k + 1
            end
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_col = k, conceal = '' })
          end
        end
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
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
end

return M
