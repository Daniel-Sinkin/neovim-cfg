-- Export the function under the cursor into a hermetic debug playground.
--
-- :DansDebugFn  grabs the enclosing function via treesitter, resolves each
-- signature type's definition location via clangd, and writes
-- _debug/<name>_playground.cpp containing:
--   * a real build command (with this file's include flags)
--   * a stub for every non-builtin signature type, annotated with file:line
--   * the copied function body
--   * a main() skeleton with an arg-entry placeholder
-- then opens it. You fill the stubs (or copy/monkeypatch the real definitions),
-- set the inputs, build with the command at the top, and debug with F5.
--
-- Deliberately NO external #includes (only dans core markers/types) — these
-- functions work best on POD operations; pulling the dependency graph in
-- defeats the point. Body-local types aren't auto-stubbed; add them when a
-- stub-miss fails to compile.

local M = {}

-- Built-in / alias type names that need no stub. The dans aliases come from
-- <dans/types.hpp>, which the playground includes.
local DANS_ALIASES = {
  u8 = true,
  u16 = true,
  u32 = true,
  u64 = true,
  i8 = true,
  i16 = true,
  i32 = true,
  i64 = true,
  usize = true,
  isize = true,
  uptr = true,
  iptr = true,
  f32 = true,
  f64 = true,
  byte = true,
}

local function enclosing_function(bufnr)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
  if not ok or not node then
    return nil
  end
  while node and node:type() ~= 'function_definition' do
    node = node:parent()
  end
  return node
end

local function find_declarator(func)
  local decl = func:field('declarator')[1]
  if not decl then
    return nil
  end
  if decl:type() == 'function_declarator' then
    return decl
  end
  for c in decl:iter_children() do
    if c:type() == 'function_declarator' then
      return c
    end
  end
  return nil
end

-- The function's name (for the file name + main call).
local function function_name(fdecl, bufnr)
  local id = fdecl:field('declarator')[1]
  if id then
    return vim.treesitter.get_node_text(id, bufnr)
  end
  return 'fn'
end

-- Signature param type nodes (the `type` field of each parameter_declaration).
local function param_type_nodes(fdecl)
  local params = fdecl:field('parameters')[1]
  local out = {}
  if not params then
    return out
  end
  for p in params:iter_children() do
    local t = p:type()
    if t == 'parameter_declaration' or t == 'optional_parameter_declaration' then
      local tn = p:field('type')[1]
      if tn then
        out[#out + 1] = tn
      end
    end
  end
  return out
end

local function loc_from_results(results)
  for _, r in pairs(results or {}) do
    local res = r.result
    if res then
      local item = res[1] or res
      if item then
        local uri = item.uri or item.targetUri
        local range = item.range or item.targetRange
        if uri and range then
          return vim.uri_to_fname(uri), range.start.line + 1
        end
      end
    end
  end
  return nil
end

-- Include flags (-I / -isystem) from the file's compile_commands entry, for the
-- build command printed at the top of the playground.
local function include_flags(file)
  local db = vim.fs.find({ 'compile_commands.json' }, { path = vim.fs.dirname(file), upward = true, limit = 1 })[1]
  if not db then
    for parent in vim.fs.parents(file) do
      local cand = parent .. '/build/compile_commands.json'
      if vim.uv.fs_stat(cand) then
        db = cand
        break
      end
    end
  end
  if not db then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(db), '\n'))
  if not ok then
    return {}
  end
  for _, e in ipairs(data) do
    if e.file and vim.fs.normalize(e.file) == vim.fs.normalize(file) then
      local args = e.arguments or vim.split(e.command or '', '%s+', { trimempty = true })
      local flags = {}
      local take = false
      for _, a in ipairs(args) do
        if take then
          flags[#flags + 1] = '-isystem ' .. a
          take = false
        elseif a == '-isystem' then
          take = true
        elseif a:match '^%-I' then
          flags[#flags + 1] = a
        end
      end
      return flags
    end
  end
  return {}
end

local function generate(bufnr, ctx)
  local name = ctx.name
  local rel = vim.fn.fnamemodify(ctx.file, ':.')
  local out = {}
  local function add(s)
    out[#out + 1] = s or ''
  end

  local playground = vim.fn.getcwd() .. '/_debug/' .. name .. '_playground.cpp'
  add('// Debug playground for `' .. name .. '`, exported from ' .. rel .. ':' .. ctx.line)
  add('//')
  add('// Build & debug:')
  add(
    '//   clang++ -std=c++23 -g -O0 '
      .. table.concat(ctx.flags, ' ')
      .. ' '
      .. vim.fn.fnamemodify(playground, ':.')
      .. ' -o _debug/'
      .. name
  )
  add('//   then set a breakpoint in main and run it under the debugger (F5)')
  add('//')
  add '#include <dans/development_markers.hpp>'
  add '#include <dans/types.hpp>'
  add '#include <print>'
  add ''

  if #ctx.stubs > 0 then
    add '// ---- type stubs: fill in, copy the real definition, or monkeypatch ----'
    for _, s in ipairs(ctx.stubs) do
      add('// ' .. s.name .. '  —  ' .. s.where)
      add('struct ' .. s.name)
      add '{'
      add '};'
      add ''
    end
  end
  if #ctx.todo > 0 then
    add '// ---- types needing manual handling (qualified/templated/std) ----'
    for _, t in ipairs(ctx.todo) do
      add('// TODO: ' .. t)
    end
    add ''
  end

  add '// ---- function under test ----'
  for _, l in ipairs(vim.split(ctx.text, '\n', { plain = true })) do
    add(l)
  end
  add ''
  add 'int main()'
  add '{'
  add('    // TODO: provide inputs and call ' .. name .. '(...). Breakpoint here, step in.')
  add('    // const auto result = ' .. name .. '(/* ... */);')
  add '    return 0;'
  add '}'

  vim.fn.mkdir(vim.fn.getcwd() .. '/_debug', 'p')
  vim.fn.writefile(out, playground)
  vim.cmd('edit ' .. vim.fn.fnameescape(playground))
  vim.notify('dans_debug_fn: exported ' .. name .. ' -> ' .. vim.fn.fnamemodify(playground, ':.'), vim.log.levels.INFO)
end

function M.export()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  local func = enclosing_function(bufnr)
  if not func then
    vim.notify('dans_debug_fn: no function under cursor', vim.log.levels.WARN)
    return
  end
  local fdecl = find_declarator(func)
  if not fdecl then
    vim.notify('dans_debug_fn: could not parse function declarator', vim.log.levels.WARN)
    return
  end

  local ctx = {
    file = file,
    line = func:start() + 1,
    name = function_name(fdecl, bufnr),
    text = vim.treesitter.get_node_text(func, bufnr),
    flags = include_flags(file),
    stubs = {},
    todo = {},
  }

  -- Collect distinct types from the signature.
  local seen = {}
  local to_resolve = {} -- { text, row, col }
  for _, tn in ipairs(param_type_nodes(fdecl)) do
    local kind = tn:type()
    local text = vim.treesitter.get_node_text(tn, bufnr)
    if not seen[text] then
      seen[text] = true
      if kind == 'primitive_type' or DANS_ALIASES[text] then
        -- no stub
      elseif kind == 'type_identifier' then
        local sr, sc = tn:start()
        to_resolve[#to_resolve + 1] = { name = text, row = sr, col = sc }
      else
        -- qualified_identifier / template_type / std:: / etc.
        ctx.todo[#ctx.todo + 1] = text
      end
    end
  end

  local clients = vim.lsp.get_clients { bufnr = bufnr, method = 'textDocument/definition' }
  if #to_resolve == 0 or #clients == 0 then
    -- No types to resolve, or no LSP to resolve them: stub without locations.
    for _, ty in ipairs(to_resolve) do
      ctx.stubs[#ctx.stubs + 1] = { name = ty.name, where = 'definition unresolved (no clangd?)  (fill in)' }
    end
    generate(bufnr, ctx)
    return
  end

  local pending = #to_resolve
  for _, ty in ipairs(to_resolve) do
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = ty.row, character = ty.col },
    }
    vim.lsp.buf_request_all(bufnr, 'textDocument/definition', params, function(results)
      local where
      local f, ln = loc_from_results(results)
      if f then
        where = 'defined at ' .. vim.fn.fnamemodify(f, ':.') .. ':' .. ln .. '  (fill in or copy)'
      else
        where = 'definition not found by clangd  (fill in)'
      end
      ctx.stubs[#ctx.stubs + 1] = { name = ty.name, where = where }
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          generate(bufnr, ctx)
        end)
      end
    end)
  end
end

function M.setup()
  vim.api.nvim_create_user_command('DansDebugFn', M.export, { desc = 'Export function under cursor to a debug playground' })
end

return M
