vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ vim.fn.getcwd() .. "/local-plugins/_shared/lua/?.lua", package.path }, ";")

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

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture .. "/repo/sub", "p") == 1)
assert(vim.fn.mkdir(fixture .. "/state/workspaces", "p") == 1)
assert(vim.fn.mkdir(fixture .. "/state/logs", "p") == 1)
assert(vim.fn.mkdir(fixture .. "/spool", "p") == 1)
assert(vim.fn.writefile({ "hello" }, fixture .. "/repo/sub/file.txt") == 0)
local repo = assert(vim.uv.fs_realpath(fixture .. "/repo"))
local state = assert(vim.uv.fs_realpath(fixture .. "/state"))
local spool = assert(vim.uv.fs_realpath(fixture .. "/spool"))
assert(vim.uv.fs_chmod(state, tonumber("700", 8)))
assert(vim.uv.fs_chmod(state .. "/logs", tonumber("700", 8)))
local cli = fixture .. "/devcontainer"
local docker = fixture .. "/docker"
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, cli) == 0)
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, docker) == 0)
assert(vim.uv.fs_chmod(cli, tonumber("700", 8)))
assert(vim.uv.fs_chmod(docker, tonumber("700", 8)))
cli = assert(vim.uv.fs_realpath(cli))
docker = assert(vim.uv.fs_realpath(docker))
local token = string.rep("s", 32)
local original_env = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_DEVCONTAINER_CONTAINER_ROOT = vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT,
	NVIM_DEVCONTAINER_SPOOL_ROOT = vim.env.NVIM_DEVCONTAINER_SPOOL_ROOT,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
}

vim.env.NVIM_DEVCONTAINER = "1"
vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT = repo
vim.env.NVIM_DEVCONTAINER_SPOOL_ROOT = spool
vim.env.NVIM_CONFIG_OFFLINE = "1"

local opened
local plugin_module = require("devcontainer_editor")
local function configure(notify, open_callback, overrides)
	overrides = overrides or {}
	local options = {
		state_root = state,
		spool_root = spool,
		launcher = "/bin/devcontainer-editor",
		docker_path = docker,
		resolve_cli = function()
			return cli
		end,
		watch = false,
		notify = notify,
		uuid = function()
			return "00000000-0000-4000-8000-000000000001"
		end,
		open = open_callback or function(path, position)
			opened = { path = path, position = position }
		end,
	}
	for key, value in pairs(overrides) do
		options[key] = value
	end
	assert(plugin_module.setup(options))
end

local workspace_record_file = state .. "/workspaces/" .. vim.fn.sha256(repo) .. ".json"
local lifecycle_log_file = state .. "/logs/" .. vim.fn.sha256(repo) .. ".log"

local function workspace_record(version, overrides)
	local record = {
		version = version,
		host_root = repo,
		config_path = repo .. "/.devcontainer/devcontainer.json",
		container_root = "/workspaces/project",
		container_id = "container",
		claim_id = "00000000-0000-4000-8000-000000000030",
		workspace_key = { runtime = "container", root = "/workspaces/project", repo_identity = repo },
		pid = 1,
		pane_pid = 7007,
		status = "running",
		network_authorized = false,
		ssh_agent_forwarding = false,
		tmux_pane = "%7",
		log_path = lifecycle_log_file,
		updated_at = "2026-08-31T00:00:00Z",
		exit_code = vim.NIL,
		error = vim.NIL,
	}
	if version >= 3 then
		record.cli_path = "/opt/devcontainer/bin/devcontainer"
	end
	if version >= 4 then
		record.docker_path = "/opt/homebrew/bin/podman"
	end
	if version >= 5 then
		record.phase = "monitoring-editor"
	end
	if version >= 6 then
		record.podman_connection = {
			name = "podman-machine-default",
			machine_pin = string.rep("a", 64),
		}
	end
	for key, value in pairs(overrides or {}) do
		record[key] = value
	end
	return record
end

local function write_workspace_record(record)
	assert(plugin_module._atomic_write(workspace_record_file, vim.json.encode(record)))
end

local function write_lifecycle_log(payload)
	assert(plugin_module._atomic_write(lifecycle_log_file, payload or "lifecycle\n"))
end

local function with_directory_fsync_failure(directory, failure, callback)
	local target = assert(vim.uv.fs_stat(directory))
	local original_fsync = vim.uv.fs_fsync
	local injected = false
	vim.uv.fs_fsync = function(fd)
		local stat = vim.uv.fs_fstat(fd)
		if not injected and stat and stat.type == "directory" and stat.dev == target.dev and stat.ino == target.ino then
			injected = true
			return nil, failure
		end
		return original_fsync(fd)
	end
	local ok, err = xpcall(callback, debug.traceback)
	vim.uv.fs_fsync = original_fsync
	assert(ok, err)
	assert(injected, "expected directory fsync failure was not injected")
end

local function with_directory_close_failure(directory, failure, callback)
	local target = assert(vim.uv.fs_stat(directory))
	local original_close = vim.uv.fs_close
	local injected = false
	vim.uv.fs_close = function(fd)
		local stat = vim.uv.fs_fstat(fd)
		local closed, close_err = original_close(fd)
		if not injected and stat and stat.type == "directory" and stat.dev == target.dev and stat.ino == target.ino then
			injected = true
			assert(closed, close_err)
			return nil, failure
		end
		return closed, close_err
	end
	local results
	local ok, err = xpcall(function()
		results = { callback() }
	end, debug.traceback)
	vim.uv.fs_close = original_close
	assert(ok, err)
	assert(injected, "expected directory close failure was not injected")
	return unpack(results)
end

local function with_test_hook(hook, callback)
	plugin_module._set_test_hook(hook)
	local results
	local ok, err = xpcall(function()
		results = { callback() }
	end, debug.traceback)
	plugin_module._set_test_hook(nil)
	assert(ok, err)
	return unpack(results)
end

test("pre-setup public defaults and aggregate status are copied", function()
	local first = plugin_module.effective_config()
	assert(first.docker_path == "docker" and first.lockfile_policy == "preserve")
	assert(first.claim_timeout_ms == 2000 and first.ack_timeout_ms == 5000)
	assert(first.max_messages_per_tick == 32 and first.ssh_agent == "auto")
	first.max_messages_per_tick = 1
	assert(plugin_module.effective_config().max_messages_per_tick == 32)
	assert(pcall(vim.json.encode, plugin_module.effective_config()))

	local status = plugin_module.status()
	assert(status.configured == false and status.transport.state == "idle")
	status.transport.state = "mutated"
	assert(plugin_module.status().transport.state == "idle")
end)

configure()
assert(plugin_module._prepare_spool(spool))
assert(plugin_module._atomic_write(spool .. "/auth.json", vim.json.encode({ version = 2, token = token }) .. "\n"))

