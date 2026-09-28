# ADR 0002: Native review owns one transient tab

- Status: Accepted
- Date: 2026-09-02
- Supersedes: [ADR 0001](0001-native-review-workspace.md) only for tab ownership and session UI lifecycle

## Context

ADR 0001 deliberately rendered reviews inside an ordinary editing tab. In
practice, opening review mode replaced the user's current layout and made
`<leader>rm` destructive to the tab from which it was invoked. A review already
has a logical lifecycle independent of its buffers and windows: the frozen
model, store, scope stack, and unsaved-recovery state can remain active while its
presentation is absent.

`tab-first.nvim` now provides generation-safe transient leases with synchronous
close preflight and exact close reconciliation. That contract lets the reviewer
own a UI tab without owning normal file tabs or teaching the standalone plugin
about host configuration.

## Decision

The native-review controller acquires one transient lease with identity
`{ owner = "native-review", key = "workspace" }`. Its visible title is
`Review: <repository basename> · <scope label>`.

- `ReviewOpen` validates and freezes the scope, model, and store before it
  acquires the tab. Interactive open and refresh run through generation-bound
  scheduled coroutines, with cooperative checkpoints between bounded Git calls
  and batches, files, and diffs. A newer operation, close, or teardown
  cancels stale completion; the prior visible review stays active until the
  replacement is complete. Reopening, drilling into commits, and returning to
  a parent scope focus and retitle that same live lease.
- The controller records the last valid ordinary invocation independently from
  review windows. `ReviewClose` and UI-only release return to it when it remains
  valid; review-internal transitions never overwrite it.
- `ReviewMode off` prepares any composer, tears down presenter and panel
  resources, and releases the lease while keeping the logical review active.
  `ReviewMode on` acquires a fresh generation and rebuilds the presentation from
  logical UI state. Window and buffer handles from a released generation are
  never reused.
- Supported close paths run synchronous composer preparation and may be vetoed.
  A raw external tab close cannot be vetoed reliably; existing `WinClosed`
  recovery runs best-effort, and lease reconciliation leaves the logical review
  active but visually off. A delayed callback for an old generation cannot
  affect a replacement tab.
- `ReviewClose` remains the only operation that removes the active logical
  workspace. Its existing verified recovery and force rules still apply.
- Before auto-session serializes, the review tab is physically released. Only a
  successful explicit manual session save may schedule UI restoration. Auto-save,
  failed saves, and exit never reacquire it, so session files cannot contain the
  transient review tab or its buffers.

The standalone plugin receives only the five-method tabs adapter through
`setup(opts)`: `acquire_transient`, `focus_transient`, `rename_transient`,
`release_transient`, and `valid_transient`. It does not import `config.*` or own
global commands and mappings.

## Consequences

Opening a review no longer replaces an ordinary tab. Review UI handles are
disposable and generation-bound, while frozen models, comments, scope history,
CURRENT-only LSP rules, and persistence contracts remain unchanged.

Turning review mode back on costs a deliberate presentation rebuild. External
raw close paths can report recovery failure but cannot keep an already-closing
tab alive; supported host close paths remain vetoable and are preferred.
