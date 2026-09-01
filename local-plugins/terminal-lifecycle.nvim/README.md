# terminal-lifecycle.nvim

Boundary: terminal process identity, lifecycle state, retention, and replaceable views.

The plugin owns terminal process identity and lifecycle without owning editor
commands, global mappings, session policy, or a specific terminal UI. It has no
dependency on this repository's `config.*` modules.

## Contract

Call `require("terminal_lifecycle").setup(opts)` with a replaceable visual
backend, then pass normalized `TerminalSpec` values to the lifecycle methods:

```lua
local spec = {
  key = '["host","/repository","tests"]',
  launch = {
    argv = { "just", "test" },
    cwd = "/repository",
    env = {},
  },
  policy = {
    dispose_on_success = true,
    dispose_on_stop = false,
  },
  view = {
    layout = "bottom",
    title = "Tests",
    passthrough = {},
    hide_keys = {},
  },
  metadata = {},
}
```

`key` is the stable identity. `launch` is the exact process contract. `policy`,
`view`, and `metadata` are copied when accepted. `launch.cwd` must be an existing
absolute directory, `launch.argv` is always an argv array, and `launch.env` is an
explicit string map.

The public API is `open`, `toggle`, `focus`, `restart`, `stop`, `dispose`,
`dispose_all`, `list`, `status`, and `lines`. `list()` is deterministic and
caller-owned; `dispose_all([filter])` can select records by key, state, or
metadata. A changed launch is rejected until the caller chooses `restart`
explicitly.

Every record is in exactly one of these states:

- `starting`: the backend is creating the process and view.
- `running`: the backend returned and no exit was observed.
- `exited-retained`: output remains after failure, stop, or configured retention.
- `disposed`: no live registry entry or restorable view remains.

Failures are retained. Successful exits dispose by default. `stop`, `restart`,
and live `dispose` first request a stop and remain in their current active state
until `on_exit` confirms process termination. `status` exposes `stop_pending`,
`restart_pending`, and `dispose_pending`; `accepting_input` is false whenever
any of them is pending. Repeated restarts coalesce to the latest spec, while
dispose cancels a queued restart and wins. Duplicate exit callbacks are inert.
After the confirmed exit, `stop` keeps the buffer unless
`policy.dispose_on_stop` is true, `restart` creates exactly one replacement,
and `dispose` closes the view. Synchronous exit callbacks during `backend.open`
or `backend.stop` settle by the same rules, so quick exits cannot leave
`starting` or a pending request behind.

The default `stop_timeout_ms` is 5000. Expiry is observable in status and state
events only: it never fabricates exit, disposes the view, or starts a queued
replacement before the backend reports `on_exit`. Buffer mappings are host
policy via `buffer_mappings = { close = "q", open_location = "gf" }`; either
mapping can be changed or disabled with `false`.

Zero-argument `status()` is a pure aggregate available before setup, and
`effective_config()` always returns copied non-callback defaults or active
policy. Unknown setup options are rejected before mutation, teardown is
repeatable, and `on_state_change(event)` observer failures are isolated.

Plugin buffers are tagged with `b:terminal_lifecycle.ephemeral = true` and
`b:terminal_lifecycle_ephemeral = true`. Host session adapters must exclude
terminal buffers rather than attempting to resurrect their processes.

## Backend

`backend.open(spec, callbacks)` returns an opaque handle. It may call
`callbacks.on_buffer(bufnr)`, `callbacks.on_exit(exit_code)`, and
`callbacks.on_dispose()` before or after returning. It must also provide:

```text
show(handle)       focus(handle)      hide(handle)
visible(handle)    buffer(handle)     stop(handle)
dispose(handle)    lines(handle)
```

Mutating methods return a truthy value on success or `nil, error`. The backend
must start the process without a shell, retain output until disposal, and make
`stop` a bounded request that does not create a replacement process or claim
that it has already exited. It must eventually report the matching `on_exit`;
if a non-blocking process probe already proves termination, it may report that
exit synchronously from `stop`. A live `on_dispose` is also a stop request, not
an exit notification. Buffer-local `q`, optional `gf`, passthrough keys, and
hide keys are installed by the plugin. Commands and global mappings belong to
the host adapter.
