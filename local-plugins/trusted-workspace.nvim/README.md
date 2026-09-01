# trusted-workspace.nvim

Boundary: trusted source schemas, merge provenance, immutable snapshots,
last-known-good state, transactional appliers, approvals, and capability grants.

Trusted source schemas, deterministic host/project merging, per-field provenance,
immutable snapshots, last-known-good state, and transactional appliers.

The plugin deliberately does not read or execute workspace configuration, show
prompts, register commands, or know editor profiles. Those responsibilities stay
in host adapters, which inject a private state root and register already-read
sources.

## API

- `setup({ state_root, mode = "full" })` configures owner-only persistent state.
  `mode = "host-only"` excludes project sources without requesting approval.
- `register_source({ id, layer, priority, value, repo, fingerprint })` replaces a
  source. Host layers accept the host schema; project layers retain only
  `clangd.path`, `clangd.profile`, `review`, and log settings.
- `snapshot()` returns an independent
  `{ generation, source, validity, value }` copy. `validity.provenance` maps
  leaf paths to source IDs and layers.
- `register_applier({ id, order, prepare, apply, rollback })` adds a transactional
  applier. Every prepare completes before ordered apply; completed applies roll
  back in reverse after a failure.
- `approve(repo, source, fingerprint)` persists an exact project-source
  fingerprint only when it matches the currently registered, enabled project
  candidate.
- `authorize(repo, capability)` and `revoke(repo, capability)` manage revocable
  grants. Capabilities are exactly `lint-format`, `test`, `build`, and `debug`.
- `status([repo])` returns copied candidate/applied/pending/LKG state and grants.
- `diff()` returns the candidate-to-applied leaf changes.

Persistent JSON is bounded, atomically replaced with mode `0600`, and stored in
a real mode-`0700` directory whose device/inode identity is pinned after setup.
Symlink, hard-linked, non-regular, corrupt, unknown-version, and substituted-root
state fails closed and is never silently replaced. Reads verify that the opened
descriptor still matches `lstat`; permissions are repaired through the descriptor
instead of a pathname.

All persistent namespace mutations, including state-root/quarantine `mkdir`,
state and claim publication/exchange, quarantine moves, claim unlink, and empty
quarantine removal, cross an `fsync` barrier on every pinned parent directory.
Conditional cleanup performs a final no-clobber quarantine move after validating
the exact bytes and inode, and empty-directory cleanup likewise re-quarantines
and reopens the exact directory before removal. A late replacement is retained.
Once state publication has committed, cleanup, directory-fsync, or descriptor
close failures remain successful mutations and are retained in `status().state_error`
instead of encouraging an unsafe retry. File `fsync`/close failures before
publication fail closed.

Persistent mutations use immutable, exclusive choosing/ticket claim files (a
Lamport bakery lock), reread schema-v1 state while holding the lock, and remove a
dead process's unique claim only after confirming liveness. This avoids a shared
pathname compare-then-unlink reclaim race. Claim metadata is fully written,
`fsync`ed, descriptor-verified, and then atomically renamed from a token-reserved
unrecognized staging path. A crash before rename leaves only an ignored staging
orphan; a crash after rename leaves a complete claim that can be reclaimed once
its process is confirmed dead. Pending project candidates retain their previously
approved contribution while unrelated approved/host changes continue through
transactional appliers. Candidate errors and pending approvals remain in
candidate/status validity; applied snapshot validity is derived only from the
effective sources delivered to appliers.

The bakery lock remains held until state CAS cleanup and its postcommit warning
collection finish. This is an owner-only cooperative namespace: POSIX provides
no atomic compare-and-unlink after the final exact descriptor snapshot, so the
OS owner UID is the trust boundary. The quarantine protocol preserves races
between cooperating writers; it does not claim protection from hostile code
running as that same UID.
