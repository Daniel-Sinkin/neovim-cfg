-- Small critter that wanders across the current buffer (cosmetic only).
-- :DuckHatch spawns one, :DuckCook removes the nearest one.
return {
  'tamton-aquib/duck.nvim',
  keys = {
    {
      '<leader>tp',
      function()
        require('duck').hatch('🐢', 25)
      end,
      desc = '[T]oggle [P]et (hatch turtle)',
    },
    {
      '<leader>tP',
      function()
        require('duck').cook_all()
      end,
      desc = '[T]oggle [P]et (cook all)',
    },
  },
}
