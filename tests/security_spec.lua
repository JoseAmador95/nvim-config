vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p") == 1, "could not create temporary directory")
	return path
end

local function real_git(arguments)
	local command = {
		"git",
		"--no-pager",
		"-c",
		"core.fsmonitor=false",
		"-c",
		"core.hooksPath=/dev/null",
		"-c",
		"commit.gpgsign=false",
	}
	vim.list_extend(command, arguments)
	local environment = {}
	for name, value in pairs(vim.fn.environ()) do
		if not name:match("^GIT_") then
			environment[name] = value
		end
	end
	local result = vim.system(command, { text = true, env = environment, clear_env = true }):wait(10000)
	assert(result.code == 0, table.concat({ result.stdout or "", result.stderr or "" }, "\n"))
	return vim.trim(result.stdout or "")
end

local function create_real_lazy_fixture(root, appname)
	local config_root = root .. "/config"
	local config_lua = config_root .. "/lua/config"
	assert(vim.fn.mkdir(config_lua, "p") == 1, "could not create minimal config fixture")
	for _, name in ipairs({ "fs.lua", "lazy.lua", "lazy_lock.lua" }) do
		assert(
			vim.fn.writefile(vim.fn.readfile(repo .. "/lua/config/" .. name), config_lua .. "/" .. name) == 0,
			"could not copy " .. name
		)
	end

	local checkout = root .. "/data/" .. appname .. "/lazy/lazy.nvim"
	assert(vim.fn.mkdir(checkout .. "/lua/lazy", "p") == 1, "could not create real lazy checkout fixture")
	assert(vim.fn.writefile({
		"return { setup = function(_, options) vim.g.fake_lazy_setup = options.lockfile end }",
	}, checkout .. "/lua/lazy/init.lua") == 0, "could not write real lazy fixture module")
	assert(vim.fn.writefile({ "ignored-plugin.lua" }, checkout .. "/.gitignore") == 0, "could not write ignore fixture")
	real_git({ "-C", checkout, "init", "-q" })
	real_git({ "-C", checkout, "add", ".gitignore", "lua/lazy/init.lua" })
	real_git({
		"-C",
		checkout,
		"-c",
		"user.name=Neovim Security Spec",
		"-c",
		"user.email=nvim-security@example.invalid",
		"commit",
		"-qm",
		"fixture",
	})
	local commit = real_git({ "-C", checkout, "rev-parse", "HEAD" })
	local lock = ('{\n  "lazy.nvim": { "branch": "main", "commit": "%s" }\n}\n'):format(commit)
	assert(
		vim.fn.writefile(vim.split(lock, "\n", { plain = true }), config_root .. "/lazy-lock.json") == 0,
		"could not write fixture lock"
	)
	return config_root, checkout, commit
end

