# just-workbench.nvim

Boundary: Just recipe, alias, module, and parameter catalogs; strict content trust
for the complete import/module closure; execution arbitration; and transcripts
keyed by `{runtime, task_root}`. Host commands, prompts, terminal presentation,
profiles, workspace grants, and installation of `just` stay outside.

The plugin never runs during startup. `catalog()` first reads and authorizes every
regular source in the root closure, then invokes the injected `just --dump
--dump-format json` runner. Imports are resolved relative to their source;
modules support explicit paths and Just's standard implicit search locations.
External sources are allowed only when every source content is explicitly trusted.
The closure is hashed again after cataloging and immediately before execution or
format inspection, so a changed source requires a fresh authorization/catalog.

`run()` accepts literal argv values and keeps exactly one transcript identity per
runtime/task root. If a terminal already exists it returns the intrinsic choices
`focus`, `replace`, and `cancel`; it never stops or replaces a process without the
host explicitly selecting `replace`. `format()` exposes non-mutating canonical
dump and `--fmt --check` operations. Host adapters own all UI and policy prompts.

Public API: `setup(opts)`, `catalog(spec, callback)`, `run(catalog, name, values,
opts)`, `transcript(identity)`, `status(identity)`, and `format(catalog, mode,
callback)`.
