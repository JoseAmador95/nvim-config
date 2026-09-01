# clangd-compile-db.nvim

`clangd-compile-db.nvim` is a provider-neutral, in-memory router for clangd
compilation databases. Providers submit validated candidates; an explicit RAM
override wins, and `apply` publishes the active database before a coalesced LSP
restart builds clangd's command.

Databases up to 256 MiB must decode as a JSON array. Larger files are rejected
unless the caller explicitly applies them as `unchecked`. Active files that
change or disappear become `stale`; errors never silently replace the previous
active database.

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
