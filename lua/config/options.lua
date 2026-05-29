-- Editor options, globals, and environment setup.
-- Loaded first from init.lua, before any plugin work.

-- Leader keys (must be set before plugins load).
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.g.have_nerd_font = false

-- Treat `.h` headers as C, not C++. Must be set before any filetype detection
-- runs so plain C headers don't get C++ clang-tidy checks.
vim.g.c_syntax_for_h = 1

-- macOS: `cc` resolves to the raw Xcode toolchain compiler without a sysroot,
-- so nvim-treesitter parser builds fail with "'stdlib.h' file not found".
-- Exporting SDKROOT gives clang the SDK.
if vim.fn.has 'mac' == 1 and (vim.env.SDKROOT == nil or vim.env.SDKROOT == '') then
  local sdk = vim.trim(vim.fn.system 'xcrun --show-sdk-path 2>/dev/null')
  if vim.v.shell_error == 0 and sdk ~= '' and vim.fn.isdirectory(sdk) == 1 then
    vim.env.SDKROOT = sdk
  end
end

-- GUI launches (Neovide, dock) don't inherit shell PATH; juliaup's `julia`
-- goes missing and the Julia LSP / DAP can't spawn. Prepend it explicitly.
do
  local juliaup_bin = vim.fn.expand '~/.juliaup/bin'
  if vim.fn.isdirectory(juliaup_bin) == 1 and not (vim.env.PATH or ''):find(juliaup_bin, 1, true) then
    vim.env.PATH = juliaup_bin .. ':' .. (vim.env.PATH or '')
  end
end

-- Neovide-only visuals (ignored in terminal Neovim)
if vim.g.neovide then
  vim.g.neovide_cursor_animation_length = 0.03
  vim.g.neovide_scroll_animation_length = 0.0
  vim.g.neovide_cursor_trail_size = 0.2
  vim.g.neovide_cursor_vfx_mode = ''
  -- Neovide expects a font *family* name, not a file name.
  vim.o.guifont = 'Monaspace Krypton:h12'
end

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = 'a'
vim.opt.showmode = false

-- Indentation: 4 spaces, never tabs.
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4

-- Sync clipboard between OS and Neovim. Scheduled after UiEnter for startup time.
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'yes'
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
vim.opt.inccommand = 'split'
vim.opt.cursorline = true
vim.opt.scrolloff = 10
vim.opt.confirm = true

-- For obsidian.nvim (hides markup, renders checkboxes, etc.)
vim.opt.conceallevel = 2
