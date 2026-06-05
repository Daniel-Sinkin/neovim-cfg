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
