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

State directories are owner-only (`0700`) and records, requests,
acknowledgments, authentication, and lock files are owner-only (`0600`). The
secret exists only in `spool/auth.json`; messages carry a filename-bound UUIDv4
and HMAC-SHA256, are published without clobbering, and never copy the secret
into argv, environment, records, or logs. Readers reject symlinks, non-regular
files, oversized payloads, unknown schema fields, mismatched authentication,
and path traversal. Snapshots returned by the public API are deep copies.
Once a request or acknowledgement is published it remains a committed success;
a subsequent directory-fsync failure is surfaced separately through the host's
notification callback as a bounded warning and does not skip ACK validation.
The editor-side transport pins the spool root plus `inbox`, `outbox`, and
`acks` directory descriptors. Enumeration, reads, no-clobber publications, and
conditional retirement remain relative to those descriptors, so a later
directory rename or symlink replacement cannot redirect an operation outside
the authenticated spool. Retirement uses a no-clobber reservation and restores
a replacement detected against the opened snapshot. POSIX has no
compare-and-unlink syscall; after the last reservation snapshot, other host
processes running as the same UID remain the final-syscall trust boundary.

## API

- `setup(opts)` / `stop()`
- `in_workspace()` / `network_authorized()`
- `workspace_key(value)` / `route(path, from_root, to_root, kind)`
- `status(host_root)`
- `new_claim_id()`
- `request_host(action, dependencies?, callback?)`
- `consume_spool_once()`
- `lifecycle_argv(action, spec)`

## Boundary:

The plugin never imports `config.*`, creates global commands, chooses tmux/UI
policy, installs the Dev Containers CLI, or downloads tools. Host adapters own
`:DevContainer*`, menus, statusline, session refresh, and presentation. Python
owns the detached coordinator, the advisory lock retained for its whole
lifetime, checked tmux replacement/monitoring, and explicit record retirement.
The plugin owns lifecycle argv validation and the editor-side authenticated
transport contract. `lifecycle_argv("up", spec)` therefore requires an explicit
`spec.tmux_pane` and canonical `spec.claim_id`; the host waits for that exact
claim before reporting detached startup success.
