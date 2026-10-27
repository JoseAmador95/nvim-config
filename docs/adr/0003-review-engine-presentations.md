# ADR 0003: Separate diff presentation from source relations

- Status: Accepted; GumTree-specific decisions superseded by [ADR 0005](0005-mise-tooling.md);
  Patience retired on 2026-10-20
- Date: 2026-10-01

## Context

The reviewer previously treated every non-Main engine as a structural projected
diff. Patience needs textual projection, while GumTree should annotate moves and
identifier changes without hiding textual edits. Comments must continue to name
exact frozen Git sources regardless of the selected display.

## Considered alternatives

- Inferring capabilities from engine IDs would couple each new engine to the
  presenter and repeat the existing structural-only assumption.
- Letting GumTree replace textual changes could hide formatting/comments and
  reorder source rows when move relations cross.
- Host Java or build-on-install would make GumTree execution depend on mutable
  user runtimes and compiler/package-manager state.

## Decision

Prepared engines declare native/projected presentation separately from
structural-only semantics and source-coordinate relations.
Main stays default.
Main uses native textual presentation; Difftastic uses its structural projection.
These are the two selectable engines after retiring Patience and GumTree.
Selection is workspace-local and temporary; only comment provenance is persisted.
Historical Patience and GumTree origins remain inert and readable.
The store schema does not change.

The original GumTree design used native textual presentation with validated
move/identifier-update relations, complete installed Neovim Tree-sitter trees
from frozen strings, and a managed private Java runtime.
That implementation was removed by ADR 0005.

## Consequences and limitations

Both engines share layout, context and comment workflows without changing
canonical entries or global diff options.
Main's exact text moves are conservative and omit ambiguous repeats.
Difftastic's supported text fallbacks visibly use Main.
Execution errors retain the prior view.

## Workflow and user decisions

The original selection was Patience plus exact moved blocks plus GumTree.
The user later retired GumTree and Patience while keeping Main and Difftastic.
`ReviewEngine` and its registry-derived completion expose the remaining engines.
Exact moved-block annotations remain part of Main; the reviewer keeps its
existing layout and comment workflow.