test("workspace identity is exact, lexical, and copied", function()
	local input = { runtime = "container", root = "/workspaces/project", repo_identity = repo }
	local value = assert(plugin_module.workspace_key(input))
	input.runtime = "changed"
	assert(value.runtime == "container")
	assert(
		plugin_module.workspace_key({ runtime = "container", root = "/workspaces/../tmp", repo_identity = repo }) == nil
	)
	assert(plugin_module.workspace_key({ runtime = "container", root = "relative", repo_identity = repo }) == nil)
	assert(plugin_module.workspace_key({
		runtime = "container",
		root = "/workspaces/project",
		repo_identity = repo,
		injected = true,
	}) == nil)
end)

test("routing is contained and rejects traversal through symlinks", function()
	local routed = assert(plugin_module.route("sub/file.txt", repo, "/workspaces/project", "file"))
	assert(routed == "/workspaces/project/sub/file.txt")
	assert(plugin_module.route("../outside", repo, "/workspaces/project", "file") == nil)
	assert(vim.uv.fs_symlink("/tmp", repo .. "/escape") == true)
	assert(plugin_module.route("escape/file", repo, "/workspaces/project", "file") == nil)
end)

test("authenticated inbox opens one exact contained file and writes a private ACK", function()
	assert(plugin_module._prepare_spool(spool))
	local request_id = "00000000-0000-4000-8000-000000000002"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 7,
		column = 3,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	local path = spool .. "/inbox/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(path, vim.json.encode(request) .. "\n"))
	local consumed, consume_err = plugin_module.consume_spool_once()
	assert(consumed == 1, vim.inspect({ consumed = consumed, err = consume_err }))
	assert(opened.path == repo .. "/sub/file.txt")
	assert(opened.position.lnum == 7 and opened.position.col == 3)
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	local ack = vim.json.decode(assert(plugin_module._secure_read(ack_path, "ack")))
	assert(ack.ok == true and ack.token == nil and ack.request_id == request_id)
	assert(ack.auth == assert(plugin_module._authenticate(token, "ack", ack)))
	assert(vim.uv.fs_lstat(ack_path).mode % 512 == tonumber("600", 8))
end)

