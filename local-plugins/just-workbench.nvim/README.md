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
The closure is hashed again after cataloging and immediately before opening or
replacing an execution, or before format inspection, so changed source cannot
launch code without a fresh authorization/catalog.

`run()` accepts literal argv values and keeps exactly one transcript identity per
runtime/task root. If a terminal already exists it returns the intrinsic choices
`focus`, `replace`, and `cancel`; it never stops or replaces a process without the
host explicitly selecting `replace`. Conflict discovery, `focus`, and `cancel`
remain available when the catalog closure has since changed because they launch
no code; `focus` addresses the existing terminal by its stable key and never
validates against the newly requested argv. `open` and `replace` still fail closed on that drift. `format()` exposes
non-mutating canonical dump and `--fmt --check` operations. Host adapters own all
UI and policy prompts.

Catalogs preserve modern parameter metadata and compute exact minimum/maximum
argument cardinality, including bounded and variadic parameters. Variadic input
remains one literal argv value; the plugin never whitespace-splits it. Private
recipes, aliases, modules, and every descendant of a private module are omitted.
The catalog and execution both retain the same canonical absolute `just`
executable. Optional `--one` support is probed only when an invocation is about
to launch, fails closed on an invalid probe result, and is cached per absolute
binary for that setup lifetime.

Public API: `setup(opts)`, `catalog(spec, callback)`, `run(catalog, name, values,
opts)`, `transcript(identity)`, `status(identity)`, `stop(identity)`, and
`format(catalog, mode, callback)`. Unknown setup keys are rejected before state
changes. Because every setup input is an injected adapter, `effective_config()`
always returns a fresh empty table and setup events carry that safe projection.
`status()` returns a copied aggregate with `configured`, catalogs, requests,
capabilities, and callback-free execution summaries; contextual status,
transcript, and catalog values are also caller-owned. `teardown()`
deterministically clears all process-local catalogs and executions.
