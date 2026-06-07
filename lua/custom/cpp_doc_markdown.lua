-- View-only markdown rendering of `///` doc-comment blocks in .hpp headers.
-- Conceal + virt_text only; source bytes are never touched. `///` (not plain
-- `//`) marks a doc block, so ordinary comments are left as comments. The block
-- gets a distinct background so it reads as a block; the cursor line shows the
-- raw `///` text (concealcursor=''), like the other dans view modules.
--
-- Per `///` line in a run of `///` lines:
--   /// # Heading   ->  Heading        (bold, the `#`s hidden)
--   /// - item       ->  • item         (the `-` shown as a bullet)
--   /// `code`       ->  code           (code-colored, backticks hidden)
-- and the `/// ` leader is concealed so the prose reads as prose.
--
-- Scope: heading / bullet / inline-code / leader / block background. Not yet:
-- **bold** / *italic* inline, fenced ``` blocks, numbered lists. On by default
-- for .hpp; toggle per buffer with :DansDocMarkdown.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_cpp_doc_md'
local enabled = {} -- bufnr -> bool; nil means "default", which is ON for .hpp
local last_row = {} -- bufnr -> cursor row, to skip refresh on horizontal moves

local function is_hpp(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):sub(-4) == '.hpp'
end

-- On by default (like the other view modules); :DansDocMarkdown sets an explicit
-- false to turn it off for a buffer.
local function is_on(bufnr)
  local v = enabled[bufnr]
  if v == nil then
    return true
  end
  return v
end

-- Follow tokyonight's markdown for the foreground, plus a distinct block
-- background (the float bg, which adapts day/night). The text groups carry that
-- same bg so it shows BEHIND the prose -- a fg-only group would let Normal's bg
-- through and the block would only tint the margins. Re-asserted on ColorScheme.
local function set_hl()
  local get = function(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  local normal = get 'Normal'
  local block_bg = (get 'NormalFloat').bg or normal.bg
  vim.api.nvim_set_hl(0, 'DansDocBlock', { bg = block_bg })
  local on_block = function(g, src, extra)
    local h = { fg = get(src).fg or normal.fg, bg = block_bg }
    for k, v in pairs(extra or {}) do
      h[k] = v
    end
    vim.api.nvim_set_hl(0, g, h)
  end
  on_block('DansDocText', 'Normal')
  on_block('DansDocHeading', '@markup.heading', { bold = true })
  on_block('DansDocCode', '@markup.raw')
  on_block('DansDocBullet', '@markup.list')
end

local function conceal(bufnr, row0, s, e, cchar)
  if e > s then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s, { end_col = e, conceal = cchar or '' })
  end
end

local function hl(bufnr, row0, s, e, group, priority)
  if e > s then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s, { end_col = e, hl_group = group, priority = priority })
  end
end

-- Render one `/// ...` line. row0 is 0-based; content_col is the byte column
-- where the doc text starts (after `///` and one optional space).
local function render_line(bufnr, row0, line)
  local indent, content = line:match '^(%s*)///%s?(.*)$'
  if not content or content == '' then
    return
  end
  local content_col = #line - #content -- byte col of the first content char

  -- hide the `/// ` leader
  conceal(bufnr, row0, #indent, content_col)
  -- repaint the whole body as doc text (block bg + tokyonight fg); element spans
  -- below paint over this at a higher priority.
  hl(bufnr, row0, content_col, #line, 'DansDocText', 150)

  local function col_of(idx)
    return content_col + idx - 1
  end

  -- line-level: heading (# ...) or bullet (- / *), mutually exclusive
  local hashes, htext = content:match '^(#+)%s+(.*)$'
  if hashes then
    local text_idx = #content - #htext + 1 -- 1-based index where heading text starts
    conceal(bufnr, row0, content_col, col_of(text_idx)) -- hide `#+ `
    hl(bufnr, row0, col_of(text_idx), #line, 'DansDocHeading', 200)
  else
    local b_indent = content:match '^(%s*)[%-%*]%s+'
    if b_indent then
      local marker = col_of(#b_indent + 1) -- the `-` / `*`
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, marker, {
        end_col = marker + 1,
        conceal = '•',
        hl_group = 'DansDocBullet',
        priority = 200,
      })
    end
  end

  -- inline `code`: hide the backticks, color the inner span
  local i = 1
  while true do
    local s = content:find('`', i, true)
    if not s then
      break
    end
    local e = content:find('`', s + 1, true)
    if not e then
      break
    end
    conceal(bufnr, row0, col_of(s), col_of(s) + 1)
    hl(bufnr, row0, col_of(s + 1), col_of(e), 'DansDocCode', 200)
    conceal(bufnr, row0, col_of(e), col_of(e) + 1)
    i = e + 1
  end
end

local function refresh(bufnr)
  if not (vim.api.nvim_buf_is_valid(bufnr) and is_hpp(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not is_on(bufnr) then
    return
  end
  local cur = bufnr == vim.api.nvim_get_current_buf() and (vim.api.nvim_win_get_cursor(0)[1] - 1) or -1
  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  local i = 1
  while i <= n do
    if lines[i]:match '^%s*///' then
      local j = i
      while j <= n and lines[j]:match '^%s*///' do
        j = j + 1
      end
      for k = i, j - 1 do
        local row0 = k - 1
        -- block background on every line of the run (cursor line included, so the
        -- block stays continuous while its text is revealed raw).
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, 0, { line_hl_group = 'DansDocBlock' })
        if row0 ~= cur then
          render_line(bufnr, row0, lines[k])
        end
      end
      i = j
    else
      i = i + 1
    end
  end
end

M.refresh = refresh

function M.set_enabled(bufnr, on)
  enabled[bufnr] = on or nil
  refresh(bufnr)
end

function M.setup()
  set_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_doc_md', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter', 'TextChanged', 'TextChangedI', 'WinScrolled' }, {
    group = group,
    pattern = '*.hpp',
    callback = function(ev)
      vim.opt_local.conceallevel = 2
      vim.opt_local.concealcursor = ''
      refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    pattern = '*.hpp',
    callback = function(ev)
      local r = vim.api.nvim_win_get_cursor(0)[1]
      if last_row[ev.buf] == r then
        return
      end
      last_row[ev.buf] = r
      refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })

  vim.api.nvim_create_user_command('DansDocMarkdown', function()
    local b = vim.api.nvim_get_current_buf()
    enabled[b] = not is_on(b) -- explicit true/false (nil default is on)
    refresh(b)
    vim.notify('doc markdown ' .. (enabled[b] and 'on' or 'off'), vim.log.levels.INFO)
  end, { desc = 'Toggle markdown rendering of /// doc blocks (.hpp)' })
end

return M
