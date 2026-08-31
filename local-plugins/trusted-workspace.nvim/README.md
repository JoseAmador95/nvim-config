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
  fingerprint.
- `authorize(repo, capability)` and `revoke(repo, capability)` manage revocable
  grants. Capabilities are exactly `lint-format`, `test`, `build`, and `debug`.
- `status([repo])` returns copied candidate/applied/pending/LKG state and grants.
- `diff()` returns the candidate-to-applied leaf changes.

Persistent JSON is bounded, atomically replaced with mode `0600`, and stored in
a real mode-`0700` directory. Symlink, non-regular, corrupt, and unknown-version
state fails closed and is never silently replaced.
