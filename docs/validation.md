# Validation matrix

`scripts/check-config` is the canonical offline gate. On a cold machine,
prepare its exact validators and restore the locked plugins/parsers first:

```sh
./scripts/install-ci-tools /absolute/path/to/nvim-config-tools/bin
./scripts/bootstrap-config --xdg-root /absolute/path/to/nvim-config-xdg
PATH=/absolute/path/to/nvim-config-tools/bin:$PATH \
  NVIM_CONFIG_XDG_ROOT=/absolute/path/to/nvim-config-xdg \
  ./scripts/check-config
```

`install-ci-tools` uses `curl` to fetch official precompiled StyLua, ShellCheck,
actionlint, and tree-sitter assets for Darwin/Linux on arm64/x86_64. Metadata
comes from `config.toolchain`; each archive is SHA-256 verified and atomically
promoted. It never runs Cargo, Go, or npm. Before any network restore,
`bootstrap-config` requires the exact pinned tree-sitter CLI and `cc` when
parsers are enabled; `--skip-parsers` does not require either. Bootstrap may
then use Git/network access to restore the editor, nvimpager, and stubbed
VSCode-Neovim plugin profiles and waits for the configured editor and pager
parsers. The final check disables installers, is offline, validates all four
validator pins plus `cc`, and fails if an installed plugin does not match the
lock.

The committed `lazy-lock.json` belongs to the full editor. The pager copies it
byte-for-byte to a profile-local state file before Lazy starts; Lazy may prune
that writable copy for the allowlist but can never rewrite the committed lock.
Bootstrap snapshots the source lock, fails if any profile changes it, and
checks every active pager checkout against the corresponding source-lock SHA.

## Runtime tool installation

At full-editor startup, each eligible managed-release or Mason `name@version`
is claimed exactly once in persistent state before installation starts. A
success, failure, interruption, or corrupt claim is never retried
automatically, which prevents repeated failure messages on shared hosts. The
manual command can reclaim an interrupted attempt only after its owning
process has exited; live or unverifiable owners remain locked. Set
`mason.auto_install = false` in local config to opt out. Manual retries are
explicit:

- `:NvimConfigToolsInstall [all|mmdflux|gofumpt|plantuml]` installs verified
  official precompiled releases; `!` installs the managed pin even when a host
  copy exists, without changing the host-first `PATH` precedence.
- `:MasonToolsInstallSync` retries the exact Mason manifest.

`PATH` precedence is `local_config.path` (declared order), `~/.local/bin`, the
inherited host path, managed release binaries, then Mason. The editor and pager
share the primary Neovim managed-tool root.

| Mason backend | Host dependency |
| --- | --- |
| Prebuilt | None to install; the prebuilt rust-analyzer still requires `cargo` at runtime |
| npm | `node` and `npm` |
| Go | `go` |
| PyPI | Python with working `venv` support |

Mason skips a pin whose required backend is unavailable; health reports the
blocked packages. `mmdflux`, `gofumpt`, and PlantUML use the separate prebuilt
release installer. ASM and PlantUML LSP support has been removed; PlantUML
diagram rendering is unchanged. CodeCompanion resolves an explicit
`codecompanion.acp_command` first, then a host `claude-agent-acp`, then pinned
`npx` with Node.js 22+.

| Area | Automated evidence | Manual evidence still required |
| --- | --- | --- |
| Terminal editor | Startup, argv lifecycle, commands, LSP config and plugin API contracts | Interactive completion and long editing sessions |
| nvimpager | Allowlist, source-lock SHA parity, parser set, argv/stdin filetype behavior, mappings and absence of editor-only services | Rendering in the real `nvimpager` executable |
| VSCode Neovim | Stubbed profile and action mappings; terminal-only commands/plugins stay absent | A live VS Code extension host |
| Tree-sitter | Installed/missing parser lifecycle, completion retry, large-file guard and textobject surfaces | Language-specific highlighting judgement |
| LSP | Server catalog, native neoconf disable/live-reload behavior, merge order, encoding conversion and clangd command construction | Connecting to every external language server |
| DAP | Adapter resolution and VSCode adapter aliases | Real Python, Go and C/C++ debug sessions |
| Lint/format | Filetype routing, open/save triggers and missing-tool behavior | Project-specific linter configuration |
| Diagrams | Scanner, renderer generations, atomic cache writes, corruption and pruning | Kitty image display, browser opening and visual layout |
| LogWatch | Append, partial lines, truncation, rotation, deletion/recreation and retention limits | Sustained observation of a high-volume production log |
| Remote/devcontainer | Command/config contract and dependency health | A real SSH or DevPod connection |

GitHub Actions runs the same bootstrap and check on `ubuntu-24.04` and
`macos-15`. Hosted success is delivery evidence only after the branch has been
pushed; a locally validated workflow is not itself proof that either hosted job
ran.
