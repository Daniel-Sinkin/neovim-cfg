-- :DansAsm -- compile the current translation unit to assembly and show the
-- function under the cursor in a side split, with source<->asm line sync (move
-- the cursor in either window, the matching line(s) light up in the other).
--
-- Backend is local clang/gcc: the flags come from compile_commands.json when one
-- is found (walking up from the file, plus build/), else a c++23 fallback. The
-- compile streams asm to stdout (`-S -g -O2 -o -`), so nothing is written to disk.
-- Override: vim.g.dans_asm_compiler, vim.g.dans_asm_flags (list), vim.g.dans_asm_opt.
--
-- The parser is format-agnostic across x86 ELF (`#` comments, `_Z..` labels) and
-- arm64 Mach-O (`;` comments, `__Z..` labels): both bracket each function with
-- .cfi_startproc/.cfi_endproc and map asm to source with .file/.loc, which is all
-- it keys off.

local M = {}

local function notify(msg, lvl)
  vim.notify(msg, lvl or vim.log.levels.INFO)
end

-- ============================ pure helpers (tested) ============================

-- Strip the flags that conflict with "stream asm to stdout" from a
-- compile_commands argv, drop the input file (re-added), force the opt level, and
-- append `-S -g -O<opt> -o - <infile>`. argv[1] (the compiler) is kept.
local DROP1 = {
  ['-c'] = true, ['-S'] = true, ['-E'] = true, ['-MD'] = true, ['-MMD'] = true,
  ['-MP'] = true, ['-M'] = true, ['-MM'] = true, ['-MG'] = true,
}
local DROP2 = {
  ['-o'] = true, ['-MF'] = true, ['-MT'] = true, ['-MQ'] = true, ['-MJ'] = true,
  ['--serialize-diagnostics'] = true,
}
function M.clean_args(argv, infile, opt)
  local inbase = infile:match '[^/\\]+$'
  local out, i = {}, 1
  while i <= #argv do
    local a = argv[i]
    if DROP2[a] then
      i = i + 2
    elseif DROP1[a] or a:match '^%-O' then
      i = i + 1
    elseif a == infile or a == inbase or a:match('[/\\]' .. vim.pesc(inbase) .. '$') then
      i = i + 1 -- the input file -- re-added at the end
    else
      out[#out + 1] = a
      i = i + 1
    end
  end
  vim.list_extend(out, { '-S', '-g', '-O' .. (opt or '2'), '-o', '-', infile })
  return out
end

-- Naive shell-split for a compile_commands `command` string (most DBs use the
-- `arguments` array; this is the fallback). Honors "double" and 'single' quotes.
function M.split_command(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match '%s' then
      i = i + 1
    else
      local tok, q = {}, nil
      while i <= n do
        c = s:sub(i, i)
        if q then
          if c == q then
            q = nil
          else
            tok[#tok + 1] = c
          end
        elseif c == '"' or c == "'" then
          q = c
        elseif c:match '%s' then
          break
        else
          tok[#tok + 1] = c
        end
        i = i + 1
      end
      out[#out + 1] = table.concat(tok)
    end
  end
  return out
end

-- Parse assembly text into { lines, files, line_src, blocks }:
--   files     fileidx -> basename (from `.file N ["dir"] "name"`)
--   line_src  asm line (1-based) -> source line, for lines inside a function whose
--             current .loc points at `src_base`
--   blocks    { label, first, last, srcs={set}, lo, hi } per function, bracketed by
--             .cfi_startproc/.cfi_endproc, `first` at the function label line.
function M.parse_asm(text, src_base)
  local lines = vim.split(text, '\n', { plain = true })
  local files = {}
  for _, ln in ipairs(lines) do
    local idx, rest = ln:match '^%s*%.file%s+(%d+)%s+(.+)$'
    if idx then
      local name
      for q in rest:gmatch '"([^"]*)"' do
        name = q -- last quoted token is the file name (the dir, if any, comes first)
      end
      if name then
        files[tonumber(idx)] = name:match '[^/\\]+$'
      end
    end
  end
  local ours = {}
  for idx, base in pairs(files) do
    if base == src_base then
      ours[idx] = true
    end
  end

  local line_src, blocks = {}, {}
  local cur_src, last_label, last_label_line, open = nil, nil, nil, nil
  for i, ln in ipairs(lines) do
    local t = ln:gsub('^%s+', '')
    local locidx, locline = t:match '^%.loc%s+(%d+)%s+(%d+)'
    if locidx then
      if ours[tonumber(locidx)] then
        cur_src = tonumber(locline)
      end
    elseif t:match '^%.cfi_startproc' then
      open = { label = last_label, first = last_label_line or i, last = i, srcs = {}, lo = nil, hi = nil }
    elseif t:match '^%.cfi_endproc' then
      if open then
        open.last = i
        blocks[#blocks + 1] = open
        open = nil
      end
    else
      local lbl = t:match '^([%w_$.][%w_$.@]*):'
      -- a function symbol label (not a compiler-local .L*/L*/Ltmp/Lfunc label);
      -- reset the running source line so a new function's prologue isn't tagged
      -- with the previous function's last line.
      if lbl and not lbl:match '^%.?L' then
        last_label, last_label_line, cur_src = lbl, i, nil
      end
    end
    if open then
      open.last = i
      if cur_src then
        line_src[i] = cur_src
        open.srcs[cur_src] = true
        open.lo = (not open.lo or cur_src < open.lo) and cur_src or open.lo
        open.hi = (not open.hi or cur_src > open.hi) and cur_src or open.hi
      end
    end
  end
  return { lines = lines, files = files, line_src = line_src, blocks = blocks }
end

-- The block whose source coverage overlaps the cursor function's [fstart, fend]
-- the most (handles overloads and inlined callees without needing to demangle).
function M.pick_block(parsed, fstart, fend)
  local best, bestn = nil, 0
  for _, b in ipairs(parsed.blocks) do
    local n = 0
    for s in pairs(b.srcs) do
      if s >= fstart and s <= fend then
        n = n + 1
      end
    end
    if n > bestn then
      best, bestn = b, n
    end
  end
  return best
end

-- ============================ orchestration ============================

local sync_ns = vim.api.nvim_create_namespace 'ds_asm_sync'
local sessions = {} -- asm bufnr -> { sbuf, disp_src, src_to_disp }

local function demangle(label)
  if label == nil or label == '' then
    return label
  end
  for _, tool in ipairs { 'llvm-cxxfilt', 'c++filt' } do
    if vim.fn.executable(tool) == 1 then
      local out = vim.fn.systemlist({ tool, label })
      if vim.v.shell_error == 0 and out[1] and out[1] ~= '' then
        return out[1]
      end
    end
  end
  return label
end

local function enclosing_function(bufnr)
  local ok, node = pcall(vim.treesitter.get_node)
  if not ok or not node then
    return nil
  end
  while node and node:type() ~= 'function_definition' do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local sr, _, er = node:range()
  local name
  local d = node:field('declarator')[1]
  if d then
    name = (vim.treesitter.get_node_text(d, bufnr) or ''):match '([%w_:~<>]+)%s*%('
  end
  return { name = name, fstart = sr + 1, fend = er + 1 }
end

local function find_db(file)
  local dir = vim.fn.fnamemodify(file, ':h')
  while dir and dir ~= '' do
    for _, rel in ipairs { '/compile_commands.json', '/build/compile_commands.json' } do
      local p = dir .. rel
      if vim.fn.filereadable(p) == 1 then
        return p
      end
    end
    local up = vim.fn.fnamemodify(dir, ':h')
    if up == dir then
      break
    end
    dir = up
  end
  return nil
end

local function db_entry(path, file)
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  local target = vim.fn.fnamemodify(file, ':p')
  for _, e in ipairs(data) do
    if e.file then
      local abs = (e.file:sub(1, 1) == '/' or e.file:match '^%a:') and e.file or ((e.directory or '.') .. '/' .. e.file)
      if vim.fn.fnamemodify(abs, ':p') == target then
        return e
      end
    end
  end
  return nil
end

-- Build { argv, cwd } for compiling `file` to asm on stdout, from the project's
-- compile_commands.json when present, else a c++23 fallback.
local function compile_command(file)
  local opt = vim.g.dans_asm_opt and tostring(vim.g.dans_asm_opt) or '2'
  local db = find_db(file)
  if db then
    local entry = db_entry(db, file)
    if entry then
      local argv = entry.arguments or M.split_command(entry.command or '')
      if argv and #argv > 0 then
        return { argv = M.clean_args(argv, entry.file or file, opt), cwd = entry.directory }
      end
    end
  end
  local cc = vim.g.dans_asm_compiler or 'c++'
  local argv = { cc }
  vim.list_extend(argv, vim.g.dans_asm_flags or { '-std=c++23' })
  vim.list_extend(argv, { '-S', '-g', '-O' .. opt, '-o', '-', file })
  return { argv = argv, cwd = vim.fn.fnamemodify(file, ':h') }
end

local function style_asm_window(win)
  -- Light, frontend-flavored: directives + comments gray, function labels yellow,
  -- the mnemonic itself left at default fg. Window-local matchadds.
  vim.api.nvim_win_call(win, function()
    vim.fn.matchadd('Comment', [[^\s*\..*$]]) -- directive lines
    vim.fn.matchadd('Comment', [[\s*[;#].*$]]) -- trailing/standalone comments
    vim.fn.matchadd('Function', [[^\S\+:]]) -- labels at column 0
  end)
end

local function clear_sync(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, sync_ns, 0, -1)
  end
end

local function hl_line(buf, row0)
  pcall(vim.api.nvim_buf_set_extmark, buf, sync_ns, row0, 0, { line_hl_group = 'DansAsmSync' })
end

-- source cursor -> light up (and scroll to) the matching asm lines.
local function sync_from_source(asmbuf)
  local s = sessions[asmbuf]
  if not s or not vim.api.nvim_buf_is_valid(asmbuf) then
    return
  end
  if vim.api.nvim_get_current_buf() ~= s.sbuf then
    return
  end
  clear_sync(asmbuf)
  local src = vim.api.nvim_win_get_cursor(0)[1]
  local disps = s.src_to_disp[src]
  if not disps then
    return
  end
  for _, d in ipairs(disps) do
    hl_line(asmbuf, d - 1)
  end
  local awin = vim.fn.bufwinid(asmbuf)
  if awin ~= -1 and disps[1] then
    vim.api.nvim_win_set_cursor(awin, { disps[1], 0 })
  end
end

-- asm cursor -> light up the matching source line. Highlight only (no source
-- cursor move): moving it would re-fire CursorMoved and bounce against
-- sync_from_source, and browsing the asm shouldn't yank your place in the source.
local function sync_from_asm(asmbuf)
  local s = sessions[asmbuf]
  if not s or not vim.api.nvim_buf_is_valid(s.sbuf) then
    return
  end
  clear_sync(s.sbuf)
  local disp = vim.api.nvim_win_get_cursor(0)[1]
  local src = s.disp_src[disp]
  if src then
    hl_line(s.sbuf, src - 1)
  end
end

local function open_split(sbuf, parsed, block, fn)
  local body = {}
  for i = block.first, block.last do
    body[#body + 1] = parsed.lines[i]
  end
  -- source<->asm maps (display line is 1-based within the shown block)
  local disp_src, src_to_disp = {}, {}
  for off = 0, block.last - block.first do
    local src = parsed.line_src[block.first + off]
    if src then
      local d = off + 1
      disp_src[d] = src
      src_to_disp[src] = src_to_disp[src] or {}
      src_to_disp[src][#src_to_disp[src] + 1] = d
    end
  end

  local asmbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(asmbuf, 0, -1, false, body)
  vim.bo[asmbuf].filetype = 'asm'
  vim.bo[asmbuf].buftype = 'nofile'
  vim.bo[asmbuf].bufhidden = 'wipe'
  vim.bo[asmbuf].modifiable = false
  local title = (fn.name or block.label or 'asm') .. '  ' .. (demangle(block.label) or '')
  pcall(vim.api.nvim_buf_set_name, asmbuf, 'dans-asm://' .. title)

  vim.cmd 'vsplit'
  local awin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(awin, asmbuf)
  style_asm_window(awin)

  sessions[asmbuf] = { sbuf = sbuf, disp_src = disp_src, src_to_disp = src_to_disp }

  local group = vim.api.nvim_create_augroup('ds_asm_' .. asmbuf, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = function()
      local cur = vim.api.nvim_get_current_buf()
      if cur == sbuf then
        sync_from_source(asmbuf)
      elseif cur == asmbuf then
        sync_from_asm(asmbuf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = asmbuf,
    callback = function()
      clear_sync(sbuf)
      sessions[asmbuf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- jump back to the source window and light up the current line's asm
  local swin = vim.fn.bufwinid(sbuf)
  if swin ~= -1 then
    vim.api.nvim_set_current_win(swin)
  end
  sync_from_source(asmbuf)
end

function M.show()
  local sbuf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(sbuf)
  if file == '' then
    return notify 'DansAsm: buffer has no file'
  end
  local ext = (file:match '%.([%w]+)$' or ''):lower()
  if not ({ cpp = true, cc = true, cxx = true, cu = true, c = true })[ext] then
    return notify 'DansAsm: needs a .cpp/.cc/.cxx/.cu/.c translation unit (not a header)'
  end
  local fn = enclosing_function(sbuf)
  if not fn then
    return notify 'DansAsm: put the cursor inside a function body'
  end
  local cmd = compile_command(file)
  local base = file:match '[^/\\]+$'
  notify('DansAsm: compiling ' .. (fn.name or base) .. '...')
  vim.system(cmd.argv, { cwd = cmd.cwd, text = true }, vim.schedule_wrap(function(res)
    local asm = res.stdout or ''
    if asm == '' then
      return notify('DansAsm: compile failed:\n' .. (res.stderr ~= '' and res.stderr or ('exit ' .. tostring(res.code))), vim.log.levels.ERROR)
    end
    local parsed = M.parse_asm(asm, base)
    local block = M.pick_block(parsed, fn.fstart, fn.fend)
    if not block then
      return notify('DansAsm: no assembly for ' .. (fn.name or '?') .. ' (inline-only, a template with no instantiation, or optimized away)', vim.log.levels.WARN)
    end
    open_split(sbuf, parsed, block, fn)
  end))
end

function M.setup()
  vim.api.nvim_set_hl(0, 'DansAsmSync', { link = 'Visual', default = true })
  vim.api.nvim_create_user_command('DansAsm', M.show, { desc = 'Show the asm for the function under the cursor (source<->asm synced)' })
end

return M
