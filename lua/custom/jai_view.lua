-- Read-mode that re-renders C/C++/CUDA variable declarations in a JAI-like
-- syntax. View-only (extmark conceal + inline virt_text). ON by default for
-- c/cpp/cuda buffers; toggle per-buffer with :JaiView.
--
--   int x{7}        ->  x: int = 7
--   int x{}         ->  x: int
--   T name{init}    ->  name: T = init
--   auto x = e      ->  x := e
--   auto& x = e     ->  x := &e
--   auto* x = e     ->  x := e          (pointer-ness folded into the value)
--
-- Leading `mut` / `mut_unchecked` / `cpy` markers are preserved as a prefix;
-- leading `const` is dropped (it's the hidden default, same as the const
-- concealment in config/autocmds.lua).
--
-- Insert-mode behavior mirrors the const concealment: overlays are cleared on
-- InsertEnter and restored on InsertLeave, so normal-mode cursor movement never
-- flips the rendering and only insert mode shows the real C++.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_jai_view'
local enabled = {}

-- First-token words that can never be a type in the strict declaration style;
-- guards the `TYPE NAME{INIT}` pattern against statements like `return Foo{}`.
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

-- Peel leading `const` (dropped) and mut/cpy markers (kept). Returns the kept
-- prefix (with trailing space) and the remaining declaration text.
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

-- Render a declaration body (no leading markers, no trailing ;) into JAI form,
-- or nil if it isn't a recognized declaration.
local function render_core(core)
  local sigil, name, expr = core:match '^auto([&*]?)%s+([%w_]+)%s*=%s*(.+)$'
  if name then
    if sigil == '&' then
      return name .. ' := &' .. expr
    end
    return name .. ' := ' .. expr
  end

  local typ, nm, init = core:match '^(.-)%s+([%w_]+)%s*{(.*)}$'
  if nm and looks_like_type(typ) then
    if init == '' then
      return nm .. ': ' .. typ
    end
    return nm .. ': ' .. typ .. ' = ' .. init
  end

  return nil
end

-- For a full buffer line, returns (start_col, rendered_text) for the overlay,
-- or nil if the line isn't a transformable declaration.
local function render_line(line)
  local indent = line:match '^%s*'
  local body = line:sub(#indent + 1)
  if body == '' then
    return nil
  end
  local had_semi = body:match ';%s*$' ~= nil
  local core_in = (body:gsub(';%s*$', ''))
  local prefix, core = split_markers(core_in)
  local rendered = render_core(core)
  if not rendered then
    return nil
  end
  local out = prefix .. rendered
  if had_semi then
    out = out .. ';'
  end
  return #indent, out
end

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function refresh(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  clear(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    local start_col, rendered = render_line(line)
    if start_col then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row - 1, start_col, {
        end_col = #line,
        conceal = '',
        virt_text = { { rendered, 'Normal' } },
        virt_text_pos = 'inline',
      })
    end
  end
end

local function enable(bufnr)
  enabled[bufnr] = true
  vim.opt_local.conceallevel = 2
  vim.opt_local.concealcursor = 'nc'
  refresh(bufnr)
end

local function disable(bufnr)
  enabled[bufnr] = nil
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

function M.setup()
  vim.api.nvim_create_user_command('JaiView', M.toggle, { desc = 'Toggle JAI-style declaration view' })

  local group = vim.api.nvim_create_augroup('ds_jai_view', { clear = true })
  -- On by default for C-family buffers.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      enable(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
  -- Insert mode shows the real C++ (clear overlays), restore on leaving.
  vim.api.nvim_create_autocmd('InsertEnter', {
    group = group,
    callback = function(ev)
      if enabled[ev.buf] then
        clear(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('InsertLeave', {
    group = group,
    callback = function(ev)
      refresh(ev.buf)
    end,
  })
end

return M
