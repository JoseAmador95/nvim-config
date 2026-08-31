# repo-scratch.nvim

Boundary: durable repository/ref scratch identity, optimistic CAS, conflicts, leases, legacy adoption, and safe pruning. Host commands and picker/menu integration stay outside.

The key is `{ repo_identity, ref }`, where `ref` is a full symbolic ref or full
detached OID. `open()` returns a stable handle with a content revision and lease.
`save()` compares that revision before each atomic `0600` write and returns a
conflict object instead of overwriting newer content.

Known legacy hashes are adopted in place. Files without v2 metadata remain
outside pruning, so existing Markdown files are neither moved nor duplicated.
Managed files older than 30 days are removed only when not preserved and without
an active lease. Git lookup, commands, mappings and presenters remain host-owned.
