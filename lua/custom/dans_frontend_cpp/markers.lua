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
  DansSTB = true,
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

-- Prefix conceals are extmarks (this namespace), not matchadds, so they can be
-- treesitter-gated to skip string / char / comment literals -- a window matchadd
-- is syntax-blind and would strip the prefix inside e.g. the "vkCreateInstance"
-- passed to vkGetInstanceProcAddr. The color matchadds below stay matchadds:
-- coloring inside a literal shifts nothing, only concealing hides text.
local ns = vim.api.nvim_create_namespace 'ds_cpp_markers_conceal'

local in_literal = vu.in_literal -- treesitter string/char/comment/include guard

-- Prefix conceals (vim regex). `\ze` ends the match before the kept char so only
-- the prefix is hidden; `\<` keeps `_` a word char (PFN_vkCreateX keeps its vk).
-- No `code_only` wrapper -- in_literal (treesitter) does the comment/string skip,
-- which also covers block comments and char literals the `//` guard missed.
--   inline / dans_ noise; glfw/GLFW/GLFW_ (function/type/macro); the Vulkan
--   Vk/VK_/vk plus the longer DebugUtils sub-prefix. std::/dans:: are cpp-only.
local PREFIX_PATTERNS = {
  [==[\<inline\>\s*]==],
  [==[\<static\>\s*]==], -- \> stops it matching static_assert (the `_` is a word char)
  [==[\<dans_]==],
  [==[\<glfw\ze[A-Z]]==],
  [==[\<GLFW\ze[a-z]]==],
  [==[\<GLFW_\ze[A-Z0-9]]==],
  [==[\<VkDebugUtils\ze[A-Z]]==],
  [==[\<VK_DEBUG_UTILS_\ze[A-Z0-9]]==],
  [==[\<Vk\ze[A-Z]]==],
  [==[\<VK_\ze[A-Z0-9]]==],
  [==[\<vk\ze[A-Z]]==],
}
local CPP_PATTERNS = {
  [==[\<std::ranges::views::]==],
  [==[\<std::ranges::]==],
  [==[\<std::views::]==],
  [==[\<std::]==],
  [==[\<dans::]==],
}
local rx_cache = {}
local function rx(pat)
  local r = rx_cache[pat]
  if not r then
    r = vim.regex(pat)
    rx_cache[pat] = r
  end
  return r
end

-- Conceal every match of `pat` on `line` (row0) whose start is a real `\<`
-- boundary and not inside a literal. vim.regex has no start offset, so we scan a
-- shrinking suffix; a suffix-start match that is actually mid-identifier in the
-- full line is rejected by the prev-char check, so `\<` can't be faked.
local function conceal_pattern(bufnr, row0, line, pat)
  local regex = rx(pat)
  local from, n = 0, #line
  while from <= n do
    local ms, me = regex:match_str(line:sub(from + 1))
    if not ms then
      break
    end
    local s, e = from + ms, from + me
    if e <= s then
      break -- zero-width match, avoid spinning
    end
    local prev = s > 0 and line:sub(s, s) or ''
    if (prev == '' or not prev:match '[%w_]') and not in_literal(bufnr, row0, s) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s, { end_col = e, conceal = '' })
    end
    from = e
  end
end

