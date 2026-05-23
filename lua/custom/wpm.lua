-- Tiny live WPM counter. Shows "WPM: NN" as right-aligned virtual text on the
-- line the cursor is on, while in insert mode. Timer starts on InsertEnter,
-- stops on InsertLeave. The extmark follows the cursor line.

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_wpm'
local state = { timer = nil, start_time = 0, start_words = 0, last_bufnr = nil }

local update_ms = 300

local function clear_mark()
  if state.last_bufnr and vim.api.nvim_buf_is_valid(state.last_bufnr) then
    vim.api.nvim_buf_clear_namespace(state.last_bufnr, ns, 0, -1)
  end
end

local function render()
  local now = (vim.uv or vim.loop).now()
  local dt = (now - state.start_time) / 1000
  if dt <= 0.5 then
    return
  end

  local words = vim.fn.wordcount().words
  local typed = words - state.start_words
  if typed < 0 then
    typed = 0
  end
  local wpm = typed / (dt / 60)

  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1

  clear_mark()
  state.last_bufnr = bufnr

  vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
    virt_text = { { ('WPM: %.0f'):format(wpm), 'Comment' } },
    virt_text_pos = 'right_align',
  })
end

local function start()
  if state.timer then
    return
  end
  state.start_time = (vim.uv or vim.loop).now()
  state.start_words = vim.fn.wordcount().words
  state.timer = (vim.uv or vim.loop).new_timer()
  state.timer:start(0, update_ms, vim.schedule_wrap(render))
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  clear_mark()
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ds_wpm', { clear = true })
  vim.api.nvim_create_autocmd('InsertEnter', { group = group, callback = start })
  vim.api.nvim_create_autocmd('InsertLeave', { group = group, callback = stop })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = stop })
end

return M
