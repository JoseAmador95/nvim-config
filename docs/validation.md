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

The engine screen-geometry spec uses `-c 'lua dofile(...)'` so Neovim has
initialized its screen before the test changes `lines` and `columns`. Running
that spec with `-l` can leave the headless grid at its old dimensions and crash
redraw in Neovim 0.12.5. Its redraw, scrolling and cursor assertions remain active.

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

GumTree uses the separate `maven-release` backend. Explicit
`:NvimConfigToolsInstall[!] gumtree` installs the fixed GumTree 4.0.0 JAR closure
and private Temurin JRE 17.0.20.1+1 together. Every download has an exact SHA-256;
the private receipt binds the source contract and complete installed closure,
including the launcher and JRE. Repair atomically replaces the payload and
receipt; an incomplete transaction cannot resolve. Only trusted `curl` and
`gzip` are installation prerequisites. Host Java, Maven and Gradle are unused.
The offline gate covers archive confinement, offline attempt preservation,
tampered JAR/JRE/launcher rejection, repair and cancellation. The optional real
package smoke requires an explicitly installed package and is separate from the
offline suite.

Full-editor startup registers only a lightweight command facade; the
verified-tool lifecycle and local plugin remain unloaded until the first
explicit install or repair request. Neither startup nor Mason readiness plans,
probes versions, attests, or accesses the registry/network. An explicit named
install plans only that target, while `all` is the explicit aggregate path.
The host queue bounds complete discovery-to-activation chains to two per
Neovim process and serializes chains sharing the managed release or Mason root;
verified-tools separately enforces its two global backend mutation slots and
cross-process resource locks.
Every valid named or `all` invocation has request-local progress and completion
accounting layered around that queue. When Snacks is already available, one
persistent non-history spinner uses a distinct ID for the invocation; no visual
backend is loaded just to show it. The timer stops only after all of that
request's guarded item callbacks settle, then one normal history-bearing
aggregate notification replaces the same ID (three-second success, persistent
warning on any failure). Per-tool result notifications are unchanged, and
overlapping requests—including identical targets—remain independent.
The same explicit request imports only that tool's legacy record before it is
claimed; startup never scans the legacy catalog.
Runtime resolution uses only durable managed proof or an explicit external
certification. It does not plan, inspect `PATH`, run version processes, or write
state. Release, Mason, and external authorities recheck metadata without
hashing executable payloads; active npm bundle resolution deliberately rehashes
the exact private closure and receipt on every use. A compatible candidate from
a non-bang request is re-hashed while the identity/destination/shim resources
are locked and published as a private `0600` certification; rerun the same
command to recertify metadata drift. The executable, lexical path, canonical
path, and ancestor chain must remain owned by root or the effective user, with
no group/world-writable ancestor directory. Any managed
record takes precedence and fails closed without external fallback.
`markdown-preview` is managed-only. Missing and drifted state reports the exact
recertify or `!` managed-repair action. An unsafe private external receipt is
not overwritten; inspect/remove its exact entry or choose managed `!` repair.
Explicit work is claimed once in persistent state; a failure, interruption, or
corrupt claim is never retried automatically. A manual repair can reclaim an
interrupted attempt only after its owner exits; live or unverifiable owners
remain locked, including for a bang repair. If an older Neovim still owns an
unfinished request, close that editor and rerun the explicit install or repair
from a fresh Neovim. Do not delete its verified-tools records or lock tickets.
The Mason adapter always leaves registry/install callback context before it
observes or acknowledges the result, and every terminal callback path reports
exactly once so a post-install observation error cannot strand a live lock.

