-- Tokyo Night. termguicolors is enabled here (depends on the colorscheme
-- being loaded, so kept with the plugin instead of in config/options.lua).
return {
  'folke/tokyonight.nvim',
  lazy = false,
  priority = 1000,
  opts = { style = 'night' },
  config = function(_, opts)
    vim.opt.termguicolors = true
    require('tokyonight').setup(opts)
    vim.cmd.colorscheme 'tokyonight'
  end,
}
