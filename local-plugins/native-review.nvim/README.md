# native-review.nvim

`native-review.nvim` is the stateful review engine extracted from this Neovim
configuration. It freezes exact Git scopes, builds immutable OLD/NEW models,
presents unified-inline and native split views, owns the Files/Commits/Comments
panel and comment composer, persists owner-only v1/v2 stores, renders complete
Markdown exports, reanchors canonical comments, and provides a fail-closed
CURRENT-only LSP and diagnostic bridge.

## Boundary:

The plugin never imports `config.*` and never registers global commands or
global mappings. `setup(opts)` receives repository, filesystem, editor, tabs,
clipboard, event and LSP-navigation adapters. Its own panels, protected review
buffers, composers, and export previews may install buffer-local mappings.

The host keeps `:Review*` commands, global mappings, menu/statusline adapters,
profile selection, and notifications. Upstream Diffview remains an unrelated
viewer reached through its ordinary `DiffviewOpen`, `DiffviewFileHistory`, and
`DiffviewClose` commands; it is not a review backend or presentation surface.

TUICR publication and AgentContext/AgentResults workflows are intentionally not
part of this plugin. Existing store v1/v2 `bridge` and `deliveries` fields remain
strictly decoded, preserved, and encoded as legacy metadata so opening and
saving an older review does not rewrite or discard its history. Nothing in the
controller sends, links, or otherwise acts on those fields.

## Setup

```lua
local review = require("native_review").setup({
  repo = repo_adapter,
  fs = filesystem_adapter,
  editor = editor_adapter,
  clipboard = {
    available = clipboard_available,
    setreg = clipboard_setreg,
  },
  tabs = {
    acquire_transient = acquire_transient,
    focus_transient = focus_transient,
    rename_transient = rename_transient,
    release_transient = release_transient,
    valid_transient = valid_transient,
  },
  lsp_navigation = lsp_navigation_adapter,
  event = function(status) end,
  hunk_context = 3,
  max_files = 2000,
  max_file_bytes = 4 * 1024 * 1024,
  max_model_bytes = 64 * 1024 * 1024,
  layout = "inline",
  context = "hunks",
  inline_comments = true,
  comment_types = {}, -- additional selectable types; issue is built in
  composer = { style = "card" }, -- card | minimal
  panel = { max_width = 200, max_height = 48 },
})
```

`setup()` validates the complete option object before replacing its adapters;
unknown options fail without changing the active configuration. Repeated setup
reuses stable adapter proxies while replacing their implementations. Session
preferences override the normalized defaults above. `effective_config()` and
`status()` always return copies and are callable before setup;
`teardown()` removes internal lifecycle autocmds, panels and LSP state and may
be called repeatedly. Change notifications are delivered only through the
injected event callback. The host decides whether and how to expose controller
operations or translate events into editor-wide notifications.

`controller.open()` and `controller.refresh()` remain synchronous for existing
callers. Interactive hosts should use `open_async()` and `refresh_async()`.
Those wrappers run the same synchronous core in scheduled coroutines and yield
at cooperative checkpoints between Git calls and batches, files, and diffs. A
newer open or refresh supersedes the prior epoch; logical close, surface close,
and teardown cancel it. A pending replacement never publishes over the visible
review until its scope, store, and complete immutable model have succeeded.
`status()` exposes a copied `pending`/`operation` snapshot only while work is in
flight.

## Safety contracts

- Historical scopes resolve to full object IDs before a model is built.
- Model construction rejects more than `max_files`, either represented OLD or
  NEW side above `max_file_bytes`, or the sum of all represented sides above
  `max_model_bytes`. Rejections use `review_limit_exceeded` with the limit,
  maximum, actual value, path, layer, and side. Worktree sizes and unique Git
  blob sizes are preflighted before content is read or diffed, then checked
  again while reading.
- Regular untracked files are fingerprinted with NUL-safe path discovery and
  `git hash-object --no-filters -- <paths...>` batches whose complete private
  argv stays within 128 KiB. Symlinks continue to hash their target text.
- Persisted anchors contain canonical path, side, layer and source coordinates;
  synthetic display rows are never stored.
- Unified replacements emit OLD rows before NEW rows, while shared context is
  represented once and reverse mappings remain exact.
- OLD, changed, stale, modified, path-mismatched and unmappable rows never proxy
  LSP. Only verified NEW rows may reach unchanged CURRENT source.
- Definition results return to the owned review tab when their CURRENT path and
  line map to one unambiguous frozen NEW entry. Concealed target rows are
  revealed without changing layout or context; targets outside the diff fall
  back to ordinary CURRENT navigation. The CURRENT request buffer stays hidden
  until that decision, while source bytes, path, generation, newer requests and
  picker confirmation are revalidated so stale responses are ignored.
