-- dans-cpp-frontend: a view-only re-render of C/C++/CUDA in an Odin/Pascal-like
-- style -- const hidden, mut/cpy surfaced, `T*` -> `T^`, `optional<T>` -> `T?`,
-- declarations shown as `name: T = value`, and so on. Nothing in the buffer is
-- modified; it is all conceal + virt_text.
--
-- This is the umbrella. Each feature lives in its own module under
-- custom.dans_frontend_cpp.* with its own autocmds and `ds_*` namespace, so it
-- can be read, changed, and toggled in isolation. setup() wires them up and owns
-- the :DansFrontend command.
--
--   :DansFrontend            toggle the whole frontend for the buffer
--   :DansFrontend <module>   toggle one module (view/aliases/markers/pointer/
--                            designated/fold/arrow_align) -- tab-completed
--   :DansFrontend hints      toggle clangd deduced-type hints
--   :DansFrontend lambda     toggle the lambda-as-function rendering
local M = {}

-- setup() order preserved from the original flat layout (aliases before the
-- view, decorations after) so nothing ordering-dependent shifts.
local SETUP_ORDER = { 'aliases', 'markers', 'view', 'arrow_align', 'enum_align', 'special_members', 'pointer', 'designated', 'logic', 'fold', 'lint' }

-- Modules :DansFrontend can toggle per buffer. 'view' is the declaration overlay
-- (its own enable/disable); the rest are decoration / lint modules gated by
-- util.module_enabled and re-rendered through their M.refresh.
local TOGGLEABLE = { 'view', 'aliases', 'markers', 'pointer', 'designated', 'logic', 'fold', 'arrow_align', 'enum_align', 'special_members', 'lint' }

local function mod(name)
  return require('custom.dans_frontend_cpp.' .. name)
end

local function util()
  return require 'custom.dans_frontend_cpp.util'
end

local function is_on(name, buf)
  if name == 'view' then
    return mod('view').is_enabled(buf)
  end
  return util().module_enabled(buf, name)
end

local function set_on(name, buf, on)
  if name == 'view' then
    mod('view').set_enabled(buf, on)
  else
    util().set_module(buf, name, on)
    mod(name).refresh(buf)
  end
end

local function dispatch(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local sub = vim.trim(cmd.args or '')
  if sub == 'hints' then
    mod('view').toggle_hints()
  elseif sub == 'lambda' then
    mod('view').toggle_lambda()
  elseif sub == '' then
    -- master: if anything is on, turn everything off; otherwise turn it all on.
    local any = false
    for _, n in ipairs(TOGGLEABLE) do
      if is_on(n, buf) then
        any = true
        break
      end
    end
    for _, n in ipairs(TOGGLEABLE) do
      set_on(n, buf, not any)
    end
    vim.notify('dans-cpp-frontend ' .. (any and 'off' or 'on'), vim.log.levels.INFO)
  elseif vim.tbl_contains(TOGGLEABLE, sub) then
    local on = not is_on(sub, buf)
    set_on(sub, buf, on)
    vim.notify('dans-cpp-frontend ' .. sub .. ' ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
  else
    vim.notify('DansFrontend: unknown argument "' .. sub .. '"', vim.log.levels.WARN)
  end
end

local function complete(arglead)
  local opts = vim.list_extend(vim.deepcopy(TOGGLEABLE), { 'hints', 'lambda' })
  return vim.tbl_filter(function(s)
    return s:find(arglead, 1, true) == 1
  end, opts)
end

function M.setup()
  util().setup_viewport_debounce()
  for _, name in ipairs(SETUP_ORDER) do
    require('custom.dans_frontend_cpp.' .. name).setup()
  end
  vim.api.nvim_create_user_command('DansFrontend', dispatch, {
    nargs = '?',
    complete = complete,
    desc = 'Toggle the dans-cpp-frontend view, a single module, or hints / lambda',
  })
end

return M