local function write_pinned_fake_git(root)
	local bin = root .. "/bin"
	assert(vim.fn.mkdir(bin, "p") == 1, "could not create fake binary directory")
	local fake_git = bin .. "/git"
	assert(vim.fn.writefile({
		"#!/bin/sh",
		[[printf '%s\n' "$*" >> "$FAKE_GIT_LOG"]],
		[[repo=]],
		[[operation=]],
		[[while [ "$#" -gt 0 ]; do]],
		[[  case $1 in]],
		[[    --no-pager) shift ;;]],
		[[    -c) shift 2 ;;]],
		[[    -C) repo=$2; operation=$3; shift 3; break ;;]],
		[[    clone) operation=clone; shift; break ;;]],
		[[    *) shift ;;]],
		[[  esac]],
		[[done]],
		[[if [ "$operation" = "clone" ]; then]],
		[[  for argument do target=$argument; done]],
		[[  mkdir -p "$target/lua/lazy"]],
		[[  printf '%s\n' 'local M = {}' 'function M.setup(_, options)' '  vim.g.fake_lazy_setup = options.lockfile' 'end' 'return M' > "$target/lua/lazy/init.lua"]],
		[[  exit 0]],
		[[fi]],
		[[if [ "$operation" = "checkout" ]; then]],
		[[  status=${FAKE_CHECKOUT_EXIT:-0}]],
		[[  for argument do commit=$argument; done]],
		[[  if [ "$status" -eq 0 ]; then printf '%s\n' "$commit" > "$repo/.fake-head"; fi]],
		[[  exit "$status"]],
		[[fi]],
		[[if [ "$operation" = "rev-parse" ]; then]],
		[[  if [ "${1:-}" = "--show-toplevel" ]; then]],
		[[    printf '%s\n' "$repo"]],
		[[    if [ "$#" -gt 1 ]; then]],
		[[      if [ -f "$repo/.fake-head" ]; then cat "$repo/.fake-head"; else printf '%s\n' "$FAKE_LAZY_COMMIT"; fi]],
		[[    fi]],
		[[  elif [ -f "$repo/.fake-head" ]; then cat "$repo/.fake-head"; else printf '%s\n' "$FAKE_LAZY_COMMIT"; fi]],
		[[  exit 0]],
		[[fi]],
		[[if [ "$operation" = "ls-files" ] || [ "$operation" = "diff-index" ] || [ "$operation" = "status" ] || [ "$operation" = "symbolic-ref" ]; then]],
		[[  exit 0]],
		[[fi]],
		[[if [ "$operation" = "remote" ]; then]],
		[[  if [ "${1:-}" = "get-url" ]; then printf '%s\n' 'https://github.com/folke/lazy.nvim.git'; fi]],
		[[  exit 0]],
		[[fi]],
		[[exit 64]],
	}, fake_git) == 0, "could not write pinned fake git")
	assert(vim.fn.setfperm(fake_git, "rwxr-xr-x") == 1, "could not make pinned fake git executable")
	return bin
end

local function write_bootstrap_fake_nvim(root)
	local bin = root .. "/bin"
	assert(vim.fn.mkdir(bin, "p") >= 0, "could not create fake binary directory")
	local fake_nvim = bin .. "/nvim"
	assert(vim.fn.writefile({
		"#!/bin/sh",
		[[case $PWD in]],
		[[  "$NVIM_CONFIG_XDG_ROOT"/tmp/bootstrap-cwd.*) : ;;]],
		[[  *) printf 'unsafe bootstrap cwd: %s\n' "$PWD" >&2; exit 88 ;;]],
		[[esac]],
		[[[ "$NVIM_CONFIG_FILE" != "$FAKE_XDG_ROOT/no-local-config.lua" ] || { printf 'predictable local config was reused\n' >&2; exit 89; }]],
		[[[ "$(cat "$NVIM_CONFIG_FILE")" = "return {}" ] || { printf 'bootstrap local config is not inert\n' >&2; exit 89; }]],
		[[if [ -n "${NVIM_CONFIG_PIN_FILE:-}" ]; then]],
		[[  printf 'lazy.nvim|%s|%s\n' "$FAKE_LAZY_BRANCH" "$FAKE_LAZY_COMMIT" > "$NVIM_CONFIG_PIN_FILE"]],
		[[  exit 0]],
		[[fi]],
		[[case $XDG_DATA_HOME in]],
		[[  */data/.bootstrap-data.*) : ;;]],
		[[  *) printf 'config ran outside clean staging data: %s\n' "$XDG_DATA_HOME" >&2; exit 90 ;;]],
		[[esac]],
		[[for profile in nvim nvimpager; do]],
		[[  head_file="$XDG_DATA_HOME/$profile/lazy/lazy.nvim/.fake-head"]],
		[[  [ -f "$head_file" ] || { printf 'missing staged pin for %s\n' "$profile" >&2; exit 91; }]],
		[[  [ "$(cat "$head_file")" = "$FAKE_LAZY_COMMIT" ] || { printf 'stale staged pin for %s\n' "$profile" >&2; exit 92; }]],
		[[  [ ! -e "$XDG_DATA_HOME/$profile/lazy/lazy.nvim/stale-marker" ] || { printf 'stale code copied for %s\n' "$profile" >&2; exit 93; }]],
		[[done]],
		[[printf '%s|%s\n' "$XDG_DATA_HOME" "$*" >> "$FAKE_NVIM_LOG"]],
		[[exit 0]],
	}, fake_nvim) == 0, "could not write fake Neovim")
	assert(vim.fn.setfperm(fake_nvim, "rwxr-xr-x") == 1, "could not make fake Neovim executable")
	return fake_nvim
