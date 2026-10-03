# ADR 0003: Separate diff presentation from source relations

- Status: Accepted
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
structural-only semantics and source-coordinate relations. Main stays default.
Patience owns a textual projection. Difftastic keeps its structural projection.
GumTree uses native textual presentation with validated move/identifier-update
relations. Selection is workspace-local and temporary; only comment provenance
is persisted. Existing origins and the store schema do not change.

GumTree receives complete installed Neovim Tree-sitter trees from frozen strings,
including anonymous tokens and comments. The plugin owns XML export and JSON
validation; a host adapter owns verified execution, limits and cancellation.
Its fixed Maven artifacts and private Java runtime form one attested package,
installed only through an explicit managed-tool command.

## Consequences and limitations

All four engines share layout, context and comment workflows without changing
canonical entries or global diff options. Exact text moves are conservative and
omit ambiguous repeats. GumTree relations can describe moved-and-edited nodes,
but are syntactic and file-local. Its initial four languages require installed
parsers; unsupported or over-budget files visibly use Main. Execution errors
retain the prior view.

The private JRE increases download/storage cost and the pinned artifact closure
requires coordinated updates. Platform libraries remain host facilities; the
package does not attest the operating system. Bounds deliberately exclude large
or deeply nested files from structural analysis.

## Workflow and user decisions

The user chose Patience plus exact moved blocks plus GumTree, asked GumTree to
retain the textual diff, and selected managed private Java. `ReviewEngine` and
its registry-derived completion expose the engines; `NvimConfigToolsInstall
gumtree` is the explicit install/repair path. No startup install or parser
installation is added.
