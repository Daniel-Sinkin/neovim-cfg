-- Non-plugin keymaps. Plugin-specific keymaps live in each plugin spec under
-- lua/custom/plugins/.

-- Clear highlights on search when pressing <Esc> in normal mode.
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Mousewheel: scroll viewport without smoothing.
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelUp>', '<C-y><C-y><C-y>', { silent = true })
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelDown>', '<C-e><C-e><C-e>', { silent = true })

vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Nuke stale diagnostics and refresh Neo-tree's view. Use when a closed file
-- is still marked orange in the tree.
vim.keymap.set('n', '<leader>dc', function()
  vim.diagnostic.reset()
  pcall(vim.cmd, 'Neotree refresh')
end, { desc = '[D]iagnostics [C]lear (reset all, refresh tree)' })

-- Easier terminal-mode exit (<C-\><C-n> is unguessable).
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Split navigation with Ctrl + hjkl.
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })
