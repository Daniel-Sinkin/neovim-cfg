-- LSP configuration. clangd is configured manually (not via mason). julials
-- uses LanguageServer.jl in ~/.julia/environments/nvim-lspconfig with a custom
-- root_dir picking the OUTERMOST Project.toml so nested layouts don't spawn
-- duplicate clients (see private/AGENTS.md).

-- clangd answers documentHighlight on a control-flow keyword with the whole
-- related flow (every return of the function, a loop plus its continues and
-- breaks), which reads as stray syntax coloring on the monochrome buffers.
-- Keywords are never symbols, so the cursor-hold request skips them outright.
local FLOW_KEYWORDS = {
  ['return'] = true,
  ['if'] = true,
  ['else'] = true,
  ['for'] = true,
  ['while'] = true,
  ['do'] = true,
  ['switch'] = true,
  ['case'] = true,
  ['default'] = true,
  ['break'] = true,
  ['continue'] = true,
  ['goto'] = true,
  ['try'] = true,
  ['catch'] = true,
  ['throw'] = true,
  ['co_return'] = true,
  ['co_await'] = true,
  ['co_yield'] = true,
}

return {
  {
    -- Lua LSP for Neovim config / runtime / plugins.
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'williamboman/mason.nvim', opts = {} },
      'williamboman/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- julials is rendered by custom.julia_progress instead (one stable
      -- widget); fidget still handles every other LSP.
      { 'j-hui/fidget.nvim', opts = { progress = { ignore = { 'julials' } } } },
    },
    config = function()
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('dans-lsp-attach', { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          -- gd jumps to the definition, but when you're already standing ON a
          -- definition (a function def has no other origin) clangd returns only the
          -- current spot -- fall through to "find all references" there, which is
          -- what you actually want. (Replaces the buggy <leader>D type-definition
          -- jump, which matched a function's return type from its name.)
          local function goto_def_or_refs()
            vim.lsp.buf.definition {
              on_list = function(opts)
                local here = vim.api.nvim_win_get_cursor(0)[1]
                local file = vim.api.nvim_buf_get_name(0)
                local elsewhere = false
                for _, it in ipairs(opts.items or {}) do
                  if it.lnum ~= here or it.filename ~= file then
                    elsewhere = true
                    break
                  end
                end
                if elsewhere then
                  require('telescope.builtin').lsp_definitions()
                else
                  require('telescope.builtin').lsp_references()
                end
              end,
            }
          end
          map('gd', goto_def_or_refs, '[G]oto [D]efinition (or references when on one)')
          map('gr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')
          map('gI', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')
          map('<leader>ds', require('telescope.builtin').lsp_document_symbols, '[D]ocument [S]ymbols')
          map('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')
          map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
          map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction', { 'n', 'x' })
          map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

          ---@param client vim.lsp.Client
          ---@param method vim.lsp.protocol.Method
          ---@param bufnr? integer
          ---@return boolean
          local function client_supports_method(client, method, bufnr)
            if vim.fn.has 'nvim-0.11' == 1 then
              return client:supports_method(method, bufnr)
            else
              return client.supports_method(method, { bufnr = bufnr })
            end
          end

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          -- Drop LSP semantic tokens for C/C++; the monochrome theme in
          -- treesitter.lua re-introduces color via classic syntax instead.
          -- server_capabilities is shared across all of the client's buffers, so
          -- nilling it isn't enough: a highlighter that already started on
          -- another buffer keeps running and its next delta response indexes the
          -- now-nil provider, throwing in a scheduled callback. Disable per
          -- buffer too so any live highlighter is torn down.
          if client and (vim.bo[event.buf].filetype == 'c' or vim.bo[event.buf].filetype == 'cpp') then
            client.server_capabilities.semanticTokensProvider = nil
            local bufs = { [event.buf] = true }
            for buf in pairs(client.attached_buffers or {}) do bufs[buf] = true end
            for buf in pairs(bufs) do
              pcall(vim.lsp.semantic_tokens.enable, false, { bufnr = buf })
            end
          end
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_documentHighlight, event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('dans-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = function()
                if vim.b[event.buf].dans_token_mode then return end
                if FLOW_KEYWORDS[vim.fn.expand '<cword>'] then return end
                vim.lsp.buf.document_highlight()
                -- Mirror the reference highlight onto the frontend overlay too.
                pcall(function()
                  require('custom.dans_frontend_cpp.overlay_hl').update_references(event.buf)
                end)
              end,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = function()
                vim.lsp.buf.clear_references()
                pcall(function()
                  require('custom.dans_frontend_cpp.overlay_hl').clear_references(event.buf)
                end)
              end,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('dans-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'dans-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_inlayHint, event.buf) then
            -- Toggles the *built-in* renderer (end-of-line hints). For C/C++ the
            -- deduced auto types are instead pulled and placed by custom.dans_frontend_cpp.view
            -- (rendered between the `:` and `=`), so leave the built-in off here.
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      vim.diagnostic.config {
        severity_sort = true,
        float = { border = 'rounded', source = 'if_many' },
        underline = { severity = vim.diagnostic.severity.ERROR },
        signs = vim.g.have_nerd_font and {
          text = {
            [vim.diagnostic.severity.ERROR] = '󰅚 ',
            [vim.diagnostic.severity.WARN] = '󰀪 ',
            [vim.diagnostic.severity.INFO] = '󰋽 ',
            [vim.diagnostic.severity.HINT] = '󰌶 ',
          },
        } or {},
        -- Full message only on the CURSOR line (hover a line to read it);
        -- every other diagnosed line gets a first-cell mark from
        -- custom.dans_diagmark instead of end-of-line text, so diagnostics
        -- never push code around or suppress the frontend overlay.
        virtual_text = {
          current_line = true,
          source = 'if_many',
          spacing = 2,
        },
      }

      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())

      -- `.clang-tidy` is C++-only; strip clang-tidy diagnostics out of plain C
      -- buffers so they don't see modernize-* warnings meant for .cpp/.hpp.
      local function filter_clang_tidy_for_c(err, result, ctx, config)
        if result and result.diagnostics then
          local bufnr = vim.uri_to_bufnr(result.uri)
          if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == 'c' then
            result.diagnostics = vim.tbl_filter(function(d)
              return d.source ~= 'clang-tidy'
            end, result.diagnostics)
          end
        end
        return vim.lsp.handlers['textDocument/publishDiagnostics'](err, result, ctx, config)
      end

      local servers = {
        clangd = {
          cmd = {
            -- macOS: Homebrew clang (newer than Apple's). Elsewhere: clangd
            -- from PATH (LLVM install).
            vim.fn.has 'mac' == 1 and '/opt/homebrew/opt/llvm/bin/clangd' or 'clangd',
            '--background-index',
            '--clang-tidy',
          },
          handlers = {
            ['textDocument/publishDiagnostics'] = filter_clang_tidy_for_c,
          },
        },

        lua_ls = {
          settings = {
            Lua = {
              completion = { callSnippet = 'Replace' },
            },
          },
        },

        -- Julia: LanguageServer.jl. Requires LanguageServer, SymbolServer and
        -- StaticLint installed in ~/.julia/environments/nvim-lspconfig.
        julials = {
          -- Root at the OUTERMOST Project.toml so nested package layouts only
          -- spawn one client (one root = one client).
          root_dir = function(bufnr, on_dir)
            local fname = vim.api.nvim_buf_get_name(bufnr)
            if fname == '' then
              return
            end
            local found = vim.fs.find({ 'Project.toml', 'JuliaProject.toml' }, {
              upward = true,
              path = fname,
              limit = math.huge,
            })
            on_dir(#found > 0 and vim.fs.dirname(found[#found]) or vim.fs.dirname(fname))
          end,
        },
      }

      local ensure_installed = {
        'lua_ls',
        'stylua',
      }
      -- The mason-nvim-dap integration is on by default and its require() makes
      -- lazy.nvim pull the whole DAP stack into startup; nothing DAP-shaped is in
      -- ensure_installed, so turn it (and null-ls) off.
      require('mason-tool-installer').setup {
        ensure_installed = ensure_installed,
        integrations = { ['mason-lspconfig'] = true, ['mason-null-ls'] = false, ['mason-nvim-dap'] = false },
      }
      require('mason-lspconfig').setup {
        ensure_installed = {},
        automatic_installation = false,
        handlers = {
          function(server_name)
            if server_name == 'clangd' then
              return
            end
            local server = servers[server_name] or {}
            server.capabilities = vim.tbl_deep_extend('force', {}, capabilities, server.capabilities or {})
            vim.lsp.config(server_name, server)
            vim.lsp.enable(server_name)
          end,
        },
      }

      local clangd = servers.clangd or {}
      clangd.capabilities = vim.tbl_deep_extend('force', {}, capabilities, clangd.capabilities or {})
      vim.lsp.config('clangd', clangd)
      vim.lsp.enable 'clangd'

      local julials = servers.julials or {}
      julials.capabilities = vim.tbl_deep_extend('force', {}, capabilities, julials.capabilities or {})
      vim.lsp.config('julials', julials)
      vim.lsp.enable 'julials'
    end,
  },
}