-- (Re)apply the prefix conceals over the visible range. The cursor line shows raw
-- via concealcursor='' (set in apply), so we conceal every visible line and need
-- no CursorMoved refresh -- only edit / scroll / buffer-enter.
local function conceal_refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if not vu.is_cpp(ft) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'markers') then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok and parser then
    pcall(function()
      parser:parse()
    end)
  end
  local cpp = ft == 'cpp' or ft == 'cuda'
  local sa = vu.static_assert_lines(bufnr) -- leave static_assert lines verbatim
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    if not sa[row0] then
      for _, pat in ipairs(PREFIX_PATTERNS) do
        conceal_pattern(bufnr, row0, line, pat)
      end
      if cpp then
        for _, pat in ipairs(CPP_PATTERNS) do
          conceal_pattern(bufnr, row0, line, pat)
        end
      end
    end
  end
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

  -- concealcursor is empty so the cursor line shows the real text. The prefix
  -- conceals themselves are extmarks applied by conceal_refresh (literal-aware);
  -- only the colors below are window matchadds.
  vim.opt_local.conceallevel = 2
  vim.opt_local.concealcursor = ''
  local bufnr = (ev and ev.buf) or vim.api.nvim_get_current_buf()

  -- Drop our own previous color matches so repeated FileType events don't stack.
  for _, m in ipairs(vim.fn.getmatches()) do
    if MATCH_GROUPS[m.group] then
      pcall(vim.fn.matchdelete, m.id)
    end
  end

  -- Prefix conceals (extmarks, skip string/comment literals).
  conceal_refresh(bufnr)

  if not vu.module_enabled(bufnr, 'markers') then
    return -- disabled: colors cleared above, conceals cleared in conceal_refresh
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
  -- Generic macro coloring lives in custom.dans_macros now: it colors the
  -- project's actual #define names (scanned with rg), falling back to the all-caps
  -- heuristic only when no scan is available. The library-prefixed macros
  -- (VK_/SDL_/GLFW/stb/LLDB_) are still colored by the matchadds below.
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
  -- stb single-header libs -> bright cyan: stb_/stbi_/stbtt_/stbsp_/... functions
  -- and types (lowercase stb...+_), plus the STB*/STBI_/STBIDEF macros.
  vim.fn.matchadd('DansSTB', code_only [[\<stb[a-z0-9]*_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansSTB', code_only [[\<STB[A-Za-z0-9_]*\>]], 25)
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
  -- 26 beats the macro/Vk/SDL coloring in the condition), marking it as skim-past
  -- checking code. static_assert is also left fully verbatim
  -- (util.static_assert_lines skips every conceal/sugar), so the gray now sits on
  -- top of the real, un-cut text -- a `VkResult` inside reads as a gray `VkResult`,
  -- not a misleading `Result`.
  vim.fn.matchadd('DansAssert', code_only [[\<\%(static_\)\?assert\>.\{-};]], 26)
  -- String literals -> green, priority 35 (above the other color matches) so a
  -- Vk*/macro token inside a string is not recolored. Concealing inside strings is
  -- separately prevented: the prefix conceals are treesitter-gated extmarks, not
  -- matchadds, so priority isn't what guards them. Quoted pattern (a "..." literal
  -- with escapes); not [[...]] -- the [^"\] class would trip the long-string
  -- parser. Single-line strings only.
  vim.fn.matchadd('DansString', code_only '"\\%(\\\\.\\|[^"\\\\]\\)*"', 35)
  -- The string TYPE reads like a string: std::string and const char* get the
  -- same "..."-literal green so a function returning a string stands out. \> keeps
  -- std::string from also matching inside std::string_view; the const-char form
  -- covers `const char*` / `const char *`.
  vim.fn.matchadd('DansString', code_only [[\<std::string\>]], 24)
  vim.fn.matchadd('DansString', code_only [[\<const\s\+char\s*\*]], 24)
  -- Masks (priority 28): the color matches are syntax-blind, so they'd color
  -- tokens inside /* block comments */ and #include <...> paths. Recolor those
  -- back to neutral. `\_.` so the mask spans a MULTI-LINE block comment (the big
  -- /** ... */ doxygen blocks in headers), not just single-line ones -- otherwise
  -- `copy`, a #define, etc. inside one keep their code color. There is no // mask:
  -- code_only keeps every match out of // line comments already.
  vim.fn.matchadd('DansCommentMask', [[/\*\_.\{-}\*/]], 28)
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
  -- The prefix conceals are visible-range extmarks, so re-scan on edit, scroll
  -- (the debounced settled event), and buffer enter. No CursorMoved: the cursor
  -- line is revealed by concealcursor='', not by skipping it in the scan.
  vu.on_decorate(group, { 'BufEnter', 'TextChanged', 'TextChangedI' }, conceal_refresh)
  -- Re-assert colors after a colorscheme change (tokyonight day/night swap).
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
end

return M
