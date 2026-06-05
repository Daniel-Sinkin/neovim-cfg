-- Marker-aware highlighting for C/C++/CUDA: make the mut/cpy exceptions pop
-- against the const-by-default (hidden) sea. View-only (matchadd + highlight).
--   mut, mut_unchecked          -> reddish-pink
--   cpy (and its type + name)   -> yellow
--   copy(...)                   -> yellow
-- Highlight group names are shared with view.lua, which colors the marker
-- prefix inside its overlays using the same groups.

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'

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

-- Group definitions live in highlights.lua now (one place to retheme). Still
-- re-asserted on FileType + ColorScheme via this thin wrapper.
local function set_hl()
  require('custom.dans_frontend_cpp.highlights').apply()
end

local function apply(ev)
  -- Re-assert the groups here too: `:colorscheme` (e.g. the day/night swap)
  -- runs `:hi clear`, which would otherwise blank these until a ColorScheme
  -- event; defining them on FileType guarantees they exist for this buffer.
  set_hl()

  -- Conceal the visual noise that hides off the cursor line (moved here from
  -- config/autocmds.lua so the frontend owns it): a leading `inline`, the
  -- `dans_` identifier prefix, and -- C++ only -- the std::/dans:: scope
  -- qualifiers. concealcursor is empty so the cursor line shows the real text.
  vim.opt_local.conceallevel = 2
  vim.opt_local.concealcursor = ''
  local conceals = {
    { [[\<inline\>\s*]], 30 },
    { [[\<dans_]], 10 },
  }
  if ev and (ev.match == 'cpp' or ev.match == 'cuda') then
    conceals[#conceals + 1] = { [[\<std::]], 30 }
    conceals[#conceals + 1] = { [[\<dans::]], 30 }
  end

  -- Drop our own previous matches (color + conceal) so repeated FileType events
  -- don't stack.
  local ours_conceal = {}
  for _, c in ipairs(conceals) do
    ours_conceal[c[1]] = true
  end
  for _, m in ipairs(vim.fn.getmatches()) do
    if MATCH_GROUPS[m.group] or (m.group == 'Conceal' and ours_conceal[m.pattern]) then
      pcall(vim.fn.matchdelete, m.id)
    end
  end

  if not vu.module_enabled((ev and ev.buf) or vim.api.nvim_get_current_buf(), 'markers') then
    return -- disabled: matches cleared above, conceallevel left for the overlay
  end

  for _, c in ipairs(conceals) do
    vim.fn.matchadd('Conceal', c[1], c[2], -1, { conceal = '' })
  end

  -- Window-local matches, priority above the flattened monochrome syntax.
  -- Only the keyword is colored (not the following type/name). mut/mut_unchecked
  -- are gone from source now -- the frontend (view) infers and colors them.
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
  -- still renders as `$as` (aliases); this just grays the rest of its line.
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

-- Re-apply for a buffer after a :DansFrontend toggle (synthesize the FileType
-- event apply() reads its filetype from).
function M.refresh(bufnr)
  apply { match = vim.bo[bufnr].filetype, buf = bufnr }
end

function M.setup()
  set_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_markers', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      apply(ev)
    end,
  })
  -- Re-assert colors after a colorscheme change (tokyonight day/night swap).
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
end

return M
