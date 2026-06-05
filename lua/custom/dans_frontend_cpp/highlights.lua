-- Every highlight group the dans-cpp-frontend defines, in one place. Today they
-- layer on top of tokyonight; centralizing them is the first step toward a
-- self-contained dans-cpp-dark / dans-cpp-light set that drops tokyonight
-- entirely. apply() is called on setup and re-asserted on ColorScheme (a
-- `:colorscheme` runs `:hi clear`, which would otherwise blank these).

local M = {}

function M.apply()
  local hi = function(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end
  -- mut / mut_unchecked -> reddish-pink. Not bold: mut is inferred everywhere
  -- now, so bold red was too aggressive.
  hi('DansMarkerMut', { fg = '#f7768e' })
  -- cpy (and its type + name) / copy(...) -> yellow.
  hi('DansMarkerCpy', { fg = '#e0af68', bold = true })
  -- `lambda` pseudo-keyword in the lambda rendering: green to read as a
  -- declaration keyword, distinct from the mut/cpy markers.
  hi('DansLambda', { fg = '#9ece6a', bold = true })
  -- Vulkan identifiers (Vk*, VK_*) -- purple. Dense in this codebase, so they
  -- get their own category, overriding the generic macro color for VK_*.
  hi('DansVulkan', { fg = '#bb9af7' })
  -- Other all-caps macros / preprocessor constants -- purple. The hue alone
  -- carries the category (no bold), since these are dense in API-heavy code.
  hi('DansMacro', { fg = '#bb9af7' })
  -- SDL identifiers (SDL_*) -- teal/cyan, its own category.
  hi('DansSDL', { fg = '#2ac3de' })
  -- String literals -- muted green. A calm color (strings are inert content);
  -- applied at high priority so no other coloring/conceal leaks inside them.
  hi('DansString', { fg = '#a3be8c' })
  -- runtime `assert(...)` -- grayed as auxiliary checks, not core logic
  -- (compile-time `static_assert` is spared; it reads as `$sa`).
  hi('DansAssert', { fg = '#6b7280' })
  -- Designated-init field-name hints (`.width = 800` -> `width=800`): a muted
  -- tier. Library-aware tinting (SDL / Vulkan / dearImgui) is a later refinement.
  hi('DansHint', { fg = '#8b8fa3' })
  -- Deduced-type inlay text inside the view overlays (clangd auto types) --
  -- clearly blue so it reads apart from the gray comments.
  hi('DansInlayType', { fg = '#7aa2f7' })
  -- `const` grayed wherever it stays visible (function args, trailing const, the
  -- leading const revealed on the cursor line) -- the de-emphasized default.
  hi('DansConst', { fg = '#6b7280' })
  -- Namespace/scope qualifiers (std::, dans::, Foo::) grayed as visual noise.
  hi('DansNamespace', { fg = '#6b7280' })
  -- Masks that re-neutralize text the syntax-blind matches would wrongly color:
  -- comments back to Comment, #include <...> paths back to Normal.
  hi('DansCommentMask', { link = 'Comment' })
  hi('DansIncludeMask', { link = 'Normal' })
  -- Closed contract-block fold line -- gray on the normal background (drops
  -- tokyonight's banded Folded bg; the `+-- N lines:` foldtext reads as quiet).
  hi('Folded', { fg = '#6b7280' })
end

return M