test("wrong authentication and traversal requests fail closed", function()
	for index, fields in ipairs({
		{ valid = false, path = "sub/file.txt" },
		{ valid = true, path = "../outside" },
	}) do
		local request_id = ("00000000-0000-4000-8000-%012d"):format(index + 10)
		local request = {
			version = 2,
			request_id = request_id,
			action = "open_location",
			path = fields.path,
			line = 1,
			column = 1,
			created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		request.auth = fields.valid and assert(plugin_module._authenticate(token, "open_location", request)) or "wrong"
		local path = spool .. "/inbox/" .. request_id .. ".json"
		assert(plugin_module._atomic_create(path, vim.json.encode(request) .. "\n"))
		local consumed, consume_err, report = plugin_module.consume_spool_once()
		assert(consumed == nil and type(consume_err) == "string")
		assert(report.state == "partial" and report.failed == 1 and report.records[1].ok == false)
		assert(vim.uv.fs_lstat(path) == nil)
	end
end)

test("inbox replacement cannot redirect request retirement outside the pinned spool", function()
	local request_id = "00000000-0000-4000-8000-000000000040"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 1,
		column = 1,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	local name = request_id .. ".json"
	local inbox = spool .. "/inbox"
	local pinned_inbox = spool .. "/inbox-pinned"
	local outside = fixture .. "/outside-inbox"
	assert(vim.fn.mkdir(outside, "p", tonumber("700", 8)) == 1)
	assert(vim.fn.writefile({ '{"outside":true}' }, outside .. "/" .. name) == 0)
	assert(plugin_module._atomic_create(inbox .. "/" .. name, vim.json.encode(request) .. "\n"))

	local original_read = vim.uv.fs_read
	local swapped = false
	vim.uv.fs_read = function(fd, size, offset)
		local data, err = original_read(fd, size, offset)
		if not swapped and data and data:find(request_id, 1, true) then
			swapped = true
			assert(vim.uv.fs_rename(inbox, pinned_inbox))
			assert(vim.uv.fs_symlink(outside, inbox, { dir = true }))
		end
		return data, err
	end
	local ok, consumed, consume_err = pcall(plugin_module.consume_spool_once)
	vim.uv.fs_read = original_read
	assert(ok, consumed)
	assert(consumed == 1, consume_err)
	assert(swapped)
	assert(vim.fn.readfile(outside .. "/" .. name)[1] == '{"outside":true}')
	assert(vim.uv.fs_lstat(pinned_inbox .. "/" .. name) == nil)
	assert(vim.uv.fs_unlink(inbox))
	assert(vim.uv.fs_rename(pinned_inbox, inbox))
end)

test("truncated inbox JSON is retired after its identity is validated", function()
	local request_id = "00000000-0000-4000-8000-000000000050"
	local path = spool .. "/inbox/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(path, '{"truncated":'))
	local consumed, consume_err = plugin_module.consume_spool_once()
	assert(consumed == nil)
	assert(consume_err == "spool request is not JSON")
	assert(vim.uv.fs_lstat(path) == nil)
	assert(plugin_module.consume_spool_once() == 0)
end)

test("inbox JSON with an unknown field is retired after schema rejection", function()
	local request_id = "00000000-0000-4000-8000-000000000051"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 1,
		column = 1,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		unknown = true,
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	local path = spool .. "/inbox/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(path, vim.json.encode(request)))
	local consumed, consume_err = plugin_module.consume_spool_once()
	assert(consumed == nil)
	assert(consume_err == "spool request contains an unknown field")
	assert(vim.uv.fs_lstat(path) == nil)
end)

test("invalid inbox cleanup retains a concurrent replacement and preserves the primary error", function()
	local request_id = "00000000-0000-4000-8000-000000000052"
	local path = spool .. "/inbox/" .. request_id .. ".json"
	local invalid = '{"concurrent":'
	local replacement = '{"replacement":true}'
	assert(plugin_module._atomic_create(path, invalid))
	local original_decode = vim.json.decode
	local swapped = false
	vim.json.decode = function(payload, ...)
		if not swapped and payload == invalid then
			swapped = true
			assert(vim.uv.fs_unlink(path))
			assert(plugin_module._atomic_create(path, replacement))
		end
		return original_decode(payload, ...)
	end
	local ok, consumed, consume_err = pcall(plugin_module.consume_spool_once)
	vim.json.decode = original_decode
	assert(ok, consumed)
	assert(consumed == nil)
	assert(swapped)
	assert(consume_err:find("^spool request is not JSON", 1))
	assert(consume_err:find("cleanup failed: spool entry changed during conditional retirement", 1, true))
	assert(assert(plugin_module._secure_read(path, "replacement")) == replacement)
	assert(vim.uv.fs_unlink(path))
end)

test("invalid inbox cleanup failure is appended without masking the JSON error", function()
	local request_id = "00000000-0000-4000-8000-000000000053"
	local path = spool .. "/inbox/" .. request_id .. ".json"
	local inbox = spool .. "/inbox"
	local invalid = '{"permission":'
	assert(plugin_module._atomic_create(path, invalid))
	local original_read = vim.uv.fs_read
	local restricted = false
	vim.uv.fs_read = function(fd, size, offset)
		local data, err = original_read(fd, size, offset)
		if not restricted and data == invalid then
			restricted = true
			assert(vim.uv.fs_chmod(inbox, tonumber("500", 8)))
		end
		return data, err
	end
	local ok, consumed, consume_err = pcall(plugin_module.consume_spool_once)
	vim.uv.fs_read = original_read
	assert(vim.uv.fs_chmod(inbox, tonumber("700", 8)))
	assert(ok, consumed)
	assert(consumed == nil)
	assert(restricted)
	assert(consume_err:find("^spool request is not JSON", 1))
	assert(consume_err:find("; cleanup failed:", 1, true))
	assert(vim.uv.fs_lstat(path).type == "file")
	assert(vim.uv.fs_unlink(path))
end)

test("readiness requests use an authenticated private spool and exact allowlist", function()
	local callback_value
	local function defer(callback)
		local request_path = spool .. "/outbox/00000000-0000-4000-8000-000000000001.json"
		local request = vim.json.decode(assert(plugin_module._secure_read(request_path, "request")))
		local ack = {
			version = 2,
			request_id = request.request_id,
			ok = true,
			action = request.action,
			error = vim.NIL,
		}
		assert(request.token == nil)
		assert(request.auth == assert(plugin_module._authenticate(token, "host_request", request)))
		ack.auth = assert(plugin_module._authenticate(token, "ack", ack))
		assert(plugin_module._atomic_create(spool .. "/acks/" .. request.request_id .. ".json", vim.json.encode(ack)))
		callback()
	end
	assert(plugin_module.request_host("editor_ready", { defer = defer }, function(value)
		callback_value = value
	end))
	assert(callback_value.action == "editor_ready")
	assert(plugin_module.request_host("publish") == nil)
	assert(plugin_module.request_host("execute") == nil)
	assert(vim.uv.fs_unlink(spool .. "/outbox/00000000-0000-4000-8000-000000000001.json"))
end)

test("UUID callback and random failures are isolated without leaking spool descriptors", function()
	configure(nil, nil, {
		uuid = function()
			error("fixture UUID failure")
		end,
	})
	local fd_root = vim.uv.fs_stat("/dev/fd") and "/dev/fd" or "/proc/self/fd"
	local function fd_count()
		local scanner = assert(vim.uv.fs_scandir(fd_root))
		local count = 0
		while vim.uv.fs_scandir_next(scanner) do
			count = count + 1
		end
		return count
	end
	local original_random = vim.uv.random
	vim.uv.random = function()
		error("fixture random failure")
	end
	local before = fd_count()
	local ok, err = xpcall(function()
		local claim, claim_err = plugin_module.new_claim_id()
		assert(claim == nil and tostring(claim_err):find("generate", 1, true), tostring(claim_err))
		for _ = 1, 5 do
			local safe, committed, request_err = pcall(plugin_module.request_host, "lazygit")
			assert(safe and committed == nil and tostring(request_err):find("generate", 1, true), tostring(request_err))
		end
	end, debug.traceback)
	vim.uv.random = original_random
	assert(ok, err)
	assert(fd_count() == before, "UUID failure leaked authenticated spool descriptors")
	configure()
end)

test("truncated host acknowledgement is retired without masking its decode error", function()
	local notifications = {}
	local request_id = "00000000-0000-4000-8000-000000000001"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	local committed, returned_id = plugin_module.request_host("lazygit", {
		defer = function(callback)
			assert(plugin_module._atomic_create(ack_path, '{"truncated":'))
			assert(vim.uv.fs_unlink(spool .. "/outbox/" .. request_id .. ".json"))
			callback()
		end,
		notify = function(message, level)
			notifications[#notifications + 1] = { message = message, level = level }
		end,
	})
	assert(committed == true and returned_id == request_id)
	assert(vim.uv.fs_lstat(ack_path) == nil)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.ERROR)
	assert(notifications[1].message == "spool acknowledgement is not JSON")
end)

test("validated host acknowledgement keeps success when spool close fails", function()
	local notifications = {}
	local callback_count = 0
	local request_id = "00000000-0000-4000-8000-000000000001"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	local ack = {
		version = 2,
		request_id = request_id,
		ok = true,
		action = "lazygit",
		error = vim.NIL,
	}
	ack.auth = assert(plugin_module._authenticate(token, "ack", ack))
	assert(plugin_module._atomic_create(ack_path, vim.json.encode(ack)))
	local committed, returned_id = with_directory_close_failure(
		spool .. "/acks",
		"injected ACK close failure",
		function()
			return plugin_module.request_host("lazygit", {
				notify = function(message, level)
					notifications[#notifications + 1] = { message = message, level = level }
				end,
			}, function(value)
				callback_count = callback_count + 1
				assert(value.action == "lazygit")
			end)
		end
	)
	assert(committed == true and returned_id == request_id)
	assert(callback_count == 1)
	assert(vim.uv.fs_lstat(ack_path) == nil)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("acknowledgement accepted but spool close failed", 1, true))
	assert(vim.uv.fs_unlink(spool .. "/outbox/" .. request_id .. ".json"))
end)

test("acknowledgement decode error stays primary when spool close fails", function()
	local notifications = {}
	local request_id = "00000000-0000-4000-8000-000000000001"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(ack_path, '{"truncated":'))
	local committed, returned_id = with_directory_close_failure(
		spool .. "/acks",
		"injected decode close failure",
		function()
			return plugin_module.request_host("lazygit", {
				notify = function(message, level)
					notifications[#notifications + 1] = { message = message, level = level }
				end,
			})
		end
	)
	assert(committed == true and returned_id == request_id)
	assert(vim.uv.fs_lstat(ack_path) == nil)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.ERROR)
	assert(
		notifications[1].message == "spool acknowledgement is not JSON; cleanup failed: injected decode close failure"
	)
	assert(vim.uv.fs_unlink(spool .. "/outbox/" .. request_id .. ".json"))
end)

test("acknowledgement inspect error stays primary when spool close fails", function()
	local notifications = {}
	local request_id = "00000000-0000-4000-8000-000000000001"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	assert(vim.fn.mkdir(ack_path, "p", tonumber("700", 8)) == 1)
	local committed, returned_id = with_directory_close_failure(
		spool .. "/acks",
		"injected inspect close failure",
		function()
			return plugin_module.request_host("lazygit", {
				notify = function(message, level)
					notifications[#notifications + 1] = { message = message, level = level }
				end,
			})
		end
	)
	assert(committed == true and returned_id == request_id)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.ERROR)
	assert(
		notifications[1].message
			== "private spool entry is not one owner-only single-link file; cleanup failed: injected inspect close failure"
	)
	assert(vim.uv.fs_unlink(spool .. "/outbox/" .. request_id .. ".json"))
	assert(vim.uv.fs_rmdir(ack_path))
end)

