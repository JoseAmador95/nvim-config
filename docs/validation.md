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

Mise must already be on `PATH`. The optional `scripts/install-mise` command
installs the pinned executable into `~/.local/bin` after checking its SHA-256.
`install-ci-tools` uses the shared Mise catalog and `--locked` to fetch exact
precompiled validators. It creates launchers in the requested absolute directory.
Before any network restore, `bootstrap-config` requires the exact pinned
tree-sitter CLI and `cc` when parsers are enabled; `--skip-parsers` does not
require either. Bootstrap may then use Git/network access to restore the
editor, nvimpager, and stubbed VSCode-Neovim plugin profiles and waits for the
configured editor and pager parsers. The final check disables installers, is
offline, validates all four validator pins plus `cc`, and fails if an installed
plugin does not match the lock.
Usage suites also require the host `sqlite3` CLI and use temporary databases.
They check concurrent writers, retries and reset, plus actual Neovim input and native Lazy key activation.
The LSP and Markdown navigation suites enable instrumentation to check mapping ownership and removal.

The engine screen-geometry spec uses `-c 'lua dofile(...)'` so Neovim has
initialized its screen before the test changes `lines` and `columns`. Running
that spec with `-l` can leave the headless grid at its old dimensions and crash
redraw in Neovim 0.12.5. Its redraw, scrolling and cursor assertions remain active.

The committed `lazy-lock.json` belongs to the full editor. The pager copies it
byte-for-byte to a profile-local state file before Lazy starts; Lazy may prune
that writable copy for the allowlist but can never rewrite the committed lock.
Bootstrap snapshots the source lock, fails if any profile changes it, and
checks every active pager checkout against the corresponding source-lock SHA.
Both bootstrap and the offline gate isolate `XDG_CONFIG_HOME` and override
`NVIM_CONFIG_FILE`, so host settings cannot change the tested defaults.
Theme checks exercise automatic and pinned light/dark VSCode profiles.

## Runtime provisioning contract

`scripts/provision-runtime` reconciles the caller's current private runtime;
unlike `bootstrap-config`, it does not create a disposable validation tree, and
unlike `check-config`, it may mutate runtime state only when explicitly allowed:

```sh
scripts/provision-runtime --non-interactive --report ABSOLUTE_PATH \
  [--require-managed-tools] [--allow-network]
```

The default is offline. Provisioning inventories locked Lazy checkouts, exact
Tree-sitter revisions and Mise's installed tool records. `--allow-network` is
the sole authorization for missing or stale components to be fetched. It never
installs Mise itself; a missing or too-old Mise is reported under `mise`.
`--require-managed-tools` requires every selected install path beneath
`~/.local/share/mise/installs`.

The report contract is version 2 (`--contract-version` prints `2`). Deterministic
JSON contains `schema_version`, `status`, `changed`, bounded sorted `error_codes`,
`nvim`, `lock`, editor/nvimpager plugin and parser inventories, `mise`, `tools`,
and `extra_tools`. `lock.tools` records SHA-256 digests for `mise.toml`,
`mise.lock` and all `.mise/locks` sidecars. Publication is atomic with mode `0600`.
Unrelated plugins, parsers and tools are retained, and committed locks must stay
byte-identical. The external custom-cloud consumer requires contract v1 and is
incompatible until updated in its own repository; it is outside this migration.

Provisioning rejects a non-canonical HOME, HOME under `/localdata`, XDG roots
outside HOME, unsafe report parents/targets, and concurrent or stale lock state.
Its HOME-contained XDG and state directories are secured as `0700`; the report
must live below HOME. Linux ARM64 currently lacks pinned mmdflux, clangd and
Markdown Preview assets and full provisioning reports `unsupported-platform`.

## Runtime tool installation

`config.toolchain` generates `mise.toml`; native `mise.lock` plus `.mise/locks`
fix platform artifacts and the npm/Python dependency graphs. Only the explicit
`scripts/update-tool-lock` maintenance command updates this material. Dev
Containers is fixed at 0.89.0 with Node 24.20.0; Python tooling uses Python
3.13.16 and uv 0.12.23. CMake LS 0.1.11 also fixes pygls 1.3.1 because its server API is incompatible
with pygls 2. No `latest` selector is used.

- `:NvimConfigMiseInstall` explicitly installs Mise into `~/.local/bin/mise`.
- `:NvimConfigToolsInstall [all|name]` preinstalls locked tools; `!` reinstalls.
- Runtime launchers use ordinary `mise exec`, including automatic installation
  of missing tools. Offline execution disables that installation and fails when
  the requested tool is absent. Preinstall before retrying a timed-out cold use.
- `:NvimConfigParsersInstall` explicitly resolves the managed tree-sitter CLI
  and installs configured parsers. Startup never installs parsers.

Tools and launchers are under `~/.local/share/mise`; state is under
`~/.local/state/mise` and caches under `~/.cache/mise`. Editor and pager share
them. The wrapper preserves cwd/argv/stdin, ignores project/global Mise config,
and keeps the locked tool selection separate from project interpreter policy.
Mise owns install-time verification. There is no separate runtime tool hashing,
certification, receipt database, or Mason integration. Old tool trees are retained
but excluded from executable selection. GumTree is removed; historical origins
in review comments remain inert and readable.

Rust remains external-only, with managed and old Mason roots excluded; Rust
formatting stays disabled. `rsvg-convert`, CMake/CTest and host utilities
remain outside this catalog. Native LSP, Conform, lint, DAP, diagrams, review,
JSON tools and Markdown Preview use the same catalog launchers. Their existing
execution grants, deadlines and cancellation remain in force. Project Python
selection continues to feed ty, DAP and the REPL independently of the
Python used to run installed tooling.

