# verified-tools.nvim

Boundary: the plugin owns verified tool lifecycle and durable proof state; the
host owns catalogs, installers, upstream managers, policy, commands, and UI.

`verified-tools.nvim` owns the explicit lifecycle for release and Mason tools:
planning, two-job scheduling, cross-process locks, cancellation, watchdogs,
attestation, repair, shims, and private schema-2 records. Tool manifests,
installers, Mason registry access, network policy, commands, and health UI remain
host-owned. The plugin does not install, probe external tools, or access the
network during `setup()` or aggregate `status()`; aggregate `status()` also
performs no filesystem I/O.

The host keeps startup and Mason readiness at setup-only. Its `plan(name)` API
plans one requested identity, and aggregate `plan_all()` is available only to
explicit callers. The `all` install target likewise enumerates the catalog only
after the caller names it.

## Setup and public request envelopes

`setup()` accepts exactly these top-level keys:

```lua
{
  state_root = "/absolute/private/root", -- or a zero-argument resolver
  backends = { [backend_name] = { run = run, attest = attest } },
  probe_external = probe,
  network_authorized = authorize,
  defer = schedule,
  instance_token = "<optional 64 lowercase hex>",
  lock_wait_ms = 250,
  lock_retry_ms = 25,
  watchdog_ms = 300000,
  pid = pid_resolver,
  process_alive = liveness_probe,
  clock = clock,
  notify = notify,
  events = emit,
  on_state_change = observe,
  fail_persist = test_persist_fault,
  interleave = test_interleaving_fault,
}
```

Unknown keys are rejected; backend-specific extensibility belongs under
`backends`. Backend names must be non-empty strings and each backend is a table;
its optional `run` and `attest` entries must be functions, while additional
backend-owned fields remain allowed. Callback types, timing values, the optional
instance token, PID, and canonical state-root guard are validated in locals
first. Only a completely valid setup publishes any module state. Failed setup
can therefore be retried, does not expose a shim path, and performs no
state-root creation. The PID and state-root resolvers are each snapshotted once.

`events(name, payload)` and `on_state_change(event)` receive independent deep
copies. The latter adds `event.kind = name`; observer failures are isolated from
the tool lifecycle.

`teardown()` releases process-local configuration only when no queued or running
jobs remain. Reconfiguration after setup must be exact and idempotent; changing a
root, callback, backend, PID, token, or policy requires a successful teardown
first.

`claim()` returns the only managed run authority accepted by `run()`:
`{identity, plan, record, mode}` with no extra or missing keys. `mode` must be
`auto`, `retry`, or `repair` and must equal the mode in the exact claimed
schema-2 record. The optional `run()` callback must be a function.

`status()` is a pure, copied aggregate of configuration state and process-local
jobs; it is available before setup. `jobs()` returns a deterministic flat list
whose rows contain identity/key, status, queue position, stage, and copied
resources without I/O or callbacks. `records()` explicitly enumerates durable
records. A targeted `status(identity)` or cancellation accepts either an exact
`ToolIdentity` or the exact wrapper `{identity = ToolIdentity}`; wrapper extras
are rejected before filesystem mutation. `effective_config()` returns only
copied, non-callback policy and uses a 25 ms lock-retry default. There is no
host-configurable maximum-jobs knob. `cancel()` rejects the same malformed
envelopes. `attest()` uses the same exact identity wrapper and accepts only a
function callback when one is supplied.

## Tool specs and plans

`plan(spec)` accepts only this envelope:

```lua
{
  identity = {
    backend = "release" | "mason",
    name = "logical-name",
    version = "exact-version",
    target = "exact-target",
    digest = "pinned-identity-digest",
    install_root = "/absolute/canonical/destination",
  },
  manifest = { integrity = integrity_contract, ... },
  executables = { "command" }, -- or { command = "installed-name" }
  requires_network = true,
  force_managed = false,
}
```

Unknown fields, unsafe command basenames, traversal, sparse/mixed lists,
duplicate commands, duplicate installed names, duplicate installed paths, and
non-boolean policy fields are rejected. A normalized plan is an immutable data
contract: `claim()` and `run()` reject unknown fields or any digest-covered
mutation and never probe again.

The basename of every declared integrity command path must equal the installed
basename in `executables`. Manifests and callback results must be finite,
JSON-encodable data; mixed key types and non-finite numbers fail as ordinary
validation errors rather than escaping with a Lua exception. `claim()` accepts
only `{ mode = "auto" | "retry" | "repair" }`.

The logical identity name is never used to derive a filesystem path. Every plan
contains the identity resource, canonical install-destination resource, and one
resource for every actual shim destination. Local scheduling and cross-process
locking use the complete same set.

