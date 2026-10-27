# markdown-view.nvim

Boundary: live read-only Markdown views and value-only render snapshots over stock
`md-render.nvim` v3.10.3 (`cb79d5a1c4cd929fe0144c4d75be50a1ad4c2c74`). The
host owns commands, mappings, theme, navigation, profile selection and approval
persistence. Review comparison, Git state and comments remain outside this plugin.
There are no `config.*` imports, repository paths or global commands here.

Neovim 0.12+ and the stock engine are required. Add this directory to runtimepath,
then configure with already loaded dependencies:

```lua
local reader = require("markdown_view")
local engine = require("md-render")
local image = require("md-render.image")
local wrap = require("md-render.wrap")

assert(reader.setup({ engine = engine, image = image, wrap = wrap }))
vim.keymap.set("n", "<leader>mv", reader.toggle)
```

`setup()` rejects unknown options before mutation. Requiring the module and calling
`status()` / `effective_config()` never loads the engine, probes the terminal or
reads Git; the observations are caller-owned tables. The exact loaded checkout,
its cleanliness and required APIs are verified at `setup()` before adaptation.
No installed dependency file is modified and nothing is installed automatically.

Optional setup callbacks:

- `pager() -> boolean`: use an in-place source/render toggle instead of a focused
  live tab. The default is the editor view.
- `theme()`: apply host highlights, initially and when opening a view.
- `attach(session)`: add host mappings to an editor view. Navigation receives
  `buf`, `source_bufnr` and live `content` (including byte-column links, heading
  anchors and source-line mappings).
- `preferences = { get(path), set(path, approved) }`: persist remote-image approval
  by canonical document path. Without these callbacks, approval lasts only for
  this session and the menu offers no persistent choice.

`toggle()`, `images()`, `set_wrap(enabled, win?)` and `diagram_target(selection?)`
are the action API. `pager_show_source(win)`, `pager_filetype_changed(buf)` and
`pager_initial_render()` support explicit pager lifecycle wiring. `set_wrap()`
updates the session even when Neovim suppresses `OptionSet` in callbacks.

`build_snapshot(lines, opts)` returns `content, error, captures, library`. With
`opts.nvim_config_review = true`, media stays inert and captures retain original
unwrapped prose/table spans. `library.Markdown` is the stock public parser API;
`library.resolve_language()` supplies the pinned language alias translation.
The host turns these values into its original-source review blocks.

The page uses 90% of usable width, capped at 120 columns. Margins are virtual text,
so cursor positions, selections and yanks contain only page content. Tables and
code stay complete. Narrow tables become field/value rows; nowrap uses their
natural width. One session rebuild boundary restores readonly, decorations,
virtual margins and window wrap together. Pager windows retain their own width.

Images require Kitty graphics outside tmux. Local paths are checked before the
engine can expand them. Remote images require document approval and bounded https
fetches; `NVIM_CONFIG_OFFLINE=1` blocks downloads. Automatic diagrams and videos
are disabled. The host can offer a separate on-demand diagram viewer.

`compat.lua` owns every engine function replacement, session rebuild wrapper and
image-placeholder write exception. The table/layout/decorations modules transform
values or decorate buffers. Review captures attach methods to one public
`ContentBuilder` instance; no shared builder methods are swapped per snapshot.
