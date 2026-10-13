# ADR 0005: Use Mise for editor tools

- Status: Accepted
- Date: 2026-10-08

## Context and decision

Replace Mason and the custom verified-tools installation and runtime attestation
layers with Mise. Keep the existing consumer interfaces by generating small
absolute launchers that invoke `mise exec` with the committed editor catalog.
The wrapper preserves cwd, argv and stdin and excludes project/global Mise
configuration. Consumers retain execution grants, deadlines and cancellation.

Mise is a user prerequisite. The optional explicit command
`:NvimConfigMiseInstall` (or `scripts/install-mise`) installs it into
`~/.local/bin/mise`. Startup and provisioning never bootstrap it. Editor and
pager share tools in `~/.local/share/mise/installs` and state in
`~/.local/state/mise`. Normal `mise exec` installs missing tools; offline mode
disables downloads. Explicit tool installation supports prewarming and force
reinstallation without changing versions.

`config.toolchain` remains the pure Lua source for pins and generates native
`mise.toml`. Commit it with `mise.lock` and npm/Python graph sidecars in
`.mise/locks`. Only explicit maintenance regenerates locks. Pin Dev Containers
to 0.89.0, Node to 24.20.0, tools' Python to 3.13.16 and uv to 0.12.23. Project
Python selection and external-only Rust remain independent.

Remove GumTree's engine, adapters and installation closure. Its historical
comment origin metadata remains readable. Other review engines and the separate
Markdown review work remain intact. Supersedes the GumTree-specific portions
of ADR 0003; its generic presentation/source-coordinate contract still applies.

## Consequences

Mise owns install-time artifact and graph verification. The editor no longer
rehashes installed tools or certifies host alternatives. Old managed/Mason
trees remain on disk but are excluded from resolution. A cold tool download
can exceed an existing consumer deadline; preinstall the tool and retry.

`provision-runtime` advances to contract v2 with Mise/tool inventories and all
lock digests, preserving private atomic reports, offline default, extras and
strict managed-path checks. External custom-cloud still consumes v1 and requires
a separate update; it is not modified here. Linux ARM64 cannot provision the
whole catalog until its missing mmdflux, clangd and Markdown Preview assets are
pinned. macOS x64 PlantUML retains its host-Java requirement.