test("outbound request remains committed when consumed immediately after exclusive publish", function()
	local notifications = {}
	local callback_count = 0
	local request_id = "00000000-0000-4000-8000-000000000001"
	local request_path = spool .. "/outbox/" .. request_id .. ".json"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	local ack = {
		version = 2,
		request_id = request_id,
		ok = true,
		action = "lazygit",
		error = vim.NIL,
	}
	ack.auth = assert(plugin_module._authenticate(token, "ack", ack))
	local committed, returned_id = with_test_hook(function(event, details)
		if event == "after_message_publish" and details.name == request_id .. ".json" then
			local published = vim.json.decode(assert(plugin_module._secure_read(request_path, "request")))
			assert(vim.uv.fs_lstat(request_path).nlink == 1)
			assert(published.request_id == request_id and published.action == "lazygit")
			assert(published.auth == assert(plugin_module._authenticate(token, "host_request", published)))
			assert(vim.uv.fs_unlink(request_path))
			assert(plugin_module._atomic_create(ack_path, vim.json.encode(ack)))
		end
	end, function()
		return plugin_module.request_host("lazygit", {
			notify = function(message, level)
				notifications[#notifications + 1] = { message = message, level = level }
			end,
		}, function(value)
			callback_count = callback_count + 1
			assert(value.action == "lazygit")
		end)
	end)
	assert(committed == true and returned_id == request_id)
	assert(callback_count == 1)
	assert(vim.uv.fs_lstat(request_path) == nil)
	assert(vim.uv.fs_lstat(ack_path) == nil)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("consumed before post-commit validation", 1, true))
end)

test("outbound request keeps committed success when post-publish snapshot close fails", function()
	local notifications = {}
	local callback_count = 0
	local request_id = "00000000-0000-4000-8000-000000000001"
	local request_path = spool .. "/outbox/" .. request_id .. ".json"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	local published_identity
	local injected = false
	local original_close = vim.uv.fs_close
	vim.uv.fs_close = function(fd)
		local stat = vim.uv.fs_fstat(fd)
		local closed, close_err = original_close(fd)
		if
			not injected
			and published_identity
			and stat
			and stat.type == "file"
			and stat.dev == published_identity.dev
			and stat.ino == published_identity.ino
		then
			injected = true
			assert(closed, close_err)
			return nil, "injected published snapshot close failure"
		end
		return closed, close_err
	end
	local ok, committed, returned_id = pcall(function()
		return with_test_hook(function(event, details)
			if event == "after_message_publish" and details.name == request_id .. ".json" then
				published_identity = assert(vim.uv.fs_lstat(request_path))
				assert(published_identity.nlink == 1)
			end
		end, function()
			return plugin_module.request_host("lazygit", {
				defer = function(callback)
					local request = vim.json.decode(assert(plugin_module._secure_read(request_path, "request")))
					local ack = {
						version = 2,
						request_id = request.request_id,
						ok = true,
						action = request.action,
						error = vim.NIL,
					}
					ack.auth = assert(plugin_module._authenticate(token, "ack", ack))
					assert(vim.uv.fs_unlink(request_path))
					assert(plugin_module._atomic_create(ack_path, vim.json.encode(ack)))
					callback()
				end,
				notify = function(message, level)
					notifications[#notifications + 1] = { message = message, level = level }
				end,
			}, function(value)
				callback_count = callback_count + 1
				assert(value.action == "lazygit")
			end)
		end)
	end)
	vim.uv.fs_close = original_close
	plugin_module._set_test_hook(nil)
	assert(ok, committed)
	assert(committed == true and returned_id == request_id)
	assert(injected)
	assert(callback_count == 1)
	assert(vim.uv.fs_lstat(request_path) == nil)
	assert(vim.uv.fs_lstat(ack_path) == nil)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("could not close private spool entry", 1, true))
end)

test("outbound request preserves committed success and reports a bounded fsync warning", function()
	local notifications = {}
	local callback_value
	local function defer(callback)
		local request_path = spool .. "/outbox/00000000-0000-4000-8000-000000000001.json"
		local request = vim.json.decode(assert(plugin_module._secure_read(request_path, "request")))
		local ack = {
			version = 2,
			request_id = request.request_id,
			ok = true,
			action = request.action,
			error = vim.NIL,
		}
		ack.auth = assert(plugin_module._authenticate(token, "ack", ack))
		assert(plugin_module._atomic_create(spool .. "/acks/" .. request.request_id .. ".json", vim.json.encode(ack)))
		assert(vim.uv.fs_unlink(request_path))
		callback()
	end
	local failure = "injected\n" .. string.rep("x", 700) .. "\0ignored"
	with_directory_fsync_failure(spool .. "/outbox", failure, function()
		local committed, request_id = plugin_module.request_host("lazygit", {
			defer = defer,
			notify = function(message, level)
				notifications[#notifications + 1] = { message = message, level = level }
			end,
		}, function(value)
			callback_value = value
		end)
		assert(committed == true)
		assert(request_id == "00000000-0000-4000-8000-000000000001")
	end)
	assert(callback_value and callback_value.action == "lazygit")
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("host request committed with a durability warning", 1, true))
	assert(#notifications[1].message <= 512)
	assert(not notifications[1].message:find("[%c]"))
end)

test("acknowledgement preserves committed success and reports a bounded fsync warning", function()
	local notifications = {}
	configure(function(message, level)
		notifications[#notifications + 1] = { message = message, level = level }
	end)
	local request_id = "00000000-0000-4000-8000-000000000041"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 2,
		column = 4,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	assert(plugin_module._atomic_create(spool .. "/inbox/" .. request_id .. ".json", vim.json.encode(request)))
	with_directory_fsync_failure(spool .. "/acks", "injected\nack directory fsync failure", function()
		local consumed, consume_err = plugin_module.consume_spool_once()
		assert(consumed == 1, consume_err)
	end)
	local ack = vim.json.decode(assert(plugin_module._secure_read(spool .. "/acks/" .. request_id .. ".json", "ack")))
	assert(ack.ok == true and ack.request_id == request_id)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("acknowledgement committed with a durability warning", 1, true))
	assert(#notifications[1].message <= 512)
	assert(not notifications[1].message:find("[%c]"))
	configure()
end)

test("acknowledgement remains committed when consumed immediately after exclusive publish", function()
	local notifications = {}
	local open_count = 0
	configure(function(message, level)
		notifications[#notifications + 1] = { message = message, level = level }
	end, function(path, position)
		open_count = open_count + 1
		opened = { path = path, position = position }
	end)
	local request_id = "00000000-0000-4000-8000-000000000054"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 6,
		column = 2,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	local request_path = spool .. "/inbox/" .. request_id .. ".json"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(request_path, vim.json.encode(request)))
	local consumed, consume_err = with_test_hook(function(event, details)
		if event == "after_message_publish" and details.name == request_id .. ".json" then
			local ack = vim.json.decode(assert(plugin_module._secure_read(ack_path, "ack")))
			assert(vim.uv.fs_lstat(ack_path).nlink == 1)
			assert(ack.request_id == request_id and ack.ok == true)
			assert(ack.auth == assert(plugin_module._authenticate(token, "ack", ack)))
			assert(vim.uv.fs_unlink(ack_path))
		end
	end, plugin_module.consume_spool_once)
	assert(consumed == 1, consume_err)
	assert(plugin_module.consume_spool_once() == 0)
	assert(open_count == 1)
	assert(vim.uv.fs_lstat(request_path) == nil)
	assert(vim.uv.fs_lstat(ack_path) == nil)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("consumed before post-commit validation", 1, true))
	configure()
end)

test("outbound rival is preserved and unpublished staging is cleaned", function()
	local request_id = "00000000-0000-4000-8000-000000000001"
	local request_path = spool .. "/outbox/" .. request_id .. ".json"
	local rival = '{"rival":true}'
	assert(plugin_module._atomic_create(request_path, rival))
	local committed, publish_err = plugin_module.request_host("lazygit")
	assert(committed == nil)
	assert(publish_err:find("could not publish private message without clobbering", 1, true))
	assert(assert(plugin_module._secure_read(request_path, "rival")) == rival)
	assert(vim.uv.fs_lstat(request_path).nlink == 1)
	for _, entry in ipairs(vim.fn.readdir(spool .. "/outbox")) do
		assert(not (entry:find(request_id, 1, true) and entry:sub(-4) == ".tmp"))
	end
	assert(vim.uv.fs_unlink(request_path))
end)

test("inbound open and acknowledgement keep success when spool close fails", function()
	local notifications = {}
	local open_count = 0
	configure(function(message, level)
		notifications[#notifications + 1] = { message = message, level = level }
	end, function(path, position)
		open_count = open_count + 1
		opened = { path = path, position = position }
	end)
	local request_id = "00000000-0000-4000-8000-000000000056"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 4,
		column = 2,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	local request_path = spool .. "/inbox/" .. request_id .. ".json"
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(request_path, vim.json.encode(request)))
	local consumed, consume_err = with_directory_close_failure(
		spool .. "/acks",
		"injected inbound close failure",
		plugin_module.consume_spool_once
	)
	assert(consumed == 1, consume_err)
	assert(plugin_module.consume_spool_once() == 0)
	assert(open_count == 1)
	assert(vim.uv.fs_lstat(request_path) == nil)
	assert(vim.uv.fs_lstat(ack_path).type == "file")
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("inbound spool result completed but close failed", 1, true))
	assert(vim.uv.fs_unlink(ack_path))
	configure()
end)

