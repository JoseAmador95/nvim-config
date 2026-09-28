vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = assert(vim.uv.fs_realpath(vim.fn.getcwd() .. "/local-plugins/exact-editor.nvim"))
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	vim.fn.getcwd() .. "/local-plugins/_shared/lua/?.lua",
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	package.path,
}, ";")

local exact = require("exact_editor")
local failures = {}
local count = 0

local function fake_timer_factory(observed)
	return function()
		local timer = {
			closed = false,
			close_calls = 0,
			stop_calls = 0,
			unref_calls = 0,
		}
		function timer:start(timeout, repeat_interval, callback)
			self.timeout = timeout
			self.repeat_interval = repeat_interval
			self.callback = callback
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
		end
		function timer:close()
			self.close_calls = self.close_calls + 1
			self.closed = true
		end
		function timer:is_closing()
			return self.closed
		end
		function timer:unref()
			self.unref_calls = self.unref_calls + 1
		end
		observed[#observed + 1] = timer
		return timer
	end
end

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
local state = fixture .. "/state"
local root = fixture .. "/repo"
assert(vim.fn.mkdir(root, "p") == 1)

assert(not exact._normalize_workspace({
	runtime = "host",
	root = root,
	repo_identity = root,
	injected = true,
}))
root = assert(vim.uv.fs_realpath(root))
assert(vim.fn.writefile({ "return true" }, root .. "/target.lua") == 0)
assert(exact._prepare_state(state))

local workspace = { runtime = "host", root = root, repo_identity = "repo:test" }
local instance = {
	root = state,
	instance_id = "12345678-1234-4234-8234-123456789abc",
	pid = vim.uv.os_getpid(),
	socket = state .. "/sockets/exact.sock",
	workspaces = { [exact._workspace_identity(workspace)] = workspace },
}

local function private_json(path, value)
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	local encoded = vim.json.encode(value) .. "\n"
	assert(vim.uv.fs_write(fd, encoded, 0) == #encoded)
	assert(vim.uv.fs_fsync(fd))
	assert(vim.uv.fs_close(fd))
	assert(vim.uv.fs_chmod(path, tonumber("600", 8)))
end

local function normal_request(id, overrides)
	local value = {
		version = 1,
		request_id = id,
		instance_id = instance.instance_id,
		repo_root = root,
		path = "target.lua",
		line = 4,
		column = 2,
		created_at = "2026-08-31T10:00:00Z",
	}
	for key, item in pairs(overrides or {}) do
		value[key] = item
	end
	return value
end

local function request_path(id)
	return state .. "/requests/" .. id .. ".json"
end

test("status and setup rejection are safe before an instance exists", function()
	assert(vim.deep_equal(exact.effective_config(), {
		workspace_retention = "visited",
		registry_heartbeat_seconds = 21600,
	}))
	local status = exact.status()
	assert(
		status.configured == false
			and status.workspace_retention == "visited"
			and status.registry_heartbeat_seconds == 21600
	)
	local ok, err = pcall(exact.setup, { injected = true })
	assert(not ok and tostring(err):find("unknown option: injected", 1, true))
	assert(vim.deep_equal(status, exact.status()), "rejected setup mutated status")
end)

test("heartbeat policy is strict before setup performs I/O", function()
	for _, value in ipairs({ 59, 604801, 60.5, "60" }) do
		local server_called = false
		local ok, err = pcall(exact.setup, {
			state_root = state,
			resolve_workspace = function()
				return workspace
			end,
			open = function() end,
			registry_heartbeat_seconds = value,
			server_start = function()
				server_called = true
			end,
		})
		assert(not ok and tostring(err):find("integer between 60 and 604800", 1, true))
		assert(not server_called and not exact.status().configured, "invalid heartbeat policy caused setup I/O")
	end
end)

test("failed setup restores the prior configuration", function()
	local prior_root = exact.state_root()
	local failed_state = ("/tmp/nvim-eef-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime() % 1000000000)
	local configured_instance = exact.setup({
		state_root = failed_state,
		resolve_workspace = function()
			return workspace
		end,
		open = function() end,
		uuid = function()
			return "invalid"
		end,
		notify = function() end,
	})
	assert(configured_instance == nil)
	assert(not exact.status().configured, "failed setup left an active instance")
	assert(exact.state_root() == prior_root, "failed setup retained candidate callbacks")
	vim.fn.delete(failed_state, "rf")
end)

test("registry persists an exact WorkspaceKey and returns detached values", function()
	local record = assert(exact.write_registry(instance))
	assert(record.version == 2)
	assert(vim.deep_equal(record.workspaces, { workspace }))
	record.workspaces[1].runtime = "container"
	assert(instance.workspaces[exact._workspace_identity(workspace)].runtime == "host")
	local path = state .. "/editors/" .. instance.instance_id .. ".json"
	assert(assert(vim.uv.fs_lstat(path)).mode % 512 == tonumber("600", 8))
end)

test("normal RPC opens one contained file and consumes the private request", function()
	local id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	private_json(request_path(id), normal_request(id))
	local opened
	local handled, err = exact.consume_normal(id, instance, {
		open_file = function(path, position)
			opened = { path = path, position = position }
		end,
	})
	assert(handled == 1, err)
	assert(opened.path == root .. "/target.lua")
	assert(opened.position.lnum == 4 and opened.position.col == 2)
	assert(vim.uv.fs_lstat(request_path(id)) == nil)
end)

test("normal RPC rejects traversal and a blocking schema before opening", function()
	local traversal = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	private_json(request_path(traversal), normal_request(traversal, { path = "../target.lua" }))
	assert(exact.consume_normal(traversal, instance, {
		open_file = function()
			error("opened")
		end,
	}) == nil)

	local blocking = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	private_json(request_path(blocking), {
		version = 2,
		request_id = blocking,
		instance_id = instance.instance_id,
		repo_root = root,
		path = root .. "/target.lua",
		created_at = "2026-08-31T10:00:00Z",
	})
	local handled, err = exact.consume_normal(blocking, instance, {
		open_file = function()
			error("opened")
		end,
	})
	assert(not handled and err:find("not normal", 1, true))
end)

test("concurrent waits share one finish action and fan out deterministically", function()
	local ids = {
		"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
		"ffffffff-ffff-4fff-8fff-ffffffffffff",
	}
	for _, id in ipairs(ids) do
		private_json(request_path(id), {
			version = 2,
			request_id = id,
			instance_id = instance.instance_id,
			repo_root = root,
			path = root .. "/target.lua",
			created_at = "2026-08-31T10:00:00Z",
		})
	end
	local installs = 0
	local removals = 0
	local finish
	local dependencies = {
		open_file = function(path)
			vim.cmd("tabedit " .. vim.fn.fnameescape(path))
		end,
		install_finish_mapping = function(_, callback)
			installs = installs + 1
			finish = callback
			return function()
				removals = removals + 1
			end
		end,
	}
	for _, id in ipairs(ids) do
		local handled, err = exact.consume_blocking(id, instance, dependencies)
		assert(handled == 1, err)
	end
	assert(installs == 1 and type(finish) == "function", "buffer received more than one finish action")
	local status = exact.status()
	assert(#status.waits == 2)
	assert(status.waits[1].request_id == ids[1] and status.waits[2].request_id == ids[2])
	status.waits[1].status = "mutated"
	assert(exact.status().waits[1].status == "waiting", "wait status shares plugin state")
	for _, id in ipairs(ids) do
		local wait = state .. "/waits/" .. id .. ".json"
		assert(assert(vim.uv.fs_lstat(wait)).mode % 512 == tonumber("600", 8))
		assert(vim.json.decode(table.concat(vim.fn.readfile(wait), "\n")).status == "waiting")
	end
	finish()
	assert(removals == 1, "shared finish action was not removed exactly once")
	assert(#exact.status().waits == 0, "finished waits remain active")
	for _, id in ipairs(ids) do
		local wait = state .. "/waits/" .. id .. ".json"
		assert(vim.json.decode(table.concat(vim.fn.readfile(wait), "\n")).status == "completed")
	end
end)

test("descriptor-relative cleanup preserves record replacements at both validation boundaries", function()
	local record = state .. "/editors/" .. instance.instance_id .. ".json"
	assert(exact.write_registry(instance))
	local owned_before_reserve = record .. ".owned-before-reserve"
	exact._set_test_hook(function(event, details)
		if event ~= "before_cleanup_reserve" or details.path ~= record then
			return
		end
		assert(vim.uv.fs_rename(record, owned_before_reserve))
		private_json(record, { replacement = "before-reserve" })
	end)
	exact._cleanup(instance)
	exact._set_test_hook(nil)
	assert(vim.uv.fs_lstat(owned_before_reserve), "owned record was not retained by the fixture")
	assert(
		vim.json.decode(table.concat(vim.fn.readfile(record), "\n")).replacement == "before-reserve",
		"replacement created before reserve was removed"
	)

	assert(exact.write_registry(instance))
	local owned_before_unlink = record .. ".owned-before-unlink"
	exact._set_test_hook(function(event, details)
		if event ~= "before_cleanup_unlink" or details.path ~= record then
			return
		end
		assert(vim.uv.fs_rename(details.reserved, owned_before_unlink))
		private_json(details.reserved, { replacement = "before-unlink" })
	end)
	exact._cleanup(instance)
	exact._set_test_hook(nil)
	assert(vim.uv.fs_lstat(owned_before_unlink), "validated record was not retained by the fixture")
	assert(
		vim.json.decode(table.concat(vim.fn.readfile(record), "\n")).replacement == "before-unlink",
		"replacement created before unlink was removed"
	)
end)

test("cleanup without an owned registry identity fails closed", function()
	local record = state .. "/editors/" .. instance.instance_id .. ".json"
	private_json(record, { replacement = "missing-identity" })
	local unowned = vim.deepcopy(instance)
	unowned.registry_identity = nil
	local hooks = 0
	exact._set_test_hook(function()
		hooks = hooks + 1
	end)
	exact._cleanup(unowned)
	exact._set_test_hook(nil)
	assert(hooks == 0, "cleanup without an identity temporarily moved the record")
	assert(
		vim.json.decode(table.concat(vim.fn.readfile(record), "\n")).replacement == "missing-identity",
		"record without an owned identity was removed"
	)
end)

test("post-reserve failure restores the same record before returning", function()
	local record = state .. "/editors/" .. instance.instance_id .. ".json"
	assert(exact.write_registry(instance))
	local before = assert(vim.uv.fs_lstat(record))
	local reached_unlink = false
	exact._set_test_hook(function(event, details)
		if details.path ~= record then
			return
		end
		if event == "after_cleanup_reserve" then
			error("injected inspection boundary failure")
		elseif event == "before_cleanup_unlink" then
			reached_unlink = true
		end
	end)
	exact._cleanup(instance)
	exact._set_test_hook(nil)
	local restored = assert(vim.uv.fs_lstat(record))
	assert(restored.ino == before.ino and restored.dev == before.dev, "reserved record was not restored in place")
	assert(not reached_unlink, "cleanup continued to unlink after the post-reserve failure")
end)

test("socket pathname is vacant during stop and a late replacement is restored", function()
	local socket_dir = ("/tmp/nvim-eec-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime() % 1000000000)
	assert(vim.fn.mkdir(socket_dir, "p", tonumber("700", 8)) == 1)
	assert(vim.uv.fs_chmod(socket_dir, tonumber("700", 8)))
	local socket = socket_dir .. "/server.sock"
	vim.fn.delete(socket)
	assert(vim.fn.serverstart(socket) == socket)
	assert(vim.uv.fs_chmod(socket, tonumber("600", 8)))
	local socket_identity = assert(vim.uv.fs_lstat(socket))
	local rival
	local rival_identity
	exact._set_test_hook(function(event, details)
		if event ~= "before_cleanup_server_stop" or details.path ~= socket then
			return
		end
		assert(vim.uv.fs_lstat(socket) == nil, "owned socket pathname was still visible before server stop")
		rival = assert(vim.uv.new_pipe(false))
		assert(rival:bind(socket))
		assert(rival:listen(16, function() end))
		assert(vim.uv.fs_chmod(socket, tonumber("600", 8)))
		rival_identity = assert(vim.uv.fs_lstat(socket))
	end)
	exact._cleanup({
		root = state,
		instance_id = "87654321-4321-4321-8321-cba987654321",
		socket = socket,
		socket_identity = socket_identity,
		owns_socket = true,
		workspaces = {},
	})
	exact._set_test_hook(nil)
	local restored = assert(vim.uv.fs_lstat(socket))
	assert(restored.type == "socket" and restored.ino == rival_identity.ino, "late socket replacement was not restored")
	rival:close()
	vim.wait(1000, function()
		return rival:is_closing()
	end)
	vim.fn.delete(socket_dir, "rf")
end)

test("symlink request and record paths are rejected without unlinking their targets", function()
	local id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
	local target = fixture .. "/hostile.json"
	private_json(target, normal_request(id))
	assert(vim.uv.fs_symlink(target, request_path(id)))
	local handled, err = exact.consume_normal(id, instance, {
		open_file = function()
			error("opened")
		end,
	})
	assert(not handled and err:find("non%-symlink"))
	assert(vim.uv.fs_lstat(request_path(id)).type == "link")

	local record = state .. "/editors/" .. instance.instance_id .. ".json"
	vim.fn.delete(record)
	assert(vim.uv.fs_symlink(target, record))
	exact._cleanup(instance)
	assert(vim.uv.fs_lstat(record).type == "link")
end)

test("discovery publishes only new workspaces and heartbeat is quick-exit safe", function()
	local lifecycle_state = ("/tmp/nvim-eeh-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime() % 1000000000)
	local second_root = fixture .. "/repo-second"
	assert(vim.fn.mkdir(second_root, "p") == 1)
	second_root = assert(vim.uv.fs_realpath(second_root))
	local first_workspace = { runtime = "host", root = root, repo_identity = "repo:first" }
	local second_workspace = { runtime = "host", root = second_root, repo_identity = "repo:second" }
	local resolver_calls = 0
	local events = {}
	local timers = {}
	vim.cmd("enew")
	exact._set_timer_factory_for_tests(fake_timer_factory(timers))
	local lifecycle_instance = assert(exact.setup({
		state_root = lifecycle_state,
		resolve_workspace = function(path)
			resolver_calls = resolver_calls + 1
			if path == root or path:sub(1, #root + 1) == root .. "/" then
				return first_workspace
			end
			if path == second_root or path:sub(1, #second_root + 1) == second_root .. "/" then
				return second_workspace
			end
			return nil
		end,
		open = function() end,
		uuid = function()
			return "76543210-1234-4234-8234-123456789abc"
		end,
		registry_heartbeat_seconds = 60,
		on_state_change = function(event)
			events[#events + 1] = event.kind
		end,
	}))
	assert(#timers == 1, "setup created more than one heartbeat")
	local timer = timers[1]
	assert(timer.timeout == 60000 and timer.repeat_interval == 60000, "heartbeat interval was not applied")
	assert(timer.unref_calls == 1, "heartbeat can keep a quick Neovim exit alive")
	assert(exact.setup({
		state_root = lifecycle_state,
		resolve_workspace = function()
			return nil
		end,
		open = function() end,
		registry_heartbeat_seconds = 60,
	}) == lifecycle_instance, "repeated setup did not reuse the active instance")
	assert(#timers == 1, "repeated setup created a second heartbeat")
	assert(exact.effective_config().registry_heartbeat_seconds == 60)
	assert(exact.status().registry_heartbeat_seconds == 60)

	local original_write_registry = exact.write_registry
	local writes = 0
	local fail_next = false
	exact.write_registry = function(selected)
		writes = writes + 1
		if fail_next then
			fail_next = false
			return nil, "simulated registry publication failure"
		end
		return original_write_registry(selected)
	end
	timer.callback()
	assert(
		vim.wait(1000, function()
			return writes == 1
		end, 10),
		"heartbeat did not refresh the registry"
	)

	writes = 0
	resolver_calls = 0
	local before_events = #events
	assert(exact._discover(lifecycle_instance, root .. "/target.lua"))
	assert(writes == 1 and resolver_calls == 1, "new workspace did not publish exactly once")
	assert(#events == before_events + 1 and events[#events] == "workspace-visited")
	writes = 0
	resolver_calls = 0
	assert(exact._discover(lifecycle_instance, root .. "/target.lua"))
	assert(writes == 0 and resolver_calls == 0, "known workspace discovery was not a zero-write cache hit")

	before_events = #events
	fail_next = true
	local published, publish_err = exact._discover(lifecycle_instance, second_root)
	assert(not published and publish_err:find("simulated", 1, true))
	assert(writes == 1, "failed new workspace publication did not write exactly once")
	assert(lifecycle_instance.workspaces[exact._workspace_identity(second_workspace)] == nil)
	assert(#events == before_events, "failed workspace publication emitted a visited event")
	writes = 0
	assert(exact._discover(lifecycle_instance, second_root))
	assert(writes == 1, "retried workspace publication did not write exactly once")
	assert(lifecycle_instance.workspaces[exact._workspace_identity(second_workspace)] ~= nil)
	assert(#events == before_events + 1 and events[#events] == "workspace-visited")

	writes = 0
	vim.api.nvim_exec_autocmds("VimLeavePre", {})
	assert(timer.stop_calls == 1 and timer.close_calls == 1, "VimLeavePre did not close the heartbeat")
	timer.callback()
	vim.wait(50, function()
		return false
	end, 10)
	assert(writes == 0, "stale heartbeat callback survived cleanup")
	exact.write_registry = original_write_registry
	exact._set_timer_factory_for_tests(nil)
	assert(not exact.status().configured)
	vim.fn.delete(lifecycle_state, "rf")
end)

test("failed server stop preserves the live instance and teardown can retry", function()
	local retry_state = ("/tmp/nvim-eet-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime() % 1000000000)
	local allow_stop = false
	local events = {}
	local timers = {}
	exact._set_timer_factory_for_tests(fake_timer_factory(timers))
	local retry_instance = assert(exact.setup({
		state_root = retry_state,
		resolve_workspace = function()
			return workspace
		end,
		open = function() end,
		uuid = function()
			return "98765432-1234-4234-8234-123456789abc"
		end,
		server_stop = function(path)
			if not allow_stop then
				return false
			end
			return vim.fn.serverstop(path) == 1
		end,
		on_state_change = function(event)
			events[#events + 1] = event.kind
		end,
	}))
	local record = retry_state .. "/editors/" .. retry_instance.instance_id .. ".json"
	assert(vim.uv.fs_lstat(retry_instance.socket) and vim.uv.fs_lstat(record))
	assert(exact.teardown() == false, "failed server stop was reported as a completed teardown")
	assert(exact.status().configured and _G.ExactEditorRequest, "failed teardown discarded the live instance")
	assert(
		vim.uv.fs_lstat(retry_instance.socket) and vim.uv.fs_lstat(record),
		"failed teardown removed discovery state"
	)
	assert(not vim.tbl_contains(events, "instance-stopped"), "failed teardown emitted a stop event")
	local timer = assert(timers[1], "failed-stop fixture did not create a heartbeat")
	assert(timer.stop_calls == 0 and timer.close_calls == 0, "failed server stop discarded the heartbeat")
	local original_write_registry = exact.write_registry
	local heartbeat_writes = 0
	exact.write_registry = function(selected)
		heartbeat_writes = heartbeat_writes + 1
		return original_write_registry(selected)
	end
	timer.callback()
	assert(
		vim.wait(1000, function()
			return heartbeat_writes == 1
		end, 10),
		"preserved heartbeat did not remain live for teardown retry"
	)
	exact.write_registry = original_write_registry

	allow_stop = true
	assert(exact.teardown(), "teardown retry did not stop the preserved instance")
	assert(timer.stop_calls == 1 and timer.close_calls == 1, "successful retry did not close the heartbeat")
	exact._set_timer_factory_for_tests(nil)
	assert(not exact.status().configured and _G.ExactEditorRequest == nil)
	assert(vim.uv.fs_lstat(retry_instance.socket) == nil and vim.uv.fs_lstat(record) == nil)
	local stopped = vim.tbl_filter(function(kind)
		return kind == "instance-stopped"
	end, events)
	assert(#stopped == 1 and events[#events] == "instance-stopped")
	vim.fn.delete(retry_state, "rf")
end)

test("invalid clock snapshots fail before state or server publication", function()
	for index, value in ipairs({ false, "not-a-timestamp", "2026-02-30T00:00:00Z" }) do
		local failed_state = ("/tmp/nvim-eec-clock-%d-%d-%d"):format(
			vim.uv.os_getpid(),
			vim.uv.hrtime() % 1000000000,
			index
		)
		local server_called = false
		local configured = exact.setup({
			state_root = failed_state,
			resolve_workspace = function()
				return workspace
			end,
			open = function() end,
			clock = function()
				return value
			end,
			server_start = function()
				server_called = true
			end,
			notify = function() end,
		})
		assert(configured == nil, "invalid clock was accepted")
		assert(not server_called and vim.uv.fs_lstat(failed_state) == nil, "invalid clock caused setup I/O")
		assert(not exact.status().configured)
	end
end)

test("deferred setup callbacks are invalidated by teardown", function()
	local scheduled
	local setup_calls = 0
	exact.setup_deferred({
		ui_count = function()
			return 1
		end,
		schedule = function(callback)
			scheduled = callback
		end,
		setup = function()
			setup_calls = setup_calls + 1
			return true
		end,
	})
	assert(type(scheduled) == "function")
	assert(exact.teardown())
	scheduled()
	assert(setup_calls == 0, "deferred setup survived teardown")
end)

test("deferred setup retries after the UI detaches before its callback", function()
	assert(exact.teardown())
	local callbacks = {}
	local uis = 0
	local setup_calls = 0
	exact.setup_deferred({
		ui_count = function()
			return uis
		end,
		schedule = function(callback)
			callbacks[#callbacks + 1] = callback
		end,
		setup = function()
			setup_calls = setup_calls + 1
			return true
		end,
	})

	uis = 1
	vim.api.nvim_exec_autocmds("UIEnter", { modeline = false })
	assert(#callbacks == 1, "first UI did not queue deferred setup")
	uis = 0
	callbacks[1]()
	assert(setup_calls == 0, "setup ran after its UI detached")
	uis = 1
	vim.api.nvim_exec_autocmds("UIEnter", { modeline = false })
	assert(#callbacks == 2, "later UI could not retry deferred setup")
	callbacks[2]()
	assert(setup_calls == 1, "retried setup did not run exactly once")
	assert(vim.fn.exists("#exact_editor_rpc_deferred#UIEnter") == 0, "effective setup left a deferred watcher")
	assert(exact.teardown())
end)

test("deferred setup remains retryable until setup is effective", function()
	assert(exact.teardown())
	local callbacks = {}
	local uis = 1
	local setup_calls = 0
	exact.setup_deferred({
		ui_count = function()
			return uis
		end,
		schedule = function(callback)
			callbacks[#callbacks + 1] = callback
		end,
		setup = function()
			setup_calls = setup_calls + 1
			return setup_calls > 1
		end,
	})

	callbacks[1]()
	assert(setup_calls == 1, "first deferred setup did not run")
	assert(vim.fn.exists("#exact_editor_rpc_deferred#UIEnter") == 1, "failed setup removed its retry watcher")
	uis = 0
	vim.api.nvim_exec_autocmds("UILeave", { modeline = false })
	uis = 1
	vim.api.nvim_exec_autocmds("UIEnter", { modeline = false })
	assert(#callbacks == 2, "failed setup was not retried on a later UI")
	callbacks[2]()
	assert(setup_calls == 2, "retry did not run exactly once")
	assert(vim.fn.exists("#exact_editor_rpc_deferred#UIEnter") == 0, "successful retry left a watcher")
	assert(exact.teardown())
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("exact_editor_spec: %d tests passed", count))
vim.cmd("quitall!")
