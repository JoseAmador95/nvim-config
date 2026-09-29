# Neovim configuration

This is a Neovim 0.12+ configuration with a full editor profile and a small
`nvimpager` profile. Neovim 0.12 is the real minimum because the locked
`nvim-treesitter` `main` branch requires it. Git is also required so
`lazy.nvim` can bootstrap on a fresh machine.

## Setup and optional features

Clone the repository as `~/.config/nvim` and start Neovim. Lazy restores locked
plugins; startup only registers a lightweight verified-tool command facade. The
tool lifecycle and its local plugin are loaded on the first runtime tool use or
explicit `:NvimConfigToolsInstall[!]` lifecycle request. Startup performs no
managed-tool planning, version probes, attestation, registry access, or network
work, and offline startup never consumes an attempt.

An existing `lazy.nvim` checkout is still validated fail-closed. After one
authoritative Git identity/status/hidden-index scan, startup may use a private
`0600` metadata attestation under a private `0700` cache directory. A fast hit
requires the locked resolved HEAD/ref material, index and shared-index set,
checkout root, and every non-`.git` entry to retain the same owner-controlled
identity. It reads the receipt first and validates its unique safe paths in two
bounded asynchronous `lstat` rounds around HEAD/ref inspection, without a
directory traversal; cached directory identities detect additions, removals,
and renames. A miss enumerates tracked, ignored, and untracked paths once before
Git authority and once afterward, then revalidates the accepted paths without
`readdir`. The only normalized exception is Neovim's safe regular `doc/tags`
file; unsafe metadata, corruption, ambiguity, or a race discards fast authority
and falls back to Git or fails startup without loading the checkout.

For a reproducible install or validation run, download the four pinned,
precompiled validators and restore the committed plugin/parser pins into an
isolated directory:

```sh
./scripts/install-ci-tools /absolute/path/to/nvim-config-tools/bin
./scripts/bootstrap-config --xdg-root /absolute/path/to/nvim-config-xdg
PATH=/absolute/path/to/nvim-config-tools/bin:$PATH \
  NVIM_CONFIG_XDG_ROOT=/absolute/path/to/nvim-config-xdg \
  ./scripts/check-config
```

`install-ci-tools` downloads official StyLua, ShellCheck, actionlint, and
tree-sitter assets, verifies their manifest SHA-256 values, and never builds
validators through a language package manager. The first two commands may use
the network on a cold machine.
Parser bootstrap requires the exact pinned `tree-sitter` CLI and a host `cc`;
`--skip-parsers` skips that preflight. The final gate is offline and never
mutates plugins, parsers, or the committed lock.

To reconcile the plugins, verified tools, Mason packages, and Tree-sitter
parsers in the current HOME runtime, request an owner-private schema-v1 report:

```sh
./scripts/provision-runtime --non-interactive \
  --report "$HOME/.local/state/nvim/provision-runtime.json"
```

That command is offline by default: it inventories and locally attests existing
state, but missing or stale components fail without consuming an installation
attempt. Add `--allow-network` to authorize downloads and repairs. Add
`--require-managed-tools` when every managed release must win through its
verified shim. The full interface is
`scripts/provision-runtime --non-interactive --report ABSOLUTE_PATH
[--require-managed-tools] [--allow-network]`; `--contract-version` prints `1`.

Provisioning uses only canonical paths below the caller's HOME, rejects HOME or
XDG roots under `/localdata`, secures its XDG/state directories as `0700`, and
writes the report atomically as `0600`. The report records deterministic
`status`, `changed`, bounded `error_codes`, Neovim/lock state, both runtime
profiles, Mason, and managed tools. It preserves the committed `lazy-lock.json`
and unrelated plugin, parser, and Mason extras. On Linux ARM64 the manifest has
no managed `markdown-preview` release asset, so provisioning reports
`unsupported-platform`; in particular, strict `--require-managed-tools` cannot
succeed there until a verified ARM64 asset is pinned.

Use `bootstrap-config` for a disposable isolated XDG tree, `provision-runtime`
for the caller's real private runtime, and `check-config` for the offline
non-mutating acceptance gate. `install-ci-tools` only prepares the four pinned
validators used by that gate.

Host-specific settings belong in `~/.nvim-local.lua`; create a documented
owner-only template with `:NvimConfigInit`. Plugin settings live exclusively
under `plugins.<plugin_name>`; `dap`, `ui`, `path`, `env`, and `plugins_dir` remain
host-level settings. The retired root names `theme`, `clangd`, `review`,
`log_watch`, `diagram_cache`, and `mason` are rejected rather than treated as
aliases. `:NvimConfigDump` recursively redacts environment values. For example,
native review hunk views show three unchanged lines on either side by default;
set `plugins = { native_review = { hunk_context = 0 } }` to change that
review-local context. Split view keeps one structural context line when
configured to zero so native old/new filler stays aligned.

Native review also bounds frozen-model construction to 2,000 changed entries,
4 MiB for each represented OLD or NEW side, and 64 MiB across all represented
sides. Hosts may change `max_files`, `max_file_bytes`, and `max_model_bytes`
under `plugins.native_review`; project configuration remains restricted to
`hunk_context`. Interactive open and refresh are cooperative scheduled jobs, so
newer operations, close, and teardown supersede stale completion while the old
review remains visible until its replacement is complete.

