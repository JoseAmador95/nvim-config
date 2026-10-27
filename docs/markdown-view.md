# Markdown reading view

`:MarkdownView` / `<leader>mv` opens one focused, read-only live tab per editable
Markdown source. Repeating it from the source focuses that tab; invoking it in the
view closes the tab and returns to the source. In nvimpager it toggles in place.
`:MarkdownImages` chooses whether the current document may load remote images.

The host adapter is `lua/config/markdown_view.lua`. It checks the shared lock and
injects theme, navigation, pager profile and persisted preferences into the
[standalone reader](../local-plugins/markdown-view.nvim/README.md). The upstream
engine remains stock and pinned. Its private adaptations are isolated in
`markdown_view.compat`; `lua/config/review_markdown.lua` consumes snapshot values
and constructs source-anchored review blocks. Native Review owns comparison,
comments, frozen Git text and presentation.

The refactor consolidates the former readonly, decoration and margin rebuild
wrappers into one boundary. Editor/pager width changes share one reflow path;
initial and scheduled pager rendering share one opening path. Build context and
media policy unwind through one protected call. Review captures attach to a
public `ContentBuilder` instance instead of temporarily replacing shared methods.
The host still owns the owner-only image-approval store. Pin/checkouts and media
capabilities remain checked before adaptation.

The tests cover live view lifecycle, editable sources, complete narrow/Unicode
and natural-width tables, code, headings, virtual margins, wrap changes with
suppressed `OptionSet`, source navigation, image approval/offline behavior and
frozen review source coordinates. `tests/markdown_visual_spec.lua` adds native
Neovim text/attribute screenshots at 48 and 140 columns with wrapping, and at 80
columns without wrapping.

The `tests/screenshots/markdown-*` references were captured with the stock engine
from an untouched archive of pre-refactor configuration commit
`037d8163341796caa0f78c4a4031b47f5804438b`.
They are comparison inputs, not regenerated outputs from the changed reader.
The normal offline validation compares them through pinned `mini.test`. Missing
references fail; updating them requires explicit local
`NVIM_CONFIG_UPDATE_SCREENSHOTS=1` and is forbidden in CI. Capturing a historical
baseline may additionally set `NVIM_CONFIG_SCREENSHOT_SOURCE` to that archive.
