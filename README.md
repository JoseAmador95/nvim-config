# Neovim configuration

This is a Neovim 0.12+ configuration with a full editor profile and a small
`nvimpager` profile. Neovim 0.12 is the real minimum because the locked
`nvim-treesitter` `main` branch requires it. Git is also required so
`lazy.nvim` can bootstrap on a fresh machine.

## Setup and optional features

Clone the repository as `~/.config/nvim` and start Neovim. Lazy restores locked
plugins; startup only plans and attests exact tool pins. Installation, retry and
repair are explicit through `:NvimConfigToolsInstall[!]`, and offline startup
never consumes an attempt.

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

Host-specific settings belong in `~/.nvim-local.lua`; create a documented
template with `:NvimConfigInit`. `:NvimConfigDump` recursively redacts
environment values. Native review hunk views show three unchanged lines on
either side by default; set `review = { hunk_context = 0 }` (or another
non-negative integer) to change that review-local context. Split view keeps one
structural context line when configured to zero so native old/new filler stays
aligned.

The debug UI defaults to `dap-ui`. Select the pinned `nvim-dap-view`
alternative with `dap = { ui = "dap-view" }` in local config, or for one
process with `NVIM_DAP_UI=dap-view nvim`. The selection is fixed at startup and
only the selected UI is loaded.

The versioned editor and pager theme remains VSCode. `:Theme catppuccin`
persists Catppuccin as a machine-local alternative; it follows the detected
terminal background with Latte in light mode and Mocha in dark mode.
`:Theme vscode` switches back, while `:ThemeReset` discards the local choice
and restores the versioned VSCode default.

The effective executable order is deliberate:

1. directories in `local_config.path`, in declared order;
2. `~/.local/bin`;
3. inherited host `PATH` entries;
4. config-managed release binaries under the primary Neovim data root;
5. Mason's `bin` directory.

This lets user/host tools win while the editor and `nvimpager` share the same
managed fallback. `:checkhealth nvimconfig` prints the effective origin and
order. External tools are optional unless their feature is used:

| Feature | Tools |
| --- | --- |
| Mermaid diagrams | `mmdflux` (`:NvimConfigToolsInstall mmdflux`); `rsvg-convert` from librsvg for image mode |
| PlantUML diagrams | `plantuml` (`:NvimConfigToolsInstall plantuml`); `rsvg-convert` for image mode |
| Rust language intelligence/formatting | Host/user `rust-analyzer` and `rustfmt`; managed and Mason paths are ignored |
| Dockerfile/Markdown lint | `hadolint` and `markdownlint-cli2`, managed by Mason |
| Inline diagram images | A terminal with the Kitty graphics protocol, such as Ghostty |
| Pager profile | `nvimpager` plus the config symlink below |
| Git terminal UI | Host `lazygit` |
| Container editor | An already-installed `@devcontainers/cli` and project `devcontainer.json`; see [the focused workflow](docs/devcontainer-neovim.md) |
| Just recipes | Host `just`; it is never installed automatically |

`mmdflux`, PlantUML, release tools and exact Mason packages share
`:NvimConfigToolsInstall [all|name]`; append `!` for explicit repair or to
install the managed pin when an external probe is incompatible. Mason's UI is
read-only: its install, update and uninstall commands and mappings are removed.
The managed backends and their host prerequisites are:

| Backend | Packages | Host prerequisite |
| --- | --- | --- |
| Prebuilt | clangd, Docker LS, lemminx, Lua LS, marksman, ruff, Tombi, codelldb, hadolint, jq, ShellCheck, shfmt, StyLua, tree-sitter CLI | None |
| npm | Bash/JSON/TypeScript/YAML language servers, pyright, markdownlint-cli2, prettierd | `node` and `npm` |
| PyPI | cmake-language-server, clang-format, debugpy | Python with `venv` |

Rust remains fully editable even without language tooling. Its LSP and formatter
activate only for external host/user `rust-analyzer` and `rustfmt` executables;
`:checkhealth nvimconfig` explains the edit-only state when they are absent. The
ASM and PlantUML language servers are intentionally absent. PlantUML rendering
remains available through the precompiled renderer above.

TOML language intelligence and formatting use the exact Mason pin Tombi 1.2.7.
The versioned user default in `tombi/config.toml` keeps schema strict mode off
and disables schema catalogs. Projects can opt in with a project-level
`tombi.toml`; an individual document can use a leading `#:schema` directive
followed by a blank line. Remote schema URLs are therefore fetched only when a
project or document names one explicitly.

The unified viewer is `:DiagramShow [svg|ascii]`. Rendering is asynchronous,
superseded work is cancelled, and content-addressed results are bounded under
`stdpath("cache")/diagram`. Missing tools are reported with install hints and
SVG mode falls back to ASCII when possible. `:LogWatchCurrentFile` follows
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