The native review plugin itself offers only `issue` by default. This editor
configuration adds `suggestion`, `objection!`, `question`, `pedantic`, and
`praise` through its host schema. Set `plugins.native_review.comment_types = {}`
in `~/.nvim-local.lua` for issue-only, or replace the list with your own type
definitions. Existing comments of removed types still load and display.

Log workbench limits also live in the host file under
`plugins.log_workbench`. `continuity_bytes`, `max_matches`, and
`scan_lines_per_tick` bound host-side verification and indexing work; project
configuration cannot replace them. A trusted project may only reduce
`max_lines` and `max_bytes` for its displayed log retention.

The terminal editor starts with `ui = { redraw_profile = "full" }`. Set
`redraw_profile = "low-bandwidth"` explicitly in the per-host file to reduce
redraw traffic; it is never inferred from SSH. Project-local `ui` is forbidden:
the complete project source is rejected before approval rather than partially
merged. VSCode Neovim and `nvimpager` always keep `full`.

Inline diagnostics are a separate host-only policy under
`ui.inline_diagnostics`: `current-line`, `settled-line`, or `off`. Without an
explicit override, a local full editor uses `current-line`, a full editor over
SSH uses `settled-line`, and low-bandwidth, VSCode, and pager profiles use
`off`. Settled mode renders only after `CursorHold`, clears when the row or
active view changes, and does not repaint for column-only cursor movement.

| Surface | `full` locally | `full` over SSH | `low-bandwidth` |
| --- | --- | --- | --- |
| Core UI | `cursorline`, `showmatch`, `scrolloff=10` | same full behavior | no cursor line/match flash, `scrolloff=0` |
| Diagnostics | current-line virtual lines by default | settled-line virtual lines by default | virtual lines off by default |
| Bufferline | diagnostics and hover enabled | diagnostics and hover disabled | diagnostics and hover disabled |
| Navic / Illuminate | immediate navic; Illuminate 100 ms with LSP, Tree-sitter, regex | same full behavior | lazy navic; Illuminate 300 ms with LSP only |
| Indent / context | indent scope on at 200 ms; Tree-sitter Context on | same full behavior | scope off at 500 ms; Tree-sitter Context off |
| Markdown | raw editable source; reading view on demand | same Markdown behavior | same Markdown behavior |
| Noice / Lualine | about 33 ms / 16 ms | 100 ms / 50 ms | 100 ms / 100 ms |

The choice is fixed at startup; restart Neovim after changing it. `full`
preserves the existing interactive behavior and remains the default.
The host file may tune the full-profile redraw costs independently with
`ui.full_refresh_ms`, `ui.noice_progress_throttle_ms`,
`ui.bufferline_diagnostics`, and `ui.bufferline_hover`; these options never
come from project-local configuration.

Ordinary yanks (`y`, `yy`, and visual yanks) also copy to the system clipboard.
Deletes and changes (`d`, `c`, `x`) only update Neovim's internal registers, so
the terminal's paste shortcut (`Cmd+V` on macOS) still inserts the last copied
text after further edits. `p` and `P` retain native register behavior, including
moving a line with `dd` then `p`. Explicit register prefixes keep their native
destination. Over SSH, clipboard copies use the bounded OSC 52 provider.

Two additional host-only bounds protect interactive work over slow terminals.
`clipboard.osc52_max_bytes` limits the exact raw payload sent through OSC 52
(1 MiB by default; copies are rejected, never truncated). `whitespace.max_bytes`
and `whitespace.max_lines` cap write-time trailing-space cleanup (4 MiB and
100,000 lines by default). Configure them in `~/.nvim-local.lua`; project-local
files cannot increase or replace these host policies. Cleanup also skips
Markdown-like formats, special/binary/hex buffers, and buffers with
`vim.b.trim_trailing_whitespace = false`.

The full-editor action palette offers palette-only commands to copy the current
file's absolute path, its lexical path relative to the originating window's
working directory (including `:lcd`), or its path relative to the nearest Git
root. Unnamed and special buffers hide all three; the Git-relative command is
also hidden outside a repository. The five most recently executed palette
actions stay pinned at the top for the current Neovim session. Configure or
disable that in `~/.nvim-local.lua` with
`plugins = { action_palette = { recent_limit = 5 } }` (`0..20`).

Markdown stays raw and editable in the full editor, including native review.
`:MarkdownView` or `<leader>mv` opens a focused, read-only reading view in a
new tab. The editable source stays in its original tab, and unsaved changes
update the render live. Invoke the command from the source to focus its existing
reading tab, or from the render to close it and return to the source. The page
is centered at 90% of the available width, capped at 120 columns. The
viewer uses the exact `md-render.nvim` v3.10.3 pin; automatic media is disabled,
so Mermaid and PlantUML fences stay code blocks and render only through
`:DiagramShow`/`<leader>md`. Fenced code shows its language above a shaded
block; the light theme uses a pale gray background. `<leader>mp` still opens
the browser preview.
Tables open expanded so their cells and bare URLs remain complete. Press `<CR>`
or `za` on a table to switch to its compact view; use `zh`/`zl` to read columns
when a table is wider than the reading page.
In `nvimpager`, Markdown renders automatically, and `<leader>mv` toggles back
to the original source. `:SetFileType` and the diagram viewer operate on that
source even while the reading view is displayed.
In the full terminal editor, buffer-local `gd` opens existing regular-file links
through the tab-aware editor adapter, sends headings, fragments, and reference
links to Marksman, and opens HTTP(S)/email targets through the host UI. Under
SSH, external targets are copied through the bounded clipboard adapter
instead of launching a remote browser. Plain Markdown text falls back to the
ordinary LSP/native definition path. This mapping is absent from `nvimpager`
and VSCode Neovim and remains fail-closed in historical review buffers.

