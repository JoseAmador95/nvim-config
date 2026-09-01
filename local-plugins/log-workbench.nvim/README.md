# log-workbench.nvim

`log-workbench.nvim` provides two independent log-processing cores.

Boundary: `follow` owns ephemeral `tail://` buffers, bounded incremental UTF-8
decoding, hybrid filesystem observation, reconciliation, lifecycle, and
line/byte retention. `matches` owns per-buffer pattern IDs, extmarks, automatic
rescanning, and next/previous navigation. The plugin does not import `config.*`,
create global commands or mappings, load `log-highlight.nvim`, read host-local
configuration, or choose windows and UI.

`require("log_workbench").setup({ follow = {...}, matches = {...} })` is the
single plugin entrypoint. The two modules remain independently addressable for
hosts that need separate lifecycle adapters.

## Follow

`require("log_workbench.follow")` exposes `setup`, `open`, `find`, `session`,
`stop`, `stop_all`, `status`, and `teardown`. Each open path has one session and
a distinct unlisted `nofile` buffer named `tail://<absolute-path>`. Both a
directory `fs_event` watcher and a periodic file poll feed the same serialized
reconciliation path. The file is reopened for every refresh so append, partial
lines, copytruncate, inode rotation, deletion, and recreation converge on the
current path without overlapping reads. Invalid UTF-8 and NUL bytes are replaced
and incomplete codepoints retain at most three bytes between appends.

`change` fs-event flags request an incremental append after a bounded raw-byte
continuity probe at the previous offset. A mismatch reloads the bounded tail,
so copytruncate still converges when the replacement has already regrown past
that offset. The probe covers the complete configured `max_bytes` retention
window and never enters the UTF-8 decoder.
`rename`, unknown flags, missing filenames, and watcher errors force
current-path identity revalidation. Event storms coalesce behind one active
read and are counted as dropped events. Sessions can be paused and resumed;
pausing closes both watchers, while resuming replaces them and forces a reload.
Session status reports health, the last error, and dropped lines, bytes, and
events.

Tail buffers are read-only, swap/undo-free, and wiped on teardown. They are
ephemeral runtime state; the host session adapter must synchronously replace
tail windows before serialization and may restore them afterward.

## Matches

`require("log_workbench.matches")` exposes `setup`, `add`, `remove`, `clear`,
`refresh`, `list`, `locations`, `next`, `previous`, and `teardown`. Exact and
Neovim-regex patterns have stable caller-visible IDs and are rendered with
buffer extmarks. Pattern colors, command-line parsing, visual selections, and
highlight definitions remain host responsibilities, allowing
`log-highlight.nvim` to continue as the external syntax backend.

The default follow configuration is a 500 ms poll interval, 100,000 lines, and
64 MiB. The top-level `setup()` preflights both module option objects so unknown
options cannot partially reconfigure either module. `effective_config()` and
`status()` are copied and callable before setup; repeated setup/teardown resets
watchers, buffers, matches, and callbacks deterministically. All plugin events
are copied before invoking their module-local adapter.
