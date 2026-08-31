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
`status`, and `lines`. A changed launch is rejected until the caller chooses
`restart` explicitly.

Every record is in exactly one of these states:

- `starting`: the backend is creating the process and view.
- `running`: the backend returned and no exit was observed.
- `exited-retained`: output remains after failure, stop, or configured retention.
- `disposed`: no live registry entry or restorable view remains.

Failures are retained. Successful exits dispose by default. `stop` keeps the
buffer unless `policy.dispose_on_stop` is true; `dispose` stops a live process
and closes its view. Synchronous exit callbacks during `backend.open` settle by
the same rules, so quick exits cannot leave `starting` behind.

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
`stop` a bounded request that does not create a replacement process. Buffer-local
`q`, optional `gf`, passthrough keys, and hide keys are installed by the plugin.
Commands and global mappings belong to the host adapter.