Every local product exposes a strict setup contract plus copied `status()` and
`effective_config()` snapshots. `:checkhealth nvimconfig` aggregates those 17
surfaces without refreshing state, starting processes, installing tools, or
downloading parsers. Workflow commands remain in the host configuration rather
than inside the plugins.

Workspace execution is opt-in per canonical repository and capability. Use
`:NvimConfigExecutionAuthorize lint-format`, `test`, `build`, or `debug` to
grant one capability, `:NvimConfigExecutionRevoke <capability>` to revoke it,
and `:NvimConfigExecutionStatus [capability]` to inspect the durable state.
There is no implicit prompt: an unauthorized action stops before its runner is
started. Grants express trust in that repository; they are not a sandbox and do
not replace Just's stricter content-based closure checks. Tool installation and
network access remain separate, explicit decisions.

All 17 local plugin directories stay on `runtimepath`; none is registered as a
Lazy plugin. The startup-owned foundations are `trusted-workspace`, `tab-first`,
`treesitter-runtime`, and `theme-router` (VSCode and pager use their smaller
profile-specific subsets). Exact-editor loads only after a stable interactive
UI, and native-review plus the devcontainer, terminal, Python, action palette,
diagram, log, scratch, coverage, Just, clangd compile-database, and
verified-tools cores load only at their documented first-use boundary. Their
host commands and mappings remain available from startup through lightweight
adapters.

The debug UI defaults to `dap-ui`. Select the pinned `nvim-dap-view`
alternative with `dap = { ui = "dap-view" }` in local config, or for one
process with `NVIM_DAP_UI=dap-view nvim`. The selection is fixed at startup and
only the selected UI is loaded.

The versioned editor and pager theme remains VSCode. `:Theme catppuccin`
persists Catppuccin as a machine-local alternative; it follows the detected
terminal background with Latte in light mode and Mocha in dark mode.
`:Theme vscode` switches back, while `:ThemeReset` discards the local choice
and restores the current versioned default without persisting it; a private
migration marker prevents the retained legacy Lua choice from returning.
Focus, terminal-background option, and OSC response bursts share one 100 ms
refresh window; a durable reload wins over repaint when both are pending.

The effective executable order is deliberate:

1. core-owned verified shims;
2. directories in `local_config.path`, in declared order;
3. `~/.local/bin`;
4. inherited host `PATH` entries;
5. config-managed release binaries under the primary Neovim data root;
6. Mason's `bin` directory.

External candidates are probed only while planning an explicit install request,
before a managed claim. A compatible candidate from a non-bang request is
re-hashed while holding its identity, destination, and shim resources and
persisted as a private explicit
external certification. Runtime resolution reads only durable managed proof or
that certification: it never inspects `PATH`, runs a version process, or writes
state. Non-bundle authorities recheck canonical path and complete fingerprint
metadata without hashing executable contents. Active npm bundle resolution is
the deliberate exception: it rehashes the exact private closure and receipt on
every use. Drift asks for the same non-bang command to recertify.
`:NvimConfigToolsInstall! <name>` bypasses external probing and
selects managed installation/repair. Any managed record has precedence and an
unhealthy one fails closed without external fallback. `markdown-preview` is
managed-only because its host bridge is tied to the pinned release layout.
External executables and their path ancestors must be owned by root or the
effective user, and ancestor directories cannot be group/world-writable. An
unsafe private certification receipt must be inspected and removed manually, or
superseded with the explicit managed `!` action; it is never overwritten.
Older managed records without the complete metadata fingerprint require repair.
`:checkhealth nvimconfig` prints the effective origin and order.
External tools are optional unless their feature is used:

| Feature | Tools |
| --- | --- |
| Mermaid diagrams | `mmdflux` (`:NvimConfigToolsInstall mmdflux`); `rsvg-convert` from librsvg for image mode |
| PlantUML diagrams | `plantuml` (`:NvimConfigToolsInstall plantuml`); `rsvg-convert` for image mode |
| Rust language intelligence | Host/user `rust-analyzer`; managed and Mason paths are ignored |
| Dockerfile/Markdown lint | `hadolint` and `markdownlint-cli2`, managed by Mason |
| Inline diagram images | A terminal with the Kitty graphics protocol, such as Ghostty |
| Pager profile | `nvimpager` plus the config symlink below |
| Git terminal UI | Host `lazygit` |
| Container editor | An active verified `devcontainers-cli` bundle and project `devcontainer.json`; an explicit `:NvimConfigToolsInstall devcontainers-cli` (or `all`) resolves npm `latest`, bundles private Node 24.20.0, and activates it for offline runtime use. See [the focused workflow](docs/devcontainer-neovim.md) |
| Just recipes | Host `just`; it is never installed automatically |

