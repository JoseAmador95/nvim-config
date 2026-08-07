# Neovim configuration

This is a Neovim 0.12+ configuration with a full editor profile and a small
`nvimpager` profile. Neovim 0.12 is the real minimum because the locked
`nvim-treesitter` `main` branch requires it. Git is also required so
`lazy.nvim` can bootstrap on a fresh machine.

## Setup and optional features

Clone the repository as `~/.config/nvim`, start Neovim, and let Lazy/Mason
install the managed plugins and language tools. For a reproducible install or
validation run, prepare pinned validators and restore the committed plugin and
parser pins into an isolated directory:

```sh
./scripts/install-ci-tools /absolute/path/to/nvim-config-tools/bin
./scripts/bootstrap-config --xdg-root /absolute/path/to/nvim-config-xdg
PATH=/absolute/path/to/nvim-config-tools/bin:$PATH \
  NVIM_CONFIG_XDG_ROOT=/absolute/path/to/nvim-config-xdg \
  ./scripts/check-config
```

The first two commands may use the network on a cold machine. The final gate is
offline and never mutates plugins, parsers, or the committed lock.

Host-specific settings belong in `~/.nvim-local.lua`; create a documented
template with `:NvimConfigInit`. Put the Claude subscription credential under
`codecompanion.oauth_token`, not `env`, so only the pinned ACP child receives
it. `:NvimConfigDump` recursively redacts both that token and environment
values.

External tools are optional unless their feature is used:

| Feature | Tools |
| --- | --- |
| Mermaid diagrams | `mmdflux` (`:NvimConfigToolsInstall mmdflux`); `rsvg-convert` from librsvg for image mode |
| PlantUML diagrams | `plantuml`; `rsvg-convert` for image mode |
| PlantUML LSP | `:NvimConfigToolsInstall plantuml-lsp` (or `:PlantumlLspInstall`) |
| Dockerfile/Markdown lint | `hadolint` and `markdownlint-cli2`, managed by Mason |
| Inline diagram images | A terminal with the Kitty graphics protocol, such as Ghostty |
| Pager profile | `nvimpager` plus the config symlink below |
| Remote devcontainers | `devpod` and its container provider |
| GitHub PR/issue UI | Authenticated `gh` CLI |
| CodeCompanion Claude ACP | `npx`; first use downloads the pinned `@agentclientprotocol/claude-agent-acp@0.66.0` child |

The unified viewer is `:DiagramShow [svg|ascii]`. Rendering is asynchronous,
superseded work is cancelled, and content-addressed results are bounded under
`stdpath("cache")/diagram`. Missing tools are reported with install hints and
SVG mode falls back to ASCII when possible. `:LogWatchCurrentFile` follows
files incrementally, preserves partial lines, survives rotation, and refuses
to overwrite unsaved buffer changes.

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
actionlint, and `git diff --check`. Writable state, cache, temporary files, and
logs are isolated. The check is offline; only `bootstrap-config` restores
plugins and parsers, while `install-ci-tools` prepares the exact validator
versions. Both preparation commands may need network access on a cold cache.
GitHub Actions runs the same contract on Linux and macOS with Neovim 0.12.4 and
pinned validation tools.

Tree-sitter never installs parsers implicitly during startup. Install the
configured set explicitly with `:NvimConfigParsersInstall`; bootstrap uses the
same API and waits for completion. Lint runs once after opening an existing
Dockerfile/Markdown file and once per save, never on `InsertLeave`.

Formatting on save is intentionally disabled by default:

- `:FormatFile` formats the current buffer immediately.
- `:FormatToggle` changes the global format-on-save default.
- `:FormatToggle!` toggles an override for only the current buffer, independent
  of the global default.

## State and reload behavior

Persistent undo now lives under `stdpath("state")/undo` with owner-only
permissions. The old repository-local `.undodir` is ignored but deliberately
not deleted because it may contain useful or sensitive history; inspect and
remove it manually when it is no longer needed.

`:ReloadConfig` performs a clean Neovim `:restart`. `:NvimConfigReload` only
refreshes the local-config cache; restart Neovim to apply all environment,
theme, and plugin changes.