test("inbound decode error stays primary when spool close fails", function()
	local request_id = "00000000-0000-4000-8000-000000000057"
	local request_path = spool .. "/inbox/" .. request_id .. ".json"
	assert(plugin_module._atomic_create(request_path, '{"truncated":'))
	local consumed, consume_err = with_directory_close_failure(
		spool .. "/acks",
		"injected inbound error close failure",
		plugin_module.consume_spool_once
	)
	assert(consumed == nil)
	assert(consume_err == "spool request is not JSON; cleanup failed: injected inbound error close failure")
	assert(vim.uv.fs_lstat(request_path) == nil)
end)

test("committed request retirement reports its directory fsync warning", function()
	local notifications = {}
	configure(function(message, level)
		notifications[#notifications + 1] = { message = message, level = level }
	end)
	local request_id = "00000000-0000-4000-8000-000000000042"
	local request = {
		version = 2,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 3,
		column = 5,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	assert(plugin_module._atomic_create(spool .. "/inbox/" .. request_id .. ".json", vim.json.encode(request)))
	with_directory_fsync_failure(spool .. "/inbox", "injected request retirement fsync failure", function()
		local consumed, consume_err = plugin_module.consume_spool_once()
		assert(consumed == 1, consume_err)
	end)
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("inbound request retirement committed", 1, true))
	assert(vim.uv.fs_unlink(spool .. "/acks/" .. request_id .. ".json"))
	configure()
end)

test("committed acknowledgement retirement reports its directory fsync warning", function()
	local notifications = {}
	local callback_value
	configure()
	local request_id = "00000000-0000-4000-8000-000000000001"
	local ack = {
		version = 2,
		request_id = request_id,
		ok = true,
		action = "lazygit",
		error = vim.NIL,
	}
	ack.auth = assert(plugin_module._authenticate(token, "ack", ack))
	assert(plugin_module._atomic_create(spool .. "/acks/" .. request_id .. ".json", vim.json.encode(ack)))
	with_directory_fsync_failure(spool .. "/acks", "injected acknowledgement retirement fsync failure", function()
		local committed, returned_id = plugin_module.request_host("lazygit", {
			defer = function(callback)
				callback()
			end,
			notify = function(message, level)
				notifications[#notifications + 1] = { message = message, level = level }
			end,
		}, function(value)
			callback_value = value
		end)
		assert(committed == true and returned_id == request_id)
	end)
	assert(callback_value and callback_value.action == "lazygit")
	assert(#notifications == 1)
	assert(notifications[1].level == vim.log.levels.WARN)
	assert(notifications[1].message:find("acknowledgement retirement committed", 1, true))
	assert(vim.uv.fs_unlink(spool .. "/outbox/" .. request_id .. ".json"))
end)

test("Lua HMAC projection matches the cross-language protocol vector", function()
	local request = {
		version = 2,
		request_id = "00000000-0000-4000-8000-000000000002",
		action = "open_location",
		path = "sub/file.txt",
		line = 7,
		column = 3,
		created_at = "2026-08-31T00:00:00Z",
	}
	assert(
		plugin_module._authenticate(token, "open_location", request)
			== "932a4baa287a1918d780db3b192fa6b88e548ae2ec67f39a739914da9b841596"
	)
end)

test("auth symlinks, UUID filename mismatch, and message clobber fail closed", function()
	local request = {
		version = 2,
		request_id = "00000000-0000-4000-8000-000000000021",
		action = "open_location",
		path = "sub/file.txt",
		line = 1,
		column = 1,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	request.auth = assert(plugin_module._authenticate(token, "open_location", request))
	local mismatched = spool .. "/inbox/00000000-0000-4000-8000-000000000022.json"
	assert(plugin_module._atomic_create(mismatched, vim.json.encode(request)))
	assert(plugin_module.consume_spool_once() == nil)
	assert(vim.uv.fs_lstat(mismatched) == nil)

	local no_clobber = spool .. "/outbox/00000000-0000-4000-8000-000000000023.json"
	assert(plugin_module._atomic_create(no_clobber, '{"first":true}'))
	assert(plugin_module._atomic_create(no_clobber, '{"second":true}') == nil)
	assert(vim.json.decode(assert(plugin_module._secure_read(no_clobber, "request"))).first == true)
	assert(vim.uv.fs_unlink(no_clobber))

	local auth_path = spool .. "/auth.json"
	assert(vim.uv.fs_unlink(auth_path))
	assert(vim.uv.fs_symlink(repo .. "/sub/file.txt", auth_path))
	assert(plugin_module._auth_token(spool) == nil)
	assert(vim.uv.fs_unlink(auth_path))
	assert(plugin_module._atomic_write(auth_path, vim.json.encode({ version = 2, token = token })))
	local duplicate = spool .. "/auth-copy.json"
	assert(vim.uv.fs_link(auth_path, duplicate))
	assert(plugin_module._auth_token(spool) == nil)
	assert(vim.uv.fs_unlink(duplicate))
	assert(plugin_module._auth_token(spool) == token)
end)

test("offline authorization and lifecycle argv are explicit", function()
	assert(plugin_module.in_workspace())
	assert(not plugin_module.network_authorized())
	local argv = assert(plugin_module.lifecycle_argv("up", {
		root = repo,
		tmux_pane = "%7",
		claim_id = "00000000-0000-4000-8000-000000000030",
		recreate = true,
		allow_network = true,
	}))
	assert(vim.deep_equal(argv, {
		"/bin/devcontainer-editor",
		"up",
		"--repo",
		repo,
		"--cli-path",
		cli,
		"--docker-path",
		docker,
		"--lockfile-policy",
		"preserve",
		"--ssh-agent",
		"auto",
		"--tmux-pane",
		"%7",
		"--claim-id",
		"00000000-0000-4000-8000-000000000030",
		"--recreate",
		"--allow-network",
	}))
	assert(plugin_module.lifecycle_argv("up", { root = repo }) == nil)
	assert(plugin_module.lifecycle_argv("up", { root = repo, tmux_pane = "%7\n" }) == nil)
	assert(plugin_module.lifecycle_argv("up", { root = repo, tmux_pane = "%7", claim_id = "bad" }) == nil)
	assert(vim.deep_equal(
		assert(plugin_module.lifecycle_argv("restart-dead", {
			root = repo,
			tmux_pane = "%7",
			claim_id = "00000000-0000-4000-8000-000000000031",
			recreate = true,
		})),
		{
			"/bin/devcontainer-editor",
			"restart-dead",
			"--repo",
			repo,
			"--tmux-pane",
			"%7",
			"--claim-id",
			"00000000-0000-4000-8000-000000000031",
			"--recreate",
		}
	))
	assert(plugin_module.lifecycle_argv("delete", {}) == nil)
	assert(vim.deep_equal(assert(plugin_module.lifecycle_argv("doctor", { root = repo })), {
		"/bin/devcontainer-editor",
		"doctor",
		"--repo",
		repo,
		"--cli-path",
		cli,
		"--docker-path",
		docker,
		"--lockfile-policy",
		"preserve",
		"--ssh-agent",
		"auto",
	}))
	assert(vim.deep_equal(
		assert(plugin_module.lifecycle_argv("doctor", {
			root = repo,
			config = repo .. "/.devcontainer/devcontainer.json",
			cli_path = cli,
			docker_path = docker,
		})),
		{
			"/bin/devcontainer-editor",
			"doctor",
			"--repo",
			repo,
			"--cli-path",
			cli,
			"--docker-path",
			docker,
			"--lockfile-policy",
			"preserve",
			"--ssh-agent",
			"auto",
			"--config",
			repo .. "/.devcontainer/devcontainer.json",
		}
	))
	assert(plugin_module.lifecycle_argv("doctor", { root = repo, cli_path = cli }) == nil)
	assert(plugin_module.lifecycle_argv("host", { root = repo, tmux_pane = "%bad" }) == nil)
end)

test("workspace status rejects hostile state and returns immutable copies", function()
	local expected_log = state .. "/logs/" .. vim.fn.sha256(repo) .. ".log"
	local record = {
		version = 2,
		host_root = repo,
		config_path = repo .. "/.devcontainer/devcontainer.json",
		container_root = "/workspaces/project",
		container_id = "container",
		claim_id = "00000000-0000-4000-8000-000000000030",
		workspace_key = { runtime = "container", root = "/workspaces/project", repo_identity = repo },
		pid = 1,
		pane_pid = 7007,
		status = "running",
		network_authorized = false,
		ssh_agent_forwarding = false,
		tmux_pane = "%7",
		log_path = expected_log,
		updated_at = "2026-08-31T00:00:00Z",
		exit_code = vim.NIL,
		error = vim.NIL,
	}
	local path = state .. "/workspaces/" .. vim.fn.sha256(repo) .. ".json"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	local first = assert(plugin_module.status(repo))
	assert(first.token == nil and first.workspace_key.runtime == "container")
	first.workspace_key.runtime = "changed"
	assert(assert(plugin_module.status(repo)).workspace_key.runtime == "container")
	record.version = 3
	record.cli_path = "/opt/devcontainer/bin/devcontainer"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	local current = assert(plugin_module.status(repo))
	assert(current.version == 3 and current.cli_path == "/opt/devcontainer/bin/devcontainer")
	record.cli_path = "relative/devcontainer"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil)
	record.version = 4
	record.cli_path = "/opt/devcontainer/bin/devcontainer"
	record.docker_path = "/opt/homebrew/bin/podman"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(assert(plugin_module.status(repo)).docker_path == "/opt/homebrew/bin/podman")
	record.docker_path = "podman"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil)
	record.docker_path = "/opt/homebrew/bin/podman"
	record.phase = "claimed"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil, "v4 must reject the v5 phase field")
	record.version = 5
	local phases = {
		"claimed",
		"preparing-config",
		"starting-container",
		"checking-ssh-agent",
		"checking-editor-config",
		"opening-editor",
		"monitoring-editor",
		"returning-host",
	}
	for _, phase in ipairs(phases) do
		record.phase = phase
		assert(plugin_module._atomic_write(path, vim.json.encode(record)))
		local current_phase = assert(plugin_module.status(repo))
		assert(current_phase.version == 5 and current_phase.phase == phase)
		current_phase.phase = "mutated"
		assert(assert(plugin_module.status(repo)).phase == phase)
	end
	record.phase = nil
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil, "v5 must require phase")
	record.phase = "unknown"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil, "v5 must reject unknown phases")
	record.phase = "monitoring-editor"
	record.extra = true
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil, "v5 must reject extra fields")
	record.extra = nil
	record.version = 6
	record.podman_connection = {
		name = "podman-machine-default",
		machine_pin = string.rep("a", 64),
	}
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	local current_v6 = assert(plugin_module.status(repo))
	assert(current_v6.version == 6 and current_v6.phase == "monitoring-editor")
	assert(current_v6.podman_connection.name == "podman-machine-default")
	current_v6.podman_connection.name = "mutated"
	assert(assert(plugin_module.status(repo)).podman_connection.name == "podman-machine-default")

	local invalid_connections = {
		"podman-machine-default",
		{ name = 7, machine_pin = string.rep("a", 64) },
		{ name = "", machine_pin = string.rep("a", 64) },
		{ name = string.rep("a", 129), machine_pin = string.rep("a", 64) },
		{ name = "podman machine", machine_pin = string.rep("a", 64) },
		{ name = "podman-machine-default", machine_pin = string.rep("A", 64) },
		{ name = "podman-machine-default", machine_pin = string.rep("a", 63) },
		{ name = "podman-machine-default" },
		{ machine_pin = string.rep("a", 64) },
		{ name = "podman-machine-default", machine_pin = string.rep("a", 64), extra = true },
	}
	for _, connection in ipairs(invalid_connections) do
		record.podman_connection = connection
		assert(plugin_module._atomic_write(path, vim.json.encode(record)))
		assert(plugin_module.status(repo) == nil, "v6 must reject an invalid Podman connection")
	end
	record.podman_connection = nil
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil, "v6 must require the Podman connection field")
	record.podman_connection = {
		name = "podman-machine-default",
		machine_pin = string.rep("a", 64),
	}
	record.version = 7
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil, "v7 record versions must fail closed")
	record.version = 6
	record.phase = "starting-container"
	record.status = "error"
	record.error = "runtime resolution failed before a claim could start"
	record.cli_path = vim.NIL
	record.docker_path = vim.NIL
	record.podman_connection = vim.NIL
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	local early_failure = assert(plugin_module.status(repo))
	assert(early_failure.error == record.error)
	assert(early_failure.phase == "starting-container", "errors must retain their last lifecycle phase")
	assert(early_failure.cli_path == nil and early_failure.docker_path == nil)
	assert(early_failure.podman_connection == nil)
	record.status = "running"
	record.error = vim.NIL
	record.cli_path = "/opt/devcontainer/bin/devcontainer"
	record.docker_path = "podman"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	assert(plugin_module.status(repo) == nil)
	assert(vim.uv.fs_unlink(path))
	assert(vim.uv.fs_symlink(repo .. "/sub/file.txt", path))
	assert(plugin_module.status(repo) == nil)
	assert(vim.uv.fs_unlink(path))
