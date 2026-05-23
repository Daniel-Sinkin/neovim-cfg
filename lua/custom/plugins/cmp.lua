-- Autocompletion. LSP completion is OFF by default; <leader>tc toggles it.
return {
  {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'hrsh7th/cmp-nvim-lsp-signature-help',
      {
        'L3MON4D3/LuaSnip',
        version = 'v2.*',
        build = 'make install_jsregexp',
      },
      'saadparwaiz1/cmp_luasnip',
    },
    config = function()
      local cmp = require 'cmp'

      local lsp_completion_enabled = false

      local quiet_sources = {
        { name = 'buffer' },
        { name = 'path' },
      }

      local lsp_sources = {
        {
          name = 'lazydev',
          group_index = 0,
        },
        { name = 'nvim_lsp' },
        { name = 'luasnip' },
        { name = 'path' },
        { name = 'buffer' },
        { name = 'nvim_lsp_signature_help' },
      }

      local function active_sources()
        if lsp_completion_enabled then
          return lsp_sources
        end
        return quiet_sources
      end

      local function apply_completion_sources()
        cmp.setup { sources = active_sources() }
      end

      vim.keymap.set('n', '<leader>tc', function()
        lsp_completion_enabled = not lsp_completion_enabled
        apply_completion_sources()
        local state = lsp_completion_enabled and 'on' or 'off'
        vim.notify('LSP completion ' .. state, vim.log.levels.INFO)
      end, { desc = '[T]oggle LSP [C]ompletion' })

      cmp.setup {
        completion = { completeopt = 'menu,menuone,noinsert' },

        snippet = {
          expand = function(args)
            require('luasnip').lsp_expand(args.body)
          end,
        },

        mapping = cmp.mapping.preset.insert {
          ['<C-n>'] = cmp.mapping.select_next_item(),
          ['<C-p>'] = cmp.mapping.select_prev_item(),
          ['<C-b>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<C-y>'] = cmp.mapping.confirm { select = true },
          ['<CR>'] = cmp.mapping.confirm { select = true },

          ['<Tab>'] = cmp.mapping(function(fallback)
            local luasnip = require 'luasnip'
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { 'i', 's' }),

          ['<S-Tab>'] = cmp.mapping(function(fallback)
            local luasnip = require 'luasnip'
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { 'i', 's' }),

          ['<C-Space>'] = cmp.mapping.complete {},
        },
        sources = active_sources(),
      }
    end,
  },

  { 'rafamadriz/friendly-snippets' },
}
