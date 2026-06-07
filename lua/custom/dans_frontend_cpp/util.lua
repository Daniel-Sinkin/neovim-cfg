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

-- Whether (row, col) (0-based) sits inside a string / char literal / comment /
-- include path, via treesitter -- so syntax-blind coloring / conceals never fire
-- inside one. Robust where a text scan isn't: block comments, char literals, raw
-- and multi-line strings.
local SKIP_NODES = {
  string_literal = true,
  raw_string_literal = true,
  char_literal = true,
  comment = true,
  system_lib_string = true,
  string_content = true,
  escape_sequence = true,
}
function M.in_literal(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok or not node then
    return false
  end
  while node do
    if SKIP_NODES[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

-- 0-based rows covered by a `static_assert(...)` declaration. Those are dedicated
-- compile-time checks -- code you skim rarely and want to read with full fidelity
-- when you do -- so the whole frontend leaves them verbatim (no conceals, sugar,
-- prefix-stripping). Cached per changedtick. Treesitter: `static_assert_declaration`.
local sa_cache = {}
function M.static_assert_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = sa_cache[bufnr]
  if c and c.tick == tick then
    return c.set
  end
  local set = {}
  pcall(function()
    local parser = vim.treesitter.get_parser(bufnr)
    local tree = parser:parse()[1]
    local q = vim.treesitter.query.parse(parser:lang(), '(static_assert_declaration) @sa')
    for _, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
      local sr, _, er = node:range()
      for r = sr, er do
        set[r] = true
      end
    end
  end)
  sa_cache[bufnr] = { tick = tick, set = set }
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
  local sa = M.static_assert_lines(bufnr)
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
    return reveal[row0] or diag[row0] == true or cfoff[row0] or sa[row0] or covered(row0, line)
  end
  return { skip = any, skip_conceal = any }
end

-- While a macro is recording, every column-shifting view transform is suspended
-- so recorded motions land on real buffer columns, not concealed / virt_text
-- ones. `fold` is exempt -- it hides lines, not columns, so recording in the
-- normal folded view is fine. The umbrella's RecordingEnter/Leave hooks flip this
-- and repaint; the gates below only have to report "off" while it is set.
local recording = false
function M.is_recording()
  return recording
end
function M.set_recording(on)
  recording = on and true or false
end

-- Per-buffer module enable/disable (default enabled). The umbrella's
-- :DansFrontend command flips these; each module's refresh consults
-- M.module_enabled and clears its own decorations when off.
local module_off = {}
function M.module_enabled(bufnr, name)
  if recording and name ~= 'fold' then
    return false
  end
  local off = module_off[bufnr]
  return not (off and off[name])
end
function M.set_module(bufnr, name, on)
  local off = module_off[bufnr] or {}
  off[name] = (not on) or nil
  module_off[bufnr] = off
end

-- Decoration repaint coalescing. The view / decoration refreshes used to run on
-- every WinScrolled, so a mouse-scroll burst reran the whole stack per notch.
-- Instead the umbrella fires this user event once, DECORATE_DEBOUNCE_MS after
-- scrolling stops; decoration modules listen to it (via on_decorate) rather than
-- WinScrolled. Edits stay immediate; cursor moves are immediate too, EXCEPT the
-- per-notch CursorMoved a scroll fires when it drags the cursor at the scrolloff
-- edge -- those are skipped (see is_scrolling) so scroll speed doesn't depend on
-- where the cursor sits, with the settled event doing the one repaint.
M.VIEWPORT_SETTLED = 'DansViewportSettled'
local DECORATE_DEBOUNCE_MS = 100
local last_scroll_ns = 0

-- True for DECORATE_DEBOUNCE_MS after the last scroll. The window equals the
-- debounce, so the settled repaint lands exactly as it closes: a real cursor move
-- within it is still painted by that settled event, and one after it refreshes
-- immediately. hrtime is monotonic ns.
function M.is_scrolling()
  return ((vim.uv or vim.loop).hrtime() - last_scroll_ns) < DECORATE_DEBOUNCE_MS * 1000000
end

-- Register decoration autocmds for `cb` (called with a bufnr): `events` fire it
-- immediately; the debounced VIEWPORT_SETTLED event drives the scroll repaint.
-- Do NOT pass WinScrolled in `events` -- scrolling goes through the settled event.
-- Scroll-dragged CursorMoved is dropped (the settled event covers it).
--
-- Cursor-move handling, since a pure cursor move only flips the reveal set (the
-- row you leave re-renders, the row you enter goes raw):
--   * if neither the changedtick nor the cursor row changed since the last paint,
--     skip entirely -- this kills the CursorMovedI that trails every insert
--     keystroke (TextChangedI already painted) and every horizontal h/l/w move.
--   * if `render_row` is given and it's a plain vertical move on unchanged text
--     (normal mode), repaint ONLY the two flipped rows instead of the whole window.
--   * otherwise (visual mode, an edit, first paint) fall back to the full `cb`.
function M.on_decorate(group, events, cb, render_row)
  local last = {} -- buf -> { tick, row }
  local function note(buf)
    last[buf] = { tick = vim.api.nvim_buf_get_changedtick(buf), row = M.cursor_row0(buf) }
  end
  vim.api.nvim_create_autocmd(events, {
    group = group,
    callback = function(ev)
      local buf = ev.buf
      if ev.event == 'CursorMoved' or ev.event == 'CursorMovedI' then
        if M.is_scrolling() then
          return
        end
        local tick = vim.api.nvim_buf_get_changedtick(buf)
        local row = M.cursor_row0(buf)
        local st = last[buf]
        if st and st.tick == tick and st.row == row then
          return -- nothing the decoration depends on changed
        end
        if render_row and st and st.tick == tick and row and st.row and vim.fn.mode():sub(1, 1) == 'n' then
          render_row(buf, st.row) -- the row we left -> back to overlay
          render_row(buf, row) -- the row we entered -> raw
          last[buf] = { tick = tick, row = row }
          return
        end
      end
      cb(buf)
      note(buf)
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = M.VIEWPORT_SETTLED,
    callback = function(ev)
      cb(ev.buf)
      note(ev.buf)
    end,
  })
end

-- Install the single WinScrolled debouncer that fires VIEWPORT_SETTLED once
-- scrolling has been quiet for DECORATE_DEBOUNCE_MS. Called once by the umbrella.
local scroll_timer
function M.setup_viewport_debounce()
  local group = vim.api.nvim_create_augroup('ds_viewport_debounce', { clear = true })
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    callback = function()
      last_scroll_ns = (vim.uv or vim.loop).hrtime()
      if not scroll_timer then
        scroll_timer = (vim.uv or vim.loop).new_timer()
      end
      scroll_timer:stop()
      scroll_timer:start(
        DECORATE_DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
          vim.api.nvim_exec_autocmds('User', { pattern = M.VIEWPORT_SETTLED })
        end)
      )
    end,
  })
end

return M
