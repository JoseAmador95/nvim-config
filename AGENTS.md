# Agent Instructions

## Commands

- There is no repo-local build script, lint script, test suite, Makefile, or GitHub Actions workflow in this checkout.
- Startup smoke check from the repo root: `nvim --headless "+quitall"`
- Formatting is configured inside Neovim through Conform, not a root-level CLI script:
  - Current buffer: `:FormatFile`
  - Toggle format-on-save globally: `:FormatToggle`
  - Toggle format-on-save for only the current buffer: `:FormatToggle!`
- There is no single-test command for this repository because no automated test runner is defined here.

## High-level architecture

- `init.lua` is the entrypoint. It sets global options, leader keys, PATH tweaks, shared autocommands/keymaps, then loads `lua/config/*` modules and bootstraps plugins through `lua/config/lazy.lua`.
- `lua/config/lazy.lua` bootstraps `lazy.nvim` and loads plugin specs from `lua/plugins/`. Most features are implemented as one plugin or feature group per file under that directory.
- There is a second "pager profile" for when nvimpager loads this config (the symlink `~/.config/nvimpager -> ~/.config/nvim` plus nvimpager's `NVIM_APPNAME=nvimpager`). `lua/config/pager.lua` detects it (`M.active = vim.env.NVIM_APPNAME == "nvimpager"`); when active, `lua/config/lazy.lua` loads only the allowlist from `pager.specs()` (theme, snacks, noice, blink, render-markdown, mermaid-nvim, a slim treesitter with just `M.parsers`, devicons) instead of `{ import = "plugins" }`. This keeps Mason/LSP/completion and the rest of the plugins from ever loading. `pager.setup()` (called from `init.lua`) is a no-op outside nvimpager; inside it: frees nvimpager's `j/k/<Up>/<Down>` scroll maps so they move the cursor, and adds a pager-only `:SetFileType`/`<leader>ft` picker that strips ANSI escapes (from `gh`, git, ...) before applying the filetype so rendering isn't corrupted. Markdown of file arguments renders via filetype detection; piped stdin can be forced with `NVIMPAGER_FILETYPE=markdown` (handled in the `VimEnter` re-emit in `lua/config/lazy.lua`). Keymaps that need absent plugins are gated on `not require("config.pager").active` (e.g. `<leader><leader>` → menu in `viewer_commands.lua`).
- Diagrams (mermaid + PlantUML) are NOT rendered inline; a ```mermaid/```plantuml block shows as a normal render-markdown code block. They are viewed on demand in a floating window via the unified `lua/config/diagram.lua` (`:DiagramShow [svg|ascii]`, default svg; registered in `M.setup()` from `init.lua`; skipped in VS Code). Keymap `<leader>md` is buffer-local to markdown/plantuml in the editor, but **global in the pager** (`pager.active`) so it works on any viewed content; `<leader>mr` (`:MarkdownRender`) is likewise global in the pager. `<leader>mp` (markdown-preview.nvim) stays editor-only since that plugin isn't in the pager allowlist.
  - **Detection**: `detect()` finds the block under the cursor (mermaid/plantuml/puml/uml) via the shared scanner `lua/config/diagram_blocks.lua`; a `plantuml` filetype (or any non-markdown buffer) uses the whole buffer.
  - **svg mode** (image in a centered float scaled to fit; `q`/`<Esc>` closes): mermaid = `mmdflux -f svg` → `rsvg-convert -f png`; plantuml = `plantuml -tpng`. The PNG is shown via `Snacks.image.placement.new(scratch_buf, png, { inline, max_width, max_height })`. Chromium-free and ImageMagick-free (a PNG source skips Snacks' ImageMagick step). Needs `image = { enabled = true, doc = { enabled = false } }` in `lua/plugins/snacks.lua` and a Kitty-graphics terminal (Ghostty). PNGs cached by hash under `stdpath("cache")/diagram`.
  - **ascii mode** (text in a float): mermaid = `mmdflux`; plantuml = `plantuml -ttxt`. svg **falls back to ascii** when `Snacks.image.supports_terminal()` is false or an svg dependency is missing.
  - **Missing dependencies are announced** via `vim.notify` with the install command (`cargo install mmdflux`, `brew install librsvg`, `brew install plantuml`) — nothing fails silently. Works in the editor and the pager.
  - **Render toggle (`<leader>mr`)**: `:MarkdownRender` (toggles render-markdown), in `lua/config/viewer_commands.lua`.
  - **Browser, one block**: `:MermaidPreview` (`lua/config/mermaid_preview.lua`, reuses `diagram_blocks`). Whole-doc browser: `<leader>mp` (markdown-preview.nvim, editor only). PlantUML also keeps `:PlantumlAscii` (vsplit) and `:PlantumlPreview` (browser).
  - `searleser97/mermaid-nvim` is kept but loads only on demand (`cmd`, not `ft`): its `build` installs/updates `mmdflux`. It no longer renders on open.
- Runtime behavior splits early on `vim.g.vscode`:
  - `lua/editor/vscode.lua` remaps the shared key vocabulary to VS Code actions.
  - `lua/editor/terminal.lua` defines the terminal-Neovim behavior and custom user commands.
  - Most UI-heavy plugins are disabled in VS Code with `cond = function() return not vim.g.vscode end`.
- LSP/tooling is centered in `lua/plugins/lsp.lua` plus `lua/config/devcontainer_tools.lua`:
  - Mason and mason-tool-installer ensure servers and external tools are present.
  - LSP servers are configured with native Neovim 0.11+ APIs (`vim.lsp.config` / `vim.lsp.enable`), not legacy `lspconfig.setup`.
  - `config.devcontainer_tools` injects wrapper binaries from `bin/` so `clangd`, `cmake`, and `ctest` can transparently run through `devcontainer exec` when editing containerized projects.
  - Container paths returned by tooling are mapped back to host paths before opening files.
- `lua/config/editor.lua` is the shared navigation primitive: it opens targets in tabs and reuses an existing tab if that file is already open. LSP jumps, snacks.picker selections (via the custom `open_in_tab` confirm action in `lua/plugins/snacks.lua`), and the custom `gf` flow all rely on it.
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
