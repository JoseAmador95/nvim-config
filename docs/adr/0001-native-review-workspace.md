# ADR 0001: Native code-review mode in ordinary tabs

- Status: Superseded by [ADR 0002](0002-native-review-owned-tab.md)
- Date: 2026-08-26

## Context

Diffview is a good standalone Git viewer, but a dedicated Diffview tab interrupts
the normal editing workspace and makes review state, current source, and
historical content difficult to distinguish.

The reviewer must support working trees, commits, contiguous commit spans, and
whole branches; file/range/review-level comments; repeatable export; optional
inline and side-by-side views; and both hunk-only and complete-file context
without taking ownership of a tab.

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
- `review_presenter` has independent `inline|split` and `hunks|full` axes. Both
  hunk views use the validated review-local context, full-width gray start/end
  bands, optional Tree-sitter function/class labels, and direct cursor jumps
  across concealed gaps without changing global `diffopt`. Full mode shows the
  complete file without artificial hunk boundaries. Inline mode uses one
  protected, immutable unified projection in the ordinary review window. Shared
  context is one real row; each replacement emits real OLD rows followed by real
  NEW/CURRENT rows. Every row is cursor-addressable and maps deterministically to
  its canonical source path and line, including rename, line-ending, and final
  newline metadata. A two-column `OLD │ NEW` source-line gutter retains native
  fold and comment signs. Only changed OLD/NEW rows receive diff highlights.
  Split mode retains Neovim's native alignment and synchronized scrolling, gives
  both versions real, focusable rows, hides context through window-scoped
  decorations, renders old/new changes with theme-derived red/green groups, and
  gives blank native filler the normal background. It retains one structural
  context line when the configured context is zero. For a size-changing hunk at
  BOF or EOF, only a boundary band without a shared real-row anchor is omitted.
- The unified projection is a protected `nofile` buffer marked before `FileType`
  and cannot attach LSP. Read-only navigation, hover, and diagnostics may bridge
  conservatively only from display rows with a safe NEW/CURRENT mapping to the
  real current source. OLD, changed, or otherwise unmappable rows do not bridge,
  and mutation-oriented LSP operations remain unavailable. In split mode,
  CURRENT is a real current buffer only when its exact bytes, including
  line-ending format and final newline, match the frozen model; otherwise it is
  an isolated read-only snapshot. Historical OLD, snapshot, unified, and panel
  buffers remain LSP-blocked. A definition result may be projected back into the
  owned review tab only when its canonical CURRENT path and line reverse-map to
  one unambiguous frozen NEW entry. Picker confirmation and direct results both
  revalidate their request generation and exact source document. The CURRENT
  request buffer remains hidden until the destination is known; only a verified
  outside-diff result uses the ordinary CURRENT-file opener.
- `review_panel` is one dismissible three-pane float composed only of core
  Neovim windows. Files is a colored, collapsible tree with change groups,
  status, line totals, rename origins, and comment counts. Commits selects one
  commit or two endpoints from one linear, single-parent span. `Enter` over a
  visual selection of contiguous commit rows applies a transient span without
  changing manually marked endpoints. Nested commit scopes keep an in-memory
  stack of exact parent workspaces and UI snapshots,
  so returning never resolves refs or rebuilds the frozen model. Merge commits
  are reviewed individually. Comments lists every file, range, and review-level
  comment and exposes jump/edit/confirmed-delete/type/reply/resolve operations;
  `a` adds a review-level comment. Reanchoring remains an explicit
  command/palette action outside that float. The panel never creates a tab and
  is suspended during normal session serialization.
- Store version 2 represents internal `general`, `file`, and `range` anchors
  explicitly. Legacy bridge and delivery fields remain strictly validated and
  round-trip unchanged, but cannot initiate linking or publication. Version-1
  state remains readable. Range anchors persist
  canonical source path, OLD/NEW side, layer, and source line coordinates, never
  unified display rows. A selection spanning both OLD-exclusive and NEW-exclusive
  rows is rejected; OLD comments can be created, edited, and jumped to directly
  without leaving inline view. Multiline comments render a rail beside line
  numbers with one type-colored badge at an anchor start and only a
  guide/terminator on continuation rows. Same-type starts and overlaps compact to
  `2` through `9`, then `9+`, while remaining separate panel items.
  File comments render as explicitly labeled virtual `0 │ [OLD]` or
  `0 │ [NEW]` rows for the anchor's path, side, and layer. CursorHold previews use
  a separate transient namespace; previews and panel rows color only their type
  badge. The default range composer is one rounded, theme-aware card and reserves
  its one-to-six-row body plus two border rows without changing source text or
  the persisted schema. The host-only `minimal` style retains the borderless body
  and separate instruction row while still coloring the selected type.
  File and review-level create/edit/reply flows use a centered rounded modal
  capped at 88 by 18 rows and reserve no source rows. Tab/Shift-Tab cycle new or
  edited comment types in Normal and Insert mode and return to Insert; replies do
  not cycle. Normal-mode double Enter and `<C-s>` share one save path.
- `ReviewExport` renders all comments every time and copies complete Markdown or
  uses a temporary float. The header retains the frozen scope and exact
  revisions. Comment headings contain only file, line/range, and `[OLD]` or
  `[NEW]` location data; items retain status, body, and reply hierarchy. Export
  deliberately omits source snippets, captured context, context hashes, and the
  internal change-layer value. It does not mark comments delivered. Normal
  export refuses working-tree drift, session drift, and stale anchors;
  `ReviewExport!` exports only after writing and verifying owner-only recovery
  Markdown. Global drift labels the saved snapshot stale, while anchor drift is
  recorded on the affected comment. Linking and publication are outside the
  native reviewer boundary.
- The public key namespace is lower-case `<leader>r`. The main entries are `rr`
  panel, `ro` open, `rm` mode, `rs` scope, `rb` parent scope, `rf/rh/rl` panes,
  `rv` layout, `rw` context, `ri` inline previews, `rg` code, `ra/rA` line-or-file
  add, `rR` review-level add, `re` edit, `rc` type, `rd` delete, `rp` reply, `rt`
  resolve, `rE` export, `ru` refresh, and `rq` close. `[r` and `]r` navigate. A
  review status component and review-local winbar expose the active frozen scope
  and presentation state.

Raw Diffview is intentionally independent. Its plugin specification contains no
review imports, hooks, guarded actions, custom help groups, or tab-close
interception. Ordinary tab closure likewise has no review-owned-tab path.

If persisting a live mutation fails, refresh and scope changes stop instead of
discarding the in-memory review. The reviewer remains available for recovery
export and can be abandoned only through the verified `ReviewClose!` path.

## Consequences

Reviewing no longer leaves the user's normal tab or changes its bufferline
identity. OLD and NEW rows are both directly reviewable inline while persisted
anchors remain tied to exact source coordinates. The mixed projection itself
never becomes an LSP document; conservative CURRENT bridges preserve useful
read-only navigation, hover, and diagnostics without exposing OLD rows or
mutation operations. The panel can be opened only when needed, and exported text
is always available in chat-oriented workflows without requiring an external
review-round identifier.

Working scopes become stale instead of silently remapping anchors. An OLD or
unmappable NEW row cannot use the LSP bridge, and a mixed-side range cannot become
a partial review anchor. These refusals are intentional evidence-preservation
boundaries.
