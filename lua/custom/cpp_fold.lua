-- Folding for contract-style scope blocks: `{ // Expects ... }` and
-- `{ // Ensures ... }` are made foldable and auto-closed, so the pre/post-
-- condition asserts don't clutter the body. foldmethod=expr for c/cpp/cuda; only
-- those blocks fold (every other line stays level 0, i.e. never folded).

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

function M.setup()
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('ds_cpp_fold', { clear = true }),
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function()
      vim.opt_local.foldmethod = 'expr'
      vim.opt_local.foldexpr = 'v:lua.dans_cpp_foldexpr()'
      vim.opt_local.foldenable = true
      vim.opt_local.foldlevel = 0 -- the Expects/Ensures folds start closed
    end,
  })
end

return M
