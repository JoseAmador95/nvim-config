# Verified runtime consumers

`verified-tools.nvim` is the only authority for release-managed and Mason-managed
executables. A successful install is not enough by itself: each consumer asks
`config.tool_bootstrap.resolve(tool, command)` for an absolute path immediately
before its process boundary. Missing, stale, corrupt, or drifted records fail
closed and never fall through to `$PATH` or a project-local `node_modules/.bin`.

## Process boundaries

| Consumer | Runtime boundary |
| --- | --- |
| Native LSP | Every managed server has a function-valued `cmd`. Root activation performs an observational availability check; the `cmd` resolves again immediately before `vim.lsp.rpc.start`. |
| clangd | The compile-database router freezes the selected database for each restart, while the executable is resolved again at the RPC boundary. A configured absolute override must equal the attested executable. |
| Conform | Each formatter command function resolves the manifest command immediately before Conform starts it. |
| nvim-lint | A copied linter definition receives a command function that resolves immediately before `uv.spawn`. |
| DAP | debugpy and codelldb resolve after durable `debug` authority and immediately before the adapter callback receives its launch command. |
| Diagrams | Managed mmdflux and PlantUML resolve for each render request before the cancellable stage pipeline is built. |
| JQX / JsonTree | The host adapter resolves jq for each request and invokes it as an argv vector with buffer content on stdin. The pinned `nvim-jqx` package supplies visual defaults only; its shell-string commands, completion functions, mapping, and autocmd are synchronously reclaimed. |

Loading the consumer modules does not resolve, probe, install, repair, or start a
tool. Opening a buffer whose native LSP applies is an actual use: its root gate
performs the metadata-only lookup. If authority is absent, it withholds the root
callback and emits one bounded warning instead of aborting the `FileType` event.

Approval of a project `plugins.clangd_compile_db.path` value is configuration
authority, not executable attestation. A relative value other than the canonical
`clangd` command, or an absolute value different from the currently certified
path, is retained in the effective config but blocks the launch with a clear
error.

## Explicit host-tool exceptions

Some tools are intentionally outside the release/Mason catalogue:

- `rust-analyzer` remains an optional host/user executable. Its lookup is delayed
  until a Rust buffer activates the client, and the path resolver excludes Mason,
  managed-tool, and verified-shim roots.
- `just` remains subject to the Just workbench's content-closure trust plus the
  durable `build` grant. Discovery and execution are bound to the same canonical
  host executable.
- CMake/CTest and platform helpers such as `rsvg-convert`, `osascript`, `wl-copy`,
  and `xclip` are host facilities. They are canonicalized or capability-gated by
  their adapters; they are not represented as verified-tools managed packages.

These exceptions must not be described as verified-tools attestations. Adding a
host utility to the managed catalogue requires an exact version/integrity
contract first.
