-- Debug Adapter Protocol. Prefers CodeLLDB on macOS, falls back to lldb-dap.
-- nvim-dap-julia wires DebugAdapter.jl into its pinned Julia env on build.
return {
  'mfussenegger/nvim-dap',
  dependencies = {
    {
      'rcarriga/nvim-dap-ui',
      dependencies = { 'nvim-neotest/nvim-nio' },
    },
    {
      'theHamsta/nvim-dap-virtual-text',
      opts = {
        enabled = true,
        enabled_commands = true,
        highlight_changed_variables = false,
        show_stop_reason = false,
        commented = true,
        virt_text_pos = 'eol',
        virt_text_win_col = nil,
        all_frames = false,
        virt_lines = false,
        virt_text_priority = 200,
      },
    },
    {
      'jay-babu/mason-nvim-dap.nvim',
      dependencies = { 'williamboman/mason.nvim' },
      opts = {
        automatic_installation = true,
        handlers = {},
        ensure_installed = { 'codelldb' },
      },
    },
    {
      'kdheepak/nvim-dap-julia',
      build = "julia --project=. -e 'using Pkg; Pkg.instantiate()'",
    },
  },
  config = function()
    local dap = require 'dap'
    local dapui = require 'dapui'

    dapui.setup()

    -- Auto-load .vscode/launch.json from the project root if present, so DAP
    -- configurations defined there show up in the F5 picker without manually
    -- calling load_launchjs().
    pcall(function()
      require('dap.ext.vscode').load_launchjs(nil, {})
    end)

    vim.api.nvim_set_hl(0, 'DapVirtualText', { fg = '#6b7280', italic = false })
    vim.api.nvim_set_hl(0, 'DapVirtualTextChanged', { fg = '#9ca3af', italic = false })
    vim.api.nvim_set_hl(0, 'DapVirtualTextError', { fg = '#9ca3af', italic = false })

    -- Red disc breakpoint signs.
    vim.fn.sign_define('DapBreakpoint', { text = '🔴', texthl = '', linehl = '', numhl = '' })
    vim.fn.sign_define('DapBreakpointCondition', { text = '🔴', texthl = '', linehl = '', numhl = '' })
    vim.fn.sign_define('DapBreakpointRejected', { text = '🔴', texthl = '', linehl = '', numhl = '' })

    dap.listeners.after.event_initialized['dapui_config'] = function()
      dapui.open()
    end
    dap.listeners.before.event_terminated['dapui_config'] = function()
      dapui.close()
    end
    dap.listeners.before.event_exited['dapui_config'] = function()
      dapui.close()
    end

    local mason_data = vim.fn.stdpath 'data'
    local codelldb_adapter = mason_data .. '/mason/packages/codelldb/extension/adapter/codelldb'
    local lldb_dap_mason = mason_data .. '/mason/bin/lldb-dap'
    local lldb_dap_homebrew = '/opt/homebrew/opt/llvm/bin/lldb-dap'

    if vim.fn.executable(codelldb_adapter) == 1 then
      dap.adapters.codelldb = {
        type = 'server',
        port = '${port}',
        executable = {
          command = codelldb_adapter,
          args = { '--port', '${port}' },
        },
      }
    else
      local lldb_dap = (vim.fn.executable(lldb_dap_mason) == 1 and lldb_dap_mason)
        or (vim.fn.executable(lldb_dap_homebrew) == 1 and lldb_dap_homebrew)
        or 'lldb-dap'

      dap.adapters.lldb = {
        type = 'executable',
        command = lldb_dap,
        name = 'lldb',
      }
    end

    local function default_program()
      return vim.fn.getcwd() .. '/build/main'
    end

    local function split_args(s)
      if s == nil or s == '' then
        return {}
      end
      return vim.split(s, '%s+')
    end

    local preferred_type = (dap.adapters.codelldb ~= nil) and 'codelldb' or 'lldb'

    dap.configurations.cpp = {
      {
        name = 'Launch build/main',
        type = preferred_type,
        request = 'launch',
        program = default_program,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
        args = {},
        terminal = 'integrated',
      },
      {
        name = 'Launch (prompt)',
        type = preferred_type,
        request = 'launch',
        program = function()
          return vim.fn.input('Path to executable: ', default_program(), 'file')
        end,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
        args = function()
          return split_args(vim.fn.input 'Args (space-separated): ')
        end,
        terminal = 'integrated',
      },
      {
        name = 'Attach to process',
        type = preferred_type,
        request = 'attach',
        pid = require('dap.utils').pick_process,
        cwd = '${workspaceFolder}',
      },
    }
    dap.configurations.c = dap.configurations.cpp

    pcall(function()
      require('nvim-dap-julia').setup()
    end)

    vim.keymap.set('n', '<F5>', dap.continue, { desc = 'DAP: Continue' })
    vim.keymap.set('n', '<F10>', dap.step_over, { desc = 'DAP: Step over' })
    vim.keymap.set('n', '<F11>', dap.step_into, { desc = 'DAP: Step into' })
    vim.keymap.set('n', '<F12>', dap.step_out, { desc = 'DAP: Step out' })
    vim.keymap.set('n', '<leader>db', dap.toggle_breakpoint, { desc = 'DAP: Toggle breakpoint' })
    vim.keymap.set('n', '<leader>dB', function()
      dap.set_breakpoint(vim.fn.input 'Breakpoint condition: ')
    end, { desc = 'DAP: Conditional breakpoint' })
    vim.keymap.set('n', '<leader>dr', dap.repl.open, { desc = 'DAP: Open REPL' })
    vim.keymap.set('n', '<leader>dl', dap.run_last, { desc = 'DAP: Run last' })
    vim.keymap.set('n', '<leader>du', dapui.toggle, { desc = 'DAP: Toggle UI' })
  end,
}