end)

test("lifecycle log path is derived once and enforces exact records and size bounds", function()
	write_lifecycle_log("starting\n")
	local resolutions = 0
	configure(nil, nil, {
		state_root = function()
			resolutions = resolutions + 1
			return state
		end,
	})
	for version = 2, 6 do
		write_workspace_record(workspace_record(version))
		resolutions = 0
		assert(plugin_module.log_path(repo) == lifecycle_log_file)
		assert(resolutions == 1, "log_path must resolve state_root exactly once")
	end

	local mismatch = workspace_record(6, { log_path = state .. "/logs/other.log" })
	write_workspace_record(mismatch)
	assert(plugin_module.log_path(repo) == nil, "record-controlled log paths must be rejected")
	write_workspace_record(workspace_record(6))

	write_lifecycle_log(string.rep("x", 256 * 1024))
	assert(plugin_module.log_path(repo) == lifecycle_log_file, "the 256 KiB boundary must be accepted")
	write_lifecycle_log(string.rep("x", 256 * 1024 + 1))
	assert(plugin_module.log_path(repo) == nil, "oversized lifecycle logs must fail closed")
	assert(vim.uv.fs_unlink(lifecycle_log_file))
	assert(plugin_module.log_path(repo) == nil, "missing lifecycle logs must fail closed")
	assert(vim.uv.fs_lstat(lifecycle_log_file) == nil, "log_path must not create a missing log")
	configure()
end)

