-- Read-mode that re-renders C/C++/CUDA variable declarations in a JAI-like
-- syntax. View-only (extmark conceal + inline virt_text). ON by default for
-- c/cpp/cuda buffers; toggle per-buffer with :JaiView.
--
--   int x{7}        ->  x: int = 7
--   int x{}         ->  x: int
--   T name{init}    ->  name: T = init
--   auto x = e      ->  x := e          (or x: <deduced> = e when clangd has it)
--   auto& x = e     ->  x := &e
--   auto* x = e     ->  x := e          (pointer-ness folded into the value)
--
-- Deduced types come from clangd's inlay hints (requested directly here, not
-- via the built-in renderer) and are placed between the `:` and `=`, dimmed via
-- DansInlayType. `_` declarations get no type hint.
--
-- Leading `mut` / `mut_unchecked` / `cpy` markers and `[[maybe_unused]]` are
-- preserved as a prefix; leading `const` is dropped (it's the hidden default,
-- same as the const concealment in config/autocmds.lua).
--
-- Reveal is cursor-line driven: the line the cursor sits on shows the real C++
-- (no overlay, no type hint); every other line shows the JAI overlay. Moving
-- the cursor flips the line you leave back to JAI and reveals the one you land
-- on. Mode-agnostic (insert mode has no special effect).

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_jai_view'
local enabled = {}
local revealed = {} -- bufnr -> { [row0] = true } lines currently shown raw (cursor / visual selection)
local hint_type = {} -- bufnr -> { [row0] = "int *" } from clangd Type inlay hints
local show_hints = true -- deduced-type hints on/off (toggle with :InlineHints)

local STMT_KEYWORDS = {
  ['return'] = true,
  ['if'] = true,
  ['else'] = true,
  ['for'] = true,
  ['while'] = true,
  ['switch'] = true,
  ['case'] = true,
  ['do'] = true,
  ['throw'] = true,
  ['delete'] = true,
  ['using'] = true,
  ['namespace'] = true,
  ['template'] = true,
  ['struct'] = true,
  ['class'] = true,
  ['enum'] = true,
  ['typedef'] = true,
  ['def'] = true,
  ['co_return'] = true,
  ['co_await'] = true,
  ['co_yield'] = true,
  ['static_assert'] = true,
}

local MARKERS = { 'mut_unchecked', 'mut', 'cpy' }

-- Marker word -> highlight group, shared with cpp_markers.lua.
local MARKER_HL = {
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
  cpy = 'DansMarkerCpy',
}

-- Peel leading attributes/markers. `const` is dropped; mut/cpy and
-- `[[maybe_unused]]` are kept as a prefix. Returns (prefix, rest).
local function split_markers(s)
  local prefix = ''
  local rest = s
  while true do
    local matched = false

    local after_const = rest:match '^const%s+(.*)$'
    if after_const then
      rest = after_const
      matched = true
    end

    if not matched then
      local after_mu = rest:match '^%[%[maybe_unused%]%]%s+(.*)$'
      if after_mu then
        prefix = prefix .. '[[maybe_unused]] '
        rest = after_mu
        matched = true
      end
    end

    if not matched then
      for _, mk in ipairs(MARKERS) do
        local after = rest:match('^' .. mk .. '%s+(.*)$')
        if after then
          prefix = prefix .. mk .. ' '
          rest = after
          matched = true
          break
        end
      end
    end

    if not matched then
      break
    end
  end
  return prefix, rest
end

local function looks_like_type(t)
  if t == '' then
    return false
  end
  if t:match '[%(%)%[%]{}=;]' then
    return false
  end
  if t:find('->', 1, true) then
    return false
  end
  local first = t:match '^([%w_]+)'
  if first and STMT_KEYWORDS[first] then
    return false
  end
  return true
end

-- Marker keywords that should pop wherever they appear in an expression
-- (e.g. `copy(x)` in a value), so the overlay matches the matchadd coloring on
-- real text.
local EXPR_MARKERS = {
  copy = 'DansMarkerCpy',
  cpy = 'DansMarkerCpy',
  mut = 'DansMarkerMut',
  mut_unchecked = 'DansMarkerMut',
}

