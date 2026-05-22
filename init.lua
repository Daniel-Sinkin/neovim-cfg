--[[

=====================================================================
==================== READ THIS BEFORE CONTINUING ====================
=====================================================================
========                                    .-----.          ========
========         .----------------------.   | === |          ========
========         |.-""""""""""""""""""-.|   |-----|          ========
========         ||                    ||   | === |          ========
========         ||   KICKSTART.NVIM   ||   |-----|          ========
========         ||                    ||   | === |          ========
========         ||                    ||   |-----|          ========
========         ||:Tutor              ||   |:::::|          ========
========         |'-..................-'|   |____o|          ========
========         `"")----------------(""`   ___________      ========
========        /::::::::::|  |::::::::::\  \ no mouse \     ========
========       /:::========|  |==hjkl==:::\  \ required \    ========
========      '""""""""""""'  '""""""""""""'  '""""""""""'   ========
========                                                     ========
=====================================================================
=====================================================================

What is Kickstart?

  Kickstart.nvim is *not* a distribution.

  Kickstart.nvim is a starting point for your own configuration.
    The goal is that you can read every line of code, top-to-bottom, understand
    what your configuration is doing, and modify it to suit your needs.

    Once you've done that, you can start exploring, configuring and tinkering to
    make Neovim your own! That might mean leaving Kickstart just the way it is for a while
    or immediately breaking it into modular pieces. It's up to you!

    If you don't know anything about Lua, I recommend taking some time to read through
    a guide. One possible example which will only take 10-15 minutes:
      - https://learnxinyminutes.com/docs/lua/

    After understanding a bit more about Lua, you can use `:help lua-guide` as a
    reference for how Neovim integrates Lua.
    - :help lua-guide
    - (or HTML version): https://neovim.io/doc/user/lua-guide.html

Kickstart Guide:

  TODO: The very first thing you should do is to run the command `:Tutor` in Neovim.

    If you don't know what this means, type the following:
      - <escape key>
      - :
      - Tutor
      - <enter key>

    (If you already know the Neovim basics, you can skip this step.)

  Once you've completed that, you can continue working through **AND READING** the rest
  of the kickstart init.lua.

  Next, run AND READ `:help`.
    This will open up a help window with some basic information
    about reading, navigating and searching the builtin help documentation.

    This should be the first place you go to look when you're stuck or confused
    with something. It's one of my favorite Neovim features.

    MOST IMPORTANTLY, we provide a keymap "<space>sh" to [s]earch the [h]elp documentation,
    which is very useful when you're not exactly sure of what you're looking for.

  I have left several `:help X` comments throughout the init.lua
    These are hints about where to find more information about the relevant settings,
    plugins or Neovim features used in Kickstart.

   NOTE: Look for lines like this

    Throughout the file. These are for you, the reader, to help you understand what is happening.
    Feel free to delete them once you know what you're doing, but they should serve as a guide
    for when you are first encountering a few different constructs in your Neovim config.

If you experience any errors while trying to install kickstart, run `:checkhealth` for more info.

I hope you enjoy your Neovim journey,
- TJ

P.S. You can delete this when you're done too. It's your config now! :)
--]]

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = false

-- Treat `.h` headers as C, not C++. Must be set before any filetype detection
-- runs so plain C headers (e.g. dans-util/src/types.h) don't get C++ clang-tidy
-- checks (modernize-deprecated-headers, modernize-use-using, etc.).
vim.g.c_syntax_for_h = 1

-- macOS: `cc` resolves to the raw Xcode toolchain compiler (its bin dir sits in
-- PATH ahead of /usr/bin/cc, the xcrun shim that injects -isysroot). The raw
-- compiler has no sysroot, so nvim-treesitter parser builds fail with
-- "'stdlib.h' file not found". Exporting SDKROOT gives clang the SDK.
if vim.fn.has 'mac' == 1 and (vim.env.SDKROOT == nil or vim.env.SDKROOT == '') then
  local sdk = vim.trim(vim.fn.system 'xcrun --show-sdk-path 2>/dev/null')
  if vim.v.shell_error == 0 and sdk ~= '' and vim.fn.isdirectory(sdk) == 1 then
    vim.env.SDKROOT = sdk
  end
end

-- GUI launches (Neovide, dock) don't inherit the shell PATH, so juliaup's
-- `julia` goes missing and the Julia LSP / debug adapter can't spawn. Put it
-- on PATH explicitly.
do
  local juliaup_bin = vim.fn.expand '~/.juliaup/bin'
  if vim.fn.isdirectory(juliaup_bin) == 1 and not (vim.env.PATH or ''):find(juliaup_bin, 1, true) then
    vim.env.PATH = juliaup_bin .. ':' .. (vim.env.PATH or '')
  end
end

-- Neovide-only visuals (ignored in terminal Neovim)
if vim.g.neovide then
  -- Smooth cursor interpolation
  vim.g.neovide_cursor_animation_length = 0.06

  -- Disable Neovide's built-in smooth scrolling so mousewheel stays responsive
  vim.g.neovide_scroll_animation_length = 0.0

  -- Cursor trail size (0.0 disables trail)
  vim.g.neovide_cursor_trail_size = 0.35

  -- Cursor visual effect
  vim.g.neovide_cursor_vfx_mode = ''

  -- Neovide expects a *font family* name (not a file name). Monaspace's family is "Monaspace Krypton".
  vim.o.guifont = 'Monaspace Krypton:h14'
end

-- [[ Setting options ]]
-- See `:help vim.opt`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
vim.opt.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = 'a'

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Sync clipboard between OS and Neovim.
--  Schedule the setting after `UiEnter` because it can increase startup-time.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.opt.confirm = true

-- Enable concealment for plugins like obsidian.nvim (hides markup, renders checkboxes, etc.)
vim.opt.conceallevel = 2

-- Disable automatic comment continuation on newline / o / O
vim.api.nvim_create_autocmd('FileType', {
  pattern = '*',
  callback = function()
    -- r: continue comments when pressing Enter
    -- o: continue comments when using o or O
    -- c: auto-wrap comments (also remove, to be safe)
    vim.opt_local.formatoptions:remove { 'r', 'o', 'c' }
  end,
})

