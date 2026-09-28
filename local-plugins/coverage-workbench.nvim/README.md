# coverage-workbench.nvim

Boundary: pure Coverage.py JSON and LCOV import, strict models, project registry, owned signs, summaries, and manual refresh. It never owns generators, Ex commands, or host test workflows.

`load({ root, path, format })` reads only an existing report and accepts
Coverage.py JSON legacy formats and formats 1-3, or LCOV records. Unknown future
Coverage.py formats fail closed. `snapshot(root)`, `summary(root)`,
`refresh(root)`, and `clear(root)` return copied state and never execute a
generator. The host retains project resolution, commands, menus and generators.

Reports are contained within their canonical project root and are read through a
bounded regular-file descriptor snapshot. The open descriptor's own path is
bound to the canonical report path using the operating-system primitive on Linux
or macOS; imports fail closed when that primitive is unavailable. Identity,
size, timestamps, and the final path are rechecked before imported bytes are
accepted. Symlink swaps and concurrent replacement therefore fail closed. A
successful replacement report immediately removes this plugin's signs for files
it no longer contains; a rejected refresh preserves the previous registry
snapshot and its signs.

Every imported file entry is bound to the source descriptor identity and a
content digest at report-load time. Canonical aliases are rejected before a
second bind. The descriptor's `fstat()` size is checked before reading or
hashing: each source is capped at 16 MiB and the unique sources represented by
one model are capped at 64 MiB. The same configurable ceiling independently
bounds a conservative normalized-model estimate (source records plus unique
line entries), so a small report cannot expand into an unbounded Lua model.
Host options may only reduce those hard limits. Line numbers are restricted to
the range supported by Neovim's sign API.
A modified buffer, in-place source edit, or path replacement makes that entry
stale. The default `stale = "hide"` removes owned signs immediately, and a
failed refresh re-renders the preserved report without ever restoring stale
signs. The default report ceiling is 50 MiB (hard maximum 256 MiB) and the
default sign mode is `signs = "all"`; covered-only, missing-only, and no-sign
modes are also available.

Runtime redraw work is indexed by canonical source path. Once a buffer enters
the modified state, subsequent `TextChanged`/`TextChangedI` callbacks perform no
source reads, hashes, canonicalization, or sign replacement; the transition
removes owned signs once. Unmodified lifecycle events compare the bound
descriptor metadata first and also re-resolve the buffer name. If a symlink is
retargeted, old-target signs and buffer state are released before a reload can
index the new canonical target. Sources whose identity is still exact are never
re-read. Loading or refreshing a report remains the only path that reads and
hashes source contents.

Coverage.py entries must classify every line into at most one of
`executed_lines`, `missing_lines`, and `excluded_lines`; overlap is rejected
instead of affecting totals or signs ambiguously.

`setup()` rejects unknown options before changing configuration. Repeated setup
replaces its autocmd group and adapters deterministically. `effective_config()`,
`status()`, reports, summaries, and events are copied; `teardown()` clears owned
signs and is safe to repeat.
