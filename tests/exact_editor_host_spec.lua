vim.o.shadafile = "NONE"
vim.o.swapfile = false

local config_repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(config_repo)
package.path = table.concat({ config_repo .. "/lua/?.lua", config_repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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

local function git(arguments)
	local command = { "git" }
	vim.list_extend(command, arguments)
	local result = vim.system(command, { text = true }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout or "")
end

local fixture = vim.fn.tempname()
local state = vim.fn.tempname()
local outside = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
assert(vim.fn.writefile({ "target" }, fixture .. "/target.lua") == 0)
assert(vim.fn.writefile({ "outside" }, outside) == 0)
git({ "-C", fixture, "init", "-q" })
assert(vim.uv.fs_symlink(outside, fixture .. "/escape.lua"))
local root = assert(vim.uv.fs_realpath(fixture))
local external = assert(vim.uv.fs_realpath(outside))
local external_files = { outside }
local original_environment = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_EXACT_EDITOR_RUNTIME = vim.env.NVIM_EXACT_EDITOR_RUNTIME,
	NVIM_EXACT_EDITOR_WORKSPACE_ROOT = vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT,
	NVIM_EXACT_EDITOR_REPO_IDENTITY = vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY,
}
vim.env.NVIM_DEVCONTAINER = nil
vim.env.NVIM_EXACT_EDITOR_RUNTIME = nil
vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = nil
vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = nil

local function temporary_text(lines)
	local path = vim.fn.tempname()
	assert(vim.fn.writefile(lines or { "outside" }, path) == 0)
	external_files[#external_files + 1] = path
	return assert(vim.uv.fs_realpath(path))
end

local rpc = require("config.exact_editor")
assert(package.loaded.exact_editor == nil, "host adapter imported exact-editor at module load")

test("host adapter coalesces one delayed activation without importing the core", function()
	local callbacks = {}
	local delays = {}
	local entered = false
	local setups = 0
	assert(type(rpc._options().open) == "function", "core-free host options are incomplete")
	assert(package.loaded.exact_editor == nil, "host option construction imported exact-editor")
	local deps = {
		activation_delay_ms = 137,
		has_entered = function()
			return entered
		end,
		ui_count = function()
			return 1
		end,
		defer_fn = function(callback, delay)
			callbacks[#callbacks + 1] = callback
			delays[#delays + 1] = delay
		end,
		setup = function()
			setups = setups + 1
			return true
		end,
	}
	rpc.setup_deferred(deps)
	rpc.setup_deferred(deps)
	assert(#callbacks == 0, "attached UI bypassed the UIEnter lifecycle boundary")
	entered = true
	vim.api.nvim_exec_autocmds("UIEnter", { modeline = false })
	assert(#callbacks == 1 and setups == 0, "delayed activation was not coalesced")
	assert(delays[1] == 137, "configured activation delay was not forwarded")
	assert(package.loaded.exact_editor == nil, "queued activation imported exact-editor before its callback")
	callbacks[1]()
	assert(setups == 1, "delayed activation did not run exactly once")
	assert(package.loaded.exact_editor == nil, "injected activation unexpectedly imported the core")
	assert(rpc.teardown(), "adapter teardown failed after injected activation")
end)

test("a detached UI at the deadline keeps activation dormant and retryable", function()
	local callbacks = {}
	local setups = 0
	local uis = 1
	rpc.setup_deferred({
		activation_delay_ms = 0,
		has_entered = function()
			return true
		end,
		ui_count = function()
			return uis
		end,
		defer_fn = function(callback)
			callbacks[#callbacks + 1] = callback
		end,
		setup = function()
			setups = setups + 1
			return true
		end,
	})
	assert(#callbacks == 1, "initial attached UI did not queue activation")
	uis = 0
	callbacks[1]()
	assert(setups == 0, "activation ran after its UI detached")
	uis = 1
	vim.api.nvim_exec_autocmds("UIEnter", { modeline = false })
	assert(#callbacks == 2, "a later UI could not retry activation")
	callbacks[2]()
	assert(setups == 1, "retried activation did not run exactly once")
	assert(package.loaded.exact_editor == nil, "UI retry imported the core before explicit setup")
	assert(rpc.teardown(), "adapter teardown failed after UI retry")
end)

test("teardown cancels and invalidates a pending activation without importing the core", function()
	local callback
	local setups = 0
	local timer = { closed = false, stopped = false }
	function timer:stop()
		self.stopped = true
	end
	function timer:is_closing()
		return self.closed
	end
	function timer:close()
		self.closed = true
	end
	rpc.setup_deferred({
		activation_delay_ms = 300,
		has_entered = function()
			return true
		end,
		ui_count = function()
			return 1
		end,
		defer_fn = function(queued)
			callback = queued
			return timer
		end,
		setup = function()
			setups = setups + 1
			return true
		end,
	})
	assert(type(callback) == "function", "pending activation callback is missing")
	assert(rpc.teardown(), "core-free teardown failed")
	assert(timer.stopped and timer.closed, "teardown did not stop and close the activation timer")
	callback()
	assert(setups == 0, "generation-invalidated activation still ran")
	assert(package.loaded.exact_editor == nil, "teardown imported exact-editor")
end)

test("VimLeavePre cancels pending activation and blocks startup replay", function()
	local callback
	local setups = 0
	rpc.setup_deferred({
		activation_delay_ms = 300,
		has_entered = function()
			return true
		end,
		ui_count = function()
			return 1
		end,
		defer_fn = function(queued)
			callback = queued
		end,
		setup = function()
			setups = setups + 1
			return true
		end,
	})
	vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })
	callback()
	assert(setups == 0, "VimLeavePre did not invalidate pending activation")
	rpc.setup_deferred({
		ui_count = function()
			return 1
		end,
	})
	assert(setups == 0, "activation was re-armed after VimLeavePre")
	assert(package.loaded.exact_editor == nil, "exit cancellation imported exact-editor")
	assert(rpc.teardown(), "adapter teardown did not reset exit state")
end)

assert(rpc._prepare_state(state))
local instance = {
	root = state,
	instance_id = "12345678-1234-4234-8234-123456789abc",
	socket = state .. "/sockets/editor.sock",
	roots = { [root] = true },
}

local function request(overrides)
	local value = {
		version = 1,
		request_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		instance_id = instance.instance_id,
		repo_root = root,
		path = "target.lua",
		line = 7,
		column = 9,
		created_at = "2026-08-09T12:00:00Z",
	}
	for key, item in pairs(overrides or {}) do
		value[key] = item
	end
	return value
end

local function write_request(value)
	local path = state .. "/requests/" .. value.request_id .. ".json"
	assert(require("config.fs").write_binary_atomic(path, vim.json.encode(value) .. "\n"))
	return path
end

local function wait_request(request_id, path, overrides)
	local value = {
		version = 2,
		request_id = request_id,
		instance_id = instance.instance_id,
		repo_root = root,
		path = path,
		created_at = "2026-08-09T12:00:00Z",
	}
	for key, item in pairs(overrides or {}) do
		value[key] = item
	end
	return value
end

local function wait_state(request_id)
	local path = state .. "/waits/" .. request_id .. ".json"
	local encoded = assert(require("config.fs").read_binary(path))
	local value = vim.json.decode(encoded)
	for key in pairs(rpc._wait_state_keys) do
		assert(value[key] ~= nil, "wait state omitted " .. key)
	end
	return value, path
end

local function drain()
	vim.wait(100, function()
		return false
	end, 10)
end

test("host setup options do not leak request-only dependencies", function()
	local setup = rpc._options()
	assert(type(setup.open) == "function", "setup open callback is missing")
	assert(setup.open_file == nil, "request-only open_file leaked into strict setup options")
	assert(setup.activation_delay_ms == nil, "host activation policy leaked into strict setup options")
end)

test("state root follows override, XDG, then home modes", function()
	local old_override = vim.env.NVIM_EXACT_EDITOR_STATE_HOME
	local old_xdg = vim.env.XDG_STATE_HOME
	local old_home = vim.env.HOME
	vim.env.NVIM_EXACT_EDITOR_STATE_HOME = "/tmp/exact-editor-explicit"
	vim.env.XDG_STATE_HOME = "/tmp/review-xdg"
	vim.env.HOME = "/tmp/review-home"
	assert(rpc.state_root() == "/tmp/exact-editor-explicit")
	vim.env.NVIM_EXACT_EDITOR_STATE_HOME = nil
	assert(rpc.state_root() == "/tmp/review-xdg/exact-editor")
	vim.env.XDG_STATE_HOME = nil
	assert(rpc.state_root() == "/tmp/review-home/.local/state/exact-editor")
	vim.env.NVIM_EXACT_EDITOR_STATE_HOME = old_override
	vim.env.XDG_STATE_HOME = old_xdg
	vim.env.HOME = old_home
end)

test("state directories and atomic registry are owner-only", function()
	local record = assert(rpc.write_registry(instance))
	assert(record.version == 2 and record.instance_id == instance.instance_id)
	assert(vim.deep_equal(record.workspaces, { { runtime = "host", root = root, repo_identity = root } }))
	for _, directory in ipairs({
		state,
		state .. "/editors",
		state .. "/requests",
		state .. "/waits",
		state .. "/sockets",
	}) do
		assert(assert(vim.uv.fs_lstat(directory)).mode % 512 == 448, directory .. " is not 0700")
	end
	local path = state .. "/editors/" .. instance.instance_id .. ".json"
	assert(assert(vim.uv.fs_lstat(path)).mode % 512 == 384, "registry is not 0600")
	local decoded = vim.json.decode(assert(require("config.fs").read_binary(path)))
	for key in pairs(rpc._record_keys) do
		assert(decoded[key] ~= nil or key == "TMUX_PANE", "registry omitted " .. key)
	end
end)

test("container registration requires and preserves the exact environment triplet", function()
	vim.env.NVIM_DEVCONTAINER = "1"
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = "container"
	vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = root
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = "/host/logical/repository"
	local options = rpc._options()
	local workspace, err = options.resolve_workspace(root .. "/target.lua")
	assert(workspace and not err)
	assert(vim.deep_equal(workspace, {
		runtime = "container",
		root = root,
		repo_identity = "/host/logical/repository",
	}))

	local container_instance = {
		root = state,
		instance_id = "23456789-2345-4345-8345-23456789abcd",
		socket = state .. "/sockets/container.sock",
		roots = { [root] = true },
	}
	local record = assert(rpc.write_registry(container_instance))
	assert(#record.workspaces == 1 and record.workspaces[1].runtime == "container")
	assert(record.workspaces[1].repo_identity == "/host/logical/repository")

	local retry_instance = {
		root = state,
		instance_id = "34567890-3456-4456-8456-34567890abcd",
		socket = state .. "/sockets/retry.sock",
		roots = { [root] = true },
	}
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = nil
	local failed, failed_err = rpc.write_registry(retry_instance)
	assert(not failed and failed_err:find("requires runtime, workspace root, and repository identity", 1, true))
	assert(retry_instance.workspaces == nil, "failed migration partially mutated the legacy instance")
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = "/host/logical/repository"
	local retried = assert(rpc.write_registry(retry_instance))
	assert(#retried.workspaces == 1 and retried.workspaces[1].runtime == "container")

	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = nil
	workspace, err = options.resolve_workspace(root .. "/target.lua")
	assert(not workspace and err:find("requires runtime, workspace root, and repository identity", 1, true))
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = "/host/logical/repository"
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = "host"
	workspace, err = options.resolve_workspace(root .. "/target.lua")
	assert(not workspace and err:find("runtime must be container", 1, true))

	vim.env.NVIM_DEVCONTAINER = nil
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = nil
	vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = nil
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = nil
end)

test("version-2 editor request arms durable state before acknowledging and finishes only after close", function()
	local request_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	local value = wait_request(request_id, external)
	write_request(value)
	local handled, err = rpc.consume_request(request_id, instance)
	assert(handled == 1, err)
	local waiting, wait_file = wait_state(request_id)
	assert(waiting.status == "waiting")
	assert(assert(vim.uv.fs_lstat(wait_file)).mode % 512 == 384, "wait state is not 0600")
	local buf = vim.api.nvim_get_current_buf()
	assert(assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf))) == external)

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "saved editor text" })
	vim.api.nvim_buf_call(buf, function()
		vim.cmd.write()
	end)
	assert(wait_state(request_id).status == "waiting", "BufWritePost completed the editor request")

	local finish
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if mapping.desc == "Save and finish external editor" then
			finish = mapping.callback
		end
	end
	assert(type(finish) == "function", "temporary editor mapping is missing")
	finish()
	drain()
	assert(wait_state(request_id).status == "completed")
	assert(table.concat(vim.fn.readfile(external), "\n") == "saved editor text")
end)

test("closing a modified editor window aborts and preserves the exact buffer", function()
	local request_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	local target = temporary_text()
	local value = wait_request(request_id, target)
	write_request(value)
	assert(rpc.consume_request(request_id, instance) == 1)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved window text" })
	vim.bo[buf].modified = true
	vim.api.nvim_win_close(win, true)
	drain()
	assert(wait_state(request_id).status == "aborted")
	assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified, "modified buffer was discarded")
	assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved window text")
end)

test("deleting a modified editor buffer aborts and preserves a recovery buffer", function()
	local request_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
	local target = temporary_text()
	local value = wait_request(request_id, target)
	write_request(value)
	assert(rpc.consume_request(request_id, instance) == 1)
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved deleted text" })
	vim.bo[buf].modified = true
	vim.api.nvim_buf_delete(buf, { force = true })
	drain()
	assert(wait_state(request_id).status == "aborted")
	local recovery
	for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(candidate) and vim.b[candidate].nvim_editor_recovery_target == target then
			recovery = candidate
		end
	end
	assert(recovery and vim.api.nvim_buf_is_valid(recovery), "modified text was not recovered")
	assert(vim.bo[recovery].modified, "recovery buffer is not modified")
	assert(vim.api.nvim_buf_get_lines(recovery, 0, -1, false)[1] == "unsaved deleted text")
end)

test("version-2 requests reject schema injection, symlinks, binary files, and a different opened target", function()
	local symlink = fixture .. "/external-link"
	assert(vim.uv.fs_symlink(external, symlink))
	local binary = vim.fn.tempname()
	assert(require("config.fs").write_binary_atomic(binary, "binary\0payload"))
	external_files[#external_files + 1] = binary
	local binary_path = assert(vim.uv.fs_realpath(binary))
	local cases = {
		wait_request("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", external, { action = "execute" }),
		wait_request("ffffffff-ffff-4fff-8fff-ffffffffffff", symlink),
		wait_request("12121212-3434-4567-8899-121212121212", binary_path),
	}
	for _, value in ipairs(cases) do
		write_request(value)
		local handled = rpc.consume_request(value.request_id, instance)
		assert(not handled, "unsafe version-2 request was accepted")
	end

	local request_id = "23232323-4545-4678-8999-232323232323"
	write_request(wait_request(request_id, external))
	local handled, err = rpc.consume_request(request_id, instance, {
		open_file = function()
			vim.cmd("tabedit " .. vim.fn.fnameescape(root .. "/target.lua"))
		end,
	})
	assert(not handled and err:find("different target", 1, true))
	assert(vim.uv.fs_lstat(state .. "/waits/" .. request_id .. ".json") == nil)
end)

test("VimLeavePre completes saved work and aborts modified work", function()
	local saved_id = "34343434-5656-4789-8aaa-343434343434"
	local saved_path = temporary_text()
	write_request(wait_request(saved_id, saved_path))
	assert(rpc.consume_request(saved_id, instance) == 1)

	local modified_path = temporary_text({ "initial" })
	local modified_id = "45454545-6767-489a-8bbb-454545454545"
	write_request(wait_request(modified_id, modified_path))
	assert(rpc.consume_request(modified_id, instance) == 1)
	local modified_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "not written" })
	vim.bo[modified_buf].modified = true

	vim.api.nvim_exec_autocmds("VimLeavePre", {})
	assert(wait_state(saved_id).status == "completed")
	assert(wait_state(modified_id).status == "aborted")
end)

test("opaque UUID request is consumed once and delegates exact tab position", function()
	local value = request()
	local path = write_request(value)
	local opened
	local handled, err = rpc.consume_request(value.request_id, instance, {
		open_file = function(target, options)
			opened = { target, options }
		end,
	})
	assert(handled == 1, err)
	assert(opened[1] == root .. "/target.lua")
	assert(opened[2].lnum == 7 and opened[2].col == 9)
	assert(vim.uv.fs_lstat(path) == nil, "request was not unlinked after consumption")
	assert(rpc.consume_request(value.request_id, instance, { open_file = function() end }) == nil)
end)

test("request schema, identity, and opaque id reject injected fields", function()
	assert(rpc.consume_request('../target")', instance, { open_file = function() end }) == nil)
	local value = request({ action = "execute" })
	local path = write_request(value)
	local handled, err = rpc.consume_request(value.request_id, instance, { open_file = function() end })
	assert(not handled and err:find("unknown key", 1, true))
	assert(vim.uv.fs_lstat(path) == nil)
	value = request({ instance_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" })
	write_request(value)
	handled, err = rpc.consume_request(value.request_id, instance, { open_file = function() end })
	assert(not handled and err:find("identity", 1, true))
end)

test("request containment rejects traversal and symlink escape", function()
	for _, unsafe in ipairs({ "../outside.lua", "/etc/passwd", "escape.lua", "missing.lua" }) do
		local value = request({ path = unsafe })
		write_request(value)
		local handled = rpc.consume_request(value.request_id, instance, { open_file = function() end })
		assert(not handled, "unsafe request path was accepted: " .. unsafe)
	end
end)

test("symlinked state directories are rejected before chmod", function()
	local symlink_root = vim.fn.tempname()
	local target = vim.fn.tempname()
	assert(vim.fn.mkdir(target, "p") == 1)
	assert(vim.uv.fs_symlink(target, symlink_root))
	local ok, err = rpc._prepare_state(symlink_root)
	assert(not ok and err:find("not a real directory", 1, true))
	vim.fn.delete(symlink_root)
	vim.fn.delete(target, "rf")
end)

test("host applies the bounded default registry heartbeat", function()
	assert(rpc._options().registry_heartbeat_seconds == 21600, "host heartbeat policy default changed")
end)

vim.fn.delete(fixture, "rf")
vim.fn.delete(state, "rf")
for _, path in ipairs(external_files) do
	vim.fn.delete(path)
end
for name, value in pairs(original_environment) do
	vim.env[name] = value
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("exact_editor_host_spec: %d tests passed", count))
vim.cmd("quitall!")
