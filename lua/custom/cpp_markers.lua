-- Marker-aware highlighting for C/C++/CUDA: make the mut/cpy exceptions pop
-- against the const-by-default (hidden) sea. View-only (matchadd + highlight).
--   mut, mut_unchecked          -> reddish-pink
--   cpy (and its type + name)   -> yellow
--   copy(...)                   -> yellow
-- Highlight group names are shared with jai_view.lua, which colors the marker
-- prefix inside its overlays using the same groups.

local M = {}

local function set_hl()
  vim.api.nvim_set_hl(0, 'DansMarkerMut', { fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'DansMarkerCpy', { fg = '#e0af68', bold = true })
  -- Deduced-type inlay text inside jai_view overlays (clangd auto types).
  vim.api.nvim_set_hl(0, 'DansInlayType', { fg = '#7dcfff' })
end

local function apply()
  -- Window-local matches, priority above the flattened monochrome syntax.
  vim.fn.matchadd('DansMarkerMut', [[\<mut\>]], 20)
  vim.fn.matchadd('DansMarkerMut', [[\<mut_unchecked\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', [[\<copy\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', [[\<cpy\>]], 20)
  -- cpy parameter: also color the type and name that follow, up to the next
  -- `,` or `)` (the parameter's extent in a function signature).
  vim.fn.matchadd('DansMarkerCpy', [[\<cpy\>\s\+\zs[^,)]\+]], 20)
end

function M.setup()
  set_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_markers', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = apply,
  })
  -- Re-assert colors after a colorscheme change (tokyonight day/night swap).
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
end

return M
