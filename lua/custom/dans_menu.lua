-- DANS config menu (<leader>dan): one place to toggle every dans-cpp-frontend
-- module, flip the view/tool options (type hints, lambda view, perf overlay,
-- profiler), and set the font size. A small floating grid.
--
--   j / k (count ok, e.g. 3j)  move between rows
--   h / l, b / w, arrows       move between the two columns (b = left, w = right)
--   <CR> / <Space>             toggle, or (font) open an input to type a value
--   q / <Esc>                  close
--
-- Module toggles apply to the buffer/window the menu was opened from (captured as
-- target_*), run through nvim_win_call so window-local effects (conceallevel, the
-- visible range) land there rather than in the floating window.

local M = {}

local frontend = require 'custom.dans_frontend_cpp'
local docmd = require 'custom.cpp_doc_markdown'
local macros = require 'custom.dans_macros'
local view = require 'custom.dans_frontend_cpp.view'
local perf = require 'custom.dans_perf'

local ns = vim.api.nvim_create_namespace 'ds_dans_menu'
local COLW = 24

local state = nil -- { buf, win, target_buf, target_win, sections, lines, navrows, headers, cur }

-- ----------------------------------------------------------------- font I/O ---

local function font_pt()
  return tonumber((vim.o.guifont or ''):match ':h(%d+%.?%d*)')
end

local function set_font_pt(pt)
  local g = vim.o.guifont or ''
  if g == '' then
    g = 'Monaspace Krypton:h' .. pt
  elseif g:match ':h%d' then
    g = g:gsub(':h%d+%.?%d*', ':h' .. pt)
  else
    g = g .. ':h' .. pt
  end
  vim.o.guifont = g
end

-- --------------------------------------------------------------- item model ---
-- Each item: { label, checked()->bool|nil, value()->str|nil, activate(), full? }

local function checkbox(label, checked, toggle)
  return { label = label, checked = checked, activate = toggle }
end

local function build_sections(tbuf, twin)
  local in_target = function(fn)
    vim.api.nvim_win_call(twin, fn)
  end

  -- frontend modules + doc markdown
  local mods = {}
  for _, name in ipairs(frontend.TOGGLEABLE) do
    mods[#mods + 1] = checkbox(name, function()
      return frontend.module_is_on(name, tbuf)
    end, function()
      local on = frontend.module_is_on(name, tbuf)
      in_target(function()
        frontend.module_set(name, tbuf, not on)
      end)
    end)
  end
  mods[#mods + 1] = checkbox('doc markdown', function()
    return docmd.is_enabled(tbuf)
  end, function()
    local on = docmd.is_enabled(tbuf)
    in_target(function()
      docmd.set_enabled(tbuf, not on)
    end)
  end)
  mods[#mods + 1] = checkbox('macros', function()
    return macros.is_enabled(tbuf)
  end, function()
    local on = macros.is_enabled(tbuf)
    in_target(function()
      macros.set_enabled(tbuf, not on)
    end)
  end)

  local all_on = function()
    for _, it in ipairs(mods) do
      if not it.checked() then
        return false
      end
    end
    return true
  end
  local all = checkbox('all modules', all_on, function()
    local target = not all_on()
    in_target(function()
      for _, name in ipairs(frontend.TOGGLEABLE) do
        frontend.module_set(name, tbuf, target)
      end
      docmd.set_enabled(tbuf, target)
      macros.set_enabled(tbuf, target)
    end)
  end)
  all.full = true

  local hints = checkbox('type hints', view.hints_enabled, view.toggle_hints)
  local lambda = checkbox('lambda view', view.lambda_enabled, view.toggle_lambda)
  local tokens = checkbox('tokenizer view', function()
    return require('custom.dans_tokenizer').is_enabled(tbuf)
  end, function()
    in_target(function()
      require('custom.dans_tokenizer').toggle(tbuf)
    end)
  end)
  -- Global (not per-buffer): drops every custom display tweak and shows stock
  -- tokyonight everywhere.
  local vanilla = checkbox('vanilla theme', function()
    return require('custom.dans_vanilla').is_enabled()
  end, function()
    require('custom.dans_vanilla').toggle()
  end)

  local mon = checkbox('perf overlay', perf.monitor_enabled, perf.monitor_toggle)
  local prof = checkbox('profiler', perf.profile_running, function()
    M.close() -- so the real work / report split isn't the menu itself
    perf.profile_toggle()
  end)
  local asm = {
    label = 'asm (fn under cursor)',
    full = true,
    activate = function()
      M.close() -- the asm split must open in the real window, not the menu float
      if twin and vim.api.nvim_win_is_valid(twin) then
        vim.api.nvim_set_current_win(twin)
      end
      require('custom.dans_asm').show()
    end,
  }
  local keylog = {
    label = 'key log (recent input)',
    full = true,
    activate = function()
      M.close()
      require('custom.dans_keylog').show()
    end,
  }

  local font = {
    label = 'font size',
    value = function()
      return tostring(font_pt() or '?')
    end,
    full = true,
    activate = function()
      vim.ui.input({ prompt = 'Font size: ', default = tostring(font_pt() or '') }, function(input)
        local n = input and tonumber((input:match '^%s*(%d+%.?%d*)%s*$'))
        if n then
          set_font_pt(n)
          M.render()
        end
      end)
    end,
  }

  return {
    { title = 'Frontend modules', items = vim.list_extend({ all }, mods) },
    { title = 'View', items = { hints, lambda, tokens, vanilla } },
    { title = 'Tools', items = { mon, prof, asm, keylog } },
    { title = 'Settings', items = { font } },
  }
