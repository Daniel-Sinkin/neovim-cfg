-- Non-plugin keymaps. Plugin-specific keymaps live in each plugin spec under
-- lua/custom/plugins/.

-- Clear highlights on search when pressing <Esc> in normal mode.
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Mousewheel: scroll viewport without smoothing.
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelUp>', '<C-y><C-y><C-y>', { silent = true })
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelDown>', '<C-e><C-e><C-e>', { silent = true })

vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Easier terminal-mode exit (<C-\><C-n> is unguessable).
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Split navigation with Ctrl + hjkl.
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })
