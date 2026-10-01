# native-review.nvim

`native-review.nvim` is the stateful review engine extracted from this Neovim
configuration. It freezes exact Git scopes, builds immutable OLD/NEW models,
presents unified-inline and native split views, owns the Files/Commits/Comments
panel and comment composer, persists owner-only v3 stores, reads v1/v2, renders complete
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

## Diff detail and structural view

The principal engine keeps its canonical Git hunks and adds character ranges to
replacement blocks. Histogram matching with `linematch = 60` refines line
correspondence, then Myers compares graphemes after trimming common edges.
Ranges use exact OLD/NEW source lines and byte columns in both unified and
split layouts, with hunks or full context. A stronger background marks changed
characters while retaining syntax foregrounds; theme changes rebuild the
colors. Inserted/deleted lines retain their line backgrounds. Refinement skips
blocks over 128 KiB or 8192 remaining graphemes and retains the line diff.
Only the selected frozen entry's detail is cached across presentation changes.
Canonical Git hunks and anchors remain independent of the display engine.

`:ReviewEngine` or `<leader>rD` opens the numbered engine picker; use
`:ReviewEngine main|patience|difftastic|gumtree` to choose directly. Main is
the default at startup. Selection belongs to the workspace, travels with its
layout/context preferences, and is never saved in the review store. All four
engines use the existing inline and split reviewer, file panel and comments.
The optional Difftastic engine requires the explicitly installed, verified
0.71.0 tool; selecting it never installs anything or falls back to a host binary.

Patience computes display hunks from the full frozen documents with Neovim's
`patience` algorithm, indentation heuristic and `linematch=60`, retaining every
whitespace change and character refinement. Its split panes use owned, aligned
buffers; selecting it never changes global `diffopt`. Main keeps native split
alignment. Both engines mark exact moved blocks with shared `M` identifiers and
original counterpart line/byte-column coordinates. Matches must be unique among
removed/added runs, contain at least three nonempty lines and twenty ASCII
alphanumeric characters, and be byte-identical including line terminators.
Longer blocks win; overlapping or ambiguous matches are omitted. Analysis skips
more than 100,000 changed line/gap tokens and shows `Move analysis limited`.
These labels and colors are decorations; source rows and comment anchors do not
move.

GumTree keeps Main's complete textual diff and adds matched moves (`M`) and
identifier updates (`U`), including nodes moved and edited together. These are
tree-node relations, not a claim of a project-wide semantic rename. Install it
explicitly with `:NvimConfigToolsInstall gumtree` (or `!` to retry/repair).
GumTree 4.0.0, its fixed Maven JAR closure and private Temurin JRE 17.0.20.1+1
are SHA-256 pinned for macOS/Linux x64/arm64. Runtime never uses host Java,
Maven, Gradle or a compiler, and engine selection never installs or downloads.

The initial GumTree languages are Lua, Python, C and C++. Installed Neovim
Tree-sitter parsers export frozen strings, including anonymous tokens/comments,
to byte-positioned XML; GumTree uses its fixed `gumtree-simple` matcher. Missing parsers,
unsupported languages, syntax errors and preanalysis limits select Main for that
file with a visible reason while retaining the GumTree choice. Limits are 1 MiB
combined source, 50,000 combined nodes and tree depth 512. Missing tools,
timeouts or invalid JSON retain the previous view and notify. Java has a 256 MiB
heap, a five-second process deadline and an 8 MiB combined-output ceiling.
Private snapshots and process groups are cleaned on completion/cancellation.
Validated relations map to original OLD/NEW coordinates even when moves cross;
they replace textual move labels rather than duplicating them.

Difftastic interprets private copies of the frozen OLD/NEW documents through
its pinned unstable JSON format. Only structural changes receive backgrounds
and character ranges. Formatting-only changes show `No structural changes`;
full context remains commentable and unequal source bytes are kept separately.
Split panes map aligned display rows to frozen source lines, with unanchorable
blank filler rows. Scrolling and context visibility share this alignment;
native diff does not reinterpret structural equivalence.
Ranges crossing an alignment filler are rejected. When Difftastic reports a
text fallback (unsupported language or analysis limits), that file uses Main
and its winbar explains the effective engine; Difftastic remains selected.
Engine requests prepare before replacing the view, cancel on owner changes,
and reject malformed output. Failure retains the previous view. Engine changes
are blocked while a composer is active. File presentation retains a synchronous
API with a bounded, event-pumping wait for uncached analysis.

