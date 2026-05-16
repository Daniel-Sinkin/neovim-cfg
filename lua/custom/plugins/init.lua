-- Custom plugins for Kickstart.nvim
return {
  { -- Obsidian integration for Neovim
    'epwalsh/obsidian.nvim',
    version = '*', -- use latest release instead of latest commit
    lazy = true,
    ft = 'markdown',
    dependencies = {
      'nvim-lua/plenary.nvim', -- required
    },
    opts = {
      workspaces = {
        {
          name = 'thesis',
          path = '~/GitHub_private/Master-Thesis/notes',
        },
        -- Add more vaults here if needed:
        -- {
        --   name = 'personal',
        --   path = '~/Documents/PersonalVault',
        -- },
      },

      -- Optional: customize how note IDs are generated
      note_id_func = function(title)
        if title ~= nil then
          -- Use the title as-is, replacing spaces with hyphens
          return title:gsub(' ', '-'):gsub('[^A-Za-z0-9-]', ''):lower()
        else
          -- If no title, generate a 4-char random id
          local suffix = ''
          for _ = 1, 4 do
            suffix = suffix .. string.char(math.random(65, 90))
          end
          return tostring(os.time()) .. '-' .. suffix
        end
      end,

      -- Don't manage frontmatter (set to true if you want obsidian.nvim to handle YAML)
      disable_frontmatter = false,

      -- Completion of wiki links, tags, etc. via nvim-cmp
      completion = {
        nvim_cmp = true,
        min_chars = 2,
      },

      -- UI: render markdown checkboxes and references nicely
      ui = {
        enable = true,
        checkboxes = {
          [' '] = { char = '☐', hl_group = 'ObsidianTodo' },
          ['x'] = { char = '✔', hl_group = 'ObsidianDone' },
        },
      },

      -- Where new notes go by default
      new_notes_location = 'current_dir',

      -- Key mappings under <leader>o for Obsidian commands
      mappings = {
        -- Follow a link (Enter on a [[wiki link]])
        ['gf'] = {
          action = function()
            return require('obsidian').util.gf_passthrough()
          end,
          opts = { noremap = false, expr = true, buffer = true },
        },
        -- Toggle checkbox
        ['<leader>oc'] = {
          action = function()
            return require('obsidian').util.toggle_checkbox()
          end,
          opts = { buffer = true },
        },
      },
    },
    keys = {
      { '<leader>on', '<cmd>ObsidianNew<CR>', desc = 'Obsidian: New note' },
      { '<leader>oo', '<cmd>ObsidianOpen<CR>', desc = 'Obsidian: Open in app' },
      { '<leader>os', '<cmd>ObsidianSearch<CR>', desc = 'Obsidian: Search notes' },
      { '<leader>oq', '<cmd>ObsidianQuickSwitch<CR>', desc = 'Obsidian: Quick switch' },
      { '<leader>ob', '<cmd>ObsidianBacklinks<CR>', desc = 'Obsidian: Backlinks' },
      { '<leader>ot', '<cmd>ObsidianTags<CR>', desc = 'Obsidian: Tags' },
      { '<leader>ol', '<cmd>ObsidianLinks<CR>', desc = 'Obsidian: Links' },
      { '<leader>od', '<cmd>ObsidianToday<CR>', desc = 'Obsidian: Daily note' },
    },
  },
}
