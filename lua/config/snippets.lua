-- LuaSnip snippet registration. Pulls in friendly-snippets (VSCode-style) and
-- Daniel's C++ snippets. Wrapped in pcall so missing luasnip doesn't break
-- startup.
--
-- Registration runs at VeryLazy (lazy.nvim fires it right after VimEnter), not
-- at require time: pulling luasnip in synchronously cost ~70 ms of every
-- startup, and snippets can't be expanded before the UI is up anyway.

local function register()
  pcall(function()
    require('luasnip.loaders.from_vscode').lazy_load()
  end)

  pcall(function()
    local ls = require 'luasnip'
    local s = ls.snippet
    local t = ls.text_node
    local i = ls.insert_node
    local f = ls.function_node
    local rep = require('luasnip.extras').rep

    ls.config.setup { enable_autosnippets = true }

    -- Name of the class/struct whose MEMBER area the cursor is in, or nil. Returns
    -- nil inside a method body (a compound_statement seen before the class), so the
    -- rule-of-N snippets only fire where you'd declare special members. Used as the
    -- snippet condition and to fill the generated declarations.
    local function enclosing_class_name()
      local okp, parser = pcall(vim.treesitter.get_parser, 0)
      if okp and parser then
        pcall(function()
          parser:parse()
        end)
      end
      local ok, node = pcall(vim.treesitter.get_node)
      if not ok then
        return nil
      end
      while node do
        local nt = node:type()
        if nt == 'compound_statement' or nt == 'function_definition' then
          return nil
        end
        if nt == 'class_specifier' or nt == 'struct_specifier' then
          local nm = node:field('name')[1]
          return nm and vim.treesitter.get_node_text(nm, 0) or nil
        end
        node = node:parent()
      end
      return nil
    end

    -- Generate the rule-of-5 / rule-of-3 special-member declarations for the
    -- enclosing class, in the dans style (`def operator=(...) -> T& = ...`).
    -- `= default`; change to `= delete` for a non-copyable/movable type.
    local function rule_lines(five)
      local class = enclosing_class_name() or 'T'
      local out = {
        class .. '(const ' .. class .. '&) = default;',
        'def operator=(const ' .. class .. '&) -> ' .. class .. '& = default;',
      }
      if five then
        out[#out + 1] = class .. '(' .. class .. '&&) noexcept = default;'
        out[#out + 1] = 'def operator=(' .. class .. '&&) noexcept = default;'
      end
      out[#out + 1] = '~' .. class .. '() = default;'
      return out
    end

    ls.add_snippets('all', {
      -- `$//` -> `/* | */`
      s({ trig = '$//', wordTrig = false, snippetType = 'autosnippet' }, {
        t '/* ',
        i(0),
        t ' */',
      }),
    })

    ls.add_snippets('cpp', {
      -- $-alias expansion ($sc -> static_cast, $rc -> reinterpret_cast, ...) now
      -- comes from the space expander (custom/cpp_type_snippets.lua), which reads
      -- the same aliases.ALIASES table that drives the view-layer collapse.

      -- $rule5 / $rule3: drop the rule-of-5 / rule-of-3 special members for the
      -- enclosing class, name filled from treesitter. Only fires in a class/struct
      -- member area (the `condition`); elsewhere the space expander deletes the
      -- stray $-block.
      s({
        trig = '$rule5',
        wordTrig = false,
        snippetType = 'autosnippet',
        condition = function()
          return enclosing_class_name() ~= nil
        end,
      }, f(function()
        return rule_lines(true)
      end)),
      s({
        trig = '$rule3',
        wordTrig = false,
        snippetType = 'autosnippet',
        condition = function()
          return enclosing_class_name() ~= nil
        end,
      }, f(function()
        return rule_lines(false)
      end)),

      -- Class skeleton (rule of zero).
      s('dsk_class0', {
        t 'class ',
        i(1, 'MyClass'),
        t { ' {', 'public:', '\t' },
        i(0),
        t { '', '};' },
      }),

      -- Class skeleton (rule of three: copyable).
      s('dsk_class3', {
        t 'class ',
        i(1, 'MyClass'),
        t { ' {', 'public:', '\t' },
        rep(1),
        t '() = default;',
        t { '', '\t~' },
        rep(1),
        t '() = default;',
        t { '', '\t' },
        rep(1),
        t '(',
        t 'const ',
        rep(1),
        t '&) = default;',
        t { '', '\t' },
        rep(1),
        t '& operator=(',
        t 'const ',
        rep(1),
        t '&) = default;',
        t { '', '', 'private:', '\t' },
        i(0),
        t { '', '};' },
      }),

      -- Class skeleton (rule of five: movable + copyable).
      s('dsk_class5', {
        t 'class ',
        i(1, 'MyClass'),
        t { ' {', 'public:', '\t' },
        rep(1),
        t '() = default;',
        t { '', '\t~' },
        rep(1),
        t '() = default;',
        t { '', '\t' },
        rep(1),
        t '(',
        t 'const ',
        rep(1),
        t '&) = default;',
        t { '', '\t' },
        rep(1),
        t '& operator=(',
        t 'const ',
        rep(1),
        t '&) = default;',
        t { '', '\t' },
        rep(1),
        t '(',
        rep(1),
        t '&&) noexcept = default;',
        t { '', '\t' },
        rep(1),
        t '& operator=(',
        rep(1),
        t '&&) noexcept = default;',
        t { '', '', 'private:', '\t' },
        i(0),
        t { '', '};' },
      }),

      -- Indexed range loops.
      s('dsk_irange', {
        t 'for(usize i{0zu}; i < ',
        i(1, 'vec'),
        t { '.size(); ++i) {', '' },
        t { '', '}' },
      }),

      s('dsk_jrange', {
        t 'for(usize j{0zu}; j < ',
        i(1, 'vec'),
        t { '.size(); ++j) {', '' },
        t { '', '}' },
      }),

      s('dsk_krange', {
        t 'for(usize k{0zu}; k < ',
        i(1, 'vec'),
        t { '.size(); ++k) {', '' },
        t { '', '}' },
      }),

      -- Range-based loop by reference.
      s('dsk_forx', {
        t 'for(auto& ',
        i(1, 'x'),
        t ' : ',
        i(2, 'container'),
        t { ') {', '' },
        t '\t',
        i(0),
        t { '', '}' },
      }),

      -- println variants.
      s('dsk_println', {
        t 'std::println("{}", ',
        i(1, 'value'),
        t ');',
      }),

      s('dsk_printx', {
        t 'std::println("',
        i(1, 'x'),
        t '={}", ',
        rep(1),
        t ');',
      }),

      -- vector<int> of 5 elements.
      s('dsk_vec5i', {
        t 'std::vector<int> ',
        i(1, 'v'),
        t '{',
        i(2, 'a'),
        t ', ',
        i(3, 'b'),
        t ', ',
        i(4, 'c'),
        t ', ',
        i(5, 'd'),
        t ', ',
        i(6, 'e'),
        t '}',
      }),

      -- CUDA kernel launch: kernel<<<grid, block, sharedMem, stream>>>(args).
      s('dsk_cudalaunch', {
        i(1, 'kernel'),
        t '<<<',
        i(2, 'grid'),
        t ', ',
        i(3, 'block'),
        t ', ',
        i(4, '0'),
        t ', ',
        i(5, 'stream'),
        t '>>>(',
        i(0, 'args'),
        t ');',
      }),
    })
  end)
end

vim.api.nvim_create_autocmd('User', {
  pattern = 'VeryLazy',
  once = true,
  callback = register,
})
