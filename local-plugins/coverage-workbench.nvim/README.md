# coverage-workbench.nvim

Boundary: pure Coverage.py JSON and LCOV import, strict models, project registry, owned signs, summaries, and manual refresh. It never owns generators, Ex commands, or host test workflows.

`load({ root, path, format })` reads only an existing report and accepts
Coverage.py JSON legacy formats and formats 1-3, or LCOV records. Unknown future
Coverage.py formats fail closed. `snapshot(root)`, `summary(root)`,
`refresh(root)`, and `clear(root)` return copied state and never execute a
generator. The host retains project resolution, commands, menus and generators.