end

test("local config diagnostics redact environment values without mutating cache", function()
	local root = temp_dir()
	local config_path = root .. "/host.lua"
	local secret = "security-spec-secret-value"
	assert(vim.fn.writefile({
		"return {",
		"  theme = { background = 'light' },",
		"  env = { CONFIG_SECRET = '" .. secret .. "', EMPTY_SECRET = '' },",
		"}",
	}, config_path) == 0, "could not write temporary local config")

	local original_override = vim.env.NVIM_CONFIG_FILE
	vim.env.NVIM_CONFIG_FILE = config_path
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local runtime = local_config.read()
	local display = local_config.display_config()

	assert(display ~= runtime, "display helper returned the runtime cache")
	assert(display.env.CONFIG_SECRET == "<redacted>", "secret value was not redacted")
	assert(display.env.EMPTY_SECRET == "<redacted>", "empty environment value was not redacted")
	assert(runtime.env.CONFIG_SECRET == secret, "display helper mutated the cached secret")
	assert(runtime.env.EMPTY_SECRET == "", "display helper mutated the cached empty value")
	display.theme.background = "dark"
	assert(local_config.read().theme.background == "light", "display snapshot shares nested runtime tables")

	local notifications = {}
	local original_notify = vim.notify
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	local_config.setup()
	vim.cmd("NvimConfigDump")
	local dump = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	assert(dump:find("CONFIG_SECRET", 1, true), "dump removed the environment key")
	assert(dump:find("<redacted>", 1, true), "dump omitted the redaction marker")
	assert(not dump:find(secret, 1, true), "dump disclosed a secret value")

	vim.cmd("NvimConfigReload")
	local message = notifications[#notifications] or ""
	assert(message:lower():find("restart", 1, true), "reload message does not require a restart")
	assert(message:find("runtime", 1, true), "reload message overstates live runtime application")

	vim.notify = original_notify
	vim.env.NVIM_CONFIG_FILE = original_override
	vim.fn.delete(root, "rf")
end)

test("removed Claude credential is never exported while ordinary environment values remain supported", function()
	local root = temp_dir()
	local config_path = root .. "/host.lua"
	local blocked_token = "security-spec-blocked-oauth"
	assert(vim.fn.writefile({
		"return { env = {",
		"  CLAUDE_CODE_OAUTH_TOKEN = '" .. blocked_token .. "',",
		"  SECURITY_SPEC_PUBLIC = 'applied',",
		"} }",
	}, config_path) == 0, "could not write temporary environment config")

	local original_override = vim.env.NVIM_CONFIG_FILE
	local original_oauth = vim.env.CLAUDE_CODE_OAUTH_TOKEN
	local original_public = vim.env.SECURITY_SPEC_PUBLIC
	local original_path = vim.env.PATH
	local original_notify = vim.notify
	local notifications = {}
	vim.env.NVIM_CONFIG_FILE = config_path
	vim.env.CLAUDE_CODE_OAUTH_TOKEN = nil
	vim.env.SECURITY_SPEC_PUBLIC = nil
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end

	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local_config.apply_env()
	local_config.apply_env()
	assert(vim.env.CLAUDE_CODE_OAUTH_TOKEN == nil, "removed Claude credential leaked into vim.env")
	assert(vim.env.SECURITY_SPEC_PUBLIC == "applied", "ordinary environment entry was not applied")
	assert(#notifications == 1, string.format("blocked credential warned %d times instead of once", #notifications))
	assert(notifications[1]:find("will not be exported", 1, true), "blocked credential warning is not actionable")
	assert(local_config.display_config().env.CLAUDE_CODE_OAUTH_TOKEN == "<redacted>", "blocked token was not redacted")
	assert(type(local_config.codecompanion_oauth_token) == "nil", "removed credential helper remains public")

	vim.notify = original_notify
	vim.env.NVIM_CONFIG_FILE = original_override
	vim.env.CLAUDE_CODE_OAUTH_TOKEN = original_oauth
	vim.env.SECURITY_SPEC_PUBLIC = original_public
	vim.env.PATH = original_path
	vim.fn.delete(root, "rf")
end)

test("removed workflow namespaces are rejected by local config", function()
	local root = temp_dir()
	local config_path = root .. "/host.lua"
	assert(vim.fn.writefile({
		"return {",
		"  codecompanion = {},",
		"  notes = { dir = '~/Notes' },",
		"  obsidian = {},",
		"}",
	}, config_path) == 0, "could not write temporary removed-workflow config")

	local original_override = vim.env.NVIM_CONFIG_FILE
	vim.env.NVIM_CONFIG_FILE = config_path
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local runtime = local_config.read()
	for _, key in ipairs({ "codecompanion", "notes", "obsidian" }) do
		assert(runtime[key] == nil, "removed local-config namespace remains: " .. key)
	end
	local errors = table.concat(local_config.errors(), "\n")
	for _, key in ipairs({ "codecompanion", "notes", "obsidian" }) do
		assert(errors:find(key .. ": unknown field", 1, true), "removed namespace was not rejected: " .. key)
	end

	vim.env.NVIM_CONFIG_FILE = original_override
	vim.fn.delete(root, "rf")
end)

test("lazy bootstrap reports clone failure without network access", function()
	local root = temp_dir()
	local bin = root .. "/bin"
	assert(vim.fn.mkdir(bin, "p") == 1, "could not create fake binary directory")
	local fake_git = bin .. "/git"
	assert(
		vim.fn.writefile({ "#!/bin/sh", "printf '%s\\n' '  simulated clone failure  '", "exit 23" }, fake_git) == 0,
		"could not write fake git"
	)
	assert(vim.fn.setfperm(fake_git, "rwxr-xr-x") == 1, "could not make fake git executable")

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. repo,
		"-c",
		"lua local ok, err = pcall(require, 'config.lazy'); if ok then vim.cmd('quitall!') else vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 42') end",
	}, {
		text = true,
		env = {
			PATH = bin .. ":" .. (vim.env.PATH or ""),
			NVIM_LOG_FILE = root .. "/child-nvim.log",
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = "nvim-security-spec",
		},
	}):wait(10000)
	vim.fn.delete(root, "rf")

	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	assert(result.code ~= 0, "bootstrap unexpectedly succeeded")
	assert(output:find("simulated clone failure", 1, true), "clone output was not reported")
	assert(output:find("lazy/lazy.nvim", 1, true), "bootstrap destination was not reported")
	assert(output:find("git exit 23", 1, true), "git exit status was not reported")
	assert(output:find("Check Git/network access", 1, true), "bootstrap error is not actionable")
end)

