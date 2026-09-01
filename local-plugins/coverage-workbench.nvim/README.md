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
