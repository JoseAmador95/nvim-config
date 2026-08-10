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
promoted. It never builds validators through a language package manager.
Before any network restore, `bootstrap-config` requires the exact pinned
tree-sitter CLI and `cc` when parsers are enabled; `--skip-parsers` does not
require either. Bootstrap may then use Git/network access to restore the
editor, nvimpager, and stubbed VSCode-Neovim plugin profiles and waits for the
configured editor and pager parsers. The final check disables installers, is
offline, validates all four validator pins plus `cc`, and fails if an installed
plugin does not match the lock.

The committed `lazy-lock.json` belongs to the full editor. The pager copies it
byte-for-byte to a profile-local state file before Lazy starts; Lazy may prune
that writable copy for the allowlist but can never rewrite the committed lock.
Bootstrap snapshots the source lock, fails if any profile changes it, and
checks every active pager checkout against the corresponding source-lock SHA.
Both bootstrap and the offline gate isolate `XDG_CONFIG_HOME`, so a persisted
`:Theme` choice on the host cannot change their versioned-default assertions.

## Runtime tool installation

At full-editor startup, each eligible managed-release or Mason `name@version`
is claimed exactly once in persistent state before installation starts. A
success, failure, interruption, or corrupt claim is never retried
automatically, which prevents repeated failure messages on shared hosts. The
manual command can reclaim an interrupted attempt only after its owning
process has exited; live or unverifiable owners remain locked. Set
`mason.auto_install = false` in local config to opt out. Manual retries are
explicit:

- `:NvimConfigToolsInstall [all|mmdflux|plantuml]` installs verified
  official precompiled releases; `!` installs the managed pin even when a host
  copy exists, without changing the host-first `PATH` precedence.
- `:MasonToolsInstallSync` retries the exact Mason manifest.

`PATH` precedence is `local_config.path` (declared order), `~/.local/bin`, the
inherited host path, managed release binaries, then Mason. The editor and pager
share the primary Neovim managed-tool root.

| Mason backend | Host dependency |
| --- | --- |
| Prebuilt | None |
| npm | `node` and `npm` |
| PyPI | Python with working `venv` support |

Mason skips a pin whose required backend is unavailable; health reports the
blocked packages. `mmdflux` and PlantUML use the separate prebuilt release
installer. Rust language intelligence and formatting accept only host/user
`rust-analyzer` and `rustfmt`, never managed or Mason paths; missing tools leave
Rust edit-only and are explained by health. ASM and PlantUML LSP support has
been removed; PlantUML diagram rendering is unchanged.

| Area | Automated evidence | Manual evidence still required |
| --- | --- | --- |
| Terminal editor | Startup, argv lifecycle, commands, LSP config and plugin API contracts | Interactive completion and long editing sessions |
| nvimpager | Allowlist, source-lock SHA parity, parser set, argv/stdin filetype behavior, mappings and absence of editor-only services | Rendering in the real `nvimpager` executable |
| VSCode Neovim | Stubbed profile and action mappings; terminal-only commands/plugins stay absent | A live VS Code extension host |
| Themes | VSCode default, Catppuccin Latte/Mocha switching, local persistence, editor/pager availability and VSCode exclusion | Visual judgement in the real terminal and pager |
| Tree-sitter | Installed/missing parser lifecycle, completion retry, large-file guard and textobject surfaces | Language-specific highlighting judgement |
| LSP | Server catalog, native neoconf disable/live-reload behavior, merge order, single/multiple-result tab navigation and clangd command construction | Connecting to every external language server |
| DAP | Adapter resolution, VSCode aliases, exclusive UI selection, lifecycle, views and tab-aware fixture navigation | Real adapter behavior and interactive UI judgement |
| Lint/format | Save-only lint routing, formatter chains, no-LSP fallback and missing-tool behavior | Project-specific linter configuration |
| Diagrams | Scanner, renderer generations, atomic cache writes, corruption and pruning | Kitty image display, browser opening and visual layout |
| LogWatch | Append, partial lines, truncation, rotation, deletion/recreation and retention limits | Sustained observation of a high-volume production log |
| DevPod editor | Launcher/RPC schemas, argv transport, path containment, private state, provider/config identity and Git mutation fingerprints | A real Podman workspace, image lifecycle hooks and bidirectional SSH forwarding |

GitHub Actions runs the same bootstrap and check on `ubuntu-24.04` and
`macos-15`. Hosted success is delivery evidence only after the branch has been
pushed; a locally validated workflow is not itself proof that either hosted job
ran.
