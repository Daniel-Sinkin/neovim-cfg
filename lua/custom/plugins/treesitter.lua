-- Treesitter + the C/C++/CUDA enclosing-brace highlighter and monochrome theme.
--
-- For C/C++/CUDA we DISABLE treesitter highlighting and instead:
--   1. Use the bundled classic vim syntax (re-enabled per FileType below).
--   2. Flatten almost every syntax/LSP-semantic group to Normal.
--   3. Keep strings, comments (gray), and PreProc (dim) visible.
--   4. CUDA only: re-color CUDA-specific identifiers so kernels stand out.
-- The treesitter parser still runs so the brace-highlighter has its AST.
return {
  {
    -- VSCode-like sticky scope header.
    'nvim-treesitter/nvim-treesitter-context',
    ft = { 'c', 'cpp', 'cuda' },
    main = 'treesitter-context',
    opts = {
      enable = true,
      max_lines = 1,
      trim_scope = 'outer',
      mode = 'topline',
      separator = nil,
      zindex = 20,
      on_attach = function(bufnr)
        local ft = vim.bo[bufnr].filetype
        return ft == 'c' or ft == 'cpp' or ft == 'cuda'
      end,
    },
  },
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    config = function(_, opts)
      -- Windows: zig is a hermetic C compiler (ships its own libc headers), so
      -- parser builds don't need the MSVC/Windows SDK INCLUDE paths set.
      if vim.fn.has 'win32' == 1 then
        require('nvim-treesitter.install').compilers = { 'zig' }
      end
      require('nvim-treesitter.configs').setup(opts)
    end,
    opts = {
      ensure_installed = { 'bash', 'c', 'cpp', 'cuda', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
      auto_install = true,
      highlight = {
        enable = true,
        disable = function(_, bufnr)
          local ft = vim.bo[bufnr].filetype
          return ft == 'c' or ft == 'cpp' or ft == 'cuda'
        end,
        additional_vim_regex_highlighting = { 'ruby' },
      },
      indent = { enable = true, disable = { 'ruby' } },
    },
    config = function(_, opts)
      require('nvim-treesitter.configs').setup(opts)

      -- Enclosing-brace highlight for C/C++/CUDA. Uses tree-sitter parsing to
      -- find the nearest braced node around the cursor, then linearly searches
      -- a small window for the actual '{' and '}' characters.
      local brace_ns = vim.api.nvim_create_namespace 'ds_enclosing_brace'

      vim.api.nvim_set_hl(0, 'EnclosingBrace', { link = 'MatchParen' })
      vim.api.nvim_set_hl(0, 'InnerDelimiter', { link = 'DiagnosticInfo' })

      local function find_enclosing_brace_node(node)
        while node do
          local t = node:type()
          if
            t == 'compound_statement'
            or t == 'initializer_list'
            or t == 'namespace_definition'
            or t == 'class_specifier'
            or t == 'struct_specifier'
            or t == 'enum_specifier'
            or t == 'lambda_expression'
          then
            return node
          end
          node = node:parent()
        end
        return nil
      end

      local function find_open_brace(bufnr, start_row, start_col, max_rows)
        local last_row = math.min(start_row + max_rows, vim.api.nvim_buf_line_count(bufnr) - 1)
        for r = start_row, last_row do
          local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, true)[1] or ''
          local c0 = (r == start_row) and start_col or 0
          local idx = line:find('{', c0 + 1, true)
          if idx then
            return r, idx - 1
          end
        end
        return nil
      end

      local function find_close_brace(bufnr, end_row, end_col, max_rows)
        local first_row = math.max(0, end_row - max_rows)
        for r = end_row, first_row, -1 do
          local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, true)[1] or ''
          local c1
          if r == end_row then
            c1 = math.min(end_col, #line)
          else
            c1 = #line
          end
          for i = c1, 1, -1 do
            if line:sub(i, i) == '}' then
              return r, i - 1
            end
          end
        end
        return nil
      end

      local function update_enclosing_braces(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        local ft = vim.bo[bufnr].filetype
        if ft ~= 'c' and ft ~= 'cpp' and ft ~= 'cuda' then
          return
        end

        vim.api.nvim_buf_clear_namespace(bufnr, brace_ns, 0, -1)

        local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
        if not ok_parser or not parser then
          return
        end

        local trees = parser:parse()
        local tree = trees and trees[1]
        if not tree then
          return
        end
        local root = tree:root()

        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        row = row - 1

        local node = root:named_descendant_for_range(row, col, row, col)
        node = find_enclosing_brace_node(node)
        if not node then
          return
        end

        local sr, sc, er, ec = node:range()

        local open_r, open_c = find_open_brace(bufnr, sr, sc, 3)
        local close_r, close_c = find_close_brace(bufnr, er, ec, 3)
        if not (open_r and close_r) then
          return
        end

        vim.api.nvim_buf_set_extmark(bufnr, brace_ns, open_r, open_c, {
          end_col = open_c + 1,
          hl_group = 'EnclosingBrace',
          priority = 200,
        })

        vim.api.nvim_buf_set_extmark(bufnr, brace_ns, close_r, close_c, {
          end_col = close_c + 1,
          hl_group = 'EnclosingBrace',
          priority = 200,
        })

        -- Highlight inner delimiters within the scope. Bail on huge scopes.
        local max_lines = 2000
        if (close_r - open_r) > max_lines then
          return
        end

        for r = open_r, close_r do
          local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, true)[1] or ''
          local start_c = 0
          local end_c = #line

          if r == open_r then
            start_c = open_c + 1
          end
          if r == close_r then
            end_c = close_c
          end

          if end_c > start_c then
            for i = start_c + 1, end_c do
              local ch = line:sub(i, i)
              if ch == '{' or ch == '}' or ch == '(' or ch == ')' or ch == '[' or ch == ']' then
                vim.api.nvim_buf_set_extmark(bufnr, brace_ns, r, i - 1, {
                  end_col = (i - 1) + 1,
                  hl_group = 'InnerDelimiter',
                  priority = 150,
                })
              end
            end
          end
        end
      end

      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, {
        group = vim.api.nvim_create_augroup('ds-enclosing-brace', { clear = true }),
        callback = function(ev)
          update_enclosing_braces(ev.buf)
        end,
      })

      -- C/C++/CUDA monochrome theme. Re-enables classic syntax, then flattens
      -- nearly every group to Normal so only strings (+ comments in gray)
      -- carry color. CUDA-specific groups are re-colored at the end so kernel
      -- launches and __device__/__global__ markers stand out.
      vim.api.nvim_create_autocmd('FileType', {
        pattern = { 'c', 'cpp', 'cuda' },
        callback = function(ev)
          vim.cmd 'syntax clear'
          vim.cmd 'syntax on'

          local function link(group, target)
            pcall(vim.api.nvim_set_hl, 0, group, { link = target })
          end

          for _, g in ipairs {
            'Comment',
            'Constant',
            'Number',
            'Boolean',
            'Float',
            'Identifier',
            'Function',
            'Statement',
            'Conditional',
            'Repeat',
            'Label',
            'Operator',
            'Keyword',
            'Exception',
            'PreProc',
            'Include',
            'Define',
            'Macro',
            'PreCondit',
            'Type',
            'StorageClass',
            'Structure',
            'Typedef',
            'Special',
            'SpecialChar',
            'Tag',
            'Delimiter',
            'SpecialComment',
            'Debug',
            'Underlined',
            'Ignore',
            'Error',
            'Todo',
          } do
            link(g, 'Normal')
          end

          for _, g in ipairs {
            'cType',
            'cStorageClass',
            'cStructure',
            'cConstant',
            'cOperator',
            'cppType',
            'cppStatement',
            'cppStorageClass',
            'cppStructure',
            'cppConstant',
            'cppOperator',
            'cppAccess',
            'cppModifier',
            'cppExceptions',
            'cppBoolean',
          } do
            link(g, 'Normal')
          end

          for _, g in ipairs {
            '@lsp.type.namespace',
            '@lsp.type.type',
            '@lsp.type.class',
            '@lsp.type.struct',
            '@lsp.type.enum',
            '@lsp.type.interface',
            '@lsp.type.parameter',
            '@lsp.type.variable',
            '@lsp.type.property',
            '@lsp.type.function',
            '@lsp.type.method',
            '@lsp.type.macro',
            '@lsp.type.enumMember',
            '@lsp.type.member',
            '@lsp.typemod.variable.defaultLibrary',
            '@lsp.typemod.function.defaultLibrary',
            '@lsp.typemod.namespace.defaultLibrary',
            '@lsp.mod.defaultLibrary',
            '@lsp.mod.readonly',
            '@lsp.mod.constant',
            '@lsp.mod.static',
          } do
            link(g, 'Normal')
          end

          for _, g in ipairs {
            'LspSemanticNamespace',
            'LspSemanticType',
            'LspSemanticClass',
            'LspSemanticStruct',
            'LspSemanticEnum',
            'LspSemanticInterface',
            'LspSemanticParameter',
            'LspSemanticVariable',
            'LspSemanticProperty',
            'LspSemanticFunction',
            'LspSemanticMethod',
            'LspSemanticMacro',
            'LspSemanticEnumMember',
            'LspSemanticMember',
          } do
            link(g, 'Normal')
          end

          link('String', 'String')
          link('Character', 'String')

          vim.api.nvim_set_hl(0, 'Comment', { fg = '#6b7280', italic = true })

          vim.api.nvim_set_hl(0, 'PreProc', { fg = '#6b7280' })
          vim.api.nvim_set_hl(0, 'cppPreCondit', { fg = '#6b7280' })
          vim.api.nvim_set_hl(0, 'cPreCondit', { fg = '#6b7280' })

          for _, g in ipairs {
            '@comment',
            '@preproc',
            '@conditional',
            '@conditional.inactive',
          } do
            pcall(vim.api.nvim_set_hl, 0, g, { fg = '#6b7280' })
          end

          -- Dim C++ cast expressions. static_cast<T>(x), dynamic_cast<T>(x),
          -- reinterpret_cast<T>(x), const_cast<T>(x) — all gray, no italic.
          -- Distinguishable from comments (which are italic) but visually low
          -- priority so the meaningful code stands out.
          vim.api.nvim_set_hl(0, 'dansCppCast', { fg = '#6b7280' })
          vim.cmd [[syntax match dansCppCast /\<\(static\|dynamic\|reinterpret\|const\)_cast\s*<[^>]*>/]]

          if ev.match == 'cuda' then
            -- __device__ / __host__ / __global__ markers.
            vim.api.nvim_set_hl(0, 'cudaStorageClass', { fg = '#9ece6a', bold = true })
            vim.api.nvim_set_hl(0, 'cudaConstant', { fg = '#9ece6a', bold = true })
            -- dim3, vector types, cudaError_t.
            vim.api.nvim_set_hl(0, 'cudaType', { fg = '#7dcfff' })
            -- gridDim, blockIdx, blockDim, threadIdx, warpSize.
            vim.api.nvim_set_hl(0, 'cudaVariable', { fg = '#ff9e64' })
            -- <<< grid, block, sharedMem, stream >>>.
            vim.api.nvim_set_hl(0, 'cudaKernelBrackets', { fg = '#bb9af7', bold = true })
            vim.api.nvim_set_hl(0, 'cudaKernelConfig', { fg = '#e0af68' })
            vim.api.nvim_set_hl(0, 'cudaDunder', { link = 'cudaStorageClass' })

            vim.cmd [[syntax match cudaDunder /\<__\w\+__\>/]]
            vim.cmd [[syntax region cudaKernelConfig matchgroup=cudaKernelBrackets start=/<<</ end=/>>>/ oneline keepend contains=NONE]]
          end
        end,
      })
    end,
  },
}