`mmdflux`, PlantUML, release tools and exact Mason packages share
`:NvimConfigToolsInstall [all|name]`; append `!` for explicit repair or to
force the managed pin when a compatible external tool would otherwise be
certified. Repeating the non-bang command recertifies a changed compatible
external executable.
Naming one tool plans only that target; spelling `all` is the explicit aggregate
planning/install path. That explicit request also imports only the matching
legacy tool record; startup never scans the legacy catalog.
Each valid invocation owns a distinct persistent `Tools` spinner while its
items move through the shared host queue. Progress frames stay out of native
notification history; after every item in that invocation settles, the same
toast becomes one aggregate success or persistent failure summary. Existing
per-tool result notices remain available for detail, and overlapping requests
do not share progress state.
If an older Neovim owns unfinished verified-tools work, close that editor and
rerun the explicit install or repair from a fresh Neovim. A live or
unverifiable owner is never stolen, even with `!`; do not delete its state or
lock tickets manually.

Mason's UI is command-lazy and read-only: it stays outside normal file/LSP
startup, and its install, update and uninstall commands and mappings are
removed. Native `nvim-lspconfig` loads independently on file open;
`mason-lspconfig` remains dormant for compatibility checks and has no runtime
setup.
Release installs bind the verified source-archive SHA to hashes of every
promoted command/artifact. Mason validates its exact raw source version and
complete declared executable-link map, then binds them to a private `0600`
receipt and canonical launcher fingerprints. Before an already-succeeded record
is attested, the host compares it with the current immutable manifest; mismatch
selects explicit repair instead of attesting an obsolete plan.
Mason proof currently covers the receipt and canonical launcher targets, not a
launcher's transitive package tree or host interpreter. Node-loaded `dist` files
therefore remain a documented closure limit pending a versioned proof extension.
The current Mason identity digest also covers its complete immutable entry,
integrity, and executable maps. Older partial-digest records are retained as
recovery evidence but require an explicit current managed install/repair before
runtime use.

The managed backends and their host prerequisites are:

| Backend | Packages | Host prerequisite |
| --- | --- | --- |
| Prebuilt | clangd, Docker LS, lemminx, Lua LS, marksman, Ruff, Tombi, codelldb, hadolint, jq, ShellCheck, shfmt, StyLua, tree-sitter CLI | None |
| npm | Bash/JSON/TypeScript/YAML language servers, markdownlint-cli2, prettierd | `node` and `npm` |
| PyPI | ty, cmake-language-server, clang-format, debugpy | Python with `venv` |

The private npm-release bundle for `devcontainers-cli` scans eligible `curl`
and Python candidates in `PATH` order and executes only the first canonical
absolute path that passes authority validation. An unsafe Homebrew candidate
therefore cannot mask a later safe system executable, and is never executed.

Python language tooling is pinned to Ruff 0.16.6 and ty 0.0.77. Removing
Pyright from the manifest does not uninstall an existing Mason copy.

Rust remains fully editable even without language tooling. Its LSP activates
only for an external host/user `rust-analyzer`; formatting stays disabled until
`rustfmt` has an exact manifest contract instead of falling through to an
unverified PATH executable. `:checkhealth nvimconfig` explains the edit-only
state when the analyzer is absent. The ASM and PlantUML language servers are
intentionally absent. PlantUML rendering remains available through the
precompiled renderer above.

TOML language intelligence and formatting use the exact Mason pin Tombi 1.2.7.
The versioned user default in `tombi/config.toml` keeps schema strict mode off
and disables schema catalogs. Projects can opt in with a project-level
`tombi.toml`; an individual document can use a leading `#:schema` directive
followed by a blank line. Remote schema URLs are therefore fetched only when a
project or document names one explicitly.

The unified viewer is `:DiagramShow [svg|ascii]`. Rendering is asynchronous,
superseded work is cancelled, and content-addressed results are bounded under
`stdpath("cache")/diagram`. Missing tools are reported with install hints and
SVG mode falls back to ASCII when possible. In the image window, `+` (or `=`)
and `-` zoom between 100% and 800%; `0` fits the whole diagram. Move around the
enlarged image with `h`/`j`/`k`/`l` or the arrow keys. `y` copies the whole
diagram, and `q` or Escape closes the window. Zoom uses the full float as its
viewport while preserving the diagram's aspect ratio; an axis that still fits
stays centered. Zoomed views render from the
original diagram, preserving readable text; the previous view stays visible
while the new one renders. `:LogWatchCurrentFile` follows
files incrementally, preserves partial lines, survives rotation, and refuses
to overwrite unsaved buffer changes. Automatic log highlighting applies only
to the `log` filetype and `*.log`; ordinary `*.txt` files remain untouched.

The tab line uses the active colorscheme's `Visual` background (falling back to
`PmenuSel`) and bold text for the selected tab. Unmodified tabs have a native
per-tab X, while modified tabs show the modified marker in its place. The X,
middle click, `<leader>q`, and `:CloseTab` all route safely through `config.tabs`;
right click opens the hierarchical menu. Closing the final work tab preserves
user buffers, creates a pristine home tab, and opens the Snacks dashboard;
`<leader>Q` remains the explicit close-all flow.

## Native review

The full terminal editor has a native, repository-scoped review mode in one
dedicated transient tab. `:ReviewOpen` (or `<leader>ro`) first freezes a working,
commit, range, or default-branch scope, then opens or focuses that tab without
replacing the ordinary invocation buffer; `<leader>rr` opens and closes its
three-pane Files / Commits / Comments float. Selecting a file closes the float
and focuses the reviewed code. Its colored, fully expanded tree
groups only non-empty change layers, supports collapsible directories, and
shows status, line totals, rename origins, and comment counts. The Commits pane
can select one commit or two endpoints from one linear, single-parent span;
visual-selecting contiguous commit rows and pressing `Enter` reviews the whole
selected span without changing manually marked endpoints, while normal `Enter`
keeps using the current row or marked endpoints. `c` clears only those endpoints
and `b` returns to the exact frozen parent scope. Merge commits are reviewed
individually. The Comments pane supports jumping, editing, confirmed deletion,
replying, and resolving/reopening inside the same review tab; `a` adds a
review-level comment. `<leader>rR` provides the same review-level action from
review code buffers. Reanchoring remains available through
`:ReviewReanchor` and the command palette.

Review mode makes affected source buffers read-only only while its owned UI is
active and restores their prior state on release. `<leader>rv` switches between
one inline unified projection and a native synchronized side-by-side diff;
`<leader>rw` switches hunk-only and
full-file context; and `<leader>rg` focuses the reviewed code. Inline unchanged
context appears once, while each replacement places real OLD rows before real
NEW/CURRENT rows. Every code row is cursor-addressable in the owned review
window, and its `OLD │ NEW` gutter shows both source line numbers when available
without replacing fold or comment signs. Side-by-side remains Neovim's native
two-pane diff with both versions real and focusable. Jumping to an OLD or NEW
comment stays inline and moves directly to its projected row.

Both hunk views use the configured review-local context, add full-width gray
start/end bands, and name the enclosing function or class when its declaration
is hidden. In side-by-side mode, a size-changing hunk at the start or end of a
file omits only the boundary band that has no matching source row on both sides.
Leaving a visible section jumps directly to the adjacent one; full-file mode has
no artificial bands. Only real changed OLD/NEW rows use the theme's red/green
diff colors, while shared context and alignment-only split filler keep the normal
background. The statusline and review-local winbar identify REV ON/OFF, the
frozen scope, layer, layout/context, comment-preview state, source columns, and
path. The unified projection is LSP-blocked. Read-only navigation, hover, and
diagnostics are conservatively bridged from mapped NEW/CURRENT rows to the real
current source; OLD or otherwise unmappable rows remain unavailable, and
mutation operations are never proxied. An exact CURRENT pane in side-by-side
view retains its ordinary LSP behavior. In either layout, `gd` routes a selected
definition back into the owned review tab when its CURRENT path and line map to
one unambiguous frozen NEW entry, revealing hidden context in place. Definitions
outside the diff keep the normal CURRENT-file navigation path. Resolving `gd`
does not open an intermediate CURRENT tab, and delayed responses are discarded
if the source document, review generation, or a newer definition request wins.

`<leader>ra` comments the current line or visual range, `<leader>rA` comments the
file, and `<leader>rR` comments the review. A selection resolves to canonical
source path, side, and line coordinates; a range containing both OLD-exclusive
and NEW-exclusive rows is rejected instead of being partially anchored. Display
rows are never persisted. OLD comments can be created, edited, and jumped to
directly in inline view. File comments appear before file contents as virtual
`0 │ [OLD]` or `0 │ [NEW]` rows for their canonical path and change layer.
Multiline rails place one colored type badge at each anchor start;
continuation rows show only the guide and terminator. Same-type starts and
overlaps use compact counts (`2` through `9`, then `9+`) without losing the
per-type colors. Pausing on a commented range shows one concise inline row per
comment; `<leader>ri` toggles those previews without removing the rail. Only the
type badge is colored in previews and the Comments panel. By default a
line/range composer is one rounded card with a colored left rail and chunked
title/footer; it reserves its one-to-six-row body plus two chrome rows and
scrolls longer text. Host config may select `composer.style = "minimal"` to keep
the borderless body and separate footer while retaining the colored badge. File
and review-level comments, including edits and replies, use a centered rounded
modal capped at 88 by 18 rows without reserving source lines. New comments and
replies open in Insert mode; editing an existing comment opens in Normal mode.
Tab and Shift-Tab cycle types for new comments and edits only in Normal mode;
Insert-mode Tab is ordinary input and replies do not cycle. `<C-s>` saves
immediately. Enter then Enter within `timeoutlen` saves in Normal mode, while Esc
then Esc discards a non-empty draft. A physical Esc used to leave Insert counts
as the first Esc.
The transient title prompt is cancelled by any intervening key, text change,
focus/completion boundary, timeout, or teardown; `q` closes only an empty
composer. Confirmation uses a one-shot timer, never animation or periodic
redraw.

