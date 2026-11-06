# rex.nvim

A passive Neovim client for owned floating terminals in a local Rex session.
The host supplies commands, working directories and lifecycle callbacks.
The plugin uses the installed `rex` CLI with `--autostart=false` and does not implement Rex's socket protocol.

```lua
local rex = require("rex")
rex.setup({ bin = "rex", timeout_ms = 5000, poll_interval_ms = 500 })
rex.context(function(err, context)
  if err or not context then
    return
  end
  rex.open_float({
    context = context,
    label = "Preview",
    command = { "/absolute/path/to/program", "argument" },
    cwd = "/absolute/workspace",
    on_close = function() end,
  }, function(open_err, handle)
    -- Retain handle for rex.focus(handle, callback) or rex.close(handle, callback).
  end)
end)
```

`context()` verifies the inherited `REX_SESSION` and `REX_BLOCK` against the local server.
`open_float()` creates a centred 90% layer in that block's window and returns a cancellation ticket.
Operation callbacks are error-first; `on_close(handle, reason)` reports the end of an owned float.
Handles and configuration snapshots are caller-owned copies.
`hide(handle, callback)` minimises the layer while its process keeps running.
`restore(handle, callback)` restores, raises and focuses the same layer without changing its bounds.
`resize(handle, { x, y, width, height }, callback)` moves and resizes it without changing focus.
Bounds are fractions of the source window; width and height must be positive and the rectangle must fit inside it.
These operations verify the owned layer and block in their original window before mutation.
Reusing the same context, label and argv returns the owned float or reconciles an uncertain creation.
A timeout never permits an unverified second creation.
Polling detects external closure without stealing focus, and cleanup targets only the owned layer and block.
A minimised layer remains owned and is cleaned up on teardown like a visible one.
`teardown()` starts asynchronous cancellation and cleanup; the host must allow the event loop to finish during exit.
`status()` exposes pending calls and unresolved records so failures can be reported.
Remote servers are rejected.

The Neovim configuration composes this client in `config.diagram_rex`.
Diagram parsing, rendering, source observation and RPC belong to that host adapter.
