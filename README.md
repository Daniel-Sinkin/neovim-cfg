# neovim-cfg

My personal Neovim configuration, built around a view-only frontend that
re-renders C/C++/CUDA in a tighter Odin/Pascal-ish style.

## Layout

- `init.lua` - entry point, just requires the pieces below.
- `lua/config/` - non-plugin setup: options, keymaps, autocmds, the lazy.nvim
  bootstrap, snippets.
- `lua/custom/plugins/` - one file per plugin spec, imported as a directory by
  lazy.nvim.
- `lua/custom/dans_frontend_cpp/` - the C++ frontend (below).
- `lua/custom/` - the rest of the first-party modules (asm view, perf overlay,
  doc-comment markdown, ...).

## C++ frontend

`dans_frontend_cpp` repaints C/C++/CUDA buffers without changing a byte on disk.
It is pure presentation: treesitter-driven conceals, inline/overlay virtual
text, and window-local matches. A few of the transforms:

- `std::optional<T>` reads as `T?`, `unique_ptr<T>` as `T^`, `const char*` as
  `CString`.
- pointers render with a `^` caret; `auto* const p` reorders to `const auto^ p`.
- function params flip to `name: type`, with `mut` on the mutable borrows.
- concepts get a `~`-notation: `convertible_to<bool> A` -> `A ~> bool`,
  `BoolLike A` -> `A~BoolLike`, `std::invoke_result_t<T, S>` -> `{ T(S) }`.
- designated initializers collapse `.field = field` to `field`.

Nothing is written back, so the LSP, formatters, and git all see the real code.

## Snippets

`cpp_type_snippets` is a space-triggered `$`-shorthand expander, the inverse of
the frontend: type the short form, store real C++, read it back short.

- `$?$str` -> `std::optional<std::string>`
- `$um(K, V)` -> `std::unordered_map<K, V>`
- `$sc(u32, x)` -> `static_cast<u32>(x)`
- `$<$Foo` -> `std::vector<Foo>`

## Requirements

- A recent Neovim (uses the 0.11 LSP APIs where present).
- A C compiler and git, for treesitter and lazy.nvim.
- Optional Nerd Font (`vim.g.have_nerd_font`).

Plugins are managed by lazy.nvim and install on first launch.
