# diagram-view.nvim

`diagram-view.nvim` is the lifecycle core for extracting, rendering, caching,
and presenting diagrams.

Boundary: the plugin owns selection/fence/buffer extraction, a renderer
registry, cancel-safe sessions, the private v3 cache, PlantUML security policy,
and a presenter registry. It never discovers or installs tools, imports
`config.*`, registers global commands/mappings, or depends on Snacks.

`extract()` also recognizes Markdown image references once no fence owns the
cursor row, returning `kind = "image"` with the raw reference as the source.
`image_link` parses inline, reference-style, and single-line HTML forms as pure
strings: it never touches the filesystem, so resolving a reference to a file,
deciding which media is loadable, and reading it stay with the host. A fence
always wins over an image on the same row, and an extraction carries the cursor
column when the caller has one — a row without a column is the rendered reading
view, which maps rows but never columns.

PlantUML jobs always receive `PLANTUML_SECURITY_PROFILE=SANDBOX` unless the host
callback explicitly returns a `local-trusted` decision and recognized profile.
Cache identities include that effective profile. Cache directories and files
are owner-only (`0700`/`0600`); symlinks and non-regular entries are rejected.

The normalized defaults are SVG mode, a 30-second timeout for each renderer
stage, a 16 MiB combined stdout/stderr ceiling per stage, and a cache bounded to
30 days and 256 MiB. The default process adapter streams stdout/stderr only up
to that ceiling and terminates an overflowing renderer instead of first
buffering its complete output. Timed-out work is killed; generation checks
ensure late callbacks can neither write cache entries nor reach presenters.
Presenter-driven close events cannot reenter session cancellation. Selection
coordinates are accepted by `extract()`, while the host owns visual mappings
and ranged commands. A request `on_done` callback is completed at most once on
presentation, failure, or successful cancellation, including runner exceptions
and duplicate late completions.

The repository host adapter resolves managed `mmdflux` and PlantUML commands
through `verified-tools.nvim` immediately before an explicit render. This
resolution stays deferred until `:DiagramShow`; it never installs or repairs a
tool. The local `rsvg-convert` dependency is likewise passed to the renderer as
an exact resolved path rather than a PATH basename.

`setup()` rejects unknown top-level and cache options before replacing state.
Repeated setup cancels active sessions and resets renderer/presenter
registries. `effective_config()` and `status()` return copies before and after
setup, events are copied into the injected callback, and `teardown()` is
repeatable.