| Area | Automated evidence | Manual evidence still required |
| --- | --- | --- |
| Terminal editor | Startup, argv lifecycle, commands, LSP config, plugin API contracts, and cache-only statusline render sentinel | Interactive completion and long editing sessions |
| Redraw profiles | Schema/default, host/project trust boundary, full/low functional matrix, explicit SSH non-selection, and pager/VSCode full-profile guards | Subjective latency and bandwidth on a real remote terminal |
| Markdown reading view | Exact v3.10.3 checkout and media guard, local images and per-document approved https images (session, saved owner-only, revoked, offline, http/tmux refused), inert diagram/video/expand paths, raw editable source, focused read-only render tab and close/reopen, centered 90%-up-to-120-column page whose virtual margin stays out of the cursor, Visual selections and yanks, with resize reflow, continuous code shading and pastel heading pills over soft bands with bounded fallback and no terminal text scaling, complete tables bounded by the centered page while wrapped, with top/bottom rules, outer vertical borders and links, wrapped default and `:ToggleWrap` natural-width/horizontal-scroll mode (including actions inside callbacks) across live updates, resizes and pager toggles, clicks and keys never collapsing tables or code, code extending to the window edge, rendered-link `gd`, unsaved live updates, pager source recovery and filetype changes | Visual layout and inline images in Ghostty and the real `nvimpager` executable |
| nvimpager | Allowlist, source-lock SHA parity, parser set, argv/stdin filetype behavior, mappings and absence of editor-only services | Rendering in the real `nvimpager` executable |
| VSCode Neovim | Stubbed profile and action mappings; terminal-only commands/plugins stay absent | A live VS Code extension host |
| Theme | Fixed VSCode, automatic/pinned light and dark backgrounds, editor/pager availability and VSCode exclusion | Visual judgement in the real terminal and pager |
| Runtime provisioning | CLI/schema v2, offline authorization boundary, private HOME/XDG/report paths, atomic `0600` reports, exact inventories, lock immutability, extras preservation and idempotence | Network downloads on every supported OS/architecture and recovery from a deliberately stale operator lock |
| Tree-sitter | Installed/missing parser lifecycle, completion retry, large-file guard and textobject surfaces | Language-specific highlighting judgement |
| LSP | Server catalog, bounded JSONC/fingerprint approval for project settings, mutation revocation, merge order, profile isolation, single/multiple-result tab navigation and clangd command construction | Connecting to every external language server |
| DAP | Adapter resolution, VSCode aliases, dap-view lifecycle, views and tab-aware fixture navigation | Real adapter behavior and interactive UI judgement |
| Lint/format | Save-only lint routing, formatter chains, no-LSP fallback and missing-tool behavior | Project-specific linter configuration |
| Diagrams | Scanner, renderer generations, atomic cache writes, corruption and pruning | Kitty image display, browser opening and visual layout |
| LogWatch | Append, partial lines, truncation, rotation, deletion/recreation and retention limits | Sustained observation of a high-volume production log |
| Dev Container editor | CLI/spool schemas and HMAC vector, no-clobber/filename binding, explicit pane/claim argv, detached claim handshake/timeout, checked respawn/quick-exit/handoff and ACK failure, private auth state, real flock contention/stale inode reuse, official 0.89.0 bind-mount grammar, read-only doctor probes for the used `up`/`run-user-commands`/`exec` surfaces, positional cwd trampoline, frozen per-claim config closure with bounded files/directories/entries, whole-closure revalidation, host-only sidecar schema/mode/corruption checks, exact-identity cleanup under owner-directory replacement, legacy v4/v5 recovery, snapshot-without-sidecar fail-closed behavior, remote marker-probe ordering/failure, Podman Machine metadata cross-checking, v6 connection/fingerprint validation, exact endpoint propagation despite ambient/default drift, descriptor-backed durable immutable host-key pins, owner-private authenticated Unix gate, stdin-only 256-bit token that never enters TCP, per-connection domain-separated mutual HMAC, Python `-I -S` isolation, unpredictable owner-only proxy directories, executable good/bad-ACK proxy canaries, exact socket/directory retirement and supervised cleanup exit status, Python 3.9 `socket.timeout` polling, startup-only exact VM-loopback listener attestation, repeated Machine/host-agent/gate/process checks, full container-ID plus exact `devcontainer.local_folder`/`devcontainer.config_file` labels, running-state and host-network attestations before and after proxy readiness, configured-remote-user `exec`, proxy self-owner/mode checks, canonical user-owned host `SSH_AUTH_SOCK` with full ancestor identity/mode attestation and the exact macOS launchd runtime exception, host `/usr/bin/ssh`, VM `/bin/sh` and `/usr/bin/ss`, and container `/usr/bin/test`, executable `/usr/bin/python3`, `/bin/sh`, and `/usr/bin/ssh-add` prerequisites, `up --skip-post-create` ordering, supervised container-owned Unix proxy and SSH-agent protocol probes before and after exact-ID `run-user-commands` with the verified `SSH_AUTH_SOCK`, compatible-container reuse without an agent mount, BaseException cleanup, offline propagation and absence-only fallback | A real Podman Machine/Dev Container canary proving SELinux remains enforcing and the proxy process has the expected `container_t` domain, the authenticated gate-to-loopback-to-proxy handshake, host-agent identity and empty/non-empty agent behavior, hooks run only after agent verification, deterministic relay teardown, same-UID/root/daemon-system-principal adversarial mutation, and fail-closed rejection when any host, VM, CLI, network, or container prerequisite is absent |

GitHub Actions runs the same bootstrap and check on `ubuntu-24.04` and
`macos-15`. Hosted success is delivery evidence only after the branch has been
pushed; a locally validated workflow is not itself proof that either hosted job
ran.