end

-- ------------------------------------------------------------------- render ---

local function cell_text(it)
  if it.value then
    return string.format('  %-11s %s', it.label, it.value())
  end
  if it.checked then
    return string.format('  [%s] %s', it.checked() and 'x' or ' ', it.label)
  end
  return '  ' .. it.label -- plain action item (no checkbox, no value)
end

-- (Re)compute lines + the navigation grid from the live item states.
local function rebuild()
  local s = state
  s.lines, s.navrows, s.headers = {}, {}, {}
  local function add(text)
    s.lines[#s.lines + 1] = text
    return #s.lines - 1 -- 0-based row
  end
  for si, sec in ipairs(s.sections) do
    if si > 1 then
      add ''
    end
    s.headers[add(sec.title)] = true
    local i = 1
    while i <= #sec.items do
      local left = sec.items[i]
      if left.full then
        local t = cell_text(left)
        local r = add(t)
        s.navrows[#s.navrows + 1] = { { item = left, line0 = r, cs = 0, ce = #t } }
        i = i + 1
      else
        local right = (sec.items[i + 1] and not sec.items[i + 1].full) and sec.items[i + 1] or nil
        local lt = cell_text(left)
        local pad = string.rep(' ', math.max(1, COLW - vim.fn.strdisplaywidth(lt)))
        local t = lt .. (right and pad .. cell_text(right) or '')
        local r = add(t)
        local cells = { { item = left, line0 = r, cs = 0, ce = #lt } }
        if right then
          cells[2] = { item = right, line0 = r, cs = #lt + #pad, ce = #t }
        end
        s.navrows[#s.navrows + 1] = cells
        i = i + (right and 2 or 1)
      end
    end
  end
end

function M.render()
  local s = state
  if not s or not vim.api.nvim_buf_is_valid(s.buf) then
    return
  end
  rebuild()
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, s.lines)
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for row in pairs(s.headers) do
    pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, row, 0, { line_hl_group = 'Title' })
  end
  for ri, cells in ipairs(s.navrows) do
    for ci, cell in ipairs(cells) do
      local it = cell.item
      local grp = 'Normal'
      if it.checked then
        grp = it.checked() and 'DiagnosticOk' or 'Comment'
      end
      if ri == s.cur.r and ci == s.cur.c then
        grp = 'PmenuSel'
      end
      pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, cell.line0, cell.cs, { end_col = cell.ce, hl_group = grp, priority = 200 })
    end
  end
  local cell = s.navrows[s.cur.r][s.cur.c]
  if cell then
    pcall(vim.api.nvim_win_set_cursor, s.win, { cell.line0 + 1, cell.cs })
  end
end

-- ------------------------------------------------------------------- nav/act --

local function nav(dr, dc)
  local s = state
  local count = math.max(1, vim.v.count1)
  if dr ~= 0 then
    s.cur.r = math.max(1, math.min(#s.navrows, s.cur.r + dr * count))
    s.cur.c = math.max(1, math.min(#s.navrows[s.cur.r], s.cur.c))
  else
    s.cur.c = math.max(1, math.min(#s.navrows[s.cur.r], s.cur.c + dc * count))
  end
  M.render()
end

local function activate()
  local s = state
  local cell = s.navrows[s.cur.r][s.cur.c]
  if cell and cell.item.activate then
    cell.item.activate()
  end
  if state then
    M.render()
  end
end

-- --------------------------------------------------------------- open/close ---

function M.close()
  local s = state
  state = nil
  if s and s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
end

function M.open()
  if state then
    M.close()
  end
  local target_win = vim.api.nvim_get_current_win()
  local target_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'dansmenu'
  state = {
    buf = buf,
    target_buf = target_buf,
    target_win = target_win,
    sections = build_sections(target_buf, target_win),
    cur = { r = 1, c = 1 },
  }
  rebuild()
  local width = 2 * COLW + 2
  local height = #state.lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' DANS ',
    title_pos = 'center',
  })
  state.win = win
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false
  M.render()

  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('j', function()
    nav(1, 0)
  end)
  map('k', function()
    nav(-1, 0)
  end)
  map('<Down>', function()
    nav(1, 0)
  end)
  map('<Up>', function()
    nav(-1, 0)
  end)
  -- columns: h/l, plus w/b (left hand stays home -- you navigate by word anyway)
  -- and the arrows. b = left (like h), w = right (a comfier `l`).
  map('h', function()
    nav(0, -1)
  end)
  map('l', function()
    nav(0, 1)
  end)
  map('b', function()
    nav(0, -1)
  end)
  map('w', function()
    nav(0, 1)
  end)
  map('<Left>', function()
    nav(0, -1)
  end)
  map('<Right>', function()
    nav(0, 1)
  end)
  map('<CR>', activate)
  map('<Space>', activate)
  map('q', M.close)
  map('<Esc>', M.close)
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = M.close })
end

return M
