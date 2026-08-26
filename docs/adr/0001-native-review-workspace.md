# ADR 0001: Native code-review workspaces

- Status: Accepted
- Date: 2026-08-25

## Context

TUICR is useful for human review rounds, but its TUI cannot provide Neovim's
LSP diagnostics and source navigation. Ordinary Diffview tabs show exact Git
content, but they do not persist review comments, distinguish review-owned
views from normal Diffview use, or provide a safe route to the current source.

## Decision

Neovim owns a review workspace with an explicit Git identity:

- `working` shows Diffview's live staged, unstaged, and untracked aggregate and
  stores HEAD plus a separate hash for every layer. Any drift invalidates the
  review before another comment or normal export can be accepted.
- `commit`, `range`, and `branch` store full object IDs; branch review uses the
  frozen merge base.
- Diffview renders historical scopes exactly and the working scope as an
  explicitly live, fingerprint-guarded view in a transient, read-only tab. Raw
  Diffview remains independent. Review tabs start with a side-by-side diff and
  can switch in place to a unified inline diff. The review-only toggle
  (`:ReviewLayout`, `<leader>Rv`, or `g<C-x>` inside a review buffer) moves
  deterministically between those two layouts without changing ordinary
  Diffview's layout cycle. Each review-owned Git adapter gets an isolated
  environment that rejects inherited repository routing and ignores local
  shallow/graft metadata, so later Diffview jobs keep the stored object graph.
  `:ReviewCode` (`<leader>Rg`) opens the current real source buffer for LSP use and toggles
  back to the same file, layer, side, line, and history entry. That exact return
  target follows normal tab-based editor navigation, including LSP and picker
  destinations outside the reviewed diff or repository, until the review is
  replaced or closed.
- Comments use six explicit types: issue, suggestion, rationale, question,
  pedantic, and praise. They are persisted under
  `stdpath("state")/nvim-config/reviews/v1`, rendered with their original code
  context, and shown through a dedicated Trouble source and sign namespace.
  Diffview's `g?` help includes the review actions only in review-owned views.
  Normal-mode `<leader>Ra` comments on the cursor line; Visual-mode
  `<leader>Ra` comments on every touched line as one inclusive range.
  `<leader>Rl` lists navigable comments without mutating them, while
  `<leader>Rd` and `<leader>Rc` disambiguate overlapping current-line comments
  with a picker before deleting one or changing its type. `<leader>Rt` remains
  the persistent Trouble thread panel.
- Clipboard export locks only comments that were copied successfully. A linked
  TUICR round is accessed only through `tuicr-round`; successful remote writes
  use stable delivery keys and are persisted one at a time. Review state uses
  an owner lock and revision check so a second Neovim cannot overwrite it.
- Auto-session temporarily closes transient review tabs while serializing the
  normal editing session, then restores them on the next event-loop tick. It
  delegates transient teardown to the review hook instead of closing unknown
  windows before that hook can preserve them.
- A comment editor stays open when validation or persistence rejects its
  submission. Direct tab closes save its current text, and `VimLeavePre`
  synchronously saves open composers plus owner-only Markdown recovery for
  any unresolved write conflict before a global exit.

The workflow never checks out, fetches, stages, restores, resets, updates a Git
ref, or writes an object. Working-tree drift marks a saved review stale instead
of remapping its anchors.

## Consequences

Historical diff buffers intentionally do not run LSP in either presentation
layout, and commit history is browse-only because a persisted comment anchor
does not encode a log entry. `:ReviewCode` followed by ordinary source
navigation remains the supported LSP path; inherited source tabs return to the
original exact review target rather than treating the definition destination
as part of the diff. The integration isolates pinned
Diffview seams for the selected file, history entries, file-open lifecycle, and
exact file selection in `config.review_diffview`; plugin upgrades must exercise
its focused tests and the full offline config check.

TUICR remains optional. Its TUI workflow and existing `:TuicrReview` command
continue to work independently of native reviews.
