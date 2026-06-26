# soft c++ model - maybe-someday notes

Just an idea, not scheduled. Writing it down so it does not get lost.

## the itch

The frontend is a dozen modules (`aliases`, `markers`, `ppif`, `view`,
`arrow_align`, `enum_align`, `special_members`, `pointer`, `designated`,
`logic`, `fold`, `lint`) and each one re-derives the structure of the code on
its own, with its own heuristic. There is no shared idea of what the code *is*.
The same question gets answered several different ways that can disagree:

- "is this position inside a comment/string?" -> `util.in_literal` (a treesitter
  node lookup per position), `util.comment_lines` (treesitter over the visible
  range), and `markers.lua`'s `matchadd` comment masks (raw regex). Three
  detectors, three answers.
- "what's a declaration / where does this statement start / end?" -> `parse.lua`
  text+treesitter for the view, plus ad-hoc brace and `;` scanning in whoever
  else needs it.
- token coloring is window-local `matchadd` regex in `markers.lua`, decorations
  are extmarks in the other modules, and the monochrome base is classic vim
  syntax. Three highlight layers stacked, none aware of the others.

Exhibit A: the `^\s*\*.*` comment-mask regex grayed every `*ptr = v;` line
because it had no concept of a block comment as a thing, only "a line that
starts with a star is probably a comment continuation." We do not model the
multi-line comment block at all, so we approximate it per-line and get it wrong.

`scope.lua` already notes the cost side of this: per-position `in_literal`
treesitter lookups were hot enough to matter on a single cursor move.

## the idea

One cheap, lossy, display-tuned scan of the visible region that classifies it
*once* into spans/regions, cached per (buffer, changedtick, viewport). Every
decoration module reads that instead of scanning the buffer itself. It is not a
compiler and not trying to beat clang. It is there to delete the pile of
one-off regexes and per-module scans and replace them with one answer.

## what it would model (the cheap 98%)

Region level, not full AST:

- spans: code, line-comment, block-comment (as ONE multi-line region with
  open/body/close, not per line), string, char, raw-string (best effort),
  preproc line, inactive preproc block.
- on top of that, light structure: brace depth, statement boundaries (`;` `{`
  `}` at the right depth), coarse declaration-vs-expression, function-signature
  spans. Only as much as a consumer actually needs.

The win is that "block comment from line A to line B" becomes an object the
masking code consumes directly, instead of `markers.lua` guessing line by line.

## simplifying assumptions (the stuff we refuse to handle)

For-my-eyes-only means a mispaint is cosmetic, never a miscompile, so we can
throw away the 2% of edge cases that cause 99.99% of the pain:

- a multi-line block comment's `/*` is the first non-whitespace token on its
  line. `int x; /* opener [newline] ...body... */` is NOT handled (I have never
  written it and never will). Single-line `/* ... */` anywhere is fine.
- ignore line-continuation backslash games in normal code, trigraphs/digraphs,
  macro body expansion, most raw-string corner cases (punt or handle crudely).
- visible window + margin only, same discipline as `util.visible_range` /
  `cold_gate` today.
- when in doubt, guess and move on. Wrong coloring is acceptable.

## how it slots into what exists

- keep clangd for the things that need a real compiler: deduced `auto` types,
  diagnostics, references, hover. The model does not touch those.
- keep the treesitter AST where it is genuinely good (declarators, types). The
  model can be *seeded* from the treesitter tree where available and fall back
  to the text scan where treesitter is awkward, slow, or per-position lookups
  are the bottleneck. The parser stays on (the brace highlighter needs it);
  it is treesitter *highlighting* that is off for c/cpp/cuda, not the AST.
- the model replaces: `util.in_literal` / `comment_lines` / `static_assert_lines`
  / `clang_format_off` scattered scans, the `markers.lua` comment + include
  `matchadd` masks, and every module's private literal-skip predicate. One
  source of "is this code, and what kind."

## migration (incremental, parity-gated)

1. write `model.lua`: compute once per (buf, changedtick, viewport), cache it,
   expose `region_at(row,col)`, `block_comments()`, `is_code(row,col)`, etc.
2. port consumers one at a time, lowest risk first:
   - comment/literal masking (the thing that just bit us)
   - the `#include <...>` mask
   - per-module literal-skip predicates
   - then the heavier `pointer` / `aliases` treesitter passes
3. keep each old pass until its replacement reaches parity; a toggle to diff old
   vs new on the same buffer would make that honest.

## bigger wishes (separate features, later)

- structured view: an outline/explorer built from the model + treesitter
  (functions, members, scopes, the const/mut markers), in a side panel or as
  folds. Navigate the file by its shape.
- assembly view: compile the current TU or just the function under the cursor
  with the real toolchain (`-S -fverbose-asm`, or `objdump -dS`), map source
  lines to asm via debug info, show side by side. Needs real build flags
  (compile_commands.json) so it is Mac-only, gated behind a command, on the slow
  path. Good for "what did this actually compile to."

## risks / why this might not be worth doing

- writing a C/C++ tokenizer is the classic rabbit hole. The entire point is to
  bound it to the 98% and STOP. If it starts growing a preprocessor, kill it.
- perf: it has to stay inside the decorate budget. Reuse `cold_gate` /
  `visible_range`, do not scan the whole buffer.
- before writing a scanner, recheck which current heuristics could just BE
  treesitter queries against the AST that is already there. The scanner only
  earns its place for cheap whole-region classification that treesitter makes
  awkward or too slow per-position, and for modeling multi-line regions as
  objects.

## open questions

- granularity: region/span level, or down to tokens? (lean region-level; tokens
  only where a consumer needs them.)
- where it lives: a new `model.lua` that `util` and the modules consume, or fold
  into `util`?
- seed from treesitter, pure text scan, or hybrid?
- is the structured/assembly view actually wanted, or is the real prize just the
  unification of the comment/literal/region heuristics?
