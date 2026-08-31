# tab-first.nvim

`tab-first.nvim` canonically opens files into their exact visible split, reuses
an explicitly marked home tab, closes stable tab handles safely, coalesces
tabline clicks, and optionally maintains browser-like semantic history.

Boundary: the plugin owns tab, opening, and semantic-history state only. It does
not load `config.*`, inspect profiles, register global commands or mappings, or
depend on Bufferline, Snacks, sessions, or pickers. Hosts inject those policies
with `setup()` and retain every global surface.

When semantic history is disabled or exhausted, the injected native fallback
receives `-1` for back and `1` for forward.