The full terminal editor has a native, repository-scoped review mode that stays
in the current ordinary tab. `:ReviewOpen` (or `<leader>ro`) freezes a working,
commit, range, or default-branch scope; `<leader>rr` opens and closes its
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
replying, and resolving/reopening without a separate review tab; `a` adds a
review-level comment. `<leader>rR` provides the same review-level action from
ordinary review buffers. Reanchoring remains available through
`:ReviewReanchor` and the command palette.

Review mode makes affected source buffers read-only and preserves their normal
tab identity. `<leader>rv` switches between one inline unified projection and a
native synchronized side-by-side diff; `<leader>rw` switches hunk-only and
full-file context; and `<leader>rg` focuses the reviewed code. Inline unchanged
context appears once, while each replacement places real OLD rows before real
NEW/CURRENT rows. Every code row is cursor-addressable in the ordinary review
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
view retains its ordinary LSP behavior.

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
comment; `<leader>ri` toggles those previews without removing the rail. A
line/range composer reserves a one-to-six-row borderless body plus a dedicated
instruction row directly below the source anchor and scrolls longer text. File
and review-level comments, including edits and replies, use a centered rounded
modal capped at 88 by 18 rows without reserving source lines. In Normal mode,
`<CR><CR>` saves through the same path as `<C-s>`.

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

The review mappings use the lower-case `<leader>r` namespace: `rr` panel, `ro`
open, `rm` mode, `rs` scope, `rb` parent scope, `rf/rh/rl` panel panes, `rv`
layout, `rw` context, `ri` inline previews, `rg` code, `ra/rA` line-or-file
comments, `rR` review-level comment, `re` edit, `rc` type, `rd` delete, `rp`
reply, `rt` resolve, `rE` export, `ru` refresh, and `rq` close. `]r` and `[r`
navigate comments. Tests use `<leader>Tn` / `<leader>Td`, Python uses
`<leader>pr` / `<leader>ps`, and LSP rename uses `<leader>lr`.

Each interactive full editor also registers, just after its UI enters, a private
Unix RPC socket and an owner-only JSON record under the exact-editor state root. This
keeps socket and Git discovery off the startup critical path; headless validators
are not editor targets. The root is
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
its process; a failed process keeps its output. LazyGit uses a 95% float, while
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
Python settings take precedence, and selection never changes global `PATH`,
`VIRTUAL_ENV` or terminal activation. The effective interpreter for each root
is shared by Pyright, Neotest, DAP, the REPL and statusline. An attached Pyright
root or the nearest Python project marker takes precedence over an enclosing Git
root, so nested Python projects stay independent. Opening a PEP 723 script never
runs venv-selector's automatic `uv sync`; `:VenvSelect` remains manual.
`<leader>Tn` runs the nearest test, `<leader>Td` debugs it, `<leader>pr` toggles
the project REPL and `<leader>ps` opens or focuses that REPL before sending the
current line or visual selection.
Pytest is preferred when installed in that interpreter, with unittest as the
fallback; a live REPL asks before changing interpreter.

Coverage is import-only: `:CoverageLoad [path]` reads an existing
`coverage.json` or LCOV report, `:CoverageSummary` displays it and
`:CoverageClear` removes it. These commands never run tests or generate a
report. CMake Tools keeps its selected build directory as clangd's
`--compile-commands-dir` for the same root without copying or linking
`compile_commands.json`; `:ClangdSetCompileCommands` remains the manual
override and `:ClangdSwitchSourceHeader` opens the paired source/header. CTest
is the project-wide C/C++ test action in the CMake menu; Neotest-GTest remains
for a focused associated test.

`:JustRun [recipe]` reads recipes from `just --dump --dump-format json` only
after the justfile content is trusted, prompts for structured parameters and
executes literal argv in the lower terminal. `:JustImportLast` conservatively
imports contained `file:line[:column]` output into quickfix and Trouble. The
project/branch `:Scratch` (`<leader>.`) is private under `stdpath("state")`,
saved atomically and prunes only inactive files older than 30 days when opened.

`Alt-Space` in tmux exposes stable container/host editor actions. The container
action replaces only the dev session's single `editor` pane through the
already-installed `@devcontainers/cli`; agent/Git/LazyGit remain on the host.
`:DevContainerUp[!]`, `:DevContainerRecreate[!]`, `:DevContainerStatus`,
`:DevContainerLog`, and `:DevContainerHostEditor` provide the editor surfaces.
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
runs the pure and full-profile specs, startup smoke, StyLua, ShellCheck,
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
