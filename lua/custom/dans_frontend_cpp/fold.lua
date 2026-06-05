-- Folding for contract-style scope blocks: `{ // Expects ... }` and
-- `{ // Ensures ... }` collapse to a single gray `+-- N lines:` line so the
-- pre/post-condition asserts don't clutter the body. foldmethod=expr for
-- c/cpp/cuda; only those blocks fold (every other line stays level 0). Focus
-- folding (see M.setup) keeps just the fold under the cursor open.

local M = {}

-- Per-line fold descriptors for `lines`: '>1' opens a fold on an Expects/Ensures
-- `{`, '1' for the body, '<1' on the matching `}`, '0' elsewhere. Brace matching
-- is naive (counts `{`/`}` literally), which is fine for these assert-only blocks.
function M.compute_fold_levels(lines)
  local levels = {}
  for i = 1, #lines do
    levels[i] = '0'
  end
  local i = 1
  while i <= #lines do
    if lines[i]:match '^%s*{%s*//%s*[Ee]xpects' or lines[i]:match '^%s*{%s*//%s*[Ee]nsures' then
      local depth, j = 0, i
      while j <= #lines do
        for ch in lines[j]:gmatch '[{}]' do
          depth = depth + (ch == '{' and 1 or -1)
        end
        if depth <= 0 then
          break
        end
        j = j + 1
      end
      if j > i and j <= #lines then
        levels[i] = '>1'
        for k = i + 1, j - 1 do
          levels[k] = '1'
        end
        levels[j] = '<1'
        i = j + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return levels
end

-- Cached per buffer + changedtick: the foldexpr is called per line, so compute
-- the whole map once per change and look up by line.
local cache = {}
function _G.dans_cpp_foldexpr()
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, levels = M.compute_fold_levels(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) }
    cache[buf] = c
  end
  return c.levels[vim.v.lnum] or '0'
end

-- Folded display: a single gray `<indent>+-- N lines:` line on a normal
-- background (no banded Folded highlight, no echoed first-line content), so a
-- closed contract block reads as quiet auxiliary text rather than a loud band.
function _G.dans_cpp_foldtext()
  local start = vim.v.foldstart
  local first = vim.api.nvim_buf_get_lines(0, start - 1, start, false)[1] or ''
  local indent = first:match '^%s*' or ''
  local n = vim.v.foldend - start + 1
  return indent .. '+-- ' .. n .. ' lines:'
end

-- Gray foldtext on the normal background, dropping tokyonight's banded Folded
-- bg. Re-asserted on ColorScheme since the day/night swap runs `:hi clear`.
local function set_fold_hl()
  vim.api.nvim_set_hl(0, 'Folded', { fg = '#6b7280' })
end

-- Focus folding: keep only the fold under the cursor open. `zx` reapplies
-- 'foldlevel' (re-closing every Expects/Ensures fold) then `zv` (reopening the
-- one the cursor sits in). Gated on a line change so horizontal moves and
-- same-line edits don't thrash, and on normal mode so it never fires mid-visual.
local cpp_ft = { c = true, cpp = true, cuda = true }
local focus_last = {}
local function focus_folds()
  if not cpp_ft[vim.bo.filetype] then return end
  if vim.wo.foldmethod ~= 'expr' then return end
  if vim.fn.mode() ~= 'n' then return end
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if focus_last[win] == lnum then return end
  focus_last[win] = lnum
  pcall(vim.cmd, 'normal! zx')
end

function M.setup()
  set_fold_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_fold', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function()
      vim.opt_local.foldmethod = 'expr'
      vim.opt_local.foldexpr = 'v:lua.dans_cpp_foldexpr()'
      vim.opt_local.foldtext = 'v:lua.dans_cpp_foldtext()'
      vim.opt_local.fillchars:append 'fold: '
      vim.opt_local.foldenable = true
      vim.opt_local.foldlevel = 0 -- the Expects/Ensures folds start closed
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, callback = focus_folds })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_fold_hl })
end

return M
