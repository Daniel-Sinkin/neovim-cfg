-- Marker-aware highlighting for C/C++/CUDA: make the mut/cpy exceptions pop
-- against the const-by-default (hidden) sea. View-only (matchadd + highlight).
--   mut, mut_unchecked          -> reddish-pink
--   cpy (and its type + name)   -> yellow
--   copy(...)                   -> yellow
-- Highlight group names are shared with jai_view.lua, which colors the marker
-- prefix inside its overlays using the same groups.

local M = {}

local MATCH_GROUPS = {
  DansMarkerMut = true,
  DansMarkerCpy = true,
  DansConst = true,
  DansNamespace = true,
  DansMacro = true,
  DansVulkan = true,
  DansSDL = true,
  DansString = true,
  DansCommentMask = true,
  DansIncludeMask = true,
}

local function set_hl()
  vim.api.nvim_set_hl(0, 'DansMarkerMut', { fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'DansMarkerCpy', { fg = '#e0af68', bold = true })
  -- `lambda` pseudo-keyword in jai_view's lambda rendering (green to read as a
  -- declaration keyword, distinct from the mut/cpy markers).
  vim.api.nvim_set_hl(0, 'DansLambda', { fg = '#9ece6a', bold = true })
  -- Vulkan identifiers (Vk*, VK_*) -- purple. Dense in this codebase, so they
  -- get their own category, overriding the generic macro color for VK_*.
  vim.api.nvim_set_hl(0, 'DansVulkan', { fg = '#bb9af7' })
  -- Other all-caps macros / preprocessor constants -- orange. Not bold: these
  -- are dense in API-heavy code, so the hue alone carries the category.
  vim.api.nvim_set_hl(0, 'DansMacro', { fg = '#ff9e64' })
  -- SDL identifiers (SDL_*) -- teal/cyan, its own category.
  vim.api.nvim_set_hl(0, 'DansSDL', { fg = '#2ac3de' })
  -- String literals -- muted green. A calm color (strings are inert content);
  -- applied at high priority so no other coloring/conceal leaks inside them.
  vim.api.nvim_set_hl(0, 'DansString', { fg = '#a3be8c' })
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
  -- Masks that re-neutralize text the syntax-blind matches above would wrongly
  -- color: line/block comments back to Comment, #include <...> paths back to
  -- Normal. Applied at a higher priority so they win inside those regions.
  vim.api.nvim_set_hl(0, 'DansCommentMask', { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'DansIncludeMask', { link = 'Normal' })
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
  -- All-caps macros / preprocessor constants -> orange. >=2 chars so single
  -- T/R template params are spared; mixed-case names (Vec3, GLuint) and k_snake
  -- constants don't match.
  vim.fn.matchadd('DansMacro', [[\<[A-Z][A-Z0-9_]\+\>]], 20)
  -- Vulkan identifiers -> purple, at a higher priority so VK_* overrides the
  -- generic macro color above. Vk* (types) and vk* (functions) are mixed-case so
  -- they never hit the macro match anyway.
  vim.fn.matchadd('DansVulkan', [[\<VK_[A-Z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', [[\<Vk[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', [[\<vk[A-Z][A-Za-z0-9_]*\>]], 25)
  -- SDL identifiers (SDL_*) -> teal. Same priority; SDL_FOO also matches the
  -- macro pattern, so the higher priority makes the teal win.
  vim.fn.matchadd('DansSDL', [[\<SDL_[A-Za-z0-9_]*\>]], 25)
  -- String literals -> green, priority 35 (above the color matches AND the
  -- conceals at 30) so nothing else colors or conceals inside a string. Quoted
  -- pattern (a "..." literal with escapes); not [[...]] -- the [^"\] class
  -- would trip the long-string parser. Single-line strings only.
  vim.fn.matchadd('DansString', '"\\%(\\\\.\\|[^"\\\\]\\)*"', 35)
  -- Masks (priority 28, above the color matches): the matches above are syntax
  -- blind, so they color all-caps tokens inside comments (// IWYU ...) and
  -- include paths (<SDL3/SDL.h>). Recolor those regions back to neutral. Below
  -- the conceal matches (30) so const/std:: concealment is untouched.
  vim.fn.matchadd('DansCommentMask', [[//.*]], 28)
  vim.fn.matchadd('DansCommentMask', [[/\*.\{-}\*/]], 28)
  -- Quoted (not [[...]]): the trailing [>"] char class would close a long string.
  vim.fn.matchadd('DansIncludeMask', '^\\s*#\\s*include\\s*\\zs[<"].\\{-}[>"]', 28)
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
