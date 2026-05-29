-- Compile-time expression evaluation in the editor. Evaluates a constexpr
-- integral expression (sizeof, alignof, offsetof, any `constexpr` function) in
-- the context of the current file and shows the result inline.
--
-- Mechanism: copy the buffer, declare `template <auto> struct dans_eval_;`,
-- insert `dans_eval_<EXPR> probe;` after the cursor line, compile -fsyntax-only
-- with the file's flags from compile_commands.json. Instantiating the undefined
-- template forces a diagnostic that contains the value (`dans_eval_<24UL>`),
-- which we parse out. No program is run.
--
--   :DansEval                -> sizeof(<word under cursor>)
--   :DansEval alignof(Foo)   -> evaluate the given expression
--   :DansEval some_cexpr(2)  -> any constexpr integral

local M = {}

local ns = vim.api.nvim_create_namespace 'ds_dans_eval'

-- Walk up from `dir` looking for a compile_commands.json (clangd uses build/).
local function find_db(dir)
  local found = vim.fs.find({ 'compile_commands.json' }, {
    path = dir,
    upward = true,
    limit = 1,
  })[1]
  if found then
    return found
  end
  -- also check a build/ subdir at each ancestor
  for parent in vim.fs.parents(dir .. '/x') do
    local cand = parent .. '/build/compile_commands.json'
    if vim.uv.fs_stat(cand) then
      return cand
    end
  end
  return nil
end

local function db_entry(db_path, file)
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(db_path), '\n'))
  if not ok or type(data) ~= 'table' then
    return nil
  end
  for _, e in ipairs(data) do
    if e.file and vim.fs.normalize(e.file) == vim.fs.normalize(file) then
      return e
    end
  end
  return nil
end

-- Reconstruct the compiler argv from an entry, dropping -c / -o <obj> and the
-- input file (we substitute our temp file + -fsyntax-only).
local function build_argv(entry, src, tmp)
  local raw
  if entry.arguments then
    raw = entry.arguments
  else
    raw = vim.split(entry.command or '', '%s+', { trimempty = true })
  end
  local argv = {}
  local skip = false
  for _, a in ipairs(raw) do
    if skip then
      skip = false
    elseif a == '-c' then
      -- drop
    elseif a == '-o' then
      skip = true
    elseif vim.fs.normalize(a) == vim.fs.normalize(src) then
      -- drop the original input
    else
      argv[#argv + 1] = a
    end
  end
  argv[#argv + 1] = '-fsyntax-only'
  argv[#argv + 1] = tmp
  return argv
end

local function show(bufnr, row0, text, hl)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, 0, {
    virt_text = { { '  ⇒ ' .. text, hl or 'DansInlayType' } },
    virt_text_pos = 'eol',
  })
end

function M.eval(expr)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    vim.notify('dans_eval: buffer has no file', vim.log.levels.WARN)
    return
  end
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1

  expr = vim.trim(expr or '')
  if expr == '' then
    expr = 'sizeof(' .. vim.fn.expand '<cword>' .. ')'
  end

  local db = find_db(vim.fs.dirname(file))
  if not db then
    vim.notify('dans_eval: no compile_commands.json found', vim.log.levels.WARN)
    return
  end
  local entry = db_entry(db, file)
  if not entry then
    vim.notify('dans_eval: file not in compile_commands.json', vim.log.levels.WARN)
    return
  end

  -- Build the probe TU: template decl at top, instantiation after cursor line.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = { 'template <auto> struct dans_eval_;' }
  for i = 1, row0 + 1 do
    out[#out + 1] = lines[i]
  end
  out[#out + 1] = 'dans_eval_<' .. expr .. '> dans_eval_probe_;'
  for i = row0 + 2, #lines do
    out[#out + 1] = lines[i]
  end

  local tmp = vim.fn.tempname() .. '.cpp'
  vim.fn.writefile(out, tmp)
  local argv = build_argv(entry, file, tmp)

  show(bufnr, row0, '...', 'Comment')
  vim.system(argv, { cwd = entry.directory, text = true }, function(res)
    vim.schedule(function()
      pcall(vim.fn.delete, tmp)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local value = (res.stderr or ''):match 'dans_eval_<(%-?%d+)'
      if value then
        show(bufnr, row0, expr .. ' = ' .. value)
      else
        show(bufnr, row0, 'not a constexpr integral', 'DiagnosticError')
      end
    end)
  end)
end

function M.clear()
  vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
end

function M.setup()
  vim.api.nvim_create_user_command('DansEval', function(o)
    M.eval(o.args)
  end, { nargs = '?', desc = 'Evaluate a constexpr integral expression inline' })
  vim.api.nvim_create_user_command('DansEvalClear', M.clear, { desc = 'Clear the dans_eval result' })
end

return M
