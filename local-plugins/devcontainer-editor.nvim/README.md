# devcontainer-editor.nvim

`devcontainer-editor.nvim` is the provider-neutral lifecycle and transport core
for an exact Neovim editor inside a Dev Container. It models workspace identity,
validates host/container path mappings, consumes authenticated spool requests,
and exposes lifecycle/status helpers without registering commands or mappings.

The host injects the lifecycle launcher, a certified `@devcontainers/cli`
resolver, Docker-compatible engine policy, root/repository identity, editor
callbacks, notifications, and process primitives through `setup(opts)`.
Network authorization is carried into the container as
`NVIM_CONFIG_OFFLINE`; denied authorization therefore makes
`verified-tools.nvim` report `blocked/offline` without claiming an attempt.

State directories are owner-only (`0700`) and records, requests,
acknowledgments, authentication, and lock files are owner-only (`0600`). The
host launcher accepts state only below the user's canonical home or the private
temporary root used by isolated tests; a shared host mount is rejected.
The secret exists only in `spool/auth.json`; messages carry a filename-bound
UUIDv4 and HMAC-SHA256, are published without clobbering, and never copy the
secret into argv, environment, records, or logs. Readers reject symlinks,
non-regular files, oversized payloads, unknown schema fields, mismatched
authentication, and path traversal. Snapshots returned by the public API are
deep copies.
Once a request or acknowledgement is published it remains a committed success;
a subsequent directory-fsync failure is surfaced separately through the host's
notification callback as a bounded warning and does not skip ACK validation.
The editor-side transport pins the spool root plus `inbox`, `outbox`, and
`acks` directory descriptors. Enumeration, reads, no-clobber publications, and
conditional retirement remain relative to those descriptors, so a later
directory rename or symlink replacement cannot redirect an operation outside
the authenticated spool. Retirement uses a no-clobber reservation and restores
a replacement detected against the opened snapshot. POSIX has no
compare-and-unlink syscall; after the last reservation snapshot, other host
processes running as the same UID remain the final-syscall trust boundary.

Authenticated messages and `auth.json` remain protocol v2. Workspace records
use their independent schema v6. They retain the required closed `phase` field:
`claimed`, `preparing-config`, `starting-container`, `checking-ssh-agent`,
`checking-editor-config`, `opening-editor`, `monitoring-editor`, or
`returning-host`. Phase reports detailed progress independently of the coarse
`starting`, `running`, `stopped`, `error`, and `dead` status; an error or dead
record retains its last phase. Records also persist both the certified Dev
Containers CLI and the exact Docker-compatible engine path used for startup.
Version 6 additionally stores the closed optional Podman identity
`{name,machine_pin}`. `exec` and `restart-dead` invoke the exact paths and, on
macOS Podman, re-attest that identity even if `PATH` or the default connection
later changes. Legacy v2 through v5 records remain strictly readable for status
and an already-running authenticated route, but older records are never
rewritten or deleted as an automatic migration side effect. A pre-v6 macOS
Podman record is recovery-only because rebinding it to today's default Machine
would guess authority.

The inbox consumes at most `max_messages_per_tick` records (32 by default),
returns a copied per-record outcome report, immediately schedules remaining
backlog, and exponentially backs off repeated failures. Host requests use a
5000 ms acknowledgement timeout by default. Setup rejects unknown keys before
stopping an existing watcher or changing configuration.

`effective_config()` is available before setup and returns caller-owned core
policy defaults; configured projections and setup events exclude callbacks,
launcher/state/spool paths, and UUID providers. `status()` returns a copied
aggregate with `configured`, transport, and watcher state, while
`status(host_root)` keeps the authenticated workspace-record view.

## API

- `setup(opts)` / `effective_config()` / `teardown()` / `stop()`
- `in_workspace()` / `network_authorized()`
- `workspace_key(value)` / `route(path, from_root, to_root, kind)`
- `status(host_root)` / `log_path(host_root)`
- `new_claim_id()`
- `resolve_runtime()`
- `request_host(action, dependencies?, callback?)`
- `consume_spool_once()`
- `transport_status()`
- `lifecycle_argv(action, spec)`

## Boundary:

The plugin never imports `config.*`, creates global commands, chooses tmux/UI
policy, installs the Dev Containers CLI, or downloads tools. Host adapters own
`:DevContainer*`, menus, statusline, session refresh, and presentation. Python
owns the detached coordinator, the advisory lock retained for its whole
lifetime, checked tmux replacement/monitoring, and explicit record retirement.
The plugin owns lifecycle argv validation and the editor-side authenticated
transport contract. `lifecycle_argv("up", spec)` therefore requires an explicit
`spec.tmux_pane` and canonical `spec.claim_id`; the host waits for that exact
claim before reporting detached startup success.
The internal `editor_ready` host request is a no-op acknowledgement consumed
only after the coordinator has verified the replacement pane, persisted the
exact lifecycle as `running`, and successfully appended its running log entry.
The host may use that authenticated ACK to publish a single post-handoff success
notice.
`lifecycle_argv("restart-dead", spec)` carries the same exact pane and a fresh
claim but deliberately carries no CLI selector: the launcher must use the
recorded runtime identity. The coordinator retains one cross-process workspace
flock through startup, pane replacement, request handling, and verified pane
exit.

`log_path(host_root)` does not trust the path stored in a record. It derives the
only valid log name from the configured state root and workspace hash, requires
an exact record match, and inspects the canonical `0700` state/log hierarchy
plus the regular single-link `0600` log through no-follow descriptors. Missing,
symlinked, hard-linked, replaced, non-owner, or over-256-KiB logs fail closed;
inspection never creates or repairs filesystem state. The host owns log
presentation and follow-buffer policy.

The host injects a certified CLI resolver and owns `docker_path`, which defaults
to `docker` and may select a compatible engine such as `podman`. The remaining
defaults are lockfile policy `preserve`, SSH-agent policy `auto`, a 2000 ms
claim timeout, a 5000 ms ACK timeout, and 32 messages per tick. Before a new
claim, the host runs a read-only `doctor` preflight against the exact CLI,
engine, and config. The coordinator revalidates both executable paths after
publishing its starting claim and probes lockfile flag support before `up`.
Missing tools or capability support fail closed before a container command.
The plugin only carries the `auto|off` SSH-agent policy; the injected launcher
owns transport. On macOS with Podman Machine it neither changes nor disables
SELinux; a live canary, rather than the launcher, proves enforcing state and the
proxy process's expected `container_t` domain. It reverse-forwards an
owner-private authenticated host Unix gate only to VM loopback TCP. This route
requires a canonical user-owned host `SSH_AUTH_SOCK` plus host `/usr/bin/ssh`,
with every canonical parent identity and mode attested and only the exact
macOS `root:daemon` launchd runtime shape admitted as a writable exception.
It also requires Machine `/bin/sh` and `/usr/bin/ss`, and a host-networked
container with `/usr/bin/test`, executable `/usr/bin/python3` run with `-I -S`, `/bin/sh`, and
`/usr/bin/ssh-add`, plus the probed Dev Containers CLI options for `up`, `exec`, and
`run-user-commands`. The configured Dev Containers remote user creates the
private container-owned Unix `SSH_AUTH_SOCK` proxy at a fresh unpredictable
owner-only path. A fresh 256-bit
lifecycle token reaches that proxy only over stdin and never crosses loopback
TCP; a fresh challenge and domain-separated HMACs authenticate the proxy before
the host agent is opened and authenticate the gate before traffic is relayed.

The launcher runs `up --skip-post-create`, then requires one full container ID,
running state, exact `devcontainer.local_folder` and
`devcontainer.config_file` labels, and host networking before and after proxy
readiness. First host-key enrollment is allowed only against a descriptor-proven
empty private pin, learned keys are retained durably even after a failed first
attempt, and every established relay uses strict immutable pinning. Startup
retries an SSH child that exits before readiness on at most three distinct VM
ports, fully reaping it before each retry, and attests the exact VM-loopback
listener once. Subsequent relay checks revalidate
the Machine identity file, host-agent and gate socket identities, gate accept
thread, and SSH/proxy liveness; the host agent is also revalidated before each
authenticated connection opens it. The proxy checks its own directory/socket
owner and modes at creation and retires the exact socket followed by the same
empty directory at cleanup; cleanup failure remains a nonzero supervised exit. After
`/usr/bin/ssh-add -l` succeeds, exact-ID `run-user-commands` executes hooks with
the verified `SSH_AUTH_SOCK`, then the same protocol probe runs again. SSH and
proxy stdin are lifecycle leashes; the
in-process gate is stopped by closing its listener and active sockets and
joining its threads, with worker publication serialized against shutdown. The
launcher never mounts the host launchd socket or an
agent volume and never copies private keys. After selecting the Machine, every
CLI and engine subprocess is pinned to its validated SSH URI and identity file
rather than a mutable default connection. A compatible reused container needs
no recreate solely for agent transport. The same host UID, root, and the
macOS daemon-group system principal remain part of the host trust boundary.
OpenSSH clears default identity files with `IdentityFile=none` before adding
the exact Machine key, preventing fallback to unrelated user keys if that file
disappears between validation and execution.
