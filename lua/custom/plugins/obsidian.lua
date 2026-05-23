-- Obsidian integration. <leader>o* keys; vault path under ~/GitHub_private.
return {
  'epwalsh/obsidian.nvim',
  version = '*',
  lazy = true,
  ft = 'markdown',
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
  opts = {
    workspaces = {
      {
        name = 'thesis',
        path = '~/GitHub_private/Master-Thesis/notes',
      },
    },

    note_id_func = function(title)
      if title ~= nil then
        return title:gsub(' ', '-'):gsub('[^A-Za-z0-9-]', ''):lower()
      else
        local suffix = ''
        for _ = 1, 4 do
          suffix = suffix .. string.char(math.random(65, 90))
        end
        return tostring(os.time()) .. '-' .. suffix
      end
    end,

    disable_frontmatter = false,

    completion = {
      nvim_cmp = true,
      min_chars = 2,
    },

    ui = {
      enable = true,
      checkboxes = {
        [' '] = { char = '☐', hl_group = 'ObsidianTodo' },
        ['x'] = { char = '✔', hl_group = 'ObsidianDone' },
      },
    },

    new_notes_location = 'current_dir',

    mappings = {
      ['gf'] = {
        action = function()
          return require('obsidian').util.gf_passthrough()
        end,
        opts = { noremap = false, expr = true, buffer = true },
      },
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
}
