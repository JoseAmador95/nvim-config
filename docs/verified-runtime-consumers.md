# Mise runtime consumers

`config.tool_bootstrap.resolve(tool, command)` returns an absolute launcher in
`~/.local/share/mise/nvim-bin`. The launcher executes the repository's
`scripts/mise exec <tool> -- <command>` with the original argv, stdin and cwd.
Mise selects the committed catalog and may install a missing tool on first use.
`NVIM_CONFIG_OFFLINE=1` prevents downloads and rejects absent tools.

| Consumer | Process boundary |
| --- | --- |
| Native LSP / clangd | Resolve at root activation and immediately before native RPC startup; the compile-database router retains its selected database and override policy. |
| Conform / nvim-lint | Resolve the command when the formatter or copied linter definition executes. |
| DAP | Resolve debugpy or codelldb after the durable debug grant. Project Python remains the debug target. |
| Diagrams / review | Resolve mmdflux, PlantUML or Difftastic before the cancellable bounded pipeline. GumTree is absent. |
| JQX / JsonTree | Resolve jq and pass buffer content through stdin with argv-based execution. |
| Dev Containers | Resolve the fixed CLI 0.89.0 and its managed Node runtime. |
| Markdown Preview | Bridge upstream's app/bin path to the catalog launcher. No npm build or host Node fallback. |
| Parser installation | Resolve tree-sitter only for the explicit parser installation action. |

Module discovery does not install or probe tools. Opening a buffer with an LSP
is a tool use. Missing Mise gives a diagnostic naming `:NvimConfigMiseInstall`;
startup and provisioning never invoke that command themselves. A cold download
can exceed a consumer's unchanged timeout: preinstall with
`:NvimConfigToolsInstall <name>` and retry.

Artifact verification belongs to Mise at installation time. Runtime does not
rehash binaries or maintain separate certifications. Project configuration
approval and workspace execution grants remain independent authorities. A clangd
absolute override must still match the selected launcher; project configuration
cannot redirect the managed executable.

Rust remains host/user-only, excluding Mise and retired managed/Mason/shim roots.
CMake/CTest, `rsvg-convert`, clipboard helpers and platform utilities remain host facilities.
On macOS x64, the pinned PlantUML JAR uses host Java. The selected Python project
environment remains separate from the managed Python used by tooling.
