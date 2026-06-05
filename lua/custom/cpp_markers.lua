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
  DansAssert = true,
  DansCommentMask = true,
  DansIncludeMask = true,
}

local function set_hl()
  -- Not bold: mut is inferred everywhere now, so bold red was too aggressive.
  vim.api.nvim_set_hl(0, 'DansMarkerMut', { fg = '#f7768e' })
  vim.api.nvim_set_hl(0, 'DansMarkerCpy', { fg = '#e0af68', bold = true })
  -- `lambda` pseudo-keyword in jai_view's lambda rendering (green to read as a
  -- declaration keyword, distinct from the mut/cpy markers).
  vim.api.nvim_set_hl(0, 'DansLambda', { fg = '#9ece6a', bold = true })
  -- Vulkan identifiers (Vk*, VK_*) -- purple. Dense in this codebase, so they
  -- get their own category, overriding the generic macro color for VK_*.
  vim.api.nvim_set_hl(0, 'DansVulkan', { fg = '#bb9af7' })
  -- Other all-caps macros / preprocessor constants -- orange. Not bold: these
  -- are dense in API-heavy code, so the hue alone carries the category.
  vim.api.nvim_set_hl(0, 'DansMacro', { fg = '#bb9af7' })
  -- SDL identifiers (SDL_*) -- teal/cyan, its own category.
  vim.api.nvim_set_hl(0, 'DansSDL', { fg = '#2ac3de' })
  -- String literals -- muted green. A calm color (strings are inert content);
  -- applied at high priority so no other coloring/conceal leaks inside them.
  vim.api.nvim_set_hl(0, 'DansString', { fg = '#a3be8c' })
  -- runtime `assert(...)` statements -- grayed out as auxiliary checks, not core
  -- logic (compile-time `static_assert` is spared; it reads as `$sa`).
  vim.api.nvim_set_hl(0, 'DansAssert', { fg = '#6b7280' })
  -- Designated-init field-name hints (`.width = 800` -> `width=800`): a muted
  -- tier, less pronounced than normal text but not as dim as comments. Library-
  -- aware tinting (SDL / Vulkan / dearImgui) is a later refinement.
  vim.api.nvim_set_hl(0, 'DansHint', { fg = '#8b8fa3' })
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
  -- Only the keyword is colored (not the following type/name). mut/mut_unchecked
  -- are gone from source now -- the frontend (jai_view) infers and colors them.
  vim.fn.matchadd('DansMarkerCpy', [[\<copy\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', [[\<cpy\>]], 20)
  -- Gray every `const`. The leading-const conceal still hides it on non-cursor
  -- lines; this grays the ones that stay visible (args, trailing, and the
  -- leading one revealed on the cursor line).
  vim.fn.matchadd('DansConst', [[\<const\>]], 20)
  -- Gray every `ident::` scope qualifier. std:: is concealed off the cursor
  -- line by a higher-priority match; the rest stay gray-but-visible.
  vim.fn.matchadd('DansNamespace', [[\<\w\+::]], 20)
  -- All-caps macros / preprocessor constants -> purple. >=2 chars so single
  -- T/R template params are spared; mixed-case names (Vec3, GLuint) and k_snake
  -- constants don't match. A negative-lookahead skips stdlib all-caps that aren't
  -- user macros worth coloring (FILE, SEEK_*, EOF, NULL).
  vim.fn.matchadd('DansMacro', [[\<\%(\%(FILE\|SEEK_SET\|SEEK_CUR\|SEEK_END\|EOF\|NULL\)\>\)\@![A-Z][A-Z0-9_]\+\>]], 20)
  -- Vulkan identifiers -> purple, at a higher priority so VK_* overrides the
  -- generic macro color above. Vk* (types) and vk* (functions) are mixed-case so
  -- they never hit the macro match anyway.
  vim.fn.matchadd('DansVulkan', [[\<VK_[A-Z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', [[\<Vk[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', [[\<vk[A-Z][A-Za-z0-9_]*\>]], 25)
  -- SDL identifiers (SDL_*) -> teal. Same priority; SDL_FOO also matches the
  -- macro pattern, so the higher priority makes the teal win.
  vim.fn.matchadd('DansSDL', [[\<SDL_[A-Za-z0-9_]*\>]], 25)
  -- std::move / std::forward -> red: ownership-transfer points worth seeing (the
  -- source is left moved-from). `\zs` colors only the move/forward word; a member
  -- `.move()` (e.g. a widget) isn't std::-qualified so it's untouched.
  vim.fn.matchadd('DansMarkerMut', [[\<std::\zs\%(move\|forward\)\>]], 25)
  -- assert / static_assert -> gray the whole `...assert(...);` statement (priority
  -- 26 beats the macro/Vk/SDL coloring inside the condition). static_assert also
  -- still renders as `$as` (cpp_aliases); this just grays the rest of its line.
  vim.fn.matchadd('DansAssert', [[\<\%(static_\)\?assert\>.\{-};]], 26)
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
