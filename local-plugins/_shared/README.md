# Local plugin shared contracts

Boundary: pure value normalization shared by the repository-local plugins. It owns no UI, commands, mappings, persistence, process lifecycle, or host configuration.

The `local_plugins.contracts` module exposes `normalize_workspace_key`, `normalize_snapshot`, `normalize_action_target`, and `normalize_terminal_spec`; successful results are caller-owned deep copies. `exact_options` validates option allowlists and returns `true` or `nil, error`.
