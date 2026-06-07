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
  DansLLDB = true,
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

-- Restrict a matchadd pattern to CODE: never match once a `//` line comment has
-- started. This keeps the whole C++ frontend (conceals + coloring) out of comment
-- prose, so `// doc blocks` are a separate document that cpp_doc_markdown renders
-- as tokyonight markdown. Variable-length negative lookbehind for "a // earlier
-- on the line"; still matches every code occurrence, none after a //.
local function code_only(pat)
  return [[\%(//.*\)\@<!]] .. pat
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
    { code_only [[\<inline\>\s*]], 30 },
    { code_only [[\<dans_]], 10 },
    -- GLFW/glfw prefix: keep the DansSDL teal on the rest, hide just the prefix.
    -- `\ze` ends the match before the kept char, so only the prefix is concealed:
    -- `glfw` before an uppercase is a function (glfwPollEvents -> PollEvents),
    -- `GLFW` before a lowercase is a type (GLFWwindow -> window), `GLFW_` before
    -- [A-Z0-9] is a macro (GLFW_TRUE -> TRUE, inner _ kept). None match a
    -- `glfw_foo` (your own, lowercase + _), so those stay verbatim.
    { code_only [==[\<glfw\ze[A-Z]]==], 30 },
    { code_only [==[\<GLFW\ze[a-z]]==], 30 },
    { code_only [==[\<GLFW_\ze[A-Z0-9]]==], 30 },
  }
  if ev and (ev.match == 'cpp' or ev.match == 'cuda') then
    -- ranges/views are unusable at `ranges::transform` / `views::filter` length;
    -- hide the whole qualifier (these cover more than `\<std::`, so the union
    -- hides `std::ranges::views::` down to the bare algorithm/view name).
    conceals[#conceals + 1] = { code_only [[\<std::ranges::views::]], 31 }
    conceals[#conceals + 1] = { code_only [[\<std::ranges::]], 31 }
    conceals[#conceals + 1] = { code_only [[\<std::views::]], 31 }
    conceals[#conceals + 1] = { code_only [[\<std::]], 30 }
    conceals[#conceals + 1] = { code_only [[\<dans::]], 30 }
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
  -- All color matches are code_only: they never touch `//` comment prose (the
  -- doc-markdown module owns that). Only the keyword is colored, not the
  -- following type/name.
  vim.fn.matchadd('DansMarkerCpy', code_only [[\<copy\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', code_only [[\<cpy\>]], 20)
  -- Gray every `const`. The leading-const conceal still hides it on non-cursor
  -- lines; this grays the ones that stay visible (args, trailing, and the
  -- leading one revealed on the cursor line).
  vim.fn.matchadd('DansConst', code_only [[\<const\>]], 20)
  -- Gray every `ident::` scope qualifier. std:: is concealed off the cursor
  -- line by a higher-priority match; the rest stay gray-but-visible.
  vim.fn.matchadd('DansNamespace', code_only [[\<\w\+::]], 20)
  -- All-caps macros / preprocessor constants -> purple. >=2 chars so single
  -- T/R template params are spared; mixed-case names (Vec3, GLuint) and k_snake
  -- constants don't match. A negative-lookahead skips stdlib all-caps that aren't
  -- user macros worth coloring (FILE, SEEK_*, EOF, NULL).
  vim.fn.matchadd('DansMacro', code_only [[\<\%(\%(FILE\|SEEK_SET\|SEEK_CUR\|SEEK_END\|EOF\|NULL\)\>\)\@![A-Z][A-Z0-9_]\+\>]], 20)
  -- Vulkan identifiers -> purple, at a higher priority so VK_* overrides the
  -- generic macro color above. Vk* (types) and vk* (functions) are mixed-case so
  -- they never hit the macro match anyway.
  vim.fn.matchadd('DansVulkan', code_only [[\<VK_[A-Z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', code_only [[\<Vk[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', code_only [[\<vk[A-Z][A-Za-z0-9_]*\>]], 25)
  -- SDL identifiers (SDL_*) -> teal. Same priority; SDL_FOO also matches the
  -- macro pattern, so the higher priority makes the teal win.
  vim.fn.matchadd('DansSDL', code_only [[\<SDL_[A-Za-z0-9_]*\>]], 25)
  -- GLFW shares the SDL color (you wouldn't use both in one project): GLFW_*
  -- macros + GLFWwindow/GLFWmonitor types, and glfw* functions.
  vim.fn.matchadd('DansSDL', code_only [[\<GLFW[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansSDL', code_only [[\<glfw[A-Z][A-Za-z0-9_]*\>]], 25)
  -- LLDB identifiers -> orange: the LLDB_ macros, the SB* API classes
  -- (SBDebugger/SBTarget/...), and the bare StateType enum. Priority 25 so the
  -- all-caps LLDB_* wins over the generic macro purple (like VK_*/SDL_*).
  vim.fn.matchadd('DansLLDB', code_only [[\<LLDB_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansLLDB', code_only [[\<SB[A-Z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansLLDB', code_only [[\<StateType\>]], 25)
  -- std::move / std::forward -> red: ownership-transfer points worth seeing (the
  -- source is left moved-from). `\zs` colors only the move/forward word; a member
  -- `.move()` (e.g. a widget) isn't std::-qualified so it's untouched.
  vim.fn.matchadd('DansMarkerMut', code_only [[\<std::\zs\%(move\|forward\)\>]], 25)
  -- assert / static_assert -> gray the whole `...assert(...);` statement (priority
  -- 26 beats the macro/Vk/SDL coloring inside the condition). static_assert also
  -- still renders as `$as` (aliases); this just grays the rest of its line.
  vim.fn.matchadd('DansAssert', code_only [[\<\%(static_\)\?assert\>.\{-};]], 26)
  -- String literals -> green, priority 35 (above the color matches AND the
  -- conceals at 30) so nothing else colors or conceals inside a string. Quoted
  -- pattern (a "..." literal with escapes); not [[...]] -- the [^"\] class
  -- would trip the long-string parser. Single-line strings only.
  vim.fn.matchadd('DansString', code_only '"\\%(\\\\.\\|[^"\\\\]\\)*"', 35)
  -- The string TYPE reads like a string: std::string and const char* get the
  -- same "..."-literal green so a function returning a string stands out. \> keeps
  -- std::string from also matching inside std::string_view; the const-char form
  -- covers `const char*` / `const char *`.
  vim.fn.matchadd('DansString', code_only [[\<std::string\>]], 24)
  vim.fn.matchadd('DansString', code_only [[\<const\s\+char\s*\*]], 24)
  -- Masks (priority 28): the color matches are syntax-blind, so they'd color
  -- all-caps tokens inside /* block comments */ and #include <...> paths. Recolor
  -- those back to neutral. There is no // mask: code_only already keeps every
  -- match out of // line comments, so // prose falls to the plain Comment group
  -- (which cpp_doc_markdown repaints as tokyonight markdown).
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