-- Split `text` into chunks, coloring whole-word marker keywords.
local function colorize(text)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local s, e = text:find('[%a_][%w_]*', i)
    if not s then
      out[#out + 1] = { text:sub(i), 'Normal' }
      break
    end
    if s > i then
      out[#out + 1] = { text:sub(i, s - 1), 'Normal' }
    end
    local word = text:sub(s, e)
    out[#out + 1] = { word, EXPR_MARKERS[word] or 'Normal' }
    i = e + 1
  end
  return out
end

-- Build the virt_text chunk list for a parsed declaration, or nil if `core`
-- isn't a recognized declaration form.
local function build_chunks(prefix, core, had_semi, type_hint)
  local semi = had_semi and ';' or ''

  -- structured binding: auto [a, b] = expr  ->  [a, b] := expr (no per-element
  -- type hints; clangd's binding hints aren't reliable enough).
  local sb_sigil, sb_binds, sb_expr = core:match '^auto([&*]?)%s*%[(.-)%]%s*=%s*(.+)$'

  local sigil, name, expr = core:match '^auto([&*]?)%s+([%w_]+)%s*=%s*(.+)$'
  local typ, nm, init
  if not sb_binds and not name then
    typ, nm, init = core:match '^(.-)%s+([%w_]+)%s*{(.*)}$'
    if not (nm and looks_like_type(typ)) then
      return nil
    end
  end

  local chunks = {}
  local function add(text, hl)
    if text ~= '' then
      chunks[#chunks + 1] = { text, hl or 'Normal' }
    end
  end
  -- Append value text, coloring marker keywords inside it.
  local function add_value(text)
    for _, c in ipairs(colorize(text)) do
      chunks[#chunks + 1] = c
    end
  end

  if prefix ~= '' then
    add(prefix, MARKER_HL[prefix:match '^(%S+)'] or 'Normal')
  end

  if sb_binds then
    add('[' .. sb_binds .. '] := ' .. ((sb_sigil == '&') and '&' or ''))
    add_value(sb_expr)
    add(semi)
  elseif name then
    if type_hint and name ~= '_' then
      add(name .. ': ')
      add(type_hint, 'DansInlayType')
      add ' = '
      add_value(expr)
      add(semi)
    else
      add(name .. ' := ' .. ((sigil == '&') and '&' or ''))
      add_value(expr)
      add(semi)
    end
  else
    -- Explicit type: shown in Normal (your written source, not injected), so it
    -- reads apart from the muted-blue deduced hints. std:: stripped.
    add(nm .. ': ' .. (typ:gsub('std::', '')))
    if init ~= '' then
      add ' = '
      add_value(init)
    end
    add(semi)
  end

  return chunks
end

-- Returns (start_col, chunks) for the overlay, or nil if the line isn't a
-- transformable declaration. `type_hint` is the deduced type for this line.
local function render_line(line, type_hint)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  local had_semi = body:match ';%s*$' ~= nil
  local core_in = (body:gsub(';%s*$', ''))
  local prefix, core = split_markers(core_in)
  local chunks = build_chunks(prefix, core, had_semi, type_hint)
  if not chunks then
    return nil
  end
  return #indent, chunks
end

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function cursor_row0(bufnr)
  if bufnr == vim.api.nvim_get_current_buf() then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
end

local function type_for(bufnr, row0)
  if not show_hints then
    return nil
  end
  local m = hint_type[bufnr]
  return m and m[row0] or nil
end

-- Set of rows to show raw (no overlay): the cursor line, or the whole visual
-- selection while in a visual mode. Reveal is cursor/selection driven.
local function reveal_set(bufnr)
  local cur = cursor_row0(bufnr)
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

local function set_row(bufnr, row0, reveal)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, row0, row0 + 1)
  if reveal then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  if not line then
    return
  end
  local start_col, chunks = render_line(line, type_for(bufnr, row0))
  if start_col then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, start_col, {
      end_col = #line,
      conceal = '',
      virt_text = chunks,
      virt_text_pos = 'inline',
    })
  end
end

local function refresh(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  clear(bufnr)
  local set = reveal_set(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    local row0 = row - 1
    if not set[row0] then
      local start_col, chunks = render_line(line, type_for(bufnr, row0))
      if start_col then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, start_col, {
          end_col = #line,
          conceal = '',
          virt_text = chunks,
          virt_text_pos = 'inline',
        })
      end
    end
  end
  revealed[bufnr] = set
end

-- Incremental: restore overlays on rows that left the reveal set, drop overlays
-- on rows that entered it. Handles both single-cursor and visual-selection.
local function on_cursor(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local new = reveal_set(bufnr)
  local old = revealed[bufnr] or {}
  for row0 in pairs(old) do
    if not new[row0] then
      set_row(bufnr, row0, false)
    end
  end
  for row0 in pairs(new) do
    if not old[row0] then
      set_row(bufnr, row0, true)
    end
  end
  revealed[bufnr] = new
end

-- Request Type inlay hints from clangd directly (not the built-in renderer, so
-- nothing renders at end-of-line), cache the deduced type per row, re-render.
local function fetch_hints(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local clients = vim.lsp.get_clients { bufnr = bufnr, method = 'textDocument/inlayHint' }
  if #clients == 0 then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = 0, character = 0 },
      ['end'] = { line = math.max(0, n - 1), character = 0 },
    },
  }
  vim.lsp.buf_request_all(bufnr, 'textDocument/inlayHint', params, function(results)
    if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    -- Keep only the leftmost Type hint per line: that's the declarator's type,
    -- not e.g. a lambda's return-type hint placed further right on the line.
    local per_line = {}
    for _, res in pairs(results or {}) do
      for _, hint in ipairs((res or {}).result or {}) do
        if hint.kind == 1 and hint.position then -- 1 = Type
          local label = hint.label
          if type(label) == 'table' then
            local s = ''
            for _, part in ipairs(label) do
              s = s .. (part.value or '')
            end
            label = s
          end
          local t = tostring(label or ''):gsub('^%s*:%s*', ''):gsub('%s+$', '')
          local line = hint.position.line
          local char = hint.position.character
          if per_line[line] == nil or char < per_line[line].char then
            per_line[line] = { char = char, type = t }
          end
        end
      end
    end
    local map = {}
    for line, info in pairs(per_line) do
      -- const is the hidden default and std:: is hidden everywhere; drop both
      -- from the deduced type so it matches the rest of the view.
      local t = info.type:gsub('^const%s+', ''):gsub('std::', '')
      -- Lambdas render as "(lambda at ...)" — useless noise; the lambda is
      -- written inline, so show no type (matches how functions read).
      if t ~= '' and not t:find('lambda', 1, true) then
        map[line] = t
      end
    end
    hint_type[bufnr] = map
    refresh(bufnr)
  end)
end

local function enable(bufnr)
  enabled[bufnr] = true
  vim.opt_local.conceallevel = 2
  -- Empty: cursor line is raw WYSIWYG, driven by cursor position not mode.
  vim.opt_local.concealcursor = ''
  refresh(bufnr)
  fetch_hints(bufnr)
end

local function disable(bufnr)
  enabled[bufnr] = nil
  revealed[bufnr] = nil
  hint_type[bufnr] = nil
  clear(bufnr)
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  if enabled[bufnr] then
    disable(bufnr)
  else
    enable(bufnr)
  end
end

-- Toggle the deduced-type inlay hints (global) while keeping the jai overlay.
function M.toggle_hints()
  show_hints = not show_hints
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('JAI type hints ' .. (show_hints and 'on' or 'off'), vim.log.levels.INFO)
end

function M.setup()
  vim.api.nvim_create_user_command('JaiView', M.toggle, { desc = 'Toggle JAI-style declaration view' })
  vim.api.nvim_create_user_command('InlineHints', M.toggle_hints, { desc = 'Toggle deduced-type inline hints' })

  local group = vim.api.nvim_create_augroup('ds_jai_view', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      enable(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
  -- CursorMoved updates the reveal as the cursor/selection moves; ModeChanged
  -- catches entering/leaving visual mode (which may not move the cursor).
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'ModeChanged' }, {
    group = group,
    callback = function(ev)
      on_cursor(ev.buf)
    end,
  })
  -- Refresh deduced types: BufEnter/InsertLeave plus CursorHold (a natural
  -- debounce for the async clangd response after edits).
  vim.api.nvim_create_autocmd({ 'BufEnter', 'InsertLeave', 'CursorHold' }, {
    group = group,
    callback = function(ev)
      fetch_hints(ev.buf)
    end,
  })
end

return M