-- Open file explorer on startup (left) when starting in a directory / empty buffer
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function(data)
    -- If a file was specified on the command line, don't force open.
    local buf = data.buf
    local name = vim.api.nvim_buf_get_name(buf)

    -- If started with a directory: open it and show the tree
    local stat = (vim.uv or vim.loop).fs_stat(name)
    if stat and stat.type == 'directory' then
      vim.cmd.cd(name)
      vim.cmd 'Neotree show left'
      return
    end

    -- If started with an empty buffer: show the tree
    if name == '' then
      vim.cmd 'Neotree show left'
    end
  end,
})

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Mousewheel: scroll viewport without moving cursor (no smoothing)
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelUp>', '<C-y><C-y><C-y>', { silent = true })
vim.keymap.set({ 'n', 'i', 'v' }, '<ScrollWheelDown>', '<C-e><C-e><C-e>', { silent = true })

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- TIP: Disable arrow keys in normal mode
-- vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
-- vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
-- vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
-- vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- NOTE: Some terminals have coliding keymaps or are not able to send distinct keycodes
-- vim.keymap.set("n", "<C-S-h>", "<C-w>H", { desc = "Move window to the left" })
-- vim.keymap.set("n", "<C-S-l>", "<C-w>L", { desc = "Move window to the right" })
-- vim.keymap.set("n", "<C-S-j>", "<C-w>J", { desc = "Move window to the lower" })
-- vim.keymap.set("n", "<C-S-k>", "<C-w>K", { desc = "Move window to the upper" })

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- [[ Install `lazy.nvim` plugin manager ]]
--    See `:help lazy.nvim.txt` or https://github.com/folke/lazy.nvim for more info
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  local out = vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
  if vim.v.shell_error ~= 0 then
    error('Error cloning lazy.nvim:\n' .. out)
  end
end ---@diagnostic disable-next-line: undefined-field

vim.opt.rtp:prepend(lazypath)