test("lazy bootstrap checks out the exact lock commit before loading", function()
	local root = temp_dir()
	local bin = write_pinned_fake_git(root)
	local log = root .. "/git.log"
	local locked = assert(require("config.lazy_lock").plugin(repo, "lazy.nvim"))
	local appname = "nvim-security-pinned"

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. repo,
		"-c",
		"lua require('config.lazy'); assert(vim.g.fake_lazy_setup); vim.cmd('quitall!')",
	}, {
		text = true,
		env = {
			PATH = bin .. ":" .. (vim.env.PATH or ""),
			NVIM_LOG_FILE = root .. "/child-nvim.log",
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = appname,
			NVIM_CONFIG_FILE = root .. "/no-local-config.lua",
			FAKE_GIT_LOG = log,
			FAKE_LAZY_COMMIT = locked.commit,
		},
	}):wait(10000)

	local commands = table.concat(vim.fn.readfile(log), "\n")
	local destination = root .. "/data/" .. appname .. "/lazy/lazy.nvim"
	assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
	assert(
		commands:find("clone --filter=blob:none --branch=" .. locked.branch, 1, true),
		"locked branch was not cloned"
	)
	assert(commands:find("checkout --detach " .. locked.commit, 1, true), "locked commit was not checked out")
	assert(commands:find("rev-parse HEAD", 1, true), "bootstrap checkout was not verified")
	assert(vim.fn.isdirectory(destination) == 1, "verified bootstrap was not promoted")
	assert(vim.fn.glob(destination .. ".bootstrap.*") == "", "bootstrap staging directory leaked")
	vim.fn.delete(root, "rf")
