-- Read-mode that re-renders C/C++/CUDA variable declarations in a Odin-like
-- syntax. View-only (extmark conceal + inline virt_text). ON by default for
-- c/cpp/cuda buffers; toggle per-buffer with :DansFrontend.
--
--   int x{7}        ->  x: int = 7
--   int x{}         ->  x: int
--   T name{init}    ->  name: T = init
--   auto x = e      ->  x := e          (or x: <deduced> = e when clangd has it)
--   auto& x = e     ->  ref x := e      (mut ref when non-const)
--   auto* x = e     ->  x := e          (pointer-ness folded into the value)
--
-- This is the orchestration layer: per-buffer state, the visible-range refresh,
-- clangd inlay-hint fetching, and the user commands / autocmds. The parsing
-- lives in parse, the chunk building in render.
--
-- Reveal is cursor-line driven: the line the cursor sits on shows the real C++
-- (no overlay, no type hint); every other line shows the overlay. Moving
-- the cursor flips the line you leave back to the overlay and reveals the one you land
-- on. Mode-agnostic (insert mode has no special effect).

local vu = require 'custom.dans_frontend_cpp.util'
local P = require 'custom.dans_frontend_cpp.parse'
local R = require 'custom.dans_frontend_cpp.render'

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_frontend_view'
local enabled = {}
local hint_type = {} -- bufnr -> { [row0] = "int *" } from clangd Type inlay hints
local show_hints = false -- deduced-type hints off by default (toggle with :InlineHints)

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function type_for(bufnr, row0)
  if not show_hints then
    return nil
  end
  local m = hint_type[bufnr]
  return m and m[row0] or nil
end

local function refresh(bufnr)
  if not (enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  clear(bufnr)
  -- reveal_set (cursor + visual selection) and clang-format-off both stay raw.
  local set = vu.reveal_set(bufnr)
  local cfoff = vu.clang_format_off(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  local align = P.compute_align(lines, s0)
  local diag = vu.diagnostic_lines(bufnr)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    if not set[row0] and not diag[row0] and not cfoff[row0] then
      local start_col, chunks = R.render_line(line, type_for(bufnr, row0), align[row0], bufnr, row0)
      if start_col then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, start_col, {
          end_col = #line,
          conceal = '',
          virt_text = chunks,
          virt_text_pos = 'overlay',
        })
      end
    end
  end
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
      -- const is the hidden default and std::/dans:: are hidden everywhere; drop
      -- them from the deduced type so it matches the rest of the view.
      local t = info.type:gsub('^const%s+', ''):gsub('std::', ''):gsub('dans::', '')
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

-- Enable/disable the overlay for a buffer explicitly (the umbrella's
-- :DansFrontend per-module + master toggles drive this).
function M.set_enabled(bufnr, on)
  if on then
    enable(bufnr)
  else
    disable(bufnr)
  end
end

-- Toggle the deduced-type inlay hints (global) while keeping the overlay.
function M.toggle_hints()
  show_hints = not show_hints
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('frontend type hints ' .. (show_hints and 'on' or 'off'), vim.log.levels.INFO)
end

-- Toggle the experimental lambda-as-function rendering (global). The flag lives
-- in render; flip it there, then re-render every open overlay.
function M.toggle_lambda()
  local on = R.toggle_lambda()
  for bufnr in pairs(enabled) do
    refresh(bufnr)
  end
  vim.notify('frontend lambda view ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
end

-- Whether the overlay is currently active for this buffer.
function M.is_enabled(bufnr)
  return enabled[bufnr] == true
end

-- Whether a line is one the overlay rewrites. Lets other view modules
-- (aliases) defer so they don't double-render on top of the full-line
-- overlay (which orphans their inline virt_text to the end of the line).
function M.covers(line, bufnr, row0)
  return (R.render_line(line, nil, nil, bufnr, row0)) ~= nil
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_frontend_view', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      enable(ev.buf)
    end,
  })
  -- One visible-range refresh for everything: edits, scrolling (WinScrolled),
  -- and the cursor/selection reveal (CursorMoved / ModeChanged recompute
  -- reveal_set). Cheap because it only touches on-screen lines.
  vim.api.nvim_create_autocmd(
    { 'BufEnter', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI', 'ModeChanged', 'WinScrolled', 'DiagnosticChanged' },
    {
      group = group,
      callback = function(ev)
        refresh(ev.buf)
      end,
    }
  )
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
