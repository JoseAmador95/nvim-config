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

## Runtime provisioning contract

`scripts/provision-runtime` reconciles the caller's current private runtime;
unlike `bootstrap-config`, it does not create a disposable validation tree, and
unlike `check-config`, it may mutate runtime state only when explicitly allowed:

```sh
scripts/provision-runtime --non-interactive --report ABSOLUTE_PATH \
  [--require-managed-tools] [--allow-network]
```

The default is offline. It inventories locked Lazy checkouts, verified release
and Mason identities, and exact Tree-sitter revisions, and locally attests
existing successful tool records. Missing, stale, drifted, or failed state is
reported without a registry refresh, download, retry, repair, or consumed
attempt. `--allow-network` is the sole authorization to restore or repair that
state. `--require-managed-tools` additionally rejects effective managed tools
that do not resolve through their verified managed result.

The report contract is version 1 (`--contract-version` prints `1`). Its
deterministic JSON contains `schema_version`, `status`, `changed`, bounded and
sorted `error_codes`, `nvim`, `lock`, editor/nvimpager plugin and parser
inventories, `mason`, and `managed_tools`. Publication is atomic with mode
`0600`; plugin, parser, and Mason extras are retained, and the source
`lazy-lock.json` must remain byte-identical.

Provisioning rejects a non-canonical HOME, HOME under `/localdata`, XDG roots
outside HOME, unsafe report parents/targets, and concurrent or stale lock state.
Its HOME-contained XDG and state directories are secured as `0700`; the report
must also live below HOME. Linux ARM64 currently has no pinned managed
`markdown-preview` asset, so that identity reports `unsupported-platform` and a
strict `--require-managed-tools` run cannot succeed on that target.

`install-ci-tools` remains only the pinned-validator installer;
`bootstrap-config` remains the network-capable isolated plugin/parser bootstrap;
and `check-config` remains the complete offline, non-mutating acceptance gate.

## Runtime tool installation

Full-editor startup registers only a lightweight command facade; the
verified-tool lifecycle and local plugin remain unloaded until the first
explicit install or repair request. Neither startup nor Mason readiness plans,
probes versions, attests, or accesses the registry/network. An explicit named
install plans only that target, while `all` is the explicit aggregate path.
The same explicit request imports only that tool's legacy record before it is
claimed; startup never scans the legacy catalog.
Explicit work is claimed once in persistent state; a failure, interruption, or
corrupt claim is never retried automatically. A manual repair can reclaim an
interrupted attempt only after its owner exits; live or unverifiable owners
remain locked.

- `:NvimConfigToolsInstall [all|name]` installs or retries the exact release or
  Mason identity. `!` explicitly selects the managed strategy when a compatible
  external candidate exists; failed, drifted, cancelled and interrupted state
  still uses the core's explicit retry/repair claim mode.

Mason's UI is inspection-only: install, update, uninstall and registry-refresh
commands and mappings are disabled.

`PATH` precedence is verified shims, `local_config.path` (declared order),
`~/.local/bin`, the inherited host path, managed release binaries, then Mason.
The editor and pager share the primary Neovim managed-tool root. Release proof
binds the verified archive to every promoted content hash. Mason proof binds the
exact raw source version and full link map to a normalized private `0600`
receipt. Health receipt inspection and explicit attestation are local-only and
never refresh the registry. Attestation of an existing successful identity
occurs only on an explicit install/repair request.

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

Python language tooling uses the exact Ruff 0.16.6 prebuilt pin and ty 0.0.77
through the PyPI backend. The Python fixtures prove that approved interpreter
or environment input is published once for ty, Neotest, DAP, and the REPL;
that ty settings are mutated without replacing the effective LSP settings
table; and that environment changes restart only exact-root ty clients.

| Area | Automated evidence | Manual evidence still required |
| --- | --- | --- |
| Terminal editor | Startup, argv lifecycle, commands, LSP config, plugin API contracts, and cache-only statusline render sentinel | Interactive completion and long editing sessions |
| Redraw profiles | Schema/default, host/project trust boundary, full/low functional matrix, explicit SSH non-selection, and pager/VSCode full-profile guards | Subjective latency and bandwidth on a real remote terminal |
| nvimpager | Allowlist, source-lock SHA parity, parser set, argv/stdin filetype behavior, mappings and absence of editor-only services | Rendering in the real `nvimpager` executable |
| VSCode Neovim | Stubbed profile and action mappings; terminal-only commands/plugins stay absent | A live VS Code extension host |
| Themes | VSCode default, Catppuccin Latte/Mocha switching, local persistence, editor/pager availability and VSCode exclusion | Visual judgement in the real terminal and pager |
| Runtime provisioning | CLI/schema v1, offline authorization boundary, private HOME/XDG/report paths, atomic `0600` reports, exact inventories, lock immutability, extras preservation and idempotence | Network downloads on every supported OS/architecture and recovery from a deliberately stale operator lock |
| Tree-sitter | Installed/missing parser lifecycle, completion retry, large-file guard and textobject surfaces | Language-specific highlighting judgement |
| LSP | Server catalog, bounded JSONC/fingerprint approval for project settings, mutation revocation, merge order, profile isolation, single/multiple-result tab navigation and clangd command construction | Connecting to every external language server |
| DAP | Adapter resolution, VSCode aliases, exclusive UI selection, lifecycle, views and tab-aware fixture navigation | Real adapter behavior and interactive UI judgement |
| Lint/format | Save-only lint routing, formatter chains, no-LSP fallback and missing-tool behavior | Project-specific linter configuration |
| Diagrams | Scanner, renderer generations, atomic cache writes, corruption and pruning | Kitty image display, browser opening and visual layout |
| LogWatch | Append, partial lines, truncation, rotation, deletion/recreation and retention limits | Sustained observation of a high-volume production log |
| Dev Container editor | CLI/spool schemas and HMAC vector, no-clobber/filename binding, explicit pane/claim argv, detached claim handshake/timeout, checked respawn/quick-exit/handoff and ACK failure, private auth state, real flock contention/stale inode reuse, mount injection, offline propagation and absence-only fallback | A real Dev Container runtime, image lifecycle hooks and host SSH-agent forwarding |

GitHub Actions runs the same bootstrap and check on `ubuntu-24.04` and
`macos-15`. Hosted success is delivery evidence only after the branch has been
pushed; a locally validated workflow is not itself proof that either hosted job
ran.
