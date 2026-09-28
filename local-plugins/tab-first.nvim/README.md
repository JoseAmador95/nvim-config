# tab-first.nvim

`tab-first.nvim` canonically opens files into their exact visible split, reuses
an explicitly marked home tab, closes stable tab handles safely, coalesces
tabline clicks, and optionally maintains browser-like semantic history.

Boundary: the plugin owns tab, opening, and semantic-history state only. It does
not load `config.*`, inspect profiles, register global commands or mappings, or
depend on Bufferline, Snacks, sessions, or pickers. Hosts inject those policies
with `setup()` and retain every global surface.

When semantic history is disabled, or before it has recorded its first entry,
the injected native fallback receives `-1` for back or `1` for forward plus the
requested count. Once a semantic stack exists, reaching either boundary never
falls through to a window-local native jumplist.

The default semantic history is workspace-scoped, enabled, and bounded to 200
entries. Home-buffer classification is entirely injected; the plugin contains
no Snacks dashboard knowledge. `setup()` validates the complete object before
replacement, coalesced callbacks are generation-bound, and `teardown()` safely
invalidates pending work. `effective_config()`, `status()`, and history
snapshots are copied. Opening and history events are copied before reaching the
optional event adapter.

Hosts can extend the stack to non-file surfaces with
`history.capture_location()` and `history.restore_location(entry)`. Provider
entries use stable `provider`, `document_key`, and `location_key` identities,
plus a display `label` and opaque table `payload`; restoration succeeds only
when the callback returns exactly `true`. Returning `false` without an error
marks an entry stale and lets traversal skip it. Callback exceptions, `nil`, or
an error return abort traversal without advancing into older entries; an
optional third `true` says the provider already reported that error. Capture
may return `nil` for a neutral non-provider location, or `nil, err` for an
operational failure that must be reported. Malformed file and provider entries
are rejected before they can mutate the stack. Asynchronous openers may pass a
previously captured `history_origin` to `open()` so delayed responses retain
the location where navigation was invoked.