- Diagnostic mirroring requires complete consecutive visible NEW ranges and is
  removed when either side leaves the lifecycle.
- The controller owns one generation-safe transient tab for
  `{ owner = "native-review", key = "workspace" }`. UI teardown never removes
  its frozen logical workspace, and stale lease callbacks cannot affect a
  reacquired generation.
- `controller.capture_location()` and `controller.restore_location()` expose
  generation-bound logical OLD/NEW source positions for a host-owned navigation
  history. Non-source panes are neutral, source-capture failures are returned to
  the host, and file-level locations are canonical `0:1` positions. Entries
  never persist windows or buffers; restoration is transactional, while stale
  workspaces and released review surfaces fail closed without reacquiring or
  enabling review mode. Stale locations return a neutral `false`; operational
  restoration failures also return their already-reported detail so the host
  can abort rather than skipping farther back in history. Restoration compares
  canonical immutable entry fields instead of Lua object identity, accepting
  equivalent read-only proxy regeneration while rejecting content or hunk
  drift and rolling back the prior presentation.
- Supported tab closure is synchronously composer-safe and vetoable. Session
  suspension physically releases review UI; only a successful explicit manual
  session save may request restoration.
- Stores and recovery files use bounded input, atomic writes and owner-only
  permissions. V1 and v2 stores are read without mass migration.
- Every asynchronous comment workflow carries an immutable workspace-generation
  token, plus the item ID when applicable. Cancelled pickers are no-ops; a
  refreshed/replaced workspace or changed item fails closed before any later
  chooser, confirmation, composer callback, or target selection can mutate it.
- Cooperative cancellation cannot interrupt one Git process or one `vim.diff()`
  already in progress. The staged/unstaged binary fingerprint remains one
  irreducible Git invocation, while each per-file diff is bounded by the
  configured side/model limits. Either finishes its current unit before the
  next checkpoint; stale results are still discarded and never published.

## Comment UI

In this host configuration, review scope/session, layer, comment, type and
confirmation menus open a numbered list in Normal mode without a text filter.
Use `j`/`k` then Enter, or press a number directly in menus with up to nine
choices. For longer lists, type the full number then Enter (for example,
`12<Enter>`). Esc or `q` cancels. Commit and range revision prompts still accept
text. The standalone plugin continues to use the host's `vim.ui.select` with
`kind = "native_review"`.

The standalone plugin has one selectable type by default: `issue`. Pass an
ordered `comment_types` list to `setup()` to add types. Each entry requires
`id`, `icon`, `highlight`, `default_link`, and `rail_rank`; `severity` is an
optional diagnostic severity (default `INFO`) for Trouble. The list order is
the composer cycle order; ascending `rail_rank` sets sign-rail priority after
`issue` (rank 1). For example:

```lua
comment_types = {
  { id = "objection!", icon = "!", highlight = "NvimReviewCommentObjection",
    default_link = "Special", rail_rank = 2 },
}
```

This host config adds `suggestion`, `objection!`, `question`, `pedantic`, and
`praise` explicitly. A host `~/.nvim-local.lua` setting at
`plugins.native_review.comment_types` replaces that list; `{}` selects only
`issue`. Saved comments with a type no longer configured retain their type and
body, display with a neutral badge, and remain editable without changing type.
They cannot be selected for new comments. Saved `rationale` comments load as
`objection!` and are rewritten with the new type on the next save.
Panels and passive previews color only that badge, leaving locations, status,
and comment bodies neutral.

The default `card` composer is one rounded inline float with a type-colored left
rail and badge in its chunked title/footer. It reserves the body plus two chrome
rows. `minimal` retains the borderless inline body and separate footer, while
still coloring its selected type. File/review-level composers are centered
rounded modals in both styles. New comments and replies open in Insert mode;
editing an existing comment opens in Normal mode. New comments and edits cycle
types with Tab and Shift-Tab only in Normal mode; Insert-mode Tab remains
ordinary input. Replies inherit the parent type and deliberately install no
cycling mappings. `<C-s>` saves immediately. In Normal mode, Enter then Enter
within `timeoutlen` saves;
Esc then Esc discards a non-empty draft. A physical Esc used to leave Insert
mode counts as the first Esc, while mapped keys that produce Esc do not. The
composer shows the pending confirmation beside its title, and any intervening
key, text change, focus/completion boundary, timeout, or teardown cancels it.
`q` closes only an empty composer. Confirmation uses one one-shot timer; there
is no animation or periodic redraw loop.

The component specs in the repository exercise projection, frozen Git models,
store/recovery, export, reanchoring, sessions, panels, presenters and the
CURRENT-only LSP bridge without loading the complete editor profile.

Run an individual spec from the configuration root, for example:

```sh
nvim --headless -u NONE -i NONE \
  -l local-plugins/native-review.nvim/tests/native_review_spec.lua
```