`:ReviewExport[!]` always renders the complete saved review and may be repeated;
it copies Markdown or opens a closable float when no clipboard is available. Its
header retains the frozen scope and exact revisions. Each item retains its
status, body, and reply structure plus only its file and line/range location with
`[OLD]` or `[NEW]`; review-level items use `REVIEW`. Export omits source snippets,
captured context, context hashes, and the internal change-layer value. Normal
export refuses working-tree drift, session drift, or stale anchors. The bang
form first writes and verifies an owner-only recovery; global drift labels the
saved snapshot stale, while anchor drift remains attached to the affected
comment.
Legacy bridge and delivery fields in existing review stores remain validated
and round-trip unchanged, but are inert: Neovim no longer links or publishes
review sessions. Ordinary `:DiffviewOpen` and `:DiffviewFileHistory` remain
independent raw Diffview workflows.

The review tab is leased through `tab-first.nvim` and titled
`Review: <repository> · <scope>`. Reopening a review, drilling into a commit, and
returning to its parent reuse and retitle the same live tab. `<leader>rm` off
prepares an open composer, releases all review UI, and returns to the latest
ordinary invocation while keeping the frozen review resumable; turning it on
acquires a fresh generation and rebuilds the view. Supported X, middle-click,
`<leader>q`, and `:CloseTab` paths can veto closure when a nonempty composer can
be neither saved nor verified through recovery. Raw `:tabclose` is reconciled
after best-effort composer recovery and never recreates the tab by itself.
`:ReviewClose` alone removes the logical review and retains its verified
unsaved-recovery/force rules.

Auto-session physically releases the review tab before serialization. A
successful explicit manual save may restore it afterward without stealing the
ordinary focus; automatic saves, failed saves, and exit never reacquire review
UI. Consequently no review-owned tab or transient review buffer is written into
a session file.

The review mappings use the lower-case `<leader>r` namespace: `rr` panel, `ro`
open, `rm` mode, `rs` scope, `rb` parent scope, `rf/rh/rl` panel panes, `rv`
layout, `rw` context, `ri` inline previews, `rg` code, `ra/rA` line-or-file
comments, `rR` review-level comment, `re` edit, `rc` type, `rd` delete, `rp`
reply, `rt` resolve, `rE` export, `ru` refresh, and `rq` close. `]r` and `[r`
navigate comments. Tests use `<leader>Tn` / `<leader>Td`, Python uses
`<leader>pr` / `<leader>ps`, and LSP rename uses `<leader>lr`.

Each interactive full editor also registers, by default 300 ms after `UIEnter`,
a private Unix RPC socket and an owner-only JSON record under the exact-editor
state root. Set `plugins.exact_editor.activation_delay_ms` to an integer from 0
through 5000 in `~/.nvim-local.lua` to tune that settling window. Calls are
coalesced, and exit cancels a pending activation. This keeps the core import,
socket setup, and Git discovery off the startup critical path; headless
validators are not editor targets. The root is
`$NVIM_EXACT_EDITOR_STATE_HOME`, otherwise `$XDG_STATE_HOME/exact-editor`, otherwise
`~/.local/state/exact-editor`; its `editors`, `requests`, `waits`, and `sockets`
directories are mode 0700 and JSON files are mode 0600. Registry roots update
only on `BufEnter` and `DirChanged`, and the editor removes its record and socket
on exit.

External tools may request an already-open file with:

```sh
~/.config/nvim/scripts/exact-editor-open \
  --cwd /absolute/repository \
  --file relative/or/absolute/file \
  --line 12 \
  --column 4
```

The helper prunes dead editor records and stale requests, retries a bounded
registration/socket window while preserving live records across transient probe
failures, then requires exactly one reachable editor registered for the target
repository. Its remote calls are headless and independent of whether the caller
has a TTY. It sends
only an opaque request UUID through a constant remote expression and validates
the request and path again inside Neovim before routing through the shared tab
opener. Zero or multiple matches are errors: it never starts plain Neovim and
never falls back to another editor.

Workspace routing is an all-or-none `{runtime, root, repo_identity}` triplet.
A complete CLI triplet overrides a complete
`NVIM_EXACT_EDITOR_{RUNTIME,WORKSPACE_ROOT,REPO_IDENTITY}` environment triplet;
without either, the helper derives the host Git workspace. Partial sources fail
before lookup and values from different sources are never combined. A Dev
Container editor requires the complete environment triplet with
`runtime=container`, including while migrating an older registry record.

The same helper has an explicit blocking mode for tools such as `gh` whose
temporary editor file lives outside the repository:

```sh
~/.config/nvim/scripts/exact-editor-open --wait-editor /absolute/temporary-file
```

This mode derives the repository used for editor selection from its working
directory, accepts one existing canonical regular non-symlink text file, and
waits outside Neovim on owner-only durable state. `--signal-ready` prints
`READY` only after Neovim has opened the file and armed its exact window/buffer
lifecycle. Writing alone does not finish the editor. Save and close the window,
delete an unmodified buffer, or use buffer-local `<leader>q` to write and close;
closing a modified window aborts the caller while preserving the buffer.

## Development workflows

