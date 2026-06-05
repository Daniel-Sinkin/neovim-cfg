-- Shared helpers for the C/C++/CUDA view-layer modules (cpp_aliases,
-- cpp_pointer, view). These were copy-pasted in each; centralized here so
-- the visible-range window, cursor row, and filetype guard stay in one place.

local M = {}

-- The filetypes the view modules operate on.
function M.is_cpp(ft)
  return ft == 'c' or ft == 'cpp' or ft == 'cuda'
end

-- 0-based cursor row in `bufnr`, or nil when it isn't the current buffer (so a
-- background buffer's decorations don't track some other window's cursor).
function M.cursor_row0(bufnr)
  if bufnr == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
end

-- Set of 0-based rows carrying a diagnostic (clangd / clang-tidy / etc). The view
-- modules skip these lines so their overlay doesn't collide with the diagnostic's
-- own inline virtual text (which would garble both).
function M.diagnostic_lines(bufnr)
  local set = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    set[d.lnum] = true
  end
  return set
end

-- 0-based [start, end) line range to decorate: the on-screen window plus a
-- margin, so a big file isn't re-scanned whole on every edit / scroll / cursor
-- move. Off-screen rows are (re)decorated as they scroll in (WinScrolled). A
-- non-current buffer has no window, so fall back to the whole buffer.
M.VISIBLE_MARGIN = 40
function M.visible_range(bufnr)
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return 0, vim.api.nvim_buf_line_count(bufnr)
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  return math.max(0, vim.fn.line 'w0' - 1 - M.VISIBLE_MARGIN), math.min(n, vim.fn.line 'w$' + M.VISIBLE_MARGIN)
end

-- Per-refresh skip predicates, capturing the cursor row, diagnostic rows, and
-- view-overlay coverage once (so a module computes them a single time, not per
-- line/capture). `.skip` is for virt_text decorations -- it also skips the
-- cursor line, whose real text must show under the inline text. `.skip_conceal`
-- is for pure conceals, where the cursor line is revealed by concealcursor
-- instead, so it isn't skipped. `line` is optional, fetched only if a coverage
-- check needs it.
function M.make_skipper(bufnr)
  local cur = M.cursor_row0(bufnr)
  local diag = M.diagnostic_lines(bufnr)
  local view_ok, view = pcall(require, 'custom.dans_frontend_cpp.view')
  local view_on = view_ok and view.is_enabled(bufnr)
  local function covered(row0, line)
    if not view_on then
      return false
    end
    if line == nil then
      line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
    end
    return line ~= nil and view.covers(line)
  end
  return {
    skip = function(row0, line)
      return row0 == cur or diag[row0] == true or covered(row0, line)
    end,
    skip_conceal = function(row0, line)
      return diag[row0] == true or covered(row0, line)
    end,
  }
end

return M
