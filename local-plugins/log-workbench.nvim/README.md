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
