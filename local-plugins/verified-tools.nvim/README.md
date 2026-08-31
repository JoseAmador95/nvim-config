# verified-tools.nvim

Boundary: verified release and Mason planning, scheduling, locks, watchdogs,
cancellation, attestation, repair, and exact persistent identity. Manifests,
commands, health UI, and network authorization policy stay host-owned.

Every tool uses `{ backend, name, version, target, digest, install_root }`.
Release assets and Mason packages share a two-job scheduler and cross-process
identity, destination and global-slot locks. Offline denial occurs before an
attempt is consumed; failures and drift require explicit `retry` or `repair`.

External executables are accepted only after an injected compatible probe.
Otherwise an attested managed pin is selected and its private shim precedes host
paths. Startup may plan, probe, attest and migrate legacy state, but never install.
