# ADR 0004: Compare rendered Markdown while preserving source anchors

- Status: Accepted
- Date: 2026-10-06

## Context

Source diff engines expose exact Markdown edits but do not directly show how a
reader experiences them. Rendered rows can join several source lines, expand a
table or code fence, or omit a link definition. Display columns and Git line
coordinates therefore cannot be treated as interchangeable.

## Considered alternatives

- A separate live Markdown diff viewer would duplicate Review's layouts and
  comments, and could compare mutable buffers with historical Git content.
- Painting Git hunks over rendered rows would mark hidden source edits and
  fabricate precise anchors where several source lines form one visual block.
- Using a source diff engine to classify visual changes would make equivalent
  Markdown syntax or wrapping depend on the selected textual algorithm.

## Decision

Review keeps source as its initial view and renders frozen Markdown on demand.
A host adapter uses the guarded, pinned md-render renderer to produce blocks,
visible styles and original source ranges. The plugin aligns visual blocks and
refines words only within corresponding units. Tables with matching visible
headers, columns and alignment expose logical row blocks, so a cell edit or row
insertion/deletion leaves other rows as context. Their wrapped grid rows and
field/value cards anchor the original single source row; bottom borders have no
anchor. Header/schema changes keep the whole-table fallback. Code fences with
matching languages and containers expose original source-line blocks, retaining
unchanged, shifted and repeated lines as context. Wrapped code fragments anchor
one original source line. Syntax captures come from each complete frozen fence
before wrapping or mixing sides, and the diff backgrounds preserve their colors.
Syntax recoloring does not classify line edits; missing optional language parsers
or queries keep plain code. Language/container changes retain the whole-block
fallback. Layout changes use
shared widths and explicit filler rows; resize remaps cached comparison results
onto new rows.
The source engine preference stays separate and selecting an engine prepares
its source presentation before replacing the current view.

Rendered comments anchor complete original Markdown blocks, table rows or code
lines on one side. Fillers,
mixed sides and selections that skip source content cannot become range anchors.
Comments on hidden source content remain accessible by returning to source.
The exact Git model, canonical hunks and store v3 remain unchanged; provenance
records the visual comparator and renderer version.

## Consequences and limitations

The reader can compare inline or aligned side-by-side renderings through the
existing Review commands. Hidden link destinations and visually equivalent
source edits do not receive visual markers, so source review remains necessary
for those changes. Structural or ambiguous replacements keep whole-block
backgrounds. Rendered buffers are protected and never attach LSP clients.

The host adapter depends on the pinned builder's rendering contract and source
map, so renderer upgrades require snapshot and screen-layout verification. Image
references are frozen text only; building the comparison loads no pictures,
downloads or diagram processes. An explicit host `DiagramShow` action resolves
the selected side to a detached frozen document and previews a Mermaid/PlantUML
fence on demand. Rendered selections within one fence preview the complete frozen
fence; mixed sides,
fillers and multiple diagram blocks are rejected. Current image files remain
unavailable from Review. Parser/renderer and engine errors keep the previous
presentation.

## Workflow and user decisions

The user chose integration with Review, source first, rendered word detail where
correspondence exists, comments on original blocks, and references-only media.
The user also chose visual-only markers, retaining hidden changes in source.
The later requests to compare tables by row and code fences by source line with
syntax highlighting refine comparison granularity while
keeping the same frozen sources, source engine and comment persistence contract.
`:ReviewMarkdown [source|render|toggle]` and `<leader>rM` control the new view;
existing layout and context commands apply to both views.