`<leader>t` opens a host shell in a lower split. Shells, Python REPLs, LazyGit
and Just share one Snacks terminal
lifecycle keyed by runtime, repository and purpose. Hiding a terminal preserves
its process; a failed process keeps its output. Stop, restart and disposal wait
for the old job's actual exit before settling, and terminal input is rejected
while any of those transitions is pending. LazyGit uses a 95% float, while
shells, REPLs and recipe output use the lower split. `gf` on a contained
`file:line[:column]` location opens or reuses the corresponding editor tab.
Embedded LazyGit also sets a process-local `GH_EDITOR` to the blocking helper,
so `gh pr create` keeps its interactive questions in the LazyGit terminal while
its title/body file opens in the parent editor. LazyGit's ordinary `e` action
continues to use its `nvim-remote` preset.

Python projects automatically use a root-local environment when one exists.
Resolution is filesystem-only: `UV_PROJECT_ENVIRONMENT`, `.venv`, Pixi's
default environment, `venv`, `env`, `.conda`, and contained active virtual or
Conda environments are considered in that order. `:VenvSelect` remains the
manual override for cached or external environments. Explicit VSCode/neoconf
`ty.configuration.environment.python` settings take precedence, with the
existing VSCode/neoconf Python interpreter fields retained as a lower-priority
compatibility input, only after
`:NvimConfigTrustProjectSettings` approves the exact combined fingerprint of
`.vscode/settings.json` and `.neoconf.json`; any edit revokes their effect until
they are approved again. Selection never changes global `PATH`,
`VIRTUAL_ENV` or terminal activation. The effective interpreter for each root
is shared by ty, Neotest, DAP, the REPL and an event-refreshed statusline
cache. Statusline renders read cached labels only; project discovery, Git and
filesystem work run outside the render path. An attached ty root or the
nearest Python project marker takes precedence over an enclosing Git root, so
nested Python projects stay independent. `ty.toml` is the native marker;
`pyrightconfig.json` and `Pipfile` remain legacy root markers only and their
Pyright analysis settings are not translated to ty. Opening a PEP 723 script
never runs venv-selector's automatic `uv sync`; `:VenvSelect` remains manual.
Environment discovery is cached per project; use `:PythonEnvironmentRefresh`
after changing an environment on disk, or `:PythonEnvironmentClear` to discard
the manual selection and rediscover it.

`<leader>Tn` runs the nearest test, `<leader>Td` debugs it, `<leader>pr` toggles
the project REPL and `<leader>ps` opens or focuses that REPL before sending the
current line or visual selection. Sends are queued FIFO per project until the
terminal accepts input; a stopped/failed REPL or a bounded startup timeout
aborts the queue visibly instead of writing into a replacement or dead job.
Pytest is preferred when installed in that interpreter, with unittest as the
fallback; a live REPL asks before changing interpreter.

Coverage is import-only: `:CoverageLoad [path]` reads an existing
`coverage.json` or LCOV report, `:CoverageSummary` displays it and
`:CoverageClear` removes it. These commands never run tests or generate a
report. Host configuration may reduce the 16 MiB per-source and 64 MiB
aggregate-source/model bounds under `plugins.coverage_workbench`; canonical
duplicate sources, out-of-range sign lines, model expansion, and overlapping
executed/missing/excluded classifications fail closed.
CMake Tools keeps its selected build directory as clangd's
`--compile-commands-dir` for the same root without copying or linking
`compile_commands.json`; `:ClangdSetCompileCommands` remains the manual
override and `:ClangdSwitchSourceHeader` opens the paired source/header. CTest
is the project-wide C/C++ test action in the CMake menu; Neotest-GTest remains
for a focused associated test.

`:JustRun [recipe]` reads recipes from `just --dump --dump-format json` only
after the justfile content is trusted, prompts for structured parameters and
executes literal argv in the lower terminal. Flags use their long/short switches;
bounded and variadic options/positionals prompt repeatedly, required empty input
retries, repeated-flag counts accept decimal digits only, and dismissing any
prompt cancels without launching. The core rejects more than 4,096
recipe-supplied argv entries before materialization. `:JustImportLast`
conservatively imports contained `file:line[:column]` output into quickfix and
Trouble. The project/branch `:Scratch` (`<leader>.`) is private under
`stdpath("state")`, saved atomically and prunes only inactive files older than 30
days when opened.

