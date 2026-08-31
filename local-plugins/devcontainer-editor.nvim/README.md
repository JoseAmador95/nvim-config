# devcontainer-editor.nvim

`devcontainer-editor.nvim` is the provider-neutral lifecycle and transport core
for an exact Neovim editor inside a Dev Container. It models workspace identity,
validates host/container path mappings, consumes authenticated spool requests,
and exposes lifecycle/status helpers without registering commands or mappings.

The host injects the `@devcontainers/cli` launcher, root/repository identity,
editor callbacks, notifications, and process primitives through `setup(opts)`.
Network authorization is carried into the container as
`NVIM_CONFIG_OFFLINE`; denied authorization therefore makes
`verified-tools.nvim` report `blocked/offline` without claiming an attempt.

State directories are owner-only (`0700`) and records, requests, acknowledgments,
and locks are owner-only (`0600`). State readers reject symlinks, non-regular
files, oversized payloads, unknown schema fields, mismatched tokens, and path
traversal. Snapshots returned by the public API are deep copies.

## API

- `setup(opts)` / `stop()`
- `in_workspace()` / `network_authorized()`
- `workspace_key(value)` / `route(path, from_root, to_root, kind)`
- `status(host_root)`
- `request_host(action, dependencies?, callback?)`
- `consume_spool_once()`
- `lifecycle_argv(action, spec)`

## Boundary:

The plugin never imports `config.*`, creates global commands, chooses tmux/UI
policy, installs the Dev Containers CLI, or downloads tools. Host adapters own
`:DevContainer*`, menus, statusline, session refresh, and presentation. The
Python launcher owns the cross-process lock and the foreground CLI process; the
plugin owns validation and the editor-side authenticated transport contract.
