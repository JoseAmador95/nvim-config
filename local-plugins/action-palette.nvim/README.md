# action-palette.nvim

`action-palette.nvim` validates and registers action catalogs, captures exact
editor targets, revalidates availability immediately before dispatch, owns
intrinsic confirmations, and binds every presented action to one execution.

## Boundary:

The plugin never imports `config.*`, opens UI, or registers global commands or
mappings. `setup(opts)` accepts confirmation, notification, target and context
refresh adapters; a confirmation fails closed when no adapter was injected.
Snacks, menu.nvim and `vim.ui.select` remain host presentation surfaces.

The curated inventory remains host-owned in `lua/config/menu/catalog.lua` and
`lua/config/menu/actions.lua`: 292 explicit descriptors and 89 context-menu
exposures. That is the audited 298-item inventory minus the six retired
TUICR/Agent descriptors; the plugin does not synthesize or discover actions.

`ActionTarget` is exact and immutable:

```lua
{
  bufnr = 1,
  winid = 1000,
  tabpage = 1,
  cursor = { line = 12, col = 4 },
  changedtick = 7,
}
```

Before execution the target must still identify the same live tab, window,
buffer, cursor and changedtick. Availability is recomputed against refreshed
host context. Confirmation belongs to the action definition and therefore
applies identically on every surface. A bound callback is consumed by its first
attempt, including cancellation or failed revalidation.

Run the standalone tests from the configuration root:

```sh
nvim --headless -u NONE -i NONE \
  -l local-plugins/action-palette.nvim/tests/action_palette_spec.lua
```
