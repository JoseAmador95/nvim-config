# native-review.nvim

`native-review.nvim` is the stateful review engine extracted from this Neovim
configuration. It freezes exact Git scopes, builds immutable OLD/NEW models,
presents unified-inline and native split views, owns the Files/Commits/Comments
panel and comment composer, persists owner-only v1/v2 stores, renders complete
Markdown exports, reanchors canonical comments, and provides a fail-closed
CURRENT-only LSP and diagnostic bridge.

## Boundary:

The plugin never imports `config.*` and never registers global commands or
global mappings. `setup(opts)` receives repository, filesystem, editor,
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
  lsp_navigation = lsp_navigation_adapter,
  event = function(status) end,
  hunk_context = 3,
  layout = "inline",
  context = "hunks",
  inline_comments = true,
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
- Diagnostic mirroring requires complete consecutive visible NEW ranges and is
  removed when either side leaves the lifecycle.
- Stores and recovery files use bounded input, atomic writes and owner-only
  permissions. V1 and v2 stores are read without mass migration.

The component specs in the repository exercise projection, frozen Git models,
store/recovery, export, reanchoring, sessions, panels, presenters and the
CURRENT-only LSP bridge without loading the complete editor profile.

Run an individual spec from the configuration root, for example:

```sh
nvim --headless -u NONE -i NONE \
  -l local-plugins/native-review.nvim/tests/native_review_spec.lua
```
