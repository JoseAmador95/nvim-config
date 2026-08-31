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
