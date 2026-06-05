-- Designated-initializer rendering (treesitter, view-only). For each
-- `.field = value` aggregate pair:
--   .width = 800      ->  width=800     (drop the dot, tighten the `=`)
--   .width = width    ->  width         (pun: value == field, hide ` = value`)
-- The field name gets the muted hint color (DansHint). Skips the cursor line and
-- any line jai_view overlays (it renders those itself). Conceal-based, so the
-- value keeps its normal coloring.
--
-- Covers the non-jai lines: multi-line aggregate openers' body lines, call-site
-- temporaries, returns. Designated inits *inside* a jai-overlaid declaration's
-- value are not handled here (jai draws that line); that's a separate follow-up.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_designated'
local vu = require 'custom.cpp_view_util'

local DESIG_QUERY = [[(field_designator) @fd]]

local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vu.is_cpp(vim.bo[bufnr].filetype) then
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

  local cur = vu.cursor_row0(bufnr)
  local diag = vu.diagnostic_lines(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local jai_ok, jai = pcall(require, 'custom.jai_view')
  local jai_on = jai_ok and jai.is_enabled(bufnr)
  local function covered(row0)
    if not jai_on then
      return false
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
    return line ~= nil and jai.covers(line)
  end

  local okq, q = pcall(vim.treesitter.query.parse, lang, DESIG_QUERY)
  if not okq or not q then
    return
  end
  for _, node in q:iter_captures(root, bufnr, s0, e0) do
    local sr, sc, ser, fec = node:range() -- field_designator `.field`
    local pair = node:parent()
    if sr == ser and sr ~= cur and not diag[sr] and pair and pair:type() == 'initializer_pair' and not covered(sr) then
      local psr, _, per, pec = pair:range()
      if psr == sr and per == sr then -- single-line pair only
        local line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ''
        local field = line:sub(sc + 2, fec) -- drop the leading '.'
        local rest = line:sub(fec + 1, pec) -- " = value"
        local eqs, eqe = rest:find('=%s*')
        if field ~= '' and eqs then
          local value = vim.trim(rest:sub(eqe + 1))
          -- drop the leading dot
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc, { end_col = sc + 1, conceal = '' })
          -- muted hint color on the field name
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, sc + 1, { end_col = fec, hl_group = 'DansHint' })
          if value == field then
            -- pun: `.field = field` -> `field` (hide ` = field`)
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, fec, { end_col = pec, conceal = '' })
          else
            -- tighten: hide the spaces around `=`
            local eqcol = fec + eqs - 1
            local valstart = fec + eqe
            if eqcol > fec then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, fec, { end_col = eqcol, conceal = '' })
            end
            if valstart > eqcol + 1 then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, sr, eqcol + 1, { end_col = valstart, conceal = '' })
            end
          end
        end
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_cpp_designated', { clear = true })
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
