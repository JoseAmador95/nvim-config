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
event and LSP-navigation adapters. Its own panels, protected review
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
  layout = "inline",
  context = "hunks",
  inline_comments = true,
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

## Safety contracts

- Historical scopes resolve to full object IDs before a model is built.
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
- Supported tab closure is synchronously composer-safe and vetoable. Session
  suspension physically releases review UI; only a successful explicit manual
  session save may request restoration.
- Stores and recovery files use bounded input, atomic writes and owner-only
  permissions. V1 and v2 stores are read without mass migration.
- Every asynchronous comment workflow carries an immutable workspace-generation
  token, plus the item ID when applicable. Cancelled pickers are no-ops; a
  refreshed/replaced workspace or changed item fails closed before any later
  chooser, confirmation, composer callback, or target selection can mutate it.

## Comment UI

Comment types come from one internal catalogue. Composer cycling order is
`issue`, `suggestion`, `rationale`, `question`, `pedantic`, `praise`; sign-rail
priority remains `issue`, `suggestion`, `question`, `rationale`, `pedantic`,
`praise`. The catalogue also owns each icon and default theme-linked highlight.
Panels and passive previews color only that badge, leaving locations, status,
and comment bodies neutral.

The default `card` composer is one rounded inline float with a type-colored left
rail and badge in its chunked title/footer. It reserves the body plus two chrome
rows. `minimal` retains the borderless inline body and separate footer, while
still coloring its selected type. File/review-level composers are centered
rounded modals in both styles. New comments and edits cycle types with Tab and
Shift-Tab in Normal or Insert mode and return to Insert; replies inherit the
parent type and deliberately install no cycling mappings. Composer UI is
event-driven and creates no timer, animation, or periodic redraw loop.

The component specs in the repository exercise projection, frozen Git models,
store/recovery, export, reanchoring, sessions, panels, presenters and the
CURRENT-only LSP bridge without loading the complete editor profile.

Run an individual spec from the configuration root, for example:

```sh
nvim --headless -u NONE -i NONE \
  -l local-plugins/native-review.nvim/tests/native_review_spec.lua
```
