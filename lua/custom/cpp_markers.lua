-- Marker-aware highlighting for C/C++/CUDA: make the mut/cpy exceptions pop
-- against the const-by-default (hidden) sea. View-only (matchadd + highlight).
--   mut, mut_unchecked          -> reddish-pink
--   cpy (and its type + name)   -> yellow
--   copy(...)                   -> yellow
-- Highlight group names are shared with jai_view.lua, which colors the marker
-- prefix inside its overlays using the same groups.

local M = {}

local MATCH_GROUPS =
  { DansMarkerMut = true, DansMarkerCpy = true, DansConst = true, DansNamespace = true }

local function set_hl()
  vim.api.nvim_set_hl(0, 'DansMarkerMut', { fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'DansMarkerCpy', { fg = '#e0af68', bold = true })
  -- `lambda` pseudo-keyword in jai_view's lambda rendering (green to read as a
  -- declaration keyword, distinct from the mut/cpy markers).
  vim.api.nvim_set_hl(0, 'DansLambda', { fg = '#9ece6a', bold = true })
  -- Deduced-type inlay text inside jai_view overlays (clangd auto types).
  -- Clearly blue so it reads apart from the gray comments.
  vim.api.nvim_set_hl(0, 'DansInlayType', { fg = '#7aa2f7' })
  -- `const` grayed wherever it stays visible (function args, trailing const,
  -- and the leading const when revealed on the cursor line) — const is the
  -- de-emphasized default, `mut` is the bright exception.
  vim.api.nvim_set_hl(0, 'DansConst', { fg = '#6b7280' })
  -- Namespace/scope qualifiers (std::, dans::, Foo::) grayed as visual noise.
  -- std:: is additionally concealed (autocmds.lua) so it only shows, gray, on
  -- the cursor line; every other qualifier stays gray-but-visible.
  vim.api.nvim_set_hl(0, 'DansNamespace', { fg = '#6b7280' })
end

local function apply()
  -- Re-assert the groups here too: `:colorscheme` (e.g. the day/night swap)
  -- runs `:hi clear`, which would otherwise blank these until a ColorScheme
  -- event; defining them on FileType guarantees they exist for this buffer.
  set_hl()

  -- Drop our own previous matches so repeated FileType events don't stack.
  for _, m in ipairs(vim.fn.getmatches()) do
    if MATCH_GROUPS[m.group] then
      pcall(vim.fn.matchdelete, m.id)
    end
  end

  -- Window-local matches, priority above the flattened monochrome syntax.
  -- Only the keyword is colored (not the following type/name).
  vim.fn.matchadd('DansMarkerMut', [[\<mut\>]], 20)
  vim.fn.matchadd('DansMarkerMut', [[\<mut_unchecked\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', [[\<copy\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', [[\<cpy\>]], 20)
  -- Gray every `const`. The leading-const conceal still hides it on non-cursor
  -- lines; this grays the ones that stay visible (args, trailing, and the
  -- leading one revealed on the cursor line).
  vim.fn.matchadd('DansConst', [[\<const\>]], 20)
  -- Gray every `ident::` scope qualifier. std:: is concealed off the cursor
  -- line by a higher-priority match; the rest stay gray-but-visible.
  vim.fn.matchadd('DansNamespace', [[\<\w\+::]], 20)
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
