-- Autoformat. Julia goes through julials's bundled JuliaFormatter (honors a
-- project .JuliaFormatter.toml); first save in a session JITs and is slow.
return {
  'stevearc/conform.nvim',
  event = { 'BufWritePre' },
  cmd = { 'ConformInfo' },
  keys = {
    {
      '<leader>f',
      function()
        require('conform').format { async = true, lsp_format = 'fallback' }
      end,
      mode = '',
      desc = '[F]ormat buffer',
    },
  },
  opts = {
    notify_on_error = false,
    format_on_save = function(bufnr)
      local ft = vim.bo[bufnr].filetype

      if ft == 'c' or ft == 'cpp' then
        return { timeout_ms = 1000, lsp_format = 'always' }
      end

      if ft == 'julia' then
        return { timeout_ms = 3000, lsp_format = 'fallback' }
      end

      return { timeout_ms = 500, lsp_format = 'fallback' }
    end,
    formatters_by_ft = {
      lua = { 'stylua' },
    },
  },
}
