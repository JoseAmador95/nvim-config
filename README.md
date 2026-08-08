# Neovim configuration

This is a Neovim 0.12+ configuration with a full editor profile and a small
`nvimpager` profile. Neovim 0.12 is the real minimum because the locked
`nvim-treesitter` `main` branch requires it. Git is also required so
`lazy.nvim` can bootstrap on a fresh machine.

## Setup and optional features

Clone the repository as `~/.config/nvim` and start Neovim. Lazy restores locked
plugins; the full terminal profile then considers every eligible exact tool pin
once. A persistent `name@version` record is created before an automatic
attempt, so a failed package-manager install is not retried or announced on
every startup. Use `mason = { auto_install = false }` in `~/.nvim-local.lua` to
disable automatic attempts entirely.

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
environment values.

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
| Devcontainer shell | `devcontainer` CLI and ToggleTerm; see [the focused workflow](docs/devcontainer-shell.md) |

`mmdflux` and PlantUML are installed from pinned official precompiled releases
with `:NvimConfigToolsInstall [all|mmdflux|plantuml]`;
append `!` to install the managed pin even when an external executable exists
(the host-first `PATH` order is unchanged). Retry exact
Mason pins explicitly with `:MasonToolsInstallSync`. Mason's install backends
and their host prerequisites are:

| Backend | Packages | Host prerequisite |
| --- | --- | --- |
| Prebuilt | clangd, Docker LS, lemminx, Lua LS, marksman, ruff, taplo, codelldb, hadolint, jq, ShellCheck, shfmt, StyLua, tree-sitter CLI | None |
| npm | Bash/JSON/TypeScript/YAML language servers, pyright, markdownlint-cli2, prettierd | `node` and `npm` |
| PyPI | cmake-language-server, clang-format, debugpy | Python with `venv` |

Rust remains fully editable even without language tooling. Its LSP and formatter
activate only for external host/user `rust-analyzer` and `rustfmt` executables;
`:checkhealth nvimconfig` explains the edit-only state when they are absent. The
ASM and PlantUML language servers are intentionally absent. PlantUML rendering
remains available through the precompiled renderer above.

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
