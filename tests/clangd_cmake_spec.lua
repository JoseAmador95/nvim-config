vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/clangd-compile-db.nvim")
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local fixture = vim.fn.tempname()
for _, path in ipairs({ "/one/build", "/one/manual", "/two/build", "/three/manual", "/auto/build" }) do
	vim.fn.mkdir(fixture .. path, "p")
	vim.fn.writefile({ "[]" }, fixture .. path .. "/compile_commands.json")
end
fixture = vim.uv.fs_realpath(fixture) or fixture

local original_local = package.loaded["config.local_config"]
local original_clients = vim.lsp.get_clients
local original_start = vim.lsp.start
local original_attach = vim.lsp.buf_attach_client
local original_get_client = vim.lsp.get_client_by_id
local original_config = vim.lsp.config
local original_rpc_start = vim.lsp.rpc.start
local original_defer = vim.defer_fn
local original_editor = package.loaded["config.editor"]
local original_workflow = package.loaded["config.workflow_execution"]
local original_cmake_utils = package.loaded["cmake-tools.utils"]
local original_cmake_result = package.loaded["cmake-tools.result"]
local original_cmake_types = package.loaded["cmake-tools.types"]

local cmake_gate_mode = "allow"
local cmake_grants = {}
local cmake_notifications = {}
package.loaded["config.workflow_execution"] = {
	grant = function(capability, options)
		cmake_grants[#cmake_grants + 1] = { capability = capability, options = vim.deepcopy(options) }
		if cmake_gate_mode == "deny" then
			return nil, capability .. " grant denied"
		end
		return true, { runtime = "host" }
	end,
	notify = function(title, message, level)
		cmake_notifications[#cmake_notifications + 1] = { title = title, message = tostring(message), level = level }
	end,
}
local Result = {}
function Result:new(code, data, message)
	return setmetatable({ code = code, data = data, message = message }, { __index = self })
end
function Result:is_ok()
	return self.code == 0
end
local Types = { SUCCESS = 0, CMAKE_RUN_FAILED = 17 }
local utility_calls = { execute = {}, run = {} }
local cmake_utils = {
	execute = function(cmd, env_script, env, args, cwd, executor, callback)
		utility_calls.execute[#utility_calls.execute + 1] = {
			cmd = cmd,
			env_script = env_script,
			env = env,
			args = args,
			cwd = cwd,
			executor = executor,
		}
		if callback then
			callback(Result:new(Types.SUCCESS))
		end
		return "executed"
	end,
	run = function(cmd, env_script, env, args, cwd, runner, callback)
		utility_calls.run[#utility_calls.run + 1] = {
			cmd = cmd,
			env_script = env_script,
			env = env,
			args = args,
			cwd = cwd,
			runner = runner,
		}
		if callback then
			callback(Result:new(Types.SUCCESS))
		end
		return "ran"
	end,
}
package.loaded["cmake-tools.utils"] = cmake_utils
package.loaded["cmake-tools.result"] = Result
package.loaded["cmake-tools.types"] = Types

local profile = "full"
package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		assert(name == "clangd_compile_db")
		assert(defaults.path == "clangd" and defaults.profile == "full")
		assert(defaults.restart_timeout_ms == 5000 and defaults.max_validation_bytes == 256 * 1024 * 1024)
		return vim.tbl_extend(
			"force",
			vim.deepcopy(defaults),
			{ path = "/verified/bin/clangd-custom", profile = profile }
		)
	end,
}

local lsp_runtime = require("config.lsp_runtime")
local original_lsp_resolve = lsp_runtime._resolve
lsp_runtime._resolve = function(tool, command)
	assert(tool == "clangd" and command == "clangd")
	return "/verified/bin/clangd-custom"
end

local buf_one = vim.api.nvim_create_buf(false, true)
local buf_two = vim.api.nvim_create_buf(false, true)
local buf_three = vim.api.nvim_create_buf(false, true)
local stopped = {}
local started = {}
local attached = {}
local owned_clients = {}
local initialization_queries = {}
local clients = {
	{
		initialized = false,
		config = { root_dir = fixture .. "/one" },
		attached_buffers = { [buf_one] = true },
		stop = function(self)
			self.stopped = true
			stopped[#stopped + 1] = self
		end,
		is_stopped = function(self)
			return self.stopped == true
		end,
	},
	{
		initialized = false,
		config = { root_dir = fixture .. "/two" },
		attached_buffers = { [buf_two] = true },
		stop = function(self)
			self.stopped = true
			stopped[#stopped + 1] = self
		end,
		is_stopped = function(self)
			return self.stopped == true
		end,
	},
	{
		initialized = false,
		config = { root_dir = fixture .. "/three" },
		attached_buffers = { [buf_three] = true },
		stop = function(self)
			self.stopped = true
			stopped[#stopped + 1] = self
		end,
		is_stopped = function(self)
			return self.stopped == true
		end,
	},
}
vim.lsp.get_clients = function(filter)
	assert(filter.name == "clangd")
	if filter.bufnr == nil then
		assert(filter._uninitialized == true, "clangd lifecycle omitted uninitialized clients")
	end
	return clients
end
vim.lsp.config = { clangd = { name = "clangd" } }
vim.lsp.start = function(config, options)
	started[#started + 1] = { config = config, options = options }
	owned_clients[41] = {
		config = { root_dir = config.root_dir },
		initialized = true,
		is_stopped = function(self)
			return self.stopped == true
		end,
		stop = function(self)
			self.stopped = true
		end,
	}
	return 41
end
vim.lsp.buf_attach_client = function(bufnr, client_id)
	attached[#attached + 1] = { bufnr = bufnr, client_id = client_id }
	return true
end
vim.lsp.get_client_by_id = function(client_id)
	initialization_queries[#initialization_queries + 1] = client_id
	return owned_clients[client_id]
end
vim.defer_fn = function(callback)
	callback()
end

local clangd = require("config.clangd")
local cmake_config = require("config.cmake")

local function launch_argv(config)
	local observed
	vim.lsp.rpc.start = function(argv)
		observed = vim.deepcopy(argv)
		return { rpc = true }
	end
	local rpc = config.cmd({}, config)
	assert(rpc and rpc.rpc and observed, "clangd runtime command did not reach the RPC boundary")
	return observed
end

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

test("CMake build directory restarts only clangd clients for the same root", function()
	assert(clangd.set_cmake(fixture .. "/one", fixture .. "/one/build"))
	assert(#stopped == 1 and stopped[1] == clients[1])
	assert(#started == 1 and started[1].options.attach == false)
	assert(vim.deep_equal(attached, { { bufnr = buf_one, client_id = 41 } }))
	assert(vim.deep_equal(initialization_queries, { 41 }), "applied state skipped the initialization handshake")
	assert(vim.tbl_contains(launch_argv(started[1].config), "--compile-commands-dir=" .. fixture .. "/one/build"))
	local state = clangd.status(fixture .. "/one")
	assert(state.state == "active" and state.validity == "structural" and state.source == "cmake")
	assert(state.desired.directory == fixture .. "/one/build" and state.applied.directory == fixture .. "/one/build")
	assert(state.desired.revision == state.applied.revision)
	assert(clangd.status(fixture .. "/two").directory == nil)
	assert(
		vim.fn.filereadable(fixture .. "/one/compile_commands.json") == 0,
		"integration copied/symlinked the database"
	)
end)

test("host reconciliation absorbs a client autoactivated during restart", function()
	stopped = {}
	started = {}
	attached = {}
	local first_buf = vim.api.nvim_create_buf(false, true)
	local late_buf = vim.api.nvim_create_buf(false, true)
	local old = {
		initialized = false,
		config = { root_dir = fixture .. "/auto" },
		attached_buffers = { [first_buf] = true },
		stop = function(self)
			self.stopped = true
			stopped[#stopped + 1] = self
		end,
		is_stopped = function(self)
			return self.stopped == true
		end,
	}
	clients[#clients + 1] = old
	local late = {
		initialized = false,
		config = { root_dir = fixture .. "/auto" },
		attached_buffers = { [late_buf] = true },
		stop = old.stop,
		is_stopped = old.is_stopped,
	}
	local calls = 0
	vim.lsp.get_clients = function(filter)
		assert(filter.name == "clangd")
		assert(filter._uninitialized == true, "reconciliation omitted uninitialized clients")
		calls = calls + 1
		if calls == 3 then
			clients[#clients + 1] = late
		end
		return clients
	end

	assert(clangd.set_cmake(fixture .. "/auto", fixture .. "/auto/build"))
	assert(#started == 1, "autoactivation produced a competing replacement")
	assert(stopped[1] == old and stopped[2] == late, "late autoactivated client escaped reconciliation")
	assert(vim.deep_equal(attached, {
		{ bufnr = first_buf, client_id = 41 },
		{ bufnr = late_buf, client_id = 41 },
	}))
	local state = clangd.status(fixture .. "/auto")
	assert(state.desired.revision == state.applied.revision and state.applied.directory == fixture .. "/auto/build")

	vim.lsp.get_clients = function(filter)
		assert(filter.name == "clangd")
		if filter.bufnr == nil then
			assert(filter._uninitialized == true, "clangd lifecycle omitted uninitialized clients")
		end
		return clients
	end
end)

test("manual compile database override wins without touching other roots", function()
	stopped = {}
	started = {}
	attached = {}
	assert(clangd.set_manual(fixture .. "/one", fixture .. "/one/manual"))
	local state = clangd.status(fixture .. "/one")
	assert(state.state == "active" and state.source == "manual" and state.directory == fixture .. "/one/manual")
	assert(vim.tbl_contains(clangd.command(fixture .. "/one"), "--compile-commands-dir=" .. fixture .. "/one/manual"))
	assert(#stopped == 1 and stopped[1] == clients[1] and #started == 1)
end)

test("clearing the only manual database restarts clangd without a compile directory flag", function()
	stopped = {}
	started = {}
	attached = {}
	assert(clangd.set_manual(fixture .. "/three", fixture .. "/three/manual"))
	stopped = {}
	started = {}
	attached = {}
	assert(clangd.clear_manual(fixture .. "/three"))
	local state = clangd.status(fixture .. "/three")
	assert(state.state == "candidate" and state.directory == nil and state.source == nil)
	assert(#stopped == 1 and stopped[1] == clients[3])
	assert(#started == 1 and started[1].options.attach == false)
	assert(vim.deep_equal(attached, { { bufnr = buf_three, client_id = 41 } }))
	assert(not vim.iter(launch_argv(started[1].config)):any(function(arg)
		return arg:find("^%-%-compile%-commands%-dir=") ~= nil
	end))
end)

test("full profile and configured executable have an explicit flag surface", function()
	local full = clangd.command(fixture .. "/one")
	assert(full[1] == "/verified/bin/clangd-custom")
	assert(vim.tbl_contains(full, "--background-index") and vim.tbl_contains(full, "--clang-tidy"))
	assert(clangd.status(fixture .. "/one").profile == "full")
end)

test("cmake-tools successful generate feeds its actual root, preset, and build directory", function()
	local callback_result
	local fake = {
		get_config = function()
			return { cwd = fixture .. "/two" }
		end,
		get_build_directory = function()
			return fixture .. "/two/build"
		end,
		get_configure_preset = function()
			return "host-debug"
		end,
		generate = function(_, callback)
			local result = {
				is_ok = function()
					return true
				end,
			}
			callback(result)
			return "generated"
		end,
	}
	cmake_config.setup(fake)
	assert(fake.generate({}, function(result)
		callback_result = result
	end) == "generated")
	assert(callback_result and callback_result:is_ok())
	local state = cmake_config.status(fixture .. "/two")
	assert(state and state.build_dir == fixture .. "/two/build" and state.preset == "host-debug" and state.valid)
	state.valid = false
	assert(cmake_config.status(fixture .. "/two").valid, "CMake status exposed mutable internal state")
	assert(clangd.status(fixture .. "/two").source == "cmake")
end)

test("CMake publishes invalid state when generated metadata is unusable", function()
	local fake = {
		get_config = function()
			return { cwd = fixture .. "/two" }
		end,
		get_build_directory = function()
			error("build lookup exploded")
		end,
	}
	local ok, err = cmake_config.sync(fake)
	assert(not ok and err:find("build lookup exploded", 1, true), "CMake metadata failure was hidden")
	local state = cmake_config.status(fixture .. "/two")
	assert(state and state.valid == false and state.error:find("build lookup exploded", 1, true))
	state.error = "mutated"
	assert(cmake_config.status(fixture .. "/two").error ~= "mutated", "invalid CMake status was not copied")
end)

test("nested generate operations synchronize once and always deliver callbacks", function()
	local original_sync = cmake_config.sync
	local original_notify = vim.notify
	local notifications = {}
	local sync_calls = 0
	local callback_calls = 0
	local result = {
		is_ok = function()
			return true
		end,
	}
	local fake = {}
	fake.generate = function(options, callback)
		if options.outer then
			return fake.generate({ inner = true }, callback)
		end
		callback(result)
		callback(result)
		return "generated-recursively"
	end
	vim.notify = function(message, level)
		notifications[#notifications + 1] = { message = tostring(message), level = level }
	end
	local ok, err = xpcall(function()
		cmake_config.sync = function()
			sync_calls = sync_calls + 1
			return true
		end
		cmake_config.setup(fake)
		assert(fake.generate({ outer = true }, function(observed)
			callback_calls = callback_calls + 1
			assert(observed == result)
		end) == "generated-recursively")
		assert(sync_calls == 1, "a recursive generate operation synchronized more than once")
		assert(callback_calls == 1, "recursive generate did not deliver its callback exactly once")

		cmake_config.sync = function()
			error("sync exploded")
		end
		callback_calls = 0
		fake.generate({ inner = true }, function(observed)
			callback_calls = callback_calls + 1
			assert(observed == result)
		end)
		assert(callback_calls == 1, "a synchronization exception suppressed the generate callback")
		assert(
			notifications[#notifications].level == vim.log.levels.WARN
				and notifications[#notifications].message:find("sync exploded", 1, true),
			"a synchronization exception was not reported"
		)
	end, debug.traceback)
	cmake_config.sync = original_sync
	vim.notify = original_notify
	assert(ok, err)
end)

test(":CMakeGenerate resolves the current wrapped function at invocation time", function()
	local fake = {
		generate = function(_, callback)
			callback({
				is_ok = function()
					return false
				end,
			})
		end,
	}
	cmake_config.setup(fake)
	local called
	fake.generate = function(options)
		called = vim.deepcopy(options)
	end
	vim.cmd("CMakeGenerate! --fresh=value")
	assert(called and called.bang and vim.deep_equal(called.fargs, { "--fresh=value" }))
end)

test("CMake central utilities enforce build and test grants exactly once", function()
	local fake = {
		generate = function() end,
		get_config = function()
			return { cwd = fixture .. "/two" }
		end,
	}
	cmake_config.setup(fake)
	local wrapped_execute = cmake_utils.execute
	local wrapped_run = cmake_utils.run
	cmake_config.setup(fake)
	assert(cmake_utils.execute == wrapped_execute and cmake_utils.run == wrapped_run, "CMake gates wrapped twice")

	cmake_gate_mode = "allow"
	cmake_grants = {}
	utility_calls.execute = {}
	utility_calls.run = {}
	local env = { "A=B" }
	local args = { "--build", "." }
	local executor = { name = "quickfix" }
	local callback_calls = 0
	assert(cmake_utils.execute("cmake", "", env, args, fixture .. "/one", executor, function(result)
		callback_calls = callback_calls + 1
		assert(result:is_ok())
	end) == "executed")
	assert(callback_calls == 1 and #utility_calls.execute == 1)
	assert(cmake_grants[1].capability == "build" and cmake_grants[1].options.root == fixture .. "/one")
	assert(utility_calls.execute[1].env == env and utility_calls.execute[1].args == args)
	assert(vim.deep_equal(args, { "--build", "." }), "CMake gate mutated process arguments")

	assert(cmake_utils.run("/usr/bin/ctest", "", env, {}, fixture .. "/one", { name = "terminal" }) == "ran")
	assert(
		cmake_grants[#cmake_grants].capability == "test"
			and cmake_grants[#cmake_grants].options.root == fixture .. "/one"
	)
	assert(cmake_utils.run(fixture .. "/one/build/app", "", env, {}, fixture .. "/one", { name = "terminal" }) == "ran")
	assert(cmake_grants[#cmake_grants].capability == "build")

	cmake_gate_mode = "deny"
	callback_calls = 0
	local before_execute = #utility_calls.execute
	cmake_utils.execute("cmake", "", env, args, fixture .. "/one", executor, function(result)
		callback_calls = callback_calls + 1
		assert(not result:is_ok() and result.code == Types.CMAKE_RUN_FAILED)
	end)
	assert(#utility_calls.execute == before_execute, "denied CMake build reached the executor")
	assert(callback_calls == 1, "denied CMake build completed its callback more than once")
	assert(
		cmake_notifications[#cmake_notifications].message:find("grant denied", 1, true),
		"CMake denial was not reported"
	)
	cmake_gate_mode = "allow"
	callback_calls = 0
	local before_run = #utility_calls.run
	local before_grants = #cmake_grants
	cmake_utils.run("ctest", "", env, {}, nil, { name = "terminal" }, function(result)
		callback_calls = callback_calls + 1
		assert(not result:is_ok() and result.code == Types.CMAKE_RUN_FAILED)
	end)
	assert(#utility_calls.run == before_run, "CMake run without an exact cwd reached the runner")
	assert(#cmake_grants == before_grants, "CMake inferred authority without an exact cwd")
	assert(callback_calls == 1, "invalid CMake cwd completed its callback more than once")
	assert(cmake_notifications[#cmake_notifications].message:find("cwd is unavailable", 1, true))
	cmake_gate_mode = "allow"
end)

test("source/header switch uses clangd and shared tab navigation", function()
	local opened
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path)
			opened = path
		end,
	}
	clients = {
		{
			request = function(_, method, _, callback)
				assert(method == "textDocument/switchSourceHeader")
				callback(nil, vim.uri_from_fname(fixture .. "/one/header.hpp"))
			end,
		},
	}
	vim.fn.writefile({ "#pragma once" }, fixture .. "/one/header.hpp")
	require("config.clangd_commands").switch_source_header()
	assert(vim.api.nvim_get_commands({}).ClangdSetCompileCommands.bang == true)
	for _, name in ipairs({
		"ClangdCompileCommandsStatus",
		"ClangdRefreshCompileCommands",
		"ClangdClearCompileCommands",
	}) do
		assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
	end
	vim.wait(100, function()
		return opened ~= nil
	end)
	assert(opened == fixture .. "/one/header.hpp")
end)

package.loaded["config.local_config"] = original_local
package.loaded["config.editor"] = original_editor
package.loaded["config.workflow_execution"] = original_workflow
package.loaded["cmake-tools.utils"] = original_cmake_utils
package.loaded["cmake-tools.result"] = original_cmake_result
package.loaded["cmake-tools.types"] = original_cmake_types
vim.lsp.get_clients = original_clients
vim.lsp.start = original_start
vim.lsp.buf_attach_client = original_attach
vim.lsp.get_client_by_id = original_get_client
vim.lsp.config = original_config
vim.lsp.rpc.start = original_rpc_start
lsp_runtime._resolve = original_lsp_resolve
vim.defer_fn = original_defer
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("clangd_cmake_spec: %d tests passed", count))
vim.cmd("quitall!")
