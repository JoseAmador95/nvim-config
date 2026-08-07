# Neovim configuration

This is a Neovim 0.12+ configuration with a full editor profile and a small
`nvimpager` profile. Neovim 0.12 is the real minimum because the locked
`nvim-treesitter` `main` branch requires it. Git is also required so
`lazy.nvim` can bootstrap on a fresh machine.

## Setup and optional features

Clone the repository as `~/.config/nvim`, start Neovim, and let Lazy/Mason
install the managed plugins and language tools. Host-specific settings belong
in `~/.nvim-local.lua`; create a documented template with `:NvimConfigInit`.

External tools are optional unless their feature is used:

| Feature | Tools |
| --- | --- |
| Mermaid diagrams | `mmdflux` (`cargo install mmdflux`); `rsvg-convert` from librsvg for image mode |
| PlantUML diagrams | `plantuml`; `rsvg-convert` for image mode |
| Inline diagram images | A terminal with the Kitty graphics protocol, such as Ghostty |
| Pager profile | `nvimpager` plus the config symlink below |
| Remote devcontainers | `devpod` and its container provider |
| GitHub PR/issue UI | Authenticated `gh` CLI |

The unified viewer is `:DiagramShow [svg|ascii]`. Missing diagram tools are
reported with install hints and SVG mode falls back to ASCII when possible.

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

It runs six focused headless tests, a full startup smoke check, StyLua,
ShellCheck, and `git diff --check`. Writable state, cache, temporary files, and
logs are isolated in a temporary directory and removed afterward. Existing
locked Lazy/Mason installations are reused as dependency inputs.

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
