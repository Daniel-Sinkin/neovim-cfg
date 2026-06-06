-- Shared helpers for the C/C++/CUDA view-layer modules (aliases,
-- pointer, view). These were copy-pasted in each; centralized here so
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

-- 0-based rows to show raw: the cursor line, or the whole visual selection while
-- in a visual mode. Both the overlay and the decoration modules reveal this set,
-- so a multi-line select shows the original everywhere (otherwise the overlay
-- reveals but a pointer `^` etc. lingers on the non-cursor selected lines).
function M.reveal_set(bufnr)
  local cur = M.cursor_row0(bufnr)
  if cur == nil then
    return {}
  end
  local m = vim.fn.mode():sub(1, 1)
  if m == 'v' or m == 'V' or m == string.char(22) then
    local vstart = vim.fn.getpos('v')[2] - 1
    local lo, hi = math.min(cur, vstart), math.max(cur, vstart)
    local set = {}
    for r = lo, hi do
      set[r] = true
    end
    return set
  end
  return { [cur] = true }
end

-- 0-based rows inside a `// clang-format off` ... `// clang-format on` region.
-- Those are hand-aligned (data encoded in code); the frontend leaves them
-- verbatim so it never fights the manual layout. Cached per changedtick.
local cfoff_cache = {}
function M.clang_format_off(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cfoff_cache[bufnr]
  if c and c.tick == tick then
    return c.set
  end
  local set, off = {}, false
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match '//%s*clang%-format%s+off' then
      off = true
    elseif line:match '//%s*clang%-format%s+on' then
      off = false
    end
    if off then
      set[i - 1] = true
    end
  end
  cfoff_cache[bufnr] = { tick = tick, set = set }
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

-- Per-refresh skip predicate, capturing the reveal set (cursor + visual
-- selection), diagnostic rows, clang-format-off rows, and view-overlay coverage
-- once (so a module computes them a single time, not per line/capture). A
-- decoration skips any row it returns true for. `line` is optional, fetched only
-- if a coverage check needs it. `.skip` / `.skip_conceal` are kept as distinct
-- names for call-site readability though they now coincide.
function M.make_skipper(bufnr)
  local reveal = M.reveal_set(bufnr)
  local cfoff = M.clang_format_off(bufnr)
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
    return line ~= nil and view.covers(line, bufnr, row0)
  end
  local function any(row0, line)
    return reveal[row0] or diag[row0] == true or cfoff[row0] or covered(row0, line)
  end
  return { skip = any, skip_conceal = any }
end

-- Per-buffer module enable/disable (default enabled). The umbrella's
-- :DansFrontend command flips these; each module's refresh consults
-- M.module_enabled and clears its own decorations when off.
local module_off = {}
function M.module_enabled(bufnr, name)
  local off = module_off[bufnr]
  return not (off and off[name])
end
function M.set_module(bufnr, name, on)
  local off = module_off[bufnr] or {}
  off[name] = (not on) or nil
  module_off[bufnr] = off
end

return M