-- [[ Configure and install plugins ]]
--
--  To check the current status of your plugins, run
--    :Lazy
--
--  You can press `?` in this menu for help. Use `:q` to close the window
--
--  To update plugins you can run
--    :Lazy update
--
-- NOTE: Here is where you install your plugins.
require('lazy').setup({
  -- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
  'tpope/vim-sleuth', -- Detect tabstop and shiftwidth automatically
  { -- VSCode-like multi-cursor
    'mg979/vim-visual-multi',
    branch = 'master',
    init = function()
      -- Match VSCode muscle memory
      vim.g.VM_maps = {
        ['Find Under'] = '<C-n>',
        ['Find Subword Under'] = '<C-n>',
      }

      -- Sensible defaults
      vim.g.VM_default_mappings = 1
      vim.g.VM_silent_exit = 1
    end,
  },
  { -- File explorer (left file tree)
    'nvim-neo-tree/neo-tree.nvim',
    branch = 'v3.x',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-tree/nvim-web-devicons',
      'MunifTanjim/nui.nvim',
    },
    cmd = 'Neotree',
    keys = {
      { '<leader>e', '<cmd>Neotree toggle left<CR>', desc = 'Toggle file explorer' },
      { '<leader>o', '<cmd>Neotree focus left<CR>', desc = 'Focus file explorer' },
    },
    opts = {
      close_if_last_window = true,
      popup_border_style = 'rounded',
      enable_git_status = true,
      enable_diagnostics = true,
      filesystem = {
        filtered_items = {
          hide_dotfiles = false,
          hide_gitignored = false,
        },
        follow_current_file = {
          enabled = true,
        },
        hijack_netrw_behavior = 'open_default',
      },
      window = {
        position = 'left',
        width = 32,
        mappings = {
          ['<space>'] = 'toggle_node',
          ['<cr>'] = 'open',
          ['l'] = 'open',
          ['h'] = 'close_node',
        },
      },
    },
  },

  { -- Integrated terminal as a panel
    'akinsho/toggleterm.nvim',
    version = '*',
    opts = {
      size = function(term)
        if term.direction == 'horizontal' then
          return 15 -- bottom panel height
        elseif term.direction == 'vertical' then
          return 80 -- side panel width (if you open one manually)
        end
      end,
      open_mapping = nil,
      shade_terminals = false,
      direction = 'horizontal', -- open at the bottom by default
      close_on_exit = false,
      shell = vim.o.shell,
    },
    keys = {
      {
        '<leader>tt',
        function()
          -- Toggle a dedicated bottom terminal *under the main code window* (not under Neo-tree).
          local tab = vim.api.nvim_get_current_tabpage()

          -- If the terminal window is already visible in this tab, close it.
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.bo[buf].buftype == 'terminal' and vim.b[buf].ds_bottom_term == true then
              vim.api.nvim_win_close(win, true)
              return
            end
          end

          -- Pick a target window to split: prefer a normal code buffer (not neo-tree, not terminal).
          local target_win = nil
          local best_width = -1
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local buf = vim.api.nvim_win_get_buf(win)
            local ft = vim.bo[buf].filetype
            local bt = vim.bo[buf].buftype
            if bt == '' and ft ~= 'neo-tree' then
              local w = vim.api.nvim_win_get_width(win)
              if w > best_width then
                best_width = w
                target_win = win
              end
            end
          end

          if not target_win then
            target_win = vim.api.nvim_get_current_win()
          end

          vim.api.nvim_win_call(target_win, function()
            -- Split below *this* window only.
            vim.cmd 'belowright 15split'

            -- Reuse an existing dedicated terminal buffer if we have one.
            local buf = vim.g.ds_bottom_term_buf
            if buf and vim.api.nvim_buf_is_valid(buf) then
              vim.api.nvim_win_set_buf(0, buf)
              vim.cmd 'startinsert'
              return
            end

            -- Otherwise create a real terminal buffer in this split.
            vim.cmd 'terminal'
            buf = vim.api.nvim_get_current_buf()
            vim.b.ds_bottom_term = true
            vim.bo.bufhidden = 'hide'
            vim.g.ds_bottom_term_buf = buf
            vim.cmd 'startinsert'
          end)
        end,
        desc = 'Toggle terminal (bottom of code panel)',
      },
      { '<leader>tb', '<leader>tt', remap = true, desc = 'Toggle terminal (bottom)' },
      { '<leader>tf', '<cmd>ToggleTerm direction=float<CR>', desc = 'Toggle terminal (float)' },
    },
  },

  -- NOTE: Plugins can also be added by using a table,
  -- with the first argument being the link and the following
  -- keys can be used to configure plugin behavior/loading/etc.
  --
  -- Use `opts = {}` to automatically pass options to a plugin's `setup()` function, forcing the plugin to be loaded.
  --

  -- Alternatively, use `config = function() ... end` for full control over the configuration.
  -- If you prefer to call `setup` explicitly, use:
  --    {
  --        'lewis6991/gitsigns.nvim',
  --        config = function()
  --            require('gitsigns').setup({
  --                -- Your gitsigns configuration here
  --            })
  --        end,
  --    }
  --
  -- Here is a more advanced example where we pass configuration
  -- options to `gitsigns.nvim`.
  --
  -- See `:help gitsigns` to understand what the configuration keys do
  { -- Adds git related signs to the gutter, as well as utilities for managing changes
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
  },
  {
    -- Rainbow brackets
    'HiPhish/rainbow-delimiters.nvim',
    enabled = false,
    event = 'BufReadPost',
    config = function()
      local rd = require 'rainbow-delimiters'

      vim.g.rainbow_delimiters = {
        strategy = {
          -- Default: highlight everything
          [''] = rd.strategy.global,
          -- C/C++: only highlight the scope containing the cursor (enclosing delimiters)
          c = rd.strategy['local'],
          cpp = rd.strategy['local'],
        },
        query = { [''] = 'rainbow-delimiters' },
        highlight = {
          'RainbowDelimiterRed',
          'RainbowDelimiterYellow',
          'RainbowDelimiterBlue',
          'RainbowDelimiterOrange',
          'RainbowDelimiterGreen',
          'RainbowDelimiterViolet',
          'RainbowDelimiterCyan',
        },
      }

      -- Ensure the highlight groups are actually distinct/visible in your colorscheme.
      -- (We link to existing diagnostic groups instead of hardcoding colors.)
      vim.api.nvim_set_hl(0, 'RainbowDelimiterRed', { link = 'DiagnosticError' })
      vim.api.nvim_set_hl(0, 'RainbowDelimiterYellow', { link = 'DiagnosticWarn' })
      vim.api.nvim_set_hl(0, 'RainbowDelimiterBlue', { link = 'DiagnosticInfo' })
      vim.api.nvim_set_hl(0, 'RainbowDelimiterOrange', { link = 'DiagnosticWarn' })
      vim.api.nvim_set_hl(0, 'RainbowDelimiterGreen', { link = 'DiagnosticHint' })
      vim.api.nvim_set_hl(0, 'RainbowDelimiterViolet', { link = 'DiagnosticInfo' })
      vim.api.nvim_set_hl(0, 'RainbowDelimiterCyan', { link = 'DiagnosticHint' })
    end,
  },

  -- NOTE: Plugins can also be configured to run Lua code when they are loaded.
  --
  -- This is often very useful to both group configuration, as well as handle
  -- lazy loading plugins that don't need to be loaded immediately at startup.
  --
  -- For example, in the following configuration, we use:
  --  event = 'VimEnter'
  --
  -- which loads which-key before all the UI elements are loaded. Events can be
  -- normal autocommands events (`:help autocmd-events`).
  --
  -- Then, because we use the `opts` key (recommended), the configuration runs
  -- after the plugin has been loaded as `require(MODULE).setup(opts)`.

  { -- Useful plugin to show you pending keybinds.
    'folke/which-key.nvim',
    event = 'VimEnter', -- Sets the loading event to 'VimEnter'
    opts = {
      -- delay between pressing a key and opening which-key (milliseconds)
      -- this setting is independent of vim.opt.timeoutlen
      delay = 0,
      icons = {
        -- set icon mappings to true if you have a Nerd Font
        mappings = vim.g.have_nerd_font,
        -- If you are using a Nerd Font: set icons.keys to an empty table which will use the
        -- default which-key.nvim defined Nerd Font icons, otherwise define a string table
        keys = vim.g.have_nerd_font and {} or {
          Up = '<Up> ',
          Down = '<Down> ',
          Left = '<Left> ',
          Right = '<Right> ',
          C = '<C-…> ',
          M = '<M-…> ',
          D = '<D-…> ',
          S = '<S-…> ',
          CR = '<CR> ',
          Esc = '<Esc> ',
          ScrollWheelDown = '<ScrollWheelDown> ',
          ScrollWheelUp = '<ScrollWheelUp> ',
          NL = '<NL> ',
          BS = '<BS> ',
          Space = '<Space> ',
          Tab = '<Tab> ',
          F1 = '<F1>',
          F2 = '<F2>',
          F3 = '<F3>',
          F4 = '<F4>',
          F5 = '<F5>',
          F6 = '<F6>',
          F7 = '<F7>',
          F8 = '<F8>',
          F9 = '<F9>',
          F10 = '<F10>',
          F11 = '<F11>',
          F12 = '<F12>',
        },
      },

      -- Document existing key chains
      spec = {
        { '<leader>c', group = '[C]ode', mode = { 'n', 'x' } },
        { '<leader>d', group = '[D]ocument' },
        { '<leader>r', group = '[R]ename' },
        { '<leader>s', group = '[S]earch' },
        { '<leader>w', group = '[W]orkspace' },
        { '<leader>t', group = '[T]oggle' },
        { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
        { '<leader>o', group = '[O]bsidian' },
      },
    },
  },

  -- NOTE: Plugins can specify dependencies.
  --
  -- The dependencies are proper plugin specifications as well - anything
  -- you do for a plugin at the top level, you can do for a dependency.
  --
  -- Use the `dependencies` key to specify the dependencies of a particular plugin

  { -- Fuzzy Finder (files, lsp, etc)
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    -- master (not the stale 0.1.x branch) so the LSP pickers use the
    -- Neovim 0.11 APIs and don't emit make_position_params/jump_to_location
    -- deprecation warnings.
    dependencies = {
      'nvim-lua/plenary.nvim',
      { -- If encountering errors, see telescope-fzf-native README for installation instructions
        'nvim-telescope/telescope-fzf-native.nvim',

        -- `build` is used to run some command when the plugin is installed/updated.
        -- This is only run then, not every time Neovim starts up.
        build = 'make',

        -- `cond` is a condition used to determine whether this plugin should be
        -- installed and loaded.
        cond = function()
          return vim.fn.executable 'make' == 1
        end,
      },
      { 'nvim-telescope/telescope-ui-select.nvim' },

      -- Useful for getting pretty icons, but requires a Nerd Font.
      { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
    },
    config = function()
      -- Telescope is a fuzzy finder that comes with a lot of different things that
      -- it can fuzzy find! It's more than just a "file finder", it can search
      -- many different aspects of Neovim, your workspace, LSP, and more!
      --
      -- The easiest way to use Telescope, is to start by doing something like:
      --  :Telescope help_tags
      --
      -- After running this command, a window will open up and you're able to
      -- type in the prompt window. You'll see a list of `help_tags` options and
      -- a corresponding preview of the help.
      --
      -- Two important keymaps to use while in Telescope are:
      --  - Insert mode: <c-/>
      --  - Normal mode: ?
      --
      -- This opens a window that shows you all of the keymaps for the current
      -- Telescope picker. This is really useful to discover what Telescope can
      -- do as well as how to actually do it!

      -- [[ Configure Telescope ]]
      -- See `:help telescope` and `:help telescope.setup()`
      require('telescope').setup {
        -- You can put your default mappings / updates / etc. in here
        --  All the info you're looking for is in `:help telescope.setup()`
        --
        -- defaults = {
        --   mappings = {
        --     i = { ['<c-enter>'] = 'to_fuzzy_refine' },
        --   },
        -- },
        -- pickers = {}
        extensions = {
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
        },
      }

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')

      -- See `:help telescope.builtin`
      local builtin = require 'telescope.builtin'
      vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
      vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
      vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
      -- Explicit mapping for <leader>ff to find_files
      vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = '[F]ind [F]iles' })
      vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
      vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
      vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
      vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
      vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
      vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
      vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

      -- Slightly advanced example of overriding default behavior and theme
      vim.keymap.set('n', '<leader>/', function()
        -- You can pass additional configuration to Telescope to change the theme, layout, etc.
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
      end, { desc = '[/] Fuzzily search in current buffer' })

      -- It's also possible to pass additional configuration options.
      --  See `:help telescope.builtin.live_grep()` for information about particular keys
      vim.keymap.set('n', '<leader>s/', function()
        builtin.live_grep {
          grep_open_files = true,
          prompt_title = 'Live Grep in Open Files',
        }
      end, { desc = '[S]earch [/] in Open Files' })

      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set('n', '<leader>sn', function()
        builtin.find_files { cwd = vim.fn.stdpath 'config' }
      end, { desc = '[S]earch [N]eovim files' })
    end,
  },

  -- LSP Plugins
  {
    -- `lazydev` configures Lua LSP for your Neovim config, runtime and plugins
    -- used for completion, annotations and signatures of Neovim apis
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        -- Load luvit types when the `vim.uv` word is found
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    -- Main LSP Configuration
    'neovim/nvim-lspconfig',
    dependencies = {
      -- Automatically install LSPs and related tools to stdpath for Neovim
      -- Mason must be loaded before its dependents so we need to set it up here.
      -- NOTE: `opts = {}` is the same as calling `require('mason').setup({})`
      { 'williamboman/mason.nvim', opts = {} },
      'williamboman/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- Useful status updates for LSP.
      -- julials is rendered by custom.julia_progress instead (one stable
      -- widget); fidget still handles every other LSP.
      { 'j-hui/fidget.nvim', opts = { progress = { ignore = { 'julials' } } } },

      -- Allows extra capabilities provided by nvim-cmp
      -- 'hrsh7th/cmp-nvim-lsp',
    },
    config = function()
      -- Brief aside: **What is LSP?**
      --
      -- LSP is an initialism you've probably heard, but might not understand what it is.
      --
      -- LSP stands for Language Server Protocol. It's a protocol that helps editors
      -- and language tooling communicate in a standardized fashion.
      --
      -- In general, you have a "server" which is some tool built to understand a particular
      -- language (such as `gopls`, `lua_ls`, `rust_analyzer`, etc.). These Language Servers
      -- (sometimes called LSP servers, but that's kind of like ATM Machine) are standalone
      -- processes that communicate with some "client" - in this case, Neovim!
      --
      -- LSP provides Neovim with features like:
      --  - Go to definition
      --  - Find references
      --  - Autocompletion
      --  - Symbol Search
      --  - and more!
      --
      -- Thus, Language Servers are external tools that must be installed separately from
      -- Neovim. This is where `mason` and related plugins come into play.
      --
      -- If you're wondering about lsp vs treesitter, you can check out the wonderfully
      -- and elegantly composed help section, `:help lsp-vs-treesitter`

      --  This function gets run when an LSP attaches to a particular buffer.
      --    That is to say, every time a new file is opened that is associated with
      --    an lsp (for example, opening `main.rs` is associated with `rust_analyzer`) this
      --    function will be executed to configure the current buffer
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          -- NOTE: Remember that Lua is a real programming language, and as such it is possible
          -- to define small helper and utility functions so you don't have to repeat yourself.
          --
          -- In this case, we create a function that lets us more easily define mappings specific
          -- for LSP related items. It sets the mode, buffer and description for us each time.
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          -- Jump to the definition of the word under your cursor.
          --  This is where a variable was first declared, or where a function is defined, etc.
          --  To jump back, press <C-t>.
          map('gd', require('telescope.builtin').lsp_definitions, '[G]oto [D]efinition')

          -- Find references for the word under your cursor.
          map('gr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')

          -- Jump to the implementation of the word under your cursor.
          --  Useful when your language has ways of declaring types without an actual implementation.
          map('gI', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')

          -- Jump to the type of the word under your cursor.
          --  Useful when you're not sure what type a variable is and you want to see
          --  the definition of its *type*, not where it was *defined*.
          map('<leader>D', require('telescope.builtin').lsp_type_definitions, 'Type [D]efinition')

          -- Fuzzy find all the symbols in your current document.
          --  Symbols are things like variables, functions, types, etc.
          map('<leader>ds', require('telescope.builtin').lsp_document_symbols, '[D]ocument [S]ymbols')

          -- Fuzzy find all the symbols in your current workspace.
          --  Similar to document symbols, except searches over your entire project.
          map('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')

          -- Rename the variable under your cursor.
          --  Most Language Servers support renaming across files, etc.
          map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')

          -- Execute a code action, usually your cursor needs to be on top of an error
          -- or a suggestion from your LSP for this to activate.
          map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction', { 'n', 'x' })

          -- WARN: This is not Goto Definition, this is Goto Declaration.
          --  For example, in C this would take you to the header.
          map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

          -- This function resolves a difference between neovim nightly (version 0.11) and stable (version 0.10)
          ---@param client vim.lsp.Client
          ---@param method vim.lsp.protocol.Method
          ---@param bufnr? integer some lsp support methods only in specific files
          ---@return boolean
          local function client_supports_method(client, method, bufnr)
            if vim.fn.has 'nvim-0.11' == 1 then
              return client:supports_method(method, bufnr)
            else
              return client.supports_method(method, { bufnr = bufnr })
            end
          end

          -- The following two autocommands are used to highlight references of the
          -- word under your cursor when your cursor rests there for a little while.
          --    See `:help CursorHold` for information about when this is executed
          --
          -- When you move your cursor, the highlights will be cleared (the second autocommand).
          local client = vim.lsp.get_client_by_id(event.data.client_id)
          -- Disable LSP semantic token highlighting for C/C++ (it will re-color identifiers like std::, variables, etc.)
          if client and (vim.bo[event.buf].filetype == 'c' or vim.bo[event.buf].filetype == 'cpp') then
            client.server_capabilities.semanticTokensProvider = nil
          end
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_documentHighlight, event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          -- The following code creates a keymap to toggle inlay hints in your
          -- code, if the language server you are using supports them
          --
          -- This may be unwanted, since they displace some of your code
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_inlayHint, event.buf) then
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      -- Diagnostic Config
      -- See :help vim.diagnostic.Opts
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
        virtual_text = {
          source = 'if_many',
          spacing = 2,
          format = function(diagnostic)
            local diagnostic_message = {
              [vim.diagnostic.severity.ERROR] = diagnostic.message,
              [vim.diagnostic.severity.WARN] = diagnostic.message,
              [vim.diagnostic.severity.INFO] = diagnostic.message,
              [vim.diagnostic.severity.HINT] = diagnostic.message,
            }
            return diagnostic_message[diagnostic.severity]
          end,
        },
      }

      -- LSP servers and clients are able to communicate to each other what features they support.
      --  By default, Neovim doesn't support everything that is in the LSP specification.
      --  When you add nvim-cmp, luasnip, etc. Neovim now has *more* capabilities.
      --  So, we create new capabilities with nvim cmp, and then broadcast that to the servers.
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())

      -- Filter clang-tidy diagnostics out of plain C buffers. `.clang-tidy`
      -- in the repo is intended for C++ (.cpp/.hpp); C files should only see
      -- the compiler's own diagnostics from clangd.
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
        -- NOTE: clangd re-enabled for hover (type reveal) and format-on-save.
        -- Autocomplete is disabled separately via nvim-cmp FileType autocmd below.
        clangd = {
          cmd = {
            '/opt/homebrew/opt/llvm/bin/clangd',
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
              completion = {
                callSnippet = 'Replace',
              },
            },
          },
        },

        -- Julia: LanguageServer.jl. The cmd comes from nvim-lspconfig's
        -- shipped lsp/julials.lua. Requires LanguageServer, SymbolServer and
        -- StaticLint installed in ~/.julia/environments/nvim-lspconfig (see
        -- :h lspconfig-julials). Not a mason server, configured directly below.
        julials = {
          -- Root at the OUTERMOST Project.toml. A dev-environment layout nests
          -- the package's Project.toml inside the driver's; rooting at the
          -- nearest one would spawn a separate julials per nested project
          -- (double startup, duplicated diagnostics). One root = one client.
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

      -- Ensure the servers and tools above are installed (clangd intentionally not managed by mason here)
      local ensure_installed = {
        'lua_ls',
        'stylua',
      }
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }
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

  { -- Autoformat
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

        -- Always format C/C++ via clangd on save
        if ft == 'c' or ft == 'cpp' then
          return {
            timeout_ms = 1000,
            lsp_format = 'always',
          }
        end

        -- Julia: julials formats via its bundled JuliaFormatter.jl, which
        -- honors a project-root .JuliaFormatter.toml on its own. Allow extra
        -- time for the first format of a session (JuliaFormatter JIT warmup).
        if ft == 'julia' then
          return {
            timeout_ms = 3000,
            lsp_format = 'fallback',
          }
        end

        -- Default behavior for other filetypes
        return {
          timeout_ms = 500,
          lsp_format = 'fallback',
        }
      end,
      formatters_by_ft = {
        lua = { 'stylua' },
        -- Conform can also run multiple formatters sequentially
        -- python = { "isort", "black" },
        --
        -- You can use 'stop_after_first' to run the first available formatter from the list
        -- javascript = { "prettierd", "prettier", stop_after_first = true },
      },
    },
  },

  { -- Debug Adapter Protocol client
    'mfussenegger/nvim-dap',
    dependencies = {
      { -- UI for DAP
        'rcarriga/nvim-dap-ui',
        dependencies = { 'nvim-neotest/nvim-nio' },
      },
      { -- Inline variable values
        'theHamsta/nvim-dap-virtual-text',
        opts = {
          enabled = true,
          enabled_commands = true,
          highlight_changed_variables = false,
          show_stop_reason = false,
          commented = true, -- prefix virtual text with comment markers
          virt_text_pos = 'eol',
          virt_text_win_col = nil,
          all_frames = false,
          virt_lines = false,
          virt_text_priority = 200,
        },
      },
      { -- Install debug adapters via Mason
        'jay-babu/mason-nvim-dap.nvim',
        dependencies = { 'williamboman/mason.nvim' },
        opts = {
          automatic_installation = true,
          handlers = {},
          ensure_installed = { 'codelldb' },
        },
      },
      { -- Julia debug adapter (wraps DebugAdapter.jl)
        'kdheepak/nvim-dap-julia',
        -- Install DebugAdapter.jl into the plugin's pinned Julia env.
        build = "julia --project=. -e 'using Pkg; Pkg.instantiate()'",
      },
    },
    config = function()
      local dap = require 'dap'
      local dapui = require 'dapui'

      dapui.setup()

      -- Subtle gray highlighting for DAP virtual text (debugger inlay values)
      vim.api.nvim_set_hl(0, 'DapVirtualText', { fg = '#6b7280', italic = false })
      vim.api.nvim_set_hl(0, 'DapVirtualTextChanged', { fg = '#9ca3af', italic = false })
      vim.api.nvim_set_hl(0, 'DapVirtualTextError', { fg = '#9ca3af', italic = false })

      -- Force override of DAP breakpoint signs with a red disc emoji
      vim.fn.sign_define('DapBreakpoint', {
        text = '🔴',
        texthl = '',
        linehl = '',
        numhl = '',
      })

      vim.fn.sign_define('DapBreakpointCondition', {
        text = '🔴',
        texthl = '',
        linehl = '',
        numhl = '',
      })

      vim.fn.sign_define('DapBreakpointRejected', {
        text = '🔴',
        texthl = '',
        linehl = '',
        numhl = '',
      })

      -- Open/close the UI automatically
      dap.listeners.after.event_initialized['dapui_config'] = function()
        dapui.open()
      end
      dap.listeners.before.event_terminated['dapui_config'] = function()
        dapui.close()
      end
      dap.listeners.before.event_exited['dapui_config'] = function()
        dapui.close()
      end

      -- Prefer CodeLLDB (best experience on macOS). Fall back to lldb-dap if needed.
      local mason_data = vim.fn.stdpath 'data'
      local codelldb_adapter = mason_data .. '/mason/packages/codelldb/extension/adapter/codelldb'
      local lldb_dap_mason = mason_data .. '/mason/bin/lldb-dap'
      local lldb_dap_homebrew = '/opt/homebrew/opt/llvm/bin/lldb-dap'

      if vim.fn.executable(codelldb_adapter) == 1 then
        -- CodeLLDB runs as a server; nvim-dap spawns it and connects via a chosen port.
        dap.adapters.codelldb = {
          type = 'server',
          port = '${port}',
          executable = {
            command = codelldb_adapter,
            args = { '--port', '${port}' },
          },
        }
      else
        -- Fallback: use lldb-dap (DAP provided by LLVM).
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
        -- Your build script produces build/main
        return vim.fn.getcwd() .. '/build/main'
      end

      local function split_args(s)
        if s == nil or s == '' then
          return {}
        end
        return vim.split(s, '%s+')
      end

      -- If CodeLLDB is available, prefer it; otherwise use the lldb-dap adapter.
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

      -- Julia: registers dap.adapters.julia + dap.configurations.julia.
      pcall(function()
        require('nvim-dap-julia').setup()
      end)

      -- Keymaps
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
  },

  { -- Autocompletion
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      -- Adds other completion capabilities.
      --  nvim-cmp does not ship with all sources by default. They are split
      --  into multiple repos for maintenance purposes.
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
      -- See `:help cmp`
      local cmp = require 'cmp'

      local lsp_completion_enabled = false

      local quiet_sources = {
        { name = 'buffer' },
        { name = 'path' },
      }

      local lsp_sources = {
        {
          name = 'lazydev',
          -- set group index to 0 to skip loading LuaLS completions as lazydev recommends it
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

  -- Highlight todo, notes, etc in comments
  { 'folke/todo-comments.nvim', event = 'VimEnter', dependencies = { 'nvim-lua/plenary.nvim' }, opts = { signs = false } },

  { -- Collection of various small independent plugins/modules
    'echasnovski/mini.nvim',
    config = function()
      -- Better Around/Inside textobjects
      --
      -- Examples:
      --  - va)  - [V]isually select [A]round [)]paren
      --  - yinq - [Y]ank [I]nside [N]ext [Q]uote
      --  - ci'  - [C]hange [I]nside [']quote
      require('mini.ai').setup { n_lines = 500 }

      -- Add/delete/replace surroundings (brackets, quotes, etc.)
      --
      -- - saiw) - [S]urround [A]dd [I]nner [W]ord [)]Paren
      -- - sd'   - [S]urround [D]elete [']quotes
      -- - sr)'  - [S]urround [R]eplace [)] [']
      require('mini.surround').setup()

      -- Simple and easy statusline.
      --  You could remove this setup call if you don't like it,
      --  and try some other statusline plugin
      local statusline = require 'mini.statusline'
      -- set use_icons to true if you have a Nerd Font
      statusline.setup { use_icons = vim.g.have_nerd_font }

      -- You can configure sections in the statusline by overriding their
      -- default behavior. For example, here we set the section for
      -- cursor location to LINE:COLUMN
      ---@diagnostic disable-next-line: duplicate-set-field
      statusline.section_location = function()
        return '%2l:%-2v'
      end

      -- ... and there is more!
      --  Check out: https://github.com/echasnovski/mini.nvim
    end,
  },
  { -- VSCode-like sticky scope header (Tree-sitter context)
    'nvim-treesitter/nvim-treesitter-context',
    ft = { 'c', 'cpp', 'cuda' },
    main = 'treesitter-context',
    opts = {
      enable = true,
      max_lines = 1, -- keep only the top-most scope line
      trim_scope = 'outer',
      mode = 'topline', -- show context at the very top of the window
      separator = nil,
      zindex = 20,
      on_attach = function(bufnr)
        local ft = vim.bo[bufnr].filetype
        return ft == 'c' or ft == 'cpp' or ft == 'cuda'
      end,
    },
  },
  { -- Treesitter (keep parser features; suppress highlights for C/C++)
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    main = 'nvim-treesitter.configs',
    opts = {
      ensure_installed = { 'bash', 'c', 'cpp', 'cuda', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
      auto_install = true,
      highlight = {
        enable = true,
        -- Disable TS highlighting only for C/C++/CUDA
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

      -- Highlight the enclosing `{ ... }` braces for the current cursor position (C/C++ only).
      -- This is independent of syntax/LSP highlighting and relies only on Tree-sitter parsing.
      local brace_ns = vim.api.nvim_create_namespace 'ds_enclosing_brace'

      -- Define a dedicated highlight group (link to an existing visible group; no hardcoded colors).
      vim.api.nvim_set_hl(0, 'EnclosingBrace', { link = 'MatchParen' })
      vim.api.nvim_set_hl(0, 'InnerDelimiter', { link = 'DiagnosticInfo' })

      ---Find the nearest enclosing node that represents a braced block.
      ---@param node userdata
      ---@return userdata|nil
      local function find_enclosing_brace_node(node)
        while node do
          local t = node:type()
          -- Common braced constructs in C/C++ Tree-sitter grammars
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

      ---Search forward from a (row,col) for the next '{' within a limited window.
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

      ---Search backward from a (row,col) for the previous '}' within a limited window.
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

      ---Update enclosing brace highlight for one buffer.
      local function update_enclosing_braces(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        local ft = vim.bo[bufnr].filetype
        if ft ~= 'c' and ft ~= 'cpp' and ft ~= 'cuda' then
          return
        end

        -- Clear previous marks
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

        -- Heuristic: braces are very close to the node boundaries. Search a small window.
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

        -- Highlight all inner delimiters within the current scope in blue.
        -- This intentionally does not highlight anything outside of the current `{ ... }`.
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

      -- Keep it responsive: update on movement and edits.
      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, {
        group = vim.api.nvim_create_augroup('ds-enclosing-brace', { clear = true }),
        callback = function(ev)
          update_enclosing_braces(ev.buf)
        end,
      })

      -- C/C++/CUDA: keep classic syntax, but neutralize almost all groups except strings.
      vim.api.nvim_create_autocmd('FileType', {
        pattern = { 'c', 'cpp', 'cuda' },
        callback = function(ev)
          -- Reset filetype syntax definitions, then re-enable.
          vim.cmd 'syntax clear'
          vim.cmd 'syntax on'

          local function link(group, target)
            pcall(vim.api.nvim_set_hl, 0, group, { link = target })
          end

          -- Flatten common highlight groups
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

          -- Flatten common C/C++-specific syntax groups (these often carry most of the coloring)
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

          -- Flatten Neovim LSP semantic highlight groups (these are what typically color std::, namespaces, variables, args, etc.)
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

          -- Also flatten legacy LSP highlight groups if present
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

          -- Keep strings (and chars) highlighted
          link('String', 'String')
          link('Character', 'String')

          -- Keep comments gray (use Krypton italic)
          vim.api.nvim_set_hl(0, 'Comment', { fg = '#6b7280', italic = true })

          -- Ensure preprocessor-disabled blocks are dimmed
          vim.api.nvim_set_hl(0, 'PreProc', { fg = '#6b7280' })
          vim.api.nvim_set_hl(0, 'cppPreCondit', { fg = '#6b7280' })
          vim.api.nvim_set_hl(0, 'cPreCondit', { fg = '#6b7280' })

          -- Treesitter inactive regions (best-effort across grammars)
          for _, g in ipairs {
            '@comment',
            '@preproc',
            '@conditional',
            '@conditional.inactive',
          } do
            pcall(vim.api.nvim_set_hl, 0, g, { fg = '#6b7280' })
          end

          -- CUDA: the C++ around it stays monochrome, but re-assert color on
          -- the CUDA-specific constructs so they stand out.
          if ev.match == 'cuda' then
            -- __device__ / __host__ / __global__ / ... and __CUDA_ARCH__ etc.
            vim.api.nvim_set_hl(0, 'cudaStorageClass', { fg = '#9ece6a', bold = true })
            vim.api.nvim_set_hl(0, 'cudaConstant', { fg = '#9ece6a', bold = true })
            -- dim3, vector types, cudaError_t, ...
            vim.api.nvim_set_hl(0, 'cudaType', { fg = '#7dcfff' })
            -- gridDim, blockIdx, blockDim, threadIdx, warpSize
            vim.api.nvim_set_hl(0, 'cudaVariable', { fg = '#ff9e64' })
            -- kernel launch: the <<< >>> brackets and the launch config inside
            vim.api.nvim_set_hl(0, 'cudaKernelBrackets', { fg = '#bb9af7', bold = true })
            vim.api.nvim_set_hl(0, 'cudaKernelConfig', { fg = '#e0af68' })
            vim.api.nvim_set_hl(0, 'cudaDunder', { link = 'cudaStorageClass' })

            -- Catch any __identifier__ the bundled syntax misses.
            vim.cmd [[syntax match cudaDunder /\<__\w\+__\>/]]
            -- Kernel launch config: <<< grid, block, sharedMem, stream >>>
            vim.cmd [[syntax region cudaKernelConfig matchgroup=cudaKernelBrackets start=/<<</ end=/>>>/ oneline keepend contains=NONE]]
          end
        end,
      })
    end,
  },

  -- The following comments only work if you have downloaded the kickstart repo, not just copy pasted the
  -- init.lua. If you want these files, they are in the repository, sotyou can just download them and
  -- place them in the correct locations.

  -- NOTE: Next step on your Neovim journey: Add/Configure additional plugins for Kickstart
  --
  --  Here are some example plugins that I've included in the Kickstart repository.
  --  Uncomment any of the lines below to enable them (you will need to restart nvim).
  --
  -- require 'kickstart.plugins.debug',
  -- require 'kickstart.plugins.indent_line',
  -- require 'kickstart.plugins.lint',
  -- require 'kickstart.plugins.autopairs',
  -- require 'kickstart.plugins.neo-tree',
  -- require 'kickstart.plugins.gitsigns', -- adds gitsigns recommend keymaps

  -- NOTE: The import below can automatically add your own plugins, configuration, etc from `lua/custom/plugins/*.lua`
  --    This is the easiest way to modularize your config.
  --
  --  Uncomment the following line and add your plugins to `lua/custom/plugins/*.lua` to get going.
  { import = 'custom.plugins' },
  --
  -- For additional information with loading, sourcing and examples see `:help lazy.nvim-🔌-plugin-spec`
  -- Or use telescope!
  -- In normal mode type `<space>sh` then write `lazy.nvim-plugin`
  -- you can continue same window with `<space>sr` which resumes last telescope search
}, {
  ui = {
    -- If you are using a Nerd Font: set icons to an empty table which will use the
    -- default lazy.nvim defined Nerd Font icons, otherwise define a unicode icons table
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
})

require('custom.julia_scope').setup()

require('custom.julia_progress').setup()

-- Load VSCode-style snippet collections (friendly-snippets)
pcall(function()
  require('luasnip.loaders.from_vscode').lazy_load()
end)

-- Custom snippets
pcall(function()
  local ls = require 'luasnip'
  local s = ls.snippet
  local t = ls.text_node
  local i = ls.insert_node
  local rep = require('luasnip.extras').rep

  ls.config.setup { enable_autosnippets = true }

  ls.add_snippets('all', {
    -- Type `$//` to expand to a C-style block comment with the cursor inside.
    s({ trig = '$//', wordTrig = false, snippetType = 'autosnippet' }, {
      t '/* ',
      i(0),
      t ' */',
    }),
  })

  ls.add_snippets('cpp', {
    -- Class skeleton (rule of zero: prefer this when possible)
    s('dsk_class0', {
      t 'class ',
      i(1, 'MyClass'),
      t { ' {', 'public:', '\t' },
      i(0),
      t { '', '};' },
    }),

    -- Class skeleton (rule of three: copyable)
    s('dsk_class3', {
      t 'class ',
      i(1, 'MyClass'),
      t { ' {', 'public:', '\t' },
      rep(1),
      t '() = default;',
      t { '', '\t~' },
      rep(1),
      t '() = default;',
      t { '', '\t' },
      rep(1),
      t '(',
      t 'const ',
      rep(1),
      t '&) = default;',
      t { '', '\t' },
      rep(1),
      t '& operator=(',
      t 'const ',
      rep(1),
      t '&) = default;',
      t { '', '', 'private:', '\t' },
      i(0),
      t { '', '};' },
    }),

    -- Class skeleton (rule of five: movable + copyable)
    s('dsk_class5', {
      t 'class ',
      i(1, 'MyClass'),
      t { ' {', 'public:', '\t' },
      rep(1),
      t '() = default;',
      t { '', '\t~' },
      rep(1),
      t '() = default;',
      t { '', '\t' },
      rep(1),
      t '(',
      t 'const ',
      rep(1),
      t '&) = default;',
      t { '', '\t' },
      rep(1),
      t '& operator=(',
      t 'const ',
      rep(1),
      t '&) = default;',
      t { '', '\t' },
      rep(1),
      t '(',
      rep(1),
      t '&&) noexcept = default;',
      t { '', '\t' },
      rep(1),
      t '& operator=(',
      rep(1),
      t '&&) noexcept = default;',
      t { '', '', 'private:', '\t' },
      i(0),
      t { '', '};' },
    }),

    -- Indexed range loop over container
    s('dsk_irange', {
      t 'for(usize i{0zu}; i < ',
      i(1, 'vec'),
      t { '.size(); ++i) {', '' },
      t { '', '}' },
    }),

    -- Indexed range loop over container (j index)
    s('dsk_jrange', {
      t 'for(usize j{0zu}; j < ',
      i(1, 'vec'),
      t { '.size(); ++j) {', '' },
      t { '', '}' },
    }),

    -- Indexed range loop over container (k index)
    s('dsk_krange', {
      t 'for(usize k{0zu}; k < ',
      i(1, 'vec'),
      t { '.size(); ++k) {', '' },
      t { '', '}' },
    }),

    -- Range-based loop by reference
    s('dsk_forx', {
      t 'for(auto& ',
      i(1, 'x'),
      t ' : ',
      i(2, 'container'),
      t { ') {', '' },
      t '\t',
      i(0),
      t { '', '}' },
    }),

    -- Plain println
    s('dsk_println', {
      t 'std::println("{}", ',
      i(1, 'value'),
      t ');',
    }),

    -- println with name=value formatting (single identifier)
    s('dsk_printx', {
      t 'std::println("',
      i(1, 'x'),
      t '={}", ',
      rep(1),
      t ');',
    }),

    -- std::vector<int> with 5 elements
    s('dsk_vec5i', {
      t 'std::vector<int> ',
      i(1, 'v'),
      t '{',
      i(2, 'a'),
      t ', ',
      i(3, 'b'),
      t ', ',
      i(4, 'c'),
      t ', ',
      i(5, 'd'),
      t ', ',
      i(6, 'e'),
      t '}',
    }),

    -- CUDA kernel launch: kernel<<<grid, block, sharedMem, stream>>>(args);
    s('dsk_cudalaunch', {
      i(1, 'kernel'),
      t '<<<',
      i(2, 'grid'),
      t ', ',
      i(3, 'block'),
      t ', ',
      i(4, '0'),
      t ', ',
      i(5, 'stream'),
      t '>>>(',
      i(0, 'args'),
      t ');',
    }),
  })
end)

-- Tabs become 4 spaces
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'cpp', 'c', 'h', 'hpp' },
  callback = function()
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.expandtab = true
  end,
})

-- Experimental: hide leading `const` noise in C/C++ buffers without changing files.
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'cpp', 'c', 'h', 'hpp' },
  callback = function()
    vim.opt_local.conceallevel = 2
    vim.opt_local.concealcursor = 'nc'
    vim.fn.matchadd('Conceal', [[^\s*\zsconst\>\s*]], 10, -1, { conceal = '' })
    vim.fn.matchadd('Conceal', [[\<dans_]], 10, -1, { conceal = '' })
  end,
})

-- Note: clang-tidy diagnostics are provided by clangd (with --clang-tidy).
-- Configure project-wide checks in a .clang-tidy file at the repository root.
-- Plain C buffers (filetype == 'c') strip clang-tidy diagnostics via a
-- publishDiagnostics handler override on the clangd client; .h files detected
-- as C are excluded too. C++ buffers (cpp) are unaffected.
