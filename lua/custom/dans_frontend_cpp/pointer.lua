-- Treesitter-driven C/C++ type decorations (off the cursor line):
--
--   1. pointer-type `*` -> `^` (Pascal/Odin style). Only the `*` of a pointer
--      *declarator* is rewritten, so multiplication (`a * b`) and dereference
--      (`*p`) keep their `*`. The `*` is concealed and `^` shown as grayed
--      (DansPointer) inline virt_text (width-neutral).
--   2. a leading `const` is concealed on a *value* declaration (const is the
--      hidden default) but kept on a *pointer/reference* one, where the
--      const-vs-mut distinction is meaningful.
--   3. `std::optional<T>` -> `T?`: `optional<` is concealed and the closing `>`
--      rewritten to `?`. Any ref/ptr suffix stays in the source, so
--      `optional<T>&` reads as `T?&`. Treesitter-scoped to the optional
--      template, so a `>` elsewhere (a comparison, another template) is safe.
--
-- All three skip variable-declaration lines that view overlays (it renders
-- these itself), so this mainly covers function signatures and other raw decls.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_pointer'
local vu = require 'custom.dans_frontend_cpp.util'

local PTR_QUERY = [[
  (pointer_declarator "*" @star)
  (abstract_pointer_declarator "*" @star)
]]

local CONST_QUERY = [[
  (declaration (type_qualifier) @const)
  (field_declaration (type_qualifier) @const)
]]

-- Every `Foo<...>`; the optional pass filters to the ones named `optional`.
local OPT_QUERY = [[
  (template_type) @tt
]]

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
  if not vu.is_cpp(ft) then
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

  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)

  -- 1. pointer `*` -> `^` (virt_text, skip the cursor line so the real `*` shows)
  local okp, pq = pcall(vim.treesitter.query.parse, lang, PTR_QUERY)
  if okp and pq then
    for _, node in pq:iter_captures(root, bufnr, s0, e0) do
      local sr, sc, _, ec = node:range()
      if not skip.skip(sr) then
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
    for _, node in cq:iter_captures(root, bufnr, s0, e0) do
      local sr, sc, _, ec = node:range()
      if not skip.skip_conceal(sr) and vim.treesitter.get_node_text(node, bufnr) == 'const' then
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

  -- 3. std::optional<T> -> T?: conceal `optional<` and rewrite the closing `>`
  -- to `?`. A ref/ptr suffix stays in the source, so optional<T>& reads `T?&`.
  local oko, oq = pcall(vim.treesitter.query.parse, lang, OPT_QUERY)
  if oko and oq then
    for _, node in oq:iter_captures(root, bufnr, s0, e0) do
      local nm = node:field('name')[1]
      local ar = node:field('arguments')[1]
      if nm and ar and nm:type() == 'type_identifier' and vim.treesitter.get_node_text(nm, bufnr) == 'optional' then
        local nsr, nsc = nm:range()
        local asr, asc, aer, aec = ar:range()
        if not skip.skip(nsr) and nsr == asr then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, nsr, nsc, { end_col = asc + 1, conceal = '' })
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, aer, aec - 1, { end_col = aec, conceal = '?' })
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
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter', 'CursorMoved', 'CursorMovedI', 'WinScrolled', 'DiagnosticChanged' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
end

return M
