# ADR 0001: Native code-review mode in ordinary tabs

- Status: Accepted
- Date: 2026-08-26

## Context

TUICR is useful for human review rounds, but its TUI cannot expose Neovim LSP
diagnostics and source navigation. Diffview is a good standalone Git viewer,
but a dedicated Diffview tab interrupts the normal editing workspace and makes
review state, current source, and historical content difficult to distinguish.

The reviewer must support working trees, commits, contiguous commit spans, and
whole branches; file/range/general comments; repeatable export; optional TUICR
publication; inline and side-by-side views; and both hunk-only and complete-file
context without taking ownership of a tab.

## Decision

Neovim owns a repository/session review controller in `config.code_review`:

- `review_scope` freezes full Git object IDs, the branch merge base, or a
  per-layer working-tree fingerprint. `review_changes` reads exact blobs and
  working layers without checkout, staging, ref mutation, or repository writes.
  Its immutable model includes paths, modes, bytes, hunks, and ordered commit
  date/author/subject metadata.
- Review mode runs in the current ordinary tab. `review_mode` rejects modified
  affected buffers, makes enrolled current buffers read-only, installs only its
  local hunk navigation, and restores every prior buffer mapping and window
  option when disabled.
- `review_presenter` has independent `inline|split` and `hunks|full` axes. Inline
  hunk mode uses strong start/end bands; inline full mode shows the complete
  file without artificial hunk boundaries. Split mode uses Neovim's native diff
  and synchronized scrolling so insertions and deletions align. Full split mode
  opens folds; hunk split mode uses native diff folds.
- The preferred right/new side is a real current buffer only when its exact
  bytes, including line-ending format and final newline, match the frozen model.
  Otherwise it is an isolated read-only snapshot. Historical old, snapshot, and
  panel buffers cannot attach LSP. A historical-new `gd` may bridge to the real
  current file only through an unchanged line mapping and preserves the source
  column; old content never bridges.
- `review_panel` is one dismissible three-pane float composed only of core
  Neovim windows. Files selects and focuses the current/new source; Commits
  selects one commit or two endpoints from one linear, single-parent span;
  merge commits are reviewed individually. Comments lists every file, range,
  and general comment and exposes jump/edit/delete/type/reply/resolve and
  reanchor operations. It never creates a tab and is suspended during normal
  session serialization.
- Store version 2 represents `general`, `file`, and `range` anchors explicitly.
  Resolution and delivery are independent. Version-1 state migrates under the
  existing owner lock with a backup and rollback. Multiline comments render a
  rail beside line numbers; overlapping comments collapse into a visible count
  while remaining separate items in the panel.
- `ReviewExport` renders all comments every time and copies complete Markdown or
  uses a temporary float. It does not mark comments delivered. Normal export
  refuses working-tree drift, session drift, and stale anchors;
  `ReviewExport!` exports only after writing and verifying owner-only recovery
  Markdown. Global drift labels the saved snapshot stale, while anchor drift is
  recorded on the affected comment.
  `ReviewPublish[!]` is a separate explicit TUICR operation and sends only open,
  undelivered items through `tuicr-round`, persisting each receipt.
- The public key namespace is lower-case `<leader>r`. The main entries are `rr`
  panel, `ro` open, `rm` mode, `rs` scope, `rf/rh/rl` panes, `rv` layout, `rw`
  context, `rg` code, `ra/rA` add, `re` edit, `rc` type, `rd` delete, `rp` reply,
  `rt` resolve, `rE` export, `ru` refresh, and `rq` close. `[r` and `]r` navigate.

Raw Diffview is intentionally independent. Its plugin specification contains no
review imports, hooks, guarded actions, custom help groups, or tab-close
interception. Ordinary tab closure likewise has no review-owned-tab path.

If persisting a live mutation fails, refresh and scope changes stop instead of
discarding the in-memory review. The reviewer remains available for recovery
export and can be abandoned only through the verified `ReviewClose!` path.

## Consequences

Reviewing no longer leaves the user's normal tab or changes its bufferline
identity. Current exact source retains LSP diagnostics and navigation; historical
content remains safe and deterministic. The panel can be opened only when
needed, and exported text is always available in chat-oriented workflows without
requiring a TUICR UUID.

Working scopes become stale instead of silently remapping anchors. A changed
historical line cannot use the LSP bridge, and a current buffer whose bytes differ
from the frozen side cannot receive a review anchor. These refusals are
intentional evidence-preservation boundaries.