Tool identity keys use a fixed-order serialization, so the same normalized
identity has the same record and lock key in every fresh process. Historical
schema-1 files whose old object serialization produced randomized names are
discovered by a bounded private scan. The scan matches the normalized identity
and stored filename/key, rejects duplicates, and only projects
`repair-required` in memory. Explicit repair writes canonical schema 2 while
retaining the historical file as recovery data.

Release integrity is exact:

```lua
{
  kind = "release-sha256",
  archive_sha256 = "<64 lowercase hex>", -- equals ToolIdentity.digest pin
  commands = { command = "relative/path" },
  artifacts = { "other/relative/path" },
}
```

Mason integrity is exact:

```lua
{
  kind = "mason-local-integrity",
  receipt_path = "relative/private-receipt.json",
  receipt = {
    package = "logical-name",
    version = "exact-version",
    source_version = "exact-upstream-source-version",
  },
  commands = { command = "relative/lexical/link" },
}
```

The Mason receipt above is a host-created normalized `0600` receipt, not Mason's
raw receipt. On every install and attestation the host must validate Mason's raw
receipt, installed package version, and links before returning the private
receipt path. Core independently reads the private receipt with
`lstat/open/fstat`, requires exactly `{package, version, source_version}`, and
hashes it and every command target.

## External probe contract

Unless `force_managed=true`, the injected `probe_external(identity, spec)` is
called exactly once by `plan()` and must return one exact outcome:

```lua
{ outcome = "absent" }
{ outcome = "incompatible", version = "optional", detail = "optional" }
{ outcome = "error", detail = "required" }
{
  outcome = "compatible",
  version = identity.version,
  paths = { [command] = "/exact/executable/path" },
}
```

Thrown probes, `error`, malformed `compatible`, version mismatch, missing/extra
commands, or unsafe paths stop planning before claim, attempt, backend, or
network authorization. Compatible lexical paths and core-computed fingerprints
are bound into the plan and revalidated at claim. `force_managed=true` bypasses
the probe rather than interpreting a probe failure as managed fallback.

## Installer and attestation contracts

Backends implement `run(plan, done, control)` and
`attest(plan, done, install_evidence)`. Failure is always
`done(false, bounded_reason)`. Release success is:

```lua
done(true, {
  kind = "release-install-evidence",
  archive_sha256 = plan.manifest.integrity.archive_sha256,
  artifacts = {
    -- Exact union of every command relative path and declared artifact.
    [relative_path] = "<64 lowercase hex>",
  },
  -- Optional bounded post-commit recovery/cleanup warnings. They preserve a
  -- succeeded result, are persisted in status.detail, and are notified.
  warnings = { "<warning>" },
})
```

This evidence must be produced by the installer while it still possesses and
has verified the pinned archive and extracted bytes. It is the trusted
install-time channel; echoing a manifest digest or hashing only the final shim is
not evidence. Installer success is accepted only when the first callback value
is exactly boolean `true`. A warning does not turn a committed installation into
a false failure. Mason success must call `done(true, nil)`.

Release attestation returns paths, never claimed hashes:

```lua
{
  kind = "release-sha256",
  archive_sha256 = plan.manifest.integrity.archive_sha256,
  commands = { [command] = "/exact/declared/path" },
  artifacts = { [declared_relative_artifact] = "/exact/declared/path" },
}
```

Mason attestation returns:

```lua
{
  kind = "mason-local-integrity",
  receipt_path = "/exact/private-receipt.json",
  commands = { [command] = "/exact/declared/lexical/link" },
}
```

Core requires exact key sets and lexical paths, resolves only canonical targets
contained by `install_root`, rejects hard-linked/non-executable files, and
computes SHA-256 itself. Lexically different aliases such as `bin/../bin/tool`
are rejected even when they resolve to the declared target. Mason command
entries may be symlinks only when their canonical executable targets remain
inside `install_root`.

Persisted proof uses version 1. Release proof contains
`{kind, archive_sha256, commands, artifacts}`; Mason proof contains
`{kind, receipt, commands}`. Each command/artifact value is the exact
`{path, dev, ino, size, mtime_sec, mtime_nsec, sha256}` fingerprint. A schema-2
`succeeded` record without a structurally valid normalized plan and exact proof
is exposed only as `repair-required` and is never silently rewritten.

## Locks, shims, cancellation, and recovery

`state_root` is resolved under `pcall` exactly once during `setup()`. Its parent,
root, and fixed subdirectories are canonical real directories whose inode
identities are pinned and revalidated before writes. Symlinked ancestors and
subdirectory substitution fail closed. If an absent root is created, its
original parent inode is revalidated before any child directory is created.
Path-producing and file-hash injection are not supported: path digests and file
SHA-256 values are always computed by core. Setup cannot repoint an already
pinned instance.

