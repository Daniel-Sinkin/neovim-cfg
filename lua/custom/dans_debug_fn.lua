-- Export the function under the cursor into a hermetic debug playground.
--
-- :DansDebugFn grabs the enclosing function (treesitter), crawls it for every
-- referenced user type (signature AND body) and called function (one level
-- deep), resolves each via clangd `definition`, and writes
-- _debug/<name>_playground.cpp:
--   * a real build command (this file's include flags)
--   * everything wrapped in `namespace dans` so the dans aliases resolve free
--   * each referenced definition that lives in YOUR source (not vendor/system)
--     COPIED VERBATIM, in source order, so it actually compiles
--   * `// TODO:` notes for library/std definitions (include or stub yourself)
--   * the copied function under test
--   * a trailing `def main() -> int` with a per-parameter call template
-- then opens it.

local M = {}

local DANS_ALIASES = {
  u8 = true, u16 = true, u32 = true, u64 = true,
  i8 = true, i16 = true, i32 = true, i64 = true,
  usize = true, isize = true, uptr = true, iptr = true,
  f32 = true, f64 = true, byte = true,
}

local function is_user_type(kind, text)
  if kind == 'primitive_type' or DANS_ALIASES[text] or text:match '^std::' then
    return false
  end
  if text == 'def' then -- the `auto` marker macro, not a type
    return false
  end
  return kind == 'type_identifier' or kind == 'qualified_identifier'
end

-- A path is "yours" if it's under the project (cwd) and not vendored.
local function is_user_source(path)
  local root = vim.fs.normalize(vim.fn.getcwd())
  local p = vim.fs.normalize(path)
  return vim.startswith(p, root) and not p:find('/vendor/', 1, true)
end

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

local function function_name(fdecl, bufnr)
  local id = fdecl:field('declarator')[1]
  return id and vim.treesitter.get_node_text(id, bufnr) or 'fn'
end

local function param_texts(fdecl, bufnr)
  local plist = fdecl:field('parameters')[1]
  local out = {}
  if plist then
    for p in plist:iter_children() do
      local t = p:type()
      if t == 'parameter_declaration' or t == 'optional_parameter_declaration' then
        out[#out + 1] = vim.treesitter.get_node_text(p, bufnr)
      end
    end
  end
  return out
end

local function collect(node, wanted, acc)
  for child in node:iter_children() do
    if wanted[child:type()] then
      acc[#acc + 1] = child
    end
    collect(child, wanted, acc)
  end
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
          return vim.uri_to_fname(uri), range.start.line
        end
      end
    end
  end
  return nil
end

-- Verbatim text of the definition enclosing (0-indexed) `line` in `path`, plus
-- the line it starts on (for source-order sorting). Climbs to the outermost
-- definition node so templates/enclosing declarations come along whole.
local function definition_text(path, line)
  local content = vim.fn.readfile(path)
  if not content or #content == 0 then
    return nil
  end
  local src = table.concat(content, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'cpp')
  if not ok then
    return nil
  end
  local root = parser:parse()[1]:root()
  local want = {
    struct_specifier = true,
    class_specifier = true,
    enum_specifier = true,
    union_specifier = true,
    alias_declaration = true,
    type_definition = true,
    function_definition = true,
    template_declaration = true,
    declaration = true,
  }
  local node = root:descendant_for_range(line, 0, line, 1000)
  local best
  while node do
    if node:type() == 'translation_unit' then
      break
    end
    if want[node:type()] then
      best = node
    end
    node = node:parent()
  end
  if not best then
    return nil
  end
  return vim.treesitter.get_node_text(best, src), best:start()
end

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
      local flags, take = {}, false
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
  local playground = vim.fn.getcwd() .. '/_debug/' .. name .. '_playground.cpp'
  local out = {}
  local function add(s)
    out[#out + 1] = s or ''
  end

  add('// Debug playground for `' .. name .. '`, exported from ' .. rel .. ':' .. ctx.line)
  add('//')
  add('// Build:')
  add(
    '//   clang++ -std=c++23 -g -O0 '
      .. table.concat(ctx.flags, ' ')
      .. ' '
      .. vim.fn.fnamemodify(playground, ':.')
      .. ' -o _debug/'
      .. name
  )
  add('//')
  add '#include <dans/development_markers.hpp>'
  add '#include <dans/types.hpp>'
  add '#include <print>'
  add ''
  add 'namespace dans'
  add '{'
  add ''

  if #ctx.notes > 0 then
    for _, n in ipairs(ctx.notes) do
      add('// TODO: ' .. n)
    end
    add ''
  end

  -- Copied definitions, in source order so dependencies precede dependents.
  table.sort(ctx.copies, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  for _, c in ipairs(ctx.copies) do
    add('// ' .. c.name .. '  —  copied from ' .. c.where)
    for _, l in ipairs(vim.split(c.text, '\n', { plain = true })) do
      add(l)
    end
    add ''
  end

  add '// ---- function under test ----'
  for _, l in ipairs(vim.split(ctx.text, '\n', { plain = true })) do
    add(l)
  end
  add ''
  add '}  // namespace dans'
  add ''
  add 'def main() -> int'
  add '{'
  add '    using namespace dans;'
  add ''
  add '    /*'
  if #ctx.params == 0 then
    add('    const auto result = ' .. name .. '();')
  else
    add('    const auto result = ' .. name .. '(')
    for _, p in ipairs(ctx.params) do
      add('        // ' .. p)
    end
    add '    )'
  end
  add '    */'
  add ''
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
    vim.notify('dans_debug_fn: could not parse declarator', vim.log.levels.WARN)
    return
  end

  local fstart, _, fend = func:start(), nil, func:end_()
  local ctx = {
    file = file,
    line = fstart + 1,
    name = function_name(fdecl, bufnr),
    text = vim.treesitter.get_node_text(func, bufnr),
    params = param_texts(fdecl, bufnr),
    flags = include_flags(file),
    copies = {},
    notes = {},
  }

  -- Referenced types (signature + body) and called functions, one level deep.
  local type_nodes, call_nodes = {}, {}
  collect(func, { type_identifier = true, qualified_identifier = true }, type_nodes)
  collect(func, { call_expression = true }, call_nodes)

  local seen, to_resolve = {}, {}
  for _, tn in ipairs(type_nodes) do
    local parent = tn:parent()
    -- Skip nested parts of a larger qualified name (e.g. `numbers::pi` inside
    -- `std::numbers::pi`); only the outermost qualified_identifier is judged.
    if not (parent and parent:type() == 'qualified_identifier') then
      local kind, text = tn:type(), vim.treesitter.get_node_text(tn, bufnr)
      if is_user_type(kind, text) and not seen[text] then
        seen[text] = true
        local r, c = tn:start()
        to_resolve[#to_resolve + 1] = { name = text, row = r, col = c }
      end
    end
  end
  for _, cn in ipairs(call_nodes) do
    local fn = cn:field('function')[1]
    if fn then
      local txt = vim.treesitter.get_node_text(fn, bufnr)
      local rr, cc = fn:start()
      if txt:match '^[%a_][%w_]*$' and not seen[txt] then
        seen[txt] = true
        to_resolve[#to_resolve + 1] = { name = txt, row = rr, col = cc }
      end
    end
  end

  local clients = vim.lsp.get_clients { bufnr = bufnr, method = 'textDocument/definition' }
  if #to_resolve == 0 or #clients == 0 then
    for _, t in ipairs(to_resolve) do
      ctx.notes[#ctx.notes + 1] = t.name .. ' (unresolved — no clangd?)'
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
      local f, ln = loc_from_results(results)
      if not f then
        ctx.notes[#ctx.notes + 1] = ty.name .. ' (definition not found)'
      elseif vim.fs.normalize(f) == vim.fs.normalize(file) and ln >= fstart and ln <= fend then
        -- inside the target function itself (recursion / body-local) — already
        -- present in the copied function text; skip.
      elseif is_user_source(f) then
        local text, sl = definition_text(f, ln)
        if text then
          ctx.copies[#ctx.copies + 1] = {
            name = ty.name,
            text = text,
            file = f,
            line = sl or ln,
            where = vim.fn.fnamemodify(f, ':.') .. ':' .. (ln + 1),
          }
        else
          ctx.notes[#ctx.notes + 1] = ty.name .. ' (could not extract from ' .. vim.fn.fnamemodify(f, ':.') .. ')'
        end
      else
        ctx.notes[#ctx.notes + 1] = ty.name .. ' from ' .. vim.fn.fnamemodify(f, ':.') .. ' (library — include or stub)'
      end
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          generate(bufnr, ctx)
        end)
      end
    end)
  end
end

-- Build the playground in the current buffer and launch it under the debugger,
-- with a breakpoint at the `return 0;` in main so the session stops there.
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    vim.cmd 'silent write'
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cmd, ret_line
  for i, l in ipairs(lines) do
    local c = l:match '^//%s+(clang%+%+ .+)$'
    if c then
      cmd = c
    end
    if l:match '^%s*return 0;%s*$' then
      ret_line = i
    end
  end
  if not cmd then
    vim.notify('dans_debug_fn: no build command in this buffer — run :DansDebugFn first', vim.log.levels.WARN)
    return
  end
  local binary = cmd:match '%-o%s+(%S+)'
  if not binary then
    vim.notify('dans_debug_fn: could not find -o in build command', vim.log.levels.WARN)
    return
  end

  -- Breakpoint at main's `return 0;` (binds to the nearest executable line).
  if ret_line then
    vim.api.nvim_win_set_cursor(0, { ret_line, 0 })
    pcall(function()
      require('dap').set_breakpoint()
    end)
  end

  local cwd = vim.fn.getcwd()
  vim.notify('dans_debug_fn: building...', vim.log.levels.INFO)
  vim.system({ 'sh', '-c', cmd }, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local errlines = vim.split((res.stderr or '') .. '\n' .. (res.stdout or ''), '\n', { trimempty = true })
        vim.fn.setqflist({}, ' ', { title = 'DansDebugFn build', lines = errlines })
        vim.cmd 'copen'
        vim.notify('dans_debug_fn: build failed (see quickfix)', vim.log.levels.ERROR)
        return
      end
      local dap = require 'dap'
      local atype = dap.adapters.codelldb and 'codelldb' or 'lldb'
      dap.run {
        name = 'DansDebugFn: ' .. binary,
        type = atype,
        request = 'launch',
        program = cwd .. '/' .. binary,
        cwd = cwd,
        stopOnEntry = false,
      }
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('DansDebugFn', M.export, { desc = 'Export function under cursor to a debug playground' })
  vim.api.nvim_create_user_command('DansDebugFnRun', M.run, { desc = 'Build the current playground and debug it' })
end

return M
