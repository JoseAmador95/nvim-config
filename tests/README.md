# Tests

`mini.test` is a test-only dependency pinned in `config.toolchain`. Install it
alongside the exact validators:

```sh
export NVIM_CONFIG_TEST_DEPS=/absolute/path/to/test-deps
./scripts/install-ci-tools /absolute/path/to/tools/bin
PATH=/absolute/path/to/tools/bin:$PATH ./scripts/check-config
```

The gate is offline and starts a separate Neovim process for each suite and
profile. It checks the dependency's exact commit and clean checkout. Without an
explicit `NVIM_CONFIG_TEST_DEPS`, the installer and gate use `../test-deps` beside
the validation tools' `bin` directory. Focused invocations set it explicitly.

For a focused pure suite, from the repository root:

```sh
NVIM_CONFIG_TEST_DEPS=/absolute/path/to/test-deps nvim --headless -u NONE -i NONE \
  --cmd 'lua vim.opt.runtimepath:prepend(vim.fn.getcwd()); require("config.local_plugins").setup()' \
  -l tests/runner.lua tests/clipboard_spec.lua
```

Local-plugin suites and `tests/local_plugins_spec.lua` manage their own runtime
paths and do not need the `--cmd` registry setup. Screen-geometry suites use
`NVIM_CONFIG_TEST=tests/<suite>_spec.lua` and `-c 'lua dofile("tests/runner.lua")'`
instead of `-l`. Full-profile suites require their fixture environment from
`scripts/check-config`: the runner collects them through `--cmd` before
`init.lua`, then runs them after `VimEnter`. This preserves pre-init observers,
argv fixtures and profile configuration.

Suites return a native `MiniTest.new_set()`. Register cases as
`T["observable behavior"] = function() ... end`. Use native `hooks.pre_case`,
`hooks.post_case`, `hooks.pre_once`, `hooks.post_once`, `MiniTest.finally`, and
`parametrize`; the runner owns reporting and exit status. Move final cleanup
into hooks, and keep setup between groups in nested sets' `pre_once` hooks.
Mocks of `vim.schedule` must be restored in `post_case`, because mini.test uses
the real scheduler between cases. Crash/race child branches remain separate
entry points before the test set is created.

Screenshots use mini.test's text and attribute grid with an explicit reference
path. The runner guards `MiniTest.expect.reference_screenshot` (also exposed as
`require("tests.helpers").screenshot`): missing captures/references fail. Create
or replace references deliberately with `NVIM_CONFIG_UPDATE_SCREENSHOTS=1`,
inspect the resulting diff, then rerun without that flag. CI refuses updates.