test("lifecycle log path rejects hostile leaves and unsafe hierarchy", function()
	write_workspace_record(workspace_record(6))
	local target = repo .. "/sub/file.txt"
	assert(vim.uv.fs_symlink(target, lifecycle_log_file))
	assert(plugin_module.log_path(repo) == nil, "symlink logs must be rejected")
	assert(vim.uv.fs_unlink(lifecycle_log_file))

	local hardlink_source = state .. "/logs/hardlink-source.log"
	write_lifecycle_log("hardlink\n")
	assert(vim.uv.fs_rename(lifecycle_log_file, hardlink_source))
	assert(vim.uv.fs_link(hardlink_source, lifecycle_log_file))
	assert(plugin_module.log_path(repo) == nil, "multi-link logs must be rejected")
	assert(vim.uv.fs_unlink(lifecycle_log_file))
	assert(vim.uv.fs_unlink(hardlink_source))

	assert(vim.fn.mkdir(lifecycle_log_file, "p", tonumber("700", 8)) == 1)
	assert(plugin_module.log_path(repo) == nil, "non-regular logs must be rejected")
	assert(vim.uv.fs_rmdir(lifecycle_log_file))
	write_lifecycle_log("mode\n")
	assert(vim.uv.fs_chmod(lifecycle_log_file, tonumber("640", 8)))
	assert(plugin_module.log_path(repo) == nil, "group-readable logs must be rejected")
	assert(vim.uv.fs_chmod(lifecycle_log_file, tonumber("600", 8)))

	local target_stat = assert(vim.uv.fs_stat(lifecycle_log_file))
	local original_fstat = vim.uv.fs_fstat
	vim.uv.fs_fstat = function(fd)
		local stat, stat_err = original_fstat(fd)
		if stat and stat.dev == target_stat.dev and stat.ino == target_stat.ino then
			stat = vim.deepcopy(stat)
			stat.uid = stat.uid + 1
		end
		return stat, stat_err
	end
	local safe, owner_result = pcall(plugin_module.log_path, repo)
	vim.uv.fs_fstat = original_fstat
	assert(safe and owner_result == nil, "wrong-owner logs must be rejected")

	assert(vim.uv.fs_chmod(state .. "/logs", tonumber("750", 8)))
	assert(plugin_module.log_path(repo) == nil, "unsafe log directory modes must be rejected")
	assert(vim.uv.fs_chmod(state .. "/logs", tonumber("700", 8)))
	assert(vim.uv.fs_chmod(state, tonumber("750", 8)))
	assert(plugin_module.log_path(repo) == nil, "unsafe state root modes must be rejected")
	assert(vim.uv.fs_chmod(state, tonumber("700", 8)))
	local original_getuid = vim.uv.getuid
	vim.uv.getuid = function()
		return original_getuid() + 1
	end
	local owner_safe, hierarchy_owner_result = pcall(plugin_module.log_path, repo)
	vim.uv.getuid = original_getuid
	assert(owner_safe and hierarchy_owner_result == nil, "wrong-owner state hierarchy must be rejected")

	local real_logs = state .. "/logs-real"
	assert(vim.uv.fs_rename(state .. "/logs", real_logs))
	assert(vim.uv.fs_symlink(real_logs, state .. "/logs"))
	assert(plugin_module.log_path(repo) == nil, "symlinked log directories must be rejected")
	assert(vim.uv.fs_unlink(state .. "/logs"))
	assert(vim.uv.fs_rename(real_logs, state .. "/logs"))

	assert(vim.uv.fs_rename(state .. "/logs", real_logs))
	assert(plugin_module.log_path(repo) == nil, "missing log directories must fail closed")
	assert(vim.uv.fs_lstat(state .. "/logs") == nil, "log_path must not recreate a missing directory")
	assert(vim.uv.fs_rename(real_logs, state .. "/logs"))

	local state_alias = fixture .. "/state-alias"
	assert(vim.uv.fs_symlink(state, state_alias))
	configure(nil, nil, { state_root = state_alias })
	assert(plugin_module.log_path(repo) == nil, "symlinked state roots must be rejected")
	assert(vim.uv.fs_unlink(state_alias))
	configure()
end)