end)

test("existing lazy checkout mismatch fails closed before loading or mutation", function()
	local root = temp_dir()
	local bin = write_pinned_fake_git(root)
	local log = root .. "/git.log"
	local loaded_marker = root .. "/stale-loaded"
	local locked = assert(require("config.lazy_lock").plugin(repo, "lazy.nvim"))
	local stale_commit = string.rep("a", 40)
	assert(stale_commit ~= locked.commit, "stale fixture unexpectedly matches the lock")
	local appname = "nvim-security-existing-mismatch"
	local destination = root .. "/data/" .. appname .. "/lazy/lazy.nvim"
	assert(vim.fn.mkdir(destination .. "/lua/lazy", "p") == 1, "could not create stale lazy fixture")
	assert(vim.fn.writefile({ stale_commit }, destination .. "/.fake-head") == 0, "could not write stale head")
	assert(vim.fn.writefile({
		"vim.fn.writefile({ 'loaded' }, vim.env.FAKE_LOADED_MARKER)",
		"return { setup = function() end }",
	}, destination .. "/lua/lazy/init.lua") == 0, "could not write stale lazy module")

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. repo,
		"-c",
		"lua local ok, err = pcall(require, 'config.lazy'); if ok then vim.cmd('quitall!') else vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 42') end",
	}, {
		text = true,
		env = {
			PATH = bin .. ":" .. (vim.env.PATH or ""),
			NVIM_LOG_FILE = root .. "/child-nvim.log",
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = appname,
			NVIM_CONFIG_FILE = root .. "/no-local-config.lua",
			FAKE_GIT_LOG = log,
			FAKE_LAZY_COMMIT = locked.commit,
			FAKE_LOADED_MARKER = loaded_marker,
		},
	}):wait(10000)

	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	local commands = table.concat(vim.fn.readfile(log), "\n")
	assert(result.code ~= 0, "stale existing checkout unexpectedly loaded")
	assert(output:find("Refusing to load lazy.nvim", 1, true), "stale checkout rejection was hidden")
	assert(output:find(locked.commit, 1, true), "expected lock commit was not reported")
	assert(output:find(stale_commit, 1, true), "existing stale commit was not reported")
	assert(output:find("existing checkout was not changed", 1, true), "non-mutation guarantee was omitted")
	assert(vim.fn.filereadable(loaded_marker) == 0, "stale lazy module executed before validation")
	assert(vim.fn.readfile(destination .. "/.fake-head")[1] == stale_commit, "stale checkout was mutated")
	assert(not commands:find("checkout", 1, true), "normal startup tried to repair the existing checkout")
	assert(not commands:find("clone", 1, true), "normal startup tried to replace the existing checkout")
	vim.fn.delete(root, "rf")
end)

test("ignored files in an otherwise locked lazy checkout fail closed", function()
	local root = temp_dir()
	local appname = "nvim-security-ignored"
	local config_root, checkout = create_real_lazy_fixture(root, appname)
	assert(
		vim.fn.writefile({ "return { compromised = true }" }, checkout .. "/ignored-plugin.lua") == 0,
		"could not write ignored plugin fixture"
	)

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. config_root,
		"--cmd",
		"set runtimepath+=" .. repo,
		"-c",
		"lua local ok, err = pcall(require, 'config.lazy'); if ok then vim.cmd('quitall!') else vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 42') end",
	}, {
		text = true,
		env = {
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = appname,
			NVIM_CONFIG_FILE = root .. "/no-local-config.lua",
		},
	}):wait(10000)

	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	assert(result.code ~= 0, "ignored plugin unexpectedly loaded")
	assert(output:find("Refusing modified lazy.nvim checkout", 1, true), "ignored-file rejection was hidden")
	assert(output:find("ignored-plugin.lua", 1, true), "ignored plugin path was not reported")
	vim.fn.delete(root, "rf")
