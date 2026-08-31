# Local plugin shared contracts

Boundary: pure value normalization shared by the repository-local plugins. It owns no UI, commands, mappings, persistence, process lifecycle, or host configuration.

The `local_plugins.contracts` module exposes `normalize_workspace_key`, `normalize_snapshot`, `normalize_action_target`, `normalize_terminal_spec`, and `normalize_tool_identity`; successful results are caller-owned deep copies.
