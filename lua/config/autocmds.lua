-- Autocommands that aren't tied to a plugin.

-- Disable automatic comment continuation on newline / o / O.
vim.api.nvim_create_autocmd('FileType', {
  pattern = '*',
  callback = function()
    vim.opt_local.formatoptions:remove { 'r', 'o', 'c' }
  end,
})

-- Open Neo-tree on startup when launched in a directory or empty buffer.
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function(data)
    local buf = data.buf
    local name = vim.api.nvim_buf_get_name(buf)

    local stat = (vim.uv or vim.loop).fs_stat(name)
    if stat and stat.type == 'directory' then
      vim.cmd.cd(name)
      vim.cmd 'Neotree show left'
      return
    end

    if name == '' then
      vim.cmd 'Neotree show left'
    end
  end,
})

-- Clear diagnostics for buffers being wiped out. Without this, closing a file
-- with errors leaves them cached in vim.diagnostic forever and Neo-tree keeps
-- showing it as orange.
vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = vim.api.nvim_create_augroup('ds-diagnostic-cleanup', { clear = true }),
  callback = function(ev)
    vim.diagnostic.reset(nil, ev.buf)
  end,
})

-- Highlight when yanking.
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- C/C++/headers: 4-space tabs.
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'cpp', 'c', 'h', 'hpp' },
  callback = function()
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.expandtab = true
  end,
})

-- Hide visual noise in C/C++/CUDA buffers without modifying files:
--   - leading `const` (applies to c/cpp/cuda) so `mut` stands out as the
--     exception (pair with the monochrome theme in treesitter.lua)
--   - the `dans_` prefix on identifiers (c/cpp/cuda)
--   - the `std::` qualifier (cpp/cuda only; pointless in plain C)
-- `[[nodiscard]]` is aliased to `$nd` by cpp_aliases (handled there, not here).
-- Note: filetype pattern matches the *filetype* string, not extension.
-- .h -> c, .hpp -> cpp, .cu/.cuh -> cuda. With vim.g.c_syntax_for_h = 1,
-- .h stays as c (so std:: hiding skips it).
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'c', 'cpp', 'cuda' },
  callback = function(ev)
    vim.opt_local.conceallevel = 2
    -- Empty concealcursor: the cursor line never conceals (raw WYSIWYG view of
    -- const/std::/dans_), every other line stays concealed. Reveal is driven by
    -- cursor position only — insert mode has no effect. Matches jai_view.
    vim.opt_local.concealcursor = ''

    -- Conceal specs {pattern, priority}. const/std:: at priority 30 beat
    -- cpp_markers' gray matches (priority 20) so they hide off the cursor line
    -- rather than only graying.
    local conceals = {
      -- Hide `const` as a leading type qualifier: at line start, or right after
      -- `(`, `,`, or `->` (locals, params, return types). const is the default.
      { [[\%(^\s*\|(\s*\|,\s*\|->\s*\)\zsconst\>\s*]], 30 },
      { [[\<dans_]], 10 },
    }
    if ev.match == 'cpp' or ev.match == 'cuda' then
      conceals[#conceals + 1] = { [[\<std::]], 30 }
      conceals[#conceals + 1] = { [[\<dans::]], 30 }
    end

    -- Drop our own previous matches first: matchadd is window-local and these
    -- don't self-clear, so repeated FileType events (`:e`, re-sourcing) would
    -- otherwise stack duplicates. Identified by pattern (unique to this config).
    local ours = {}
    for _, c in ipairs(conceals) do
      ours[c[1]] = true
    end
    for _, m in ipairs(vim.fn.getmatches()) do
      if m.group == 'Conceal' and ours[m.pattern] then
        pcall(vim.fn.matchdelete, m.id)
      end
    end

    for _, c in ipairs(conceals) do
      vim.fn.matchadd('Conceal', c[1], c[2], -1, { conceal = '' })
    end
  end,
})
