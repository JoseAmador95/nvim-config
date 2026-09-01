# diagram-view.nvim

`diagram-view.nvim` is the lifecycle core for extracting, rendering, caching,
and presenting diagrams.

Boundary: the plugin owns selection/fence/buffer extraction, a renderer
registry, cancel-safe sessions, the private v3 cache, PlantUML security policy,
and a presenter registry. It never discovers or installs tools, imports
`config.*`, registers global commands/mappings, or depends on Snacks.

PlantUML jobs always receive `PLANTUML_SECURITY_PROFILE=SANDBOX` unless the host
callback explicitly returns a `local-trusted` decision and recognized profile.
Cache identities include that effective profile. Cache directories and files
are owner-only (`0700`/`0600`); symlinks and non-regular entries are rejected.

The normalized defaults are SVG mode, a 30-second timeout for each renderer
stage, a 16 MiB combined stdout/stderr ceiling per stage, and a cache bounded to
30 days and 256 MiB. Timed-out work is killed; generation checks ensure late
callbacks can neither write cache entries nor reach presenters. Selection
coordinates are accepted by `extract()`, while the host owns visual mappings
and ranged commands.

`setup()` rejects unknown top-level and cache options before replacing state.
Repeated setup cancels active sessions and resets renderer/presenter
registries. `effective_config()` and `status()` return copies before and after
setup, events are copied into the injected callback, and `teardown()` is
repeatable.
