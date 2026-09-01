# treesitter-runtime.nvim

Boundary: profile allowlists, installed-only attachment, current-buffer size limits, highlight/indent lifecycle, explicit retry, and teardown. Parser lists, installation, commands, mappings, and plugin specs stay outside.

`treesitter-runtime.nvim` manages automatic Tree-sitter attachment for parsers
that are already installed. It owns no parser manifest, installation command,
global mapping, profile selection, or repository configuration.

```lua
require("treesitter_runtime").setup({
  profile = "editor",
  allowlist = { "lua", "python" },
  max_bytes = 200 * 1024,
  highlight = true,
  indent = true,
  installed = function()
    return { "lua" }
  end,
})
```

The runtime attaches only when the current buffer is loaded, its mapped language
is allowlisted, the parser is reported by `installed()`, highlighting is enabled,
and the current in-memory contents fit `max_bytes`. File size on disk is never
used, so unsaved growth and shrinkage are handled by buffer lifecycle events.

`setup()` also accepts replaceable `start(buf, language)`, `stop(buf, language)`,
`is_started(buf, language)`, `language(buf)`, and `buffer_bytes(buf)` callbacks.
`enabled = false` disables the selected profile. Calling `setup()` repeatedly is
idempotent: its autocmds are replaced and eligible existing attachments remain.

`retry([buf])` refreshes the installed-parser snapshot and retries eligible
buffers. Hosts call it after an explicit parser installation. This plugin never
installs or downloads parsers itself.

`teardown([buf])` stops every parser managed by the runtime, including one that
was already active when an eligible buffer was first observed. The same parser
is stopped when the buffer becomes ineligible and is started again on eligible
re-entry. An attachment whose parser was stopped externally is recovered by the
next lifecycle evaluation or explicit `retry()`. When indentation is enabled,
the exact previous `indentexpr` is restored only while the plugin still owns the
value it wrote; a pre-existing value or later external change is left untouched.
After complete teardown, a later `setup()` creates a fresh runtime profile.
