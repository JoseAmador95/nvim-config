# clangd-compile-db.nvim

`clangd-compile-db.nvim` is a provider-neutral, in-memory router for clangd
compilation databases. Providers submit validated candidates; an explicit RAM
override wins, and `apply` publishes the active database before a coalesced LSP
restart builds clangd's command.

Databases up to 256 MiB must decode as a JSON array. Larger files are rejected
unless the caller explicitly applies them as `unchecked`. Active files that
change or disappear become `stale`; errors never silently replace the previous
active database.

Every structural entry requires string `directory` and `file` fields plus
exactly one of a string-list `arguments` or string `command`. Validation pins
the opened file descriptor and verifies its identity before and after reading;
symlinks and replacements fail closed. A candidate that becomes invalid is
removed from eligibility while the prior active database remains available.

`apply()` revalidates the selected candidate immediately before publication and
stores its refreshed fingerprint and validity. A formerly oversized candidate
can therefore become structural after shrinking, while a structural candidate
that grows beyond the limit requires a new explicit unchecked apply. Clearing a
manual override always removes it: a valid provider fallback is published, or
the active database becomes `nil`; either transition shares one coalesced clangd
restart whose command is built from the final state.

## Boundary:

The plugin owns candidate/active/error/stale state, validation, provider
selection, overrides, and the one-client-per-root restart transaction. It does
not import `config.*`, register commands or mappings, choose clangd profiles,
know CMake, or implement prompts and source/header UI. LSP, providers, clocks,
events, and scheduling are injected through `setup(opts)`.

`setup(opts)` rejects unknown top-level and LSP callback keys transactionally.
`effective_config()` is available before setup and projects only the copied
validation limit and restart delay/timeout; setup events carry that same
callback-free projection. `status()` returns a copied aggregate with
`configured`, roots, providers, and pending restart tickets, while
`status(root)` keeps the contextual view. Neither status form probes the
filesystem; use `refresh(root)` for explicit revalidation. `teardown()` clears
roots, providers, and pending restart tickets.
The restart transaction stops every clangd for the root, waits up to the
configured timeout (5000 ms by default), starts one replacement client, and
reattaches the remaining valid buffers in order.