`devcontainers-cli` is the managed-only dynamic exception to the exact-version
catalog. Only `:NvimConfigToolsInstall devcontainers-cli` or explicit `all`
fetches the npm `latest` metadata; startup, health, resolution, and
`provision-runtime` never do. The selected stable version is materialized as an
immutable `bundle-sha256` closure containing exactly `@devcontainers/cli` and
the pinned private Node 24.20.0 binary for the current supported target. It
never executes host node/npm or Homebrew. Activation occurs only after live
attestation succeeds; runtime reads the active slot offline, failed upgrades
leave its previous pointer and bytes usable, and historical bundles are not
pruned. Its `curl` and Python prerequisites are considered in declared `PATH`
order, but an unsafe earlier candidate does not hide a later safe one: each is
authority-checked and only the first validated canonical absolute path is ever
executed. Python still runs with `-I -B`, and curl still ignores ambient config
with `--disable`.
The pinned Node digests come from the matching `.tar.gz` rows in the official
per-release
[`SHASUMS256.txt`](https://nodejs.org/dist/v24.20.0/SHASUMS256.txt); archive
names and checksums must be updated together. A failed bundle-helper phase keeps
its stable error category and appends only a whitespace-normalized, control-free
diagnostic bounded to 160 bytes. This preserves actionable checksum or archive
errors without persisting unbounded child-process output.

- `:NvimConfigToolsInstall [all|name]` certifies an exact compatible external
  tool, otherwise installs or retries the exact release, Mason identity, or
  explicitly selected npm `latest` bundle. `!` always selects the managed
  strategy; failed, drifted, cancelled, interrupted, and stale succeeded state
  uses the core's explicit retry/repair claim mode.

Mason's UI is inspection-only and command-lazy: install, update, uninstall and
registry-refresh commands and mappings are disabled. It and the dormant
`mason-lspconfig` bridge stay outside normal file/LSP startup; native
`nvim-lspconfig` registers and enables servers independently.

`PATH` precedence is verified shims, `local_config.path` (declared order),
`~/.local/bin`, the inherited host path, managed release binaries, then Mason.
The editor and pager share the primary Neovim managed-tool root. Release proof
binds the verified archive to every promoted content hash. Mason proof binds the
exact raw source version and full link map to a normalized private `0600`
receipt. Health receipt inspection and explicit attestation are local-only and
never refresh the registry. Attestation of an existing successful identity
occurs only on an explicit install/repair request.
The current Mason proof validates the raw receipt and declared executable-link
map during explicit install/attestation, then durably closes over the normalized
receipt and each canonical launcher target. It does not prove transitive package
files or the host interpreter. This is a documented schema limitation,
especially for Node launchers, and must be fixed by a versioned closure proof
plus mutation tests rather than an implicit runtime probe.
The Mason `ToolIdentity` digest covers the complete immutable entry, integrity,
and executable maps. Records produced by the older partial digest remain on disk
as recovery evidence but are not runtime authority for the new identity; an
explicit managed install/repair creates and attests the current record.

| Mason backend | Host dependency |
| --- | --- |
| Prebuilt | None |
| npm | `node` and `npm` |
| PyPI | Python with working `venv` support |

The npm-release installer itself needs only trusted system `curl` and Python
to download and construct the verified bundle. The helper and its hostile
archive fixtures are covered by `npm_release_installer_spec.lua` and
`verified_npm_bundle_spec.py`, both listed explicitly in `scripts/check-config`.

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
| Markdown reading view | Exact v3.10.3 checkout and media guard, raw editable source, focused read-only render tab and close/reopen, centered 90%-up-to-120-column page with cursor bounds and resize reflow, continuous code shading and pastel heading pills over soft bands with bounded fallback and no terminal text scaling, complete tables with top/bottom rules, outer vertical borders and links, wrapped default and `:ToggleWrap` natural-width/horizontal-scroll mode across live updates, resizes and pager toggles, clicks and keys never collapsing tables or code, blocks extending to the window edge, rendered-link `gd`, unsaved live updates, pager source recovery and filetype changes | Visual layout in Ghostty and the real `nvimpager` executable |
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
| Dev Container editor | CLI/spool schemas and HMAC vector, no-clobber/filename binding, explicit pane/claim argv, detached claim handshake/timeout, checked respawn/quick-exit/handoff and ACK failure, private auth state, real flock contention/stale inode reuse, official 0.89.0 bind-mount grammar, read-only doctor probes for the used `up`/`run-user-commands`/`exec` surfaces, positional cwd trampoline, frozen per-claim config closure with bounded files/directories/entries, whole-closure revalidation, host-only sidecar schema/mode/corruption checks, exact-identity cleanup under owner-directory replacement, legacy v4/v5 recovery, snapshot-without-sidecar fail-closed behavior, remote marker-probe ordering/failure, Podman Machine metadata cross-checking, v6 connection/fingerprint validation, exact endpoint propagation despite ambient/default drift, descriptor-backed durable immutable host-key pins, owner-private authenticated Unix gate, stdin-only 256-bit token that never enters TCP, per-connection domain-separated mutual HMAC, Python `-I -S` isolation, unpredictable owner-only proxy directories, executable good/bad-ACK proxy canaries, exact socket/directory retirement and supervised cleanup exit status, Python 3.9 `socket.timeout` polling, startup-only exact VM-loopback listener attestation, repeated Machine/host-agent/gate/process checks, full container-ID plus exact `devcontainer.local_folder`/`devcontainer.config_file` labels, running-state and host-network attestations before and after proxy readiness, configured-remote-user `exec`, proxy self-owner/mode checks, canonical user-owned host `SSH_AUTH_SOCK` with full ancestor identity/mode attestation and the exact macOS launchd runtime exception, host `/usr/bin/ssh`, VM `/bin/sh` and `/usr/bin/ss`, and container `/usr/bin/test`, executable `/usr/bin/python3`, `/bin/sh`, and `/usr/bin/ssh-add` prerequisites, `up --skip-post-create` ordering, supervised container-owned Unix proxy and SSH-agent protocol probes before and after exact-ID `run-user-commands` with the verified `SSH_AUTH_SOCK`, compatible-container reuse without an agent mount, BaseException cleanup, offline propagation and absence-only fallback | A real Podman Machine/Dev Container canary proving SELinux remains enforcing and the proxy process has the expected `container_t` domain, the authenticated gate-to-loopback-to-proxy handshake, host-agent identity and empty/non-empty agent behavior, hooks run only after agent verification, deterministic relay teardown, same-UID/root/daemon-system-principal adversarial mutation, and fail-closed rejection when any host, VM, CLI, network, or container prerequisite is absent |

GitHub Actions runs the same bootstrap and check on `ubuntu-24.04` and
`macos-15`. Hosted success is delivery evidence only after the branch has been
pushed; a locally validated workflow is not itself proof that either hosted job
ran.