test("lifecycle log path detects replacement during descriptor validation", function()
	write_workspace_record(workspace_record(6))
	write_lifecycle_log("original\n")
	local displaced = lifecycle_log_file .. ".displaced"
	local rejected = with_test_hook(function(event)
		if event == "before_log_revalidation" then
			assert(vim.uv.fs_rename(lifecycle_log_file, displaced))
			write_lifecycle_log("replacement\n")
		end
	end, function()
		return plugin_module.log_path(repo) == nil
	end)
	assert(rejected, "a path replacement during validation must fail closed")
	assert(vim.uv.fs_unlink(lifecycle_log_file))
	assert(vim.uv.fs_rename(displaced, lifecycle_log_file))
end)

test("spool batches backlog and reports each record outcome", function()
	configure(nil, nil, { max_messages_per_tick = 2 })
	local names = {}
	for index = 1, 3 do
		local request_id = ("00000000-0000-4000-8000-%012d"):format(100 + index)
		local request = {
			version = 2,
			request_id = request_id,
			action = "open_location",
			path = "sub/file.txt",
			line = index,
			column = 1,
			created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		request.auth = assert(plugin_module._authenticate(token, "open_location", request))
		assert(plugin_module._atomic_create(spool .. "/inbox/" .. request_id .. ".json", vim.json.encode(request)))
		names[#names + 1] = request_id
	end
	local consumed, err, report = plugin_module.consume_spool_once()
	assert(consumed == 2 and err == nil)
	assert(report.state == "backlog" and report.processed == 2 and report.succeeded == 2 and report.remaining == 1)
	assert(#report.records == 2 and report.records[1].ok and report.records[2].ok)
	report.records[1].ok = false
	assert(plugin_module.transport_status().records[1].ok == true)
	consumed, err, report = plugin_module.consume_spool_once()
	assert(consumed == 1 and err == nil and report.state == "idle" and report.remaining == 0)
	for _, request_id in ipairs(names) do
		assert(vim.uv.fs_unlink(spool .. "/acks/" .. request_id .. ".json"))
	end
end)

test("setup contracts reject unknown keys without state mutation", function()
	local events = {}
	configure(nil, nil, {
		event = function(event)
			events[#events + 1] = event
		end,
	})
	local before = assert(plugin_module.effective_config())
	assert(before.claim_timeout_ms == 2000 and before.ack_timeout_ms == 5000)
	assert(before.max_messages_per_tick == 32 and before.lockfile_policy == "preserve")
	assert(before.launcher == nil and before.open == nil and before.notify == nil and before.event == nil)
	assert(before.state_root == nil and before.spool_root == nil and before.uuid == nil)
	assert(pcall(vim.json.encode, before))
	before.max_messages_per_tick = 1
	assert(assert(plugin_module.effective_config()).max_messages_per_tick == 32)
	local rejected, reject_err = pcall(plugin_module.setup, { injected = true })
	assert(not rejected and tostring(reject_err):find("unknown key", 1, true))
	assert(assert(plugin_module.effective_config()).max_messages_per_tick == 32)
	for label, invalid in pairs({
		false_options = false,
		retired_cli = { cli = "devcontainer" },
		false_docker = { docker_path = false },
		false_resolver = { resolve_cli = false },
		nul_launcher = { launcher = "/bin/tool\0arg" },
		empty_state_root = { state_root = "" },
		nul_spool_root = { spool_root = "spool\0root" },
	}) do
		local accepted = pcall(plugin_module.setup, invalid)
		assert(not accepted, label .. " was accepted")
	end
	assert(assert(plugin_module.effective_config()).max_messages_per_tick == 32)

	configure(nil, nil, {
		state_root = function()
			error("state boom")
		end,
	})
	local safe, value, dynamic_err = pcall(plugin_module.status, repo)
	assert(safe and value == nil and tostring(dynamic_err):find("state boom", 1, true), "state callback escaped API")
	configure(nil, nil, {
		spool_root = function()
			error("spool boom")
		end,
	})
	safe, value, dynamic_err = pcall(plugin_module.consume_spool_once)
	assert(safe and value == nil and tostring(dynamic_err):find("spool boom", 1, true), "spool callback escaped API")
	configure(nil, nil, {
		event = function(event)
			events[#events + 1] = event
		end,
	})
	local transport = plugin_module.transport_status()
	transport.state = "mutated"
	assert(plugin_module.transport_status().state ~= "mutated")
	local aggregate = plugin_module.status()
	assert(aggregate.configured == true and aggregate.transport.state ~= "mutated")
	aggregate.transport.state = "mutated"
	assert(plugin_module.status().transport.state ~= "mutated")
	assert(events[#events].kind == "setup" and events[#events].config.launcher == nil)
	assert(pcall(vim.json.encode, events[#events].config))
	assert(plugin_module.teardown())
	assert(plugin_module.effective_config().max_messages_per_tick == 32)
	assert(plugin_module.status().configured == false)
end)

test("stale watcher callbacks cannot consume or rearm a replacement lifecycle", function()
	local original_new_timer = vim.uv.new_timer
	local original_schedule_wrap = vim.schedule_wrap
	local original_consume = plugin_module.consume_spool_once
	local timers = {}
	local consumes = 0
	vim.schedule_wrap = function(callback)
		return callback
	end
	vim.uv.new_timer = function()
		local timer = { starts = 0, closed = false }
		function timer:start(_, _, callback)
			self.starts = self.starts + 1
			self.callback = callback
		end
		function timer:stop() end
		function timer:close()
			self.closed = true
		end
		timers[#timers + 1] = timer
		return timer
	end
	plugin_module.consume_spool_once = function()
		consumes = consumes + 1
		return 0, nil, { remaining = 0 }
	end
	local ok, err = xpcall(function()
		configure(nil, nil, { watch = true })
		local stale = assert(timers[1].callback)
		configure(nil, nil, { watch = true })
		assert(timers[1].closed and timers[2].starts == 1)
		stale()
		assert(consumes == 0, "stale watcher consumed the replacement spool")
		assert(timers[2].starts == 1, "stale watcher rearmed the replacement timer")
		timers[2].callback()
		assert(consumes == 1 and timers[2].starts == 2, "active watcher did not consume and rearm")
		plugin_module.stop()
	end, debug.traceback)
	vim.uv.new_timer = original_new_timer
	vim.schedule_wrap = original_schedule_wrap
	plugin_module.consume_spool_once = original_consume
	assert(ok, err)
end)

plugin_module.stop()
for name, value in pairs(original_env) do
	vim.env[name] = value
end
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("devcontainer_editor_spec: %d tests passed", count))
vim.cmd("quitall!")
