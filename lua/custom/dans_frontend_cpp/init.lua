-- dans-cpp-frontend: a view-only re-render of C/C++/CUDA in an Odin/Pascal-like
-- style -- const hidden, mut/cpy surfaced, `T*` -> `T^`, `optional<T>` -> `T?`,
-- declarations shown as `name: T = value`, and so on. Nothing in the buffer is
-- modified; it is all conceal + virt_text.
--
-- This is the umbrella. Each feature lives in its own module under
-- custom.dans_frontend_cpp.* with its own autocmds and `ds_*` namespace, so it
-- can be read and changed in isolation. setup() wires them up and owns the
-- :DansFrontend command.
--
--   :DansFrontend           toggle the declaration overlay for the buffer
--   :DansFrontend hints     toggle clangd deduced-type hints
--   :DansFrontend lambda    toggle the lambda-as-function rendering
local M = {}

-- Preserve the original setup order (aliases before the view, decorations
-- after) so nothing ordering-dependent shifts during the move.
local SETUP_ORDER = { 'aliases', 'markers', 'view', 'arrow_align', 'pointer', 'designated', 'fold' }

local function view()
  return require 'custom.dans_frontend_cpp.view'
end

local function dispatch(cmd)
  local sub = vim.trim(cmd.args or '')
  if sub == '' then
    view().toggle()
  elseif sub == 'hints' then
    view().toggle_hints()
  elseif sub == 'lambda' then
    view().toggle_lambda()
  else
    vim.notify('DansFrontend: unknown argument "' .. sub .. '" (try hints / lambda)', vim.log.levels.WARN)
  end
end

function M.setup()
  for _, name in ipairs(SETUP_ORDER) do
    require('custom.dans_frontend_cpp.' .. name).setup()
  end
  vim.api.nvim_create_user_command('DansFrontend', dispatch, {
    nargs = '?',
    complete = function()
      return { 'hints', 'lambda' }
    end,
    desc = 'Toggle the dans-cpp-frontend view, or its hints / lambda sub-features',
  })
end

return M