Private records are capped at 256 KiB, matching the reader. A durable transaction
under the separate `record-transactions/` directory records exact OLD/NEW bytes
and inode identities before publication. Initial creation uses descriptor-relative
no-replace rename; replacement uses atomic rename exchange, so an existing record
never has a missing-name window. Both exchanged sides are re-read exactly. A
post-check conflict is exchanged back using the actual stable displaced entry,
including a symlink or other non-record rival. Recovery distinguishes prepared,
committed, and interrupted-conflict states before durable reads. Cleanup
first reserves each exact entry under a unique name and preserves replacements.
Once exact NEW is visible, sync, marker, or cleanup failures retain recovery
evidence and warn without reporting a false write failure. Final transaction-root
`fsync` and descriptor-close failures are also surfaced as postcommit durability
warnings. Schema-2 records have exact common/status keys, finite numeric
timestamps, and integer generation/PID/attempt fields.

Every record mutation that can contend with another cooperating writer keeps its
identity/resource lock through cleanup. Dead-owner recovery instead claims the
unique transaction directory with a no-replace rename before cleanup, excluding
a second cooperating recoverer. Process-local queued cancellation is the sole
authority for its queued record.

Release and Mason share two global slots. Each resource uses bounded Lamport
bakery claims. Publication descriptor-relatively renames a unique, fully synced
staging file onto an absent claim pathname with no-replace semantics, so a
visible claim has one link. A destination collision preserves the rival, and a
precommit failure conditionally removes only the staging inode. Once renamed,
parent-directory sync or close failures warn without reporting a false rollback.
Release and dead-owner reclamation move the pathname into a unique quarantine,
revalidate its exact snapshot, and unlink the reserved name; an interleaved
cooperating replacement is restored without overwrite. Corrupt, hard-linked,
unverifiable, or orphaned quarantine state fails closed. A crash before rename
may leave a `.publish` orphan, which is ignored but never deleted implicitly.

These private namespaces trust their OS owner UID. POSIX has no atomic
compare-and-unlink operation after the final descriptor snapshot, so quarantine
and bakery claims coordinate well-behaved processes but do not claim resistance
to hostile same-UID pathname mutation at that final boundary.

Before `backend.run`, every same-tool shim and private owner record is removed
under the complete resource lock set. This prevents an old wrapper or proof from
exposing partially replaced content, including a partially written PlantUML JAR.
Uncertain invalidation fails `repair-required` and retains quarantine evidence;
it never restores the old executable path. After attestation, shim promotion is
transactional across every declared command. Targets are re-fingerprinted
immediately before promotion, all new links are created no-replace, and owner
schema 2 is published only after every link succeeds. Partial promotion removes
its own new entries but does not reactivate the pre-install shim. A different
`{backend, name}` remains outside mutation. Drift/failure removes only
engine-owned shims under the same resource locks. Promotion and removal scan both
the shim and owner-record quarantine namespaces before treating either visible
path as absent. If a required repair marker cannot be persisted, the operation
retains its locks.

A destination or fatal lock failure that occurs before the invalidation boundary
uses a record-only transition protected by the identity lock and leaves shims
unchanged. Once invalidation commits, cleanup failure is warning-only and the old
shim is never restored.

Cancellation is two-phase. Queued cancellation persists before dequeue.
Running cancellation persists the reason and signals once but retains locks and
the global slot until backend acknowledgement. If acknowledgement already
arrived and attestation is pending, cancellation settles immediately and late
attestation is ignored. A watchdog uses the same path. Persistence failure does
not report success or release into ambiguous durable state: the engine writes a
`repair-required` marker or retains the locks/slot fail-closed.

Schema-2 active records carry PID, exact 64-hex instance token, and attempt. The
current PID is live only with this instance's exact token. Another existing PID
without an injected token verifier is unknown, not live; `ESRCH` is dead.
Schema-1 records and dead schema-2 active records are projected in memory as
`repair-required` without implicit rewrite. Offline denial occurs before an
attempt is consumed. Retry and repair are always explicit.

`attest(identity)` accepts no replacement manifest. It loads the persisted
succeeded plan and proof, acquires every plan resource plus a global slot, and
compares a fresh observation to the exact baseline. It can restore shims from
the same proof but can never rebaseline; tamper becomes `drift`.

`import_legacy()` can establish initial success only from an explicitly verified
private origin: release uses `origin="verified-private-install-receipt-v1"` plus
exact install evidence; Mason uses
`origin="verified-private-mason-receipt-v1"` plus the validated private receipt.
All other legacy successes become `repair-required`. A successful import
persists both normalized plan and proof and promotes shims while holding the full
resource/global lock set. Legacy evidence normalization is protected against
malformed values, and a pending import participates in the same in-process
resource set as ordinary queued work.
