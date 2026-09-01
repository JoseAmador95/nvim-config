# exact-editor.nvim

Boundary: private editor registry, exact workspace selection, normal/blocking RPC, and cleanup.

The plugin registers private Neovim RPC endpoints and routes an open request to
exactly one editor instance. It does not define commands or mappings and does
not depend on the host configuration namespace.

## Setup

```lua
require("exact_editor").setup({
  state_root = function()
    return vim.fn.stdpath("state") .. "/exact-editor"
  end,
  resolve_workspace = function(path)
    return {
      runtime = "host",
      root = resolve_root(path),
      repo_identity = resolve_repo_identity(path),
    }
  end,
  open = function(path, position)
    open_in_host_tab(path, position)
  end,
  install_finish_mapping = function(bufnr, finish)
    return host_install_buffer_mapping(bufnr, finish)
  end,
  workspace_retention = "visited",
})
```

`resolve_workspace` returns a `WorkspaceKey` with the exact fields `runtime`,
`root`, and `repo_identity`. The registry stores version-2 records. Version-1
records remain readable by the CLI as host workspaces for migration.
`install_finish_mapping` is optional: the host chooses the key and owns both
installation and removal while the plugin supplies only the lifecycle callback.
All blocking requests for one buffer share that single finish action. Completion
is persisted once per request in sorted request-ID order, so concurrent callers
observe deterministic fan-out. Visited workspaces remain in the instance
registry for its lifetime; `workspace_retention` currently accepts only
`"visited"`.

The public RPC consumers are `consume_request`, `consume_normal`, and
`consume_blocking`. Blocking requests keep an owner-only wait file until the
external caller observes `completed` or `aborted`. `setup` accepts optional
`resolve_relative`, `clock`, `pid`, `uuid`, `server_start`, `server_stop`, and
`notify` hooks for embedding and deterministic tests. An injected `server_stop`
must return the boolean `true` only after the endpoint has stopped; the native
`vim.fn.serverstop` path is successful only when it returns `1`.

## CLI

`scripts/exact-editor-open` supports normal and blocking requests. Exact
selection is one all-or-none triplet. A complete `--runtime`,
`--workspace-root`, and `--repo-identity` triplet outranks the complete
`NVIM_EXACT_EDITOR_RUNTIME`, `NVIM_EXACT_EDITOR_WORKSPACE_ROOT`, and
`NVIM_EXACT_EDITOR_REPO_IDENTITY` environment triplet. With neither source,
the CLI selects the canonical host Git root. Sources are never mixed and a
partial source fails before editor lookup. Exit status `3` means that no
matching editor exists and is the only state in which a caller may use a
fallback. All ambiguity, unsafe state, live-but-unreachable endpoints, RPC
rejection, and timeout failures use exit status `2` and fail closed.

Inside a Dev Container, the host adapter requires the complete environment
triplet with `runtime=container`. It never migrates a legacy root into a
synthetic host workspace.

Registry directories are forced to `0700`; records, requests, waits, and Unix
sockets are forced to `0600`. State symlinks and non-regular entries are never
followed or overwritten. Cleanup pins the containing directory, moves an entry
with a no-clobber descriptor-relative rename, revalidates its exact identity,
and only then uses `unlinkat` plus a directory `fsync`. Socket pathnames are
reserved before `server_stop`, and replacements observed before the final
syscall boundary are restored or retained under their quarantine name. The
private owner UID is the final trust boundary because Unix has no atomic
compare-and-unlink syscall against an expected inode; a hostile same-UID process
can still race the final syscall boundary.

`status()` returns copied instance, workspace, and active-wait state and is safe
before setup. `effective_config()` exposes only copied policy (never callbacks),
and `teardown()` is repeatable. A failed server stop preserves the live instance
for an explicit teardown retry. Unknown setup options are rejected before active
state changes; optional `on_state_change(event)` observers receive copied events
and cannot break lifecycle work.

## Tests

```sh
nvim --headless -u NONE -l local-plugins/exact-editor.nvim/tests/exact_editor_spec.lua
```
