-- Live WPM counter shown as virtual text on the current line.
return {
  'JohnnyJumper/neotypist.nvim',
  event = 'InsertEnter',
  opts = {
    notify = false,
    show_virt_text = true,
    virt_text = function(wpm)
      return ('WPM: %.0f'):format(wpm)
    end,
    virt_text_pos = 'right_align',
  },
}