end)

test("hidden Git index flags cannot conceal a lazy checkout", function()
	local root = temp_dir()
	local appname = "nvim-security-index-flags"
	local config_root, checkout = create_real_lazy_fixture(root, appname)
	real_git({ "-C", checkout, "update-index", "--assume-unchanged", "lua/lazy/init.lua" })

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. config_root,
		"--cmd",
		"set runtimepath+=" .. repo,
		"-c",
		"lua local ok, err = pcall(require, 'config.lazy'); if ok then vim.cmd('quitall!') else vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 42') end",
	}, {
		text = true,
		env = {
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = appname,
			NVIM_CONFIG_FILE = root .. "/no-local-config.lua",
		},
	}):wait(10000)

	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	assert(result.code ~= 0, "assume-unchanged checkout unexpectedly loaded")
	assert(output:find("hidden index flags", 1, true), "hidden-index rejection was not actionable")
	vim.fn.delete(root, "rf")
end)

test("Git repository redirect environment cannot bypass lazy validation", function()
	local root = temp_dir()
	local appname = "nvim-security-git-env"
	local config_root = create_real_lazy_fixture(root, appname)

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. config_root,
		"--cmd",
		"set runtimepath+=" .. repo,
		"-c",
		"lua require('config.lazy'); assert(vim.g.fake_lazy_setup); vim.cmd('quitall!')",
	}, {
		text = true,
		env = {
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = appname,
			NVIM_CONFIG_FILE = root .. "/no-local-config.lua",
			GIT_DIR = root .. "/redirected-git-dir",
			GIT_WORK_TREE = root .. "/redirected-worktree",
		},
	}):wait(10000)

	assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
	vim.fn.delete(root, "rf")
end)

test("lazy bootstrap cleans staging when locked checkout fails", function()
	local root = temp_dir()
	local bin = write_pinned_fake_git(root)
	local log = root .. "/git.log"
	local locked = assert(require("config.lazy_lock").plugin(repo, "lazy.nvim"))
	local appname = "nvim-security-checkout-failure"

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. repo,
		"-c",
		"lua local ok, err = pcall(require, 'config.lazy'); if ok then vim.cmd('quitall!') else vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 42') end",
	}, {
		text = true,
		env = {
			PATH = bin .. ":" .. (vim.env.PATH or ""),
			NVIM_LOG_FILE = root .. "/child-nvim.log",
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = appname,
			NVIM_CONFIG_FILE = root .. "/no-local-config.lua",
			FAKE_GIT_LOG = log,
			FAKE_LAZY_COMMIT = locked.commit,
			FAKE_CHECKOUT_EXIT = "24",
		},
	}):wait(10000)

	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	local destination = root .. "/data/" .. appname .. "/lazy/lazy.nvim"
	assert(result.code ~= 0, "checkout failure unexpectedly succeeded")
	assert(
		output:find("Failed to check out locked lazy.nvim commit " .. locked.commit, 1, true),
		"locked commit failure was hidden"
	)
	assert(output:find("git exit 24", 1, true), "checkout exit status was hidden")
	assert(vim.fn.isdirectory(destination) == 0, "failed checkout was promoted")
	assert(vim.fn.glob(destination .. ".bootstrap.*") == "", "failed checkout staging directory leaked")
	vim.fn.delete(root, "rf")
end)

