# repo-scratch.nvim

Boundary: durable repository/ref scratch identity, optimistic CAS, conflicts, leases, legacy adoption, and safe pruning. Host commands and picker/menu integration stay outside.

The key is `{ repo_identity, ref }`, where `ref` is a full symbolic ref or full
detached OID. `open()` returns a stable handle with a content revision and lease.
`save()` compares that revision before each atomic `0600` write and returns a
conflict object instead of overwriting newer content. Content is bounded to
1 MiB; an oversized save is rejected before lease renewal or any write. Every
open, lease change, save, release, and prune decision is serialized by immutable,
exclusive choosing/ticket claim files (a Lamport bakery arbiter) for that scratch.
Dead processes' unique claims can be removed without a shared-path
compare-then-unlink race. Claim metadata is completely written, `fsync`ed, and
descriptor-verified under a token-reserved unrecognized staging name before an
atomic rename publishes it. Pre-rename crash leftovers are ignored; published
claims remain structurally complete and reclaimable after their owner dies. A
save renews the same lease under the arbiter before committing content and
reports success only after both operations complete.

Known legacy hashes are adopted in place. Files without v2 metadata remain
outside pruning, so existing Markdown files are neither moved nor duplicated.
Managed files older than 30 days are removed only when not preserved and without
an active lease. Only an absent lease or an exact, well-formed expired lease is
reclaimable. Corrupt, truncated, oversized, schema-invalid, symlinked, and
hard-linked leases fail closed in open/save/prune. Pruning derives each candidate
from the enumerated metadata filename, requires matching v2 metadata and a direct
single-link regular child of the private state root, and never uses
`metadata.path` as a deletion target. The state-root device/inode is pinned;
opened descriptors are identity-checked and permission changes use descriptors,
so root substitution and pathname chmod races are rejected. Git lookup, commands,
mappings and presenters remain host-owned.

Prune retains the per-scratch arbiter through expired-lease, metadata, and
scratch reservation/unlink cleanup. The protocol is cooperative and owner-only:
because POSIX lacks atomic compare-and-unlink after a final exact snapshot, the
OS owner UID is the trust boundary. Quarantine preserves replacements made by
cooperating writers but cannot defend against hostile same-UID mutation after
that last snapshot.