Each new comment and reply captures `origin_engine = { id, version }` when its
composer opens, using the effective engine for that file. Main records
`builtin-v2` and the Neovim runtime version; Patience records `builtin-v1` and
Neovim; Difftastic records `0.71.0`; GumTree records its matcher/export contract
version alongside `4.0.0`.
Edits, resolution and reanchoring preserve this origin. Older comments show
`not recorded`. Markdown exports and recovery exports include the origin and
state that coordinates reference frozen original OLD/NEW sources. V1/v2 loads
are read-only projections; explicit saves migrate to v3 with an exact backup
and retain the original file. Scope identities and backend IDs do not change.

The host's `:ReviewStructuralDiff` (also in the Review palette) opens a separate
read-only float for the selected entry. Install its optional pinned Difftastic
0.71.0 backend explicitly with `:NvimConfigToolsInstall difftastic`. Startup and
opening a review never install or probe it. The float consumes colored human
output for private copies of the exact frozen OLD/NEW snapshots, including
their logical paths and modes; it never reads CURRENT source. `q` or `<Esc>`
closes it. Binary and metadata-only entries are refused. This auxiliary float has
no comment coordinates or LSP authority and is independent of engine selection.
Closing, replacing, refreshing, or tearing down the review cancels the render;
late completion cannot recreate a closed view. Process output is capped at
8 MiB, the deadline is 5 seconds, and snapshots are cleaned on every outcome.

Standalone hosts may inject an optional `structural_diff` adapter with
`run(request, callback) -> cancel_function`. The request contains a detached
`entry`, the float's integer `width`, and `background` (`dark` or `light`).
The callback receives `(colored_stdout, nil)` or `(nil, error)` at most once;
the plugin schedules UI handling and revalidates the owner before showing it.
The adapter owns process cancellation, temporary files, and cleanup. Without
this adapter, native review and its character detail remain fully available.
An optional `analyze({ entry }, callback) -> cancel_function` method supplies
raw single-file JSON for the integrated engine with the same bounded process
contract. Parsing and source-coordinate validation belong to the plugin.
`engines.list()`, `engines.origin(id)` and `engines.register(id, engine)` expose
the registry; registered engines provide `label`, `version` and a cancellable
`prepare(entry, callback)` operation. Engines never modify the canonical entry.
Prepared results explicitly declare `presentation = "native"|"projected"` and
`structural_only`; projected engines provide display projections/alignment,
line changes and intraline ranges. Textual display hunks remain separate from
canonical Git hunks. Optional `relations` use `kind = "move"|"identifier_update"`
and OLD/NEW ranges with one-based lines, zero-based byte columns and exclusive
ends. The presenter does not infer layout behavior from an engine ID.

Standalone hosts may inject `gumtree.analyze({ entry, trees = { old, new } },
callback) -> cancel_function`. It receives detached frozen metadata and exported
XML strings, returning raw GumTree JSON or an error. The adapter owns bounded
execution, cancellation and cleanup; the plugin validates action node signatures
against the exact exported trees and resolves destinations through `matches`.

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
  permissions. V1 and v2 stores are read without mass migration; v3 adds only
  optional per-item engine provenance, not workspace preferences.
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
optional diagnostic severity (default `INFO`) for Trouble. `description` is an
optional, printable, single-line UTF-8 explanation of at most 160 bytes for
the Markdown export's type legend. The list order is
the composer cycle order; ascending `rail_rank` sets sign-rail priority after
`issue` (rank 1). For example:

```lua
comment_types = {
  { id = "objection!", icon = "!", highlight = "NvimReviewCommentObjection",
    default_link = "Special", rail_rank = 2,
    description = "A concern that challenges an assumption." },
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

`:ReviewExport` includes a `Message type legend` with the descriptions of
configured types. Types found in saved comments but no longer configured are
listed as unconfigured, so the exported Markdown remains readable.

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