test("bootstrap repairs only its isolated stale checkouts before any config startup", function()
	local root = temp_dir()
	local bin = write_pinned_fake_git(root)
	local fake_nvim = write_bootstrap_fake_nvim(root)
	local git_log = root .. "/git.log"
	local nvim_log = root .. "/nvim.log"
	local locked = assert(require("config.lazy_lock").plugin(repo, "lazy.nvim"))
	local stale_commit = string.rep("b", 40)
	assert(stale_commit ~= locked.commit, "bootstrap stale fixture unexpectedly matches the lock")
	local xdg_root = root .. "/xdg"
	local editor_checkout = xdg_root .. "/data/nvim/lazy/lazy.nvim"
	local pager_checkout = xdg_root .. "/data/nvimpager/lazy/lazy.nvim"
	assert(vim.fn.mkdir(editor_checkout, "p") == 1, "could not create stale isolated checkout")
	assert(vim.fn.writefile({ stale_commit }, editor_checkout .. "/.fake-head") == 0, "could not write stale head")
	assert(vim.fn.writefile({ "stale" }, editor_checkout .. "/stale-marker") == 0, "could not write stale marker")
	assert(vim.fn.mkdir(pager_checkout, "p") == 1, "could not create stale pager checkout")
	assert(vim.fn.writefile({ stale_commit }, pager_checkout .. "/.fake-head") == 0, "could not write stale pager head")
	assert(vim.fn.writefile({ "stale" }, pager_checkout .. "/stale-marker") == 0, "could not write pager stale marker")
	assert(
		vim.fn.writefile({ "error('must not execute')" }, xdg_root .. "/no-local-config.lua") == 0,
		"could not write predictable local config fixture"
	)

	local outside_checkout = root .. "/outside/lazy.nvim"
	assert(vim.fn.mkdir(outside_checkout, "p") == 1, "could not create outside checkout fixture")
	assert(vim.fn.writefile({ "preserve" }, outside_checkout .. "/marker") == 0, "could not write outside marker")
	local source_lock = repo .. "/lazy-lock.json"
	local source_before = assert(require("config.fs").read_binary(source_lock))

	local environment = {
		PATH = bin .. ":" .. (vim.env.PATH or ""),
		NVIM_BIN = fake_nvim,
		FAKE_GIT_LOG = git_log,
		FAKE_NVIM_LOG = nvim_log,
		FAKE_LAZY_BRANCH = locked.branch,
		FAKE_LAZY_COMMIT = locked.commit,
		FAKE_XDG_ROOT = xdg_root,
	}
	local command = { repo .. "/scripts/bootstrap-config", "--xdg-root", xdg_root, "--skip-parsers" }
	local first = vim.system(command, { text = true, env = environment }):wait(30000)
	assert(first.code == 0, (first.stdout or "") .. (first.stderr or ""))
	assert(vim.fn.readfile(editor_checkout .. "/.fake-head")[1] == locked.commit, "editor pin was not repaired")
	assert(vim.fn.readfile(pager_checkout .. "/.fake-head")[1] == locked.commit, "pager pin was not prepared")
	assert(vim.fn.filereadable(editor_checkout .. "/stale-marker") == 0, "stale isolated checkout was reused")
	assert(vim.fn.filereadable(pager_checkout .. "/stale-marker") == 0, "stale pager checkout was reused")
	assert(vim.fn.readfile(outside_checkout .. "/marker")[1] == "preserve", "outside checkout was changed")
	assert(
		vim.fn.readfile(xdg_root .. "/no-local-config.lua")[1] == "error('must not execute')",
		"predictable local config was changed"
	)
	assert(require("config.fs").read_binary(source_lock) == source_before, "source lazy lock was changed")
	assert(vim.fn.glob(xdg_root .. "/data/*/.lazy.previous.*") == "", "checkout backup leaked")
	assert(vim.fn.glob(xdg_root .. "/data/.bootstrap-data.*") == "", "data staging tree leaked")
	assert(#vim.fn.readfile(nvim_log) > 0, "bootstrap never reached a post-preflight Neovim invocation")
	for _, invocation in ipairs(vim.fn.readfile(nvim_log)) do
		assert(invocation:find("/data/.bootstrap-data.", 1, true), "config ran against the reusable destination")
	end

	assert(vim.fn.writefile({}, git_log) == 0, "could not reset fake Git log")
	local second = vim.system(command, { text = true, env = environment }):wait(30000)
	assert(second.code == 0, (second.stdout or "") .. (second.stderr or ""))
	for _, command_line in ipairs(vim.fn.readfile(git_log)) do
		assert(
			not (command_line:find(" clone ", 1, true) and command_line:find("https://github.com", 1, true)),
			"reusable XDG root required a network clone"
		)
	end
	assert(require("config.fs").read_binary(source_lock) == source_before, "reused bootstrap changed source lock")
	assert(vim.fn.readfile(outside_checkout .. "/marker")[1] == "preserve", "reused bootstrap changed outside checkout")
	vim.fn.delete(root, "rf")
end)

test("bootstrap rejects an internal data symlink without touching its outside target", function()
	local root = temp_dir()
	local xdg_root = root .. "/xdg"
	local outside = root .. "/outside"
	assert(vim.fn.mkdir(xdg_root .. "/data", "p") == 1, "could not create symlink fixture parent")
	assert(vim.fn.mkdir(outside, "p") == 1, "could not create outside symlink target")
	assert(vim.fn.writefile({ "preserve" }, outside .. "/marker") == 0, "could not write outside marker")
	local linked, link_err = vim.uv.fs_symlink(outside, xdg_root .. "/data/nvim", { dir = true })
	assert(linked, tostring(link_err))

	local result = vim.system({
		repo .. "/scripts/bootstrap-config",
		"--xdg-root",
		xdg_root,
		"--skip-parsers",
	}, { text = true }):wait(10000)
	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	assert(result.code ~= 0, "bootstrap accepted an internal data symlink")
	assert(output:find("Refusing symlinked nvim data directory", 1, true), "symlink rejection was not actionable")
	assert(vim.fn.readfile(outside .. "/marker")[1] == "preserve", "outside symlink target was modified")
	assert(vim.uv.fs_realpath(xdg_root .. "/data/nvim") == vim.uv.fs_realpath(outside), "symlink fixture was replaced")
	assert(vim.fn.isdirectory(outside .. "/lazy") == 0, "bootstrap escaped through the internal symlink")
	vim.fn.delete(root, "rf")
end)

test("bootstrap lock prevents concurrent staging or promotion", function()
	local root = temp_dir()
	local xdg_root = root .. "/xdg"
	assert(vim.fn.mkdir(xdg_root .. "/.bootstrap-config.lock", "p") == 1, "could not create bootstrap lock fixture")
	assert(
		vim.fn.writefile({ "owner" }, xdg_root .. "/.bootstrap-config.lock/marker") == 0,
		"could not write bootstrap lock marker"
	)

	local result = vim.system({
		repo .. "/scripts/bootstrap-config",
		"--xdg-root",
		xdg_root,
		"--skip-parsers",
	}, { text = true }):wait(10000)
	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	assert(result.code ~= 0, "concurrent bootstrap lock was ignored")
	assert(output:find("Another bootstrap is active", 1, true), "concurrency rejection was not actionable")
	assert(vim.fn.readfile(xdg_root .. "/.bootstrap-config.lock/marker")[1] == "owner", "foreign lock was changed")
	assert(vim.fn.isdirectory(xdg_root .. "/data") == 0, "concurrent bootstrap created staging directories")
	vim.fn.delete(root, "rf")
end)

test("bootstrap rejects lexical spellings of the physical filesystem root", function()
	for _, root_path in ipairs({ "/tmp/..", "/.", "//" }) do
		local result = vim.system({
			repo .. "/scripts/bootstrap-config",
			"--xdg-root",
			root_path,
			"--skip-parsers",
		}, { text = true }):wait(10000)
		local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
		assert(result.code == 2, "physical root spelling was not rejected: " .. root_path)
		assert(output:find("Refusing to use /", 1, true), "physical root rejection was not actionable: " .. root_path)
	end
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("security_spec: %d tests passed", count))
vim.cmd("quitall!")
