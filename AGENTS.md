# Agent Instructions

## Commands

- There is no repo-local build script, lint script, test suite, Makefile, or GitHub Actions workflow in this checkout.
- Repo-level validation: `./bin/validate-config`
- Startup smoke check from the repo root: `nvim --headless "+quitall"`
- Formatting is configured inside Neovim through Conform, not a root-level CLI script:
  - Current buffer: `:FormatFile`
  - Toggle format-on-save globally: `:FormatToggle`
  - Toggle format-on-save for only the current buffer: `:FormatToggle!`
- There is no single-test command for this repository because no automated test runner is defined here.

## High-level architecture

- `init.lua` is the entrypoint. It sets global options, leader keys, PATH tweaks, shared autocommands/keymaps, then loads `lua/config/*` modules and bootstraps plugins through `lua/config/lazy.lua`.
- `lua/config/lazy.lua` bootstraps `lazy.nvim` and loads plugin specs from `lua/plugins/`. Most features are implemented as one plugin or feature group per file under that directory.
- Runtime behavior splits early on `vim.g.vscode`:
  - `lua/editor/vscode.lua` remaps the shared key vocabulary to VS Code actions.
  - `lua/editor/terminal.lua` defines the terminal-Neovim behavior and custom user commands.
  - Most UI-heavy plugins are disabled in VS Code with `cond = function() return not vim.g.vscode end`.
- LSP/tooling is centered in `lua/plugins/lsp.lua` plus `lua/config/devcontainer_tools.lua`:
  - Mason and mason-tool-installer ensure servers and external tools are present.
  - LSP servers are configured with native Neovim 0.11+ APIs (`vim.lsp.config` / `vim.lsp.enable`), not legacy `lspconfig.setup`.
  - `config.devcontainer_tools` injects wrapper binaries from `bin/` so `clangd`, `cmake`, and `ctest` can transparently run through `devcontainer exec` when editing containerized projects.
  - Container paths returned by tooling are mapped back to host paths before opening files.
- `lua/config/editor.lua` is the shared navigation primitive: it opens targets in tabs and reuses an existing tab if that file is already open. LSP jumps, Telescope selections, and the custom `gf` flow all rely on it.
- `lua/config/viewer_commands.lua`, `lua/config/lsp_commands.lua`, and related `lua/config/*` modules define the custom user commands that glue plugins together into the editing workflow.

## Key conventions

- Use `<space>` as `mapleader` and `maplocalleader`. New mappings should use `<leader>` prefix.
- Prefer adding or updating plugin behavior in `lua/plugins/<feature>.lua` instead of expanding `init.lua`. The repo is organized around small Lazy specs plus matching helper modules under `lua/config/`.
- When adding terminal-only functionality, guard it with the existing VS Code pattern: `cond = function() return not vim.g.vscode end`.
- For new LSP work, follow the current native Neovim approach in `lua/plugins/lsp.lua`; do not reintroduce `require("lspconfig").<server>.setup(...)`.
- If a feature shells out to `clangd`, `cmake`, or `ctest`, use `require("config.devcontainer_tools")` wrappers/helpers instead of calling raw binaries directly.
- When opening files from picker results, diagnostics, or tool output, route through `require("config.editor").open_file_in_tab(...)` so navigation keeps the repo's tab-based behavior.
- Formatting is intentionally opt-in for saves: Conform is installed, but `vim.g.conform_format_on_save` starts as `false`.
- Custom commands and helpers usually surface failures with `vim.notify(...)` instead of silently doing nothing; match that behavior when adding filetype- or tool-dependent commands.
