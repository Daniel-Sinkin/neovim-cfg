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
-- Fenced code: a ``` line opens a region rendered verbatim (no markdown) on a
-- separate code-block background until the closing ```; the fence lines are
-- hidden. With vim.g.dans_doc_md_inline_frontend set, fenced code additionally
-- gets the cpp frontend's text transforms (alias collapse + std:: strip) so
-- examples read in the dans dialect -- a load-time setting, off by default.
-- Scope: heading / bullet / inline-code / fenced code / leader / block
-- background. Not yet: **bold** / *italic* inline, numbered lists. On by default
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
  -- fenced ``` code: a separate code-block background (tokyonight's, falling back
  -- to the inline-code bg, then the doc-block bg) so the fence reads apart from
  -- the prose; its fg/bg also paint the code text (no markdown parsing inside).
  local code_bg = (get '@markup.raw.block').bg or (get '@markup.raw').bg or block_bg
  vim.api.nvim_set_hl(0, 'DansDocCodeBlock', { fg = (get '@markup.raw').fg or normal.fg, bg = code_bg })
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

-- Opt-in "inline frontend" over fenced code (set vim.g.dans_doc_md_inline_frontend
-- in your config; load-time, reload to change). Applies the cheap text transforms
-- of the cpp frontend -- the $-alias collapse (reusing the SAME aliases.ALIASES
-- table, so there is one source of truth) and the std::/dans:: strip -- so code
-- examples read in the dans dialect. The declaration overlay (x: T, carets) is
-- deliberately NOT applied: examples are rarely declarations, and that would need
-- treesitter over comment-embedded code.
local function inline_frontend_on()
  return vim.g.dans_doc_md_inline_frontend == true
end

local function is_word(c)
  return c ~= '' and c:match '[%w_]' ~= nil
end

local function apply_inline_frontend(bufnr, row0, content, base_col)
  -- alias collapse first, so std::runtime_error -> $re before the std:: strip.
  local ok, aliases = pcall(function()
    return require('custom.dans_frontend_cpp.aliases').ALIASES
  end)
  if ok and aliases then
    for _, a in ipairs(aliases) do
      local kw, rep = a[1], a[2]
      local from = 1
      while true do
        local s, e = content:find(kw, from, true)
        if not s then
          break
        end
        local before = s > 1 and content:sub(s - 1, s - 1) or ''
        if not is_word(before) and not is_word(content:sub(e + 1, e + 1)) then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, base_col + s - 1, {
            end_col = base_col + e,
            conceal = '',
            virt_text = { { rep, 'DansDocCodeBlock' } },
            virt_text_pos = 'inline',
          })
        end
        from = e + 1
      end
    end
  end
  for _, q in ipairs { 'std::', 'dans::' } do
    local from = 1
    while true do
      local s, e = content:find(q, from, true)
      if not s then
        break
      end
      if not is_word(s > 1 and content:sub(s - 1, s - 1) or '') then
        conceal(bufnr, row0, base_col + s - 1, base_col + e)
      end
      from = e + 1
    end
  end
end

-- Render one `/// ...` line. row0 is 0-based; content_col is the byte column
-- where the doc text starts (after `///` and one optional space).
local function render_line(bufnr, row0, line)
  local indent, content = line:match '^(%s*)///%s?(.*)$'
  if not content then
    return
  end
  local content_col = #line - #content -- byte col of the first content char

  -- hide the `/// ` leader (also for an empty `///` line, so it reads as a blank
  -- line inside the block rather than a stray `///`).
  conceal(bufnr, row0, #indent, content_col)
  if content == '' then
    return
  end
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
      local in_fence = false -- inside a ``` ... ``` fenced code region
      for k = i, j - 1 do
        local row0 = k - 1
        local indent, content = lines[k]:match '^(%s*)///%s?(.*)$'
        content = content or ''
        local is_fence = content:match '^```' ~= nil
        local code = in_fence or is_fence
        -- block background on every line of the run (cursor line included, so the
        -- block stays continuous while its text is revealed raw); fenced lines get
        -- the code-block background instead.
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, 0, {
          line_hl_group = code and 'DansDocCodeBlock' or 'DansDocBlock',
        })
        if row0 ~= cur then
          if is_fence then
            -- hide the whole fence line (leader + ``` + language); the code bg
            -- left behind delimits the block.
            conceal(bufnr, row0, #indent, #lines[k])
          elseif in_fence then
            -- code line: conceal the leader; the code shows verbatim, colored by
            -- the DansDocCodeBlock line highlight. With the inline-frontend
            -- setting on, also apply the dans text transforms to the code.
            local content_col = #lines[k] - #content
            conceal(bufnr, row0, #indent, content_col)
            if inline_frontend_on() then
              apply_inline_frontend(bufnr, row0, content, content_col)
            end
          else
            render_line(bufnr, row0, lines[k])
          end
        end
        if is_fence then
          in_fence = not in_fence
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
