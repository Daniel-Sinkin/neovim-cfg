-- LuaSnip snippet registration. Pulls in friendly-snippets (VSCode-style) and
-- Daniel's C++ snippets. Wrapped in pcall so missing luasnip doesn't break
-- startup.

pcall(function()
  require('luasnip.loaders.from_vscode').lazy_load()
end)

pcall(function()
  local ls = require 'luasnip'
  local s = ls.snippet
  local t = ls.text_node
  local i = ls.insert_node
  local rep = require('luasnip.extras').rep

  ls.config.setup { enable_autosnippets = true }

  ls.add_snippets('all', {
    -- `$//` -> `/* | */`
    s({ trig = '$//', wordTrig = false, snippetType = 'autosnippet' }, {
      t '/* ',
      i(0),
      t ' */',
    }),
  })

  ls.add_snippets('cpp', {
    -- Marker shorthands: type the $-alias, get real C++ (cpp_aliases shows it
    -- back as the alias).
    s({ trig = '$nd', wordTrig = false, snippetType = 'autosnippet' }, { t '[[nodiscard]]' }),
    s({ trig = '$sc', wordTrig = false, snippetType = 'autosnippet' }, { t 'static_cast' }),
    s({ trig = '$ne', wordTrig = false, snippetType = 'autosnippet' }, { t 'noexcept' }),

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
