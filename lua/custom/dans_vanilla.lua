-- Vanilla mode: a global toggle (dans menu) that drops every custom display
-- adjustment and shows the stock tokyonight theme. While on:
--   * the monochrome flatten no-ops (treesitter.lua checks vim.g.dans_vanilla),
--     so re-picking the colorscheme restores tokyonight's real colors;
--   * treesitter highlighting is turned back on for c/cpp/cuda (its `disable`
--     predicate also checks the flag), giving the normal treesitter palette;
--   * the dans-cpp-frontend overlay is switched off per buffer (and restored to
--     exactly what was on when vanilla turns back off).

local M = {}

local function is_cpp(buf)
  local ft = vim.bo[buf].filetype
  return ft == 'c' or ft == 'cpp' or ft == 'cuda'
end

local function frontend()
  local ok, fe = pcall(require, 'custom.dans_frontend_cpp')
  return ok and fe or nil
end

-- buf -> { module_name = was_on } captured when the overlay was switched off.
local saved = {}
local aug = nil

local function frontend_off(buf)
  local fe = frontend()
  if not fe or saved[buf] then return end
  local s = {}
  for _, name in ipairs(fe.TOGGLEABLE) do
    local on = fe.module_is_on(name, buf)
    s[name] = on
    if on then pcall(fe.module_set, name, buf, false) end
  end
  saved[buf] = s
end

local function frontend_restore(buf)
  local fe = frontend()
  local s = saved[buf]
  if fe and s and vim.api.nvim_buf_is_valid(buf) then
    for name, was_on in pairs(s) do
      if was_on then pcall(fe.module_set, name, buf, true) end
    end
  end
  saved[buf] = nil
end

local function apply(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and is_cpp(buf)) then return end
  frontend_off(buf)
  pcall(vim.treesitter.start, buf)
end

local function repick_colorscheme()
  local name = vim.g.colors_name
  if name and name ~= '' then pcall(vim.cmd.colorscheme, name) end
end

function M.is_enabled()
  return vim.g.dans_vanilla == true
end

function M.enable()
  if M.is_enabled() then return end
  vim.g.dans_vanilla = true
  repick_colorscheme() -- flatten now no-ops; tokyonight colors come back
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then apply(buf) end
  end
  aug = vim.api.nvim_create_augroup('ds_vanilla', { clear = true })
  vim.api.nvim_create_autocmd({ 'FileType', 'BufWinEnter' }, {
    group = aug,
    callback = function(ev)
      if M.is_enabled() then apply(ev.buf) end
    end,
  })
  vim.notify('dans vanilla theme on', vim.log.levels.INFO)
end

function M.disable()
  if not M.is_enabled() then return end
  vim.g.dans_vanilla = false
  if aug then
    pcall(vim.api.nvim_del_augroup_by_id, aug)
    aug = nil
  end
  for buf in pairs(saved) do
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.treesitter.stop, buf) end
    frontend_restore(buf)
  end
  saved = {}
  repick_colorscheme() -- flatten re-applies (deferred), monochrome returns
  vim.notify('dans vanilla theme off', vim.log.levels.INFO)
end

function M.toggle()
  if M.is_enabled() then
    M.disable()
  else
    M.enable()
  end
end

return M
