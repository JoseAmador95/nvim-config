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
assert(vim.fn.mkdir(fixture .. "/spool", "p") == 1)
assert(vim.fn.writefile({ "hello" }, fixture .. "/repo/sub/file.txt") == 0)
local repo = assert(vim.uv.fs_realpath(fixture .. "/repo"))
local state = assert(vim.uv.fs_realpath(fixture .. "/state"))
local spool = assert(vim.uv.fs_realpath(fixture .. "/spool"))
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
local function configure(notify, open_callback)
	plugin_module.setup({
		state_root = state,
		spool_root = spool,
		launcher = "/bin/devcontainer-editor",
		watch = false,
		notify = notify,
		uuid = function()
			return "00000000-0000-4000-8000-000000000001"
		end,
		open = open_callback or function(path, position)
			opened = { path = path, position = position }
		end,
	})
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
		assert(plugin_module.consume_spool_once() == nil)
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

test("host requests use an authenticated private spool and exact allowlist", function()
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
	assert(plugin_module.request_host("lazygit", { defer = defer }, function(value)
		callback_value = value
	end))
	assert(callback_value.action == "lazygit")
	assert(plugin_module.request_host("publish") == nil)
	assert(plugin_module.request_host("execute") == nil)
	assert(vim.uv.fs_unlink(spool .. "/outbox/00000000-0000-4000-8000-000000000001.json"))
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
	assert(plugin_module.lifecycle_argv("delete", {}) == nil)
end)

test("workspace status rejects hostile state and returns immutable copies", function()
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
		log_path = state .. "/log",
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
	assert(vim.uv.fs_unlink(path))
	assert(vim.uv.fs_symlink(repo .. "/sub/file.txt", path))
	assert(plugin_module.status(repo) == nil)
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