`Alt-Space` in tmux exposes stable container/host editor actions. The container
action starts a detached coordinator for the dev session's exact single
`editor` pane through the active verified `devcontainers-cli` bundle;
agent/Git/LazyGit remain on the host. The coordinator holds an advisory lock,
the adapter waits for its unique `starting` claim, and the coordinator checks
pane PID/ownership before publishing `running`. Routing state is removed only
after a verified host-editor handoff and durable ACK. The spool secret stays
solely in its private `auth.json`; requests and ACKs carry HMACs instead of that
secret. Selecting the container action again verifies and focuses an already
live registered pane without restarting it. The tmux host action asks the live
coordinator through that authenticated spool, because the coordinator retains
the lifecycle lock until the container editor exits.
`:DevContainerUp[!]`, `:DevContainerRecreate[!]`, `:DevContainerStatus`,
`:DevContainerLog`, and `:DevContainerHostEditor` provide the editor surfaces.
Up/recreate keep one persistent, non-history spinner updated every 500 ms with
the current v6 lifecycle phase and elapsed time; the replacement container
editor requests an authenticated readiness ACK after its UI is ready and only
then publishes the one-shot success. `:DevContainerLog` opens or focuses one
live right-hand tail split; terminal lifecycle failures observed for the exact
claim open it automatically, while preflight or UI-monitor failures do not. The host-only
`plugins.devcontainer_editor.ui` policy controls progress, interval, width, and
failure auto-open behavior. Private sanitized logs retain at most 256 KiB;
legacy v2-v5 records remain readable and are never mass-rewritten.
On macOS with Podman Machine, SSH-agent forwarding does not change or disable
SELinux; enforcing state and the proxy's actual SELinux domain remain live
canary evidence. A private authenticated host Unix gate is reverse-forwarded
only to loopback TCP inside the pinned Machine, and the configured Dev
Containers remote user creates a private container-owned `SSH_AUTH_SOCK` Unix
proxy at a fresh unpredictable owner-only path for that lifecycle. The route
retries an early SSH forward failure on at most three distinct VM ports,
fully reaping each failed child before the next attempt. The route
requires a canonical user-owned host `SSH_AUTH_SOCK` plus host
`/usr/bin/ssh`; its complete canonical parent chain is identity- and
mode-attested, with one narrow `root:daemon` macOS launchd runtime exception.
The route also requires Machine `/bin/sh` and `/usr/bin/ss`, and a
host-networked target container with `/usr/bin/test`, an executable
`/usr/bin/python3` run with `-I -S`, `/bin/sh`, and `/usr/bin/ssh-add`; the Dev Containers CLI
must also expose the probed `up`, `exec`, and
`run-user-commands` options. Its fresh 256-bit lifecycle token is delivered
only over proxy stdin and never crosses loopback TCP; each connection uses a
fresh challenge plus domain-separated HMACs that authenticate both proxy and
gate. The
container is first selected with post-create commands deferred, then its full
ID, running state, exact `devcontainer.local_folder` and
`devcontainer.config_file` labels, host network, and agent path are verified
before lifecycle hooks run with that `SSH_AUTH_SOCK`; the protocol probe is
repeated after the hooks. The launchd socket is never a Podman bind source, no
agent volume is mounted, and no private key is copied. Record v6 pins the
Machine generation and later CLI calls use its exact SSH URI and identity
instead of following a changed default. OpenSSH resets `IdentityFile` to
`none` before adding that exact key, so a validation-to-exec disappearance
cannot fall back to user-default private keys. Its first host-key enrollment is
allowed only against a descriptor-proven empty private pin; all later relay
connections require that immutable pin, and learned keys are durably retained
even when the first SSH attempt fails. Compromise by the same host UID, root,
or the macOS daemon-group system principal remains inside the host trust
boundary. Reusing a compatible container does not require recreation solely
for agent forwarding.
`!` authorizes network-dependent managed tools in the container; without it
verified-tools remains `blocked/offline` and does not consume an attempt. See
[Neovim inside a Dev Container](docs/devcontainer-neovim.md) for lifecycle,
path mapping, structured `exec --`, authenticated spool, and security limits.

Enable the lightweight pager profile with:

```sh
ln -s ~/.config/nvim ~/.config/nvimpager
```

For Markdown piped on stdin, use
`NVIMPAGER_FILETYPE=markdown nvimpager`. Run `:checkhealth nvimconfig` to check
the Neovim version, required Git dependency, optional tools, pager symlink, and
legacy undo state.

## Validation and formatting

Run the complete local validation from the repository root:

```sh
./scripts/check-config
```

It first proves every installed plugin checkout matches `lazy-lock.json`, then
runs the pure and full-profile specs (including the provisioning contract),
startup smoke, StyLua, ShellCheck for the validation/provisioning scripts,
actionlint, the exact tree-sitter CLI, a host C compiler, and `git diff --check`.
Writable state, cache, temporary files, and logs are isolated. The check is
offline; only `bootstrap-config` restores plugins and parsers, while
`install-ci-tools` prepares the exact validator versions. Both preparation
commands may need network access on a cold cache.
GitHub Actions runs the same contract on Linux and macOS with Neovim 0.12.4 and
pinned validation tools.

Tree-sitter never installs parsers implicitly during startup. Install the
configured set explicitly with `:NvimConfigParsersInstall`; bootstrap uses the
same API and waits for completion. Dockerfile, Markdown, sh, and Bash lint only
on `BufWritePost`, never on read, create, or `InsertLeave`.

Formatting on save is intentionally disabled by default:

- `:FormatFile` formats the current buffer immediately.
- `:FormatToggle` changes the global format-on-save default.
- `:FormatToggle!` toggles an override for only the current buffer, independent
  of the global default.

All formatting entry points use external Conform formatters only. If none is
available, the editor warns and never falls back to an LSP formatter.

## State and reload behavior

Persistent undo now lives under `stdpath("state")/undo` with owner-only
permissions. The old repository-local `.undodir` is ignored but deliberately
not deleted because it may contain useful or sensitive history; inspect and
remove it manually when it is no longer needed.

`:ReloadConfig` performs a clean Neovim `:restart`. `:NvimConfigReload` only
refreshes the local-config cache; restart Neovim to apply all environment,
theme, and plugin changes.
