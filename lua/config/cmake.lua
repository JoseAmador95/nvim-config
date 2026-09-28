local M = {}

local clangd = require("config.clangd")
local workflow = require("config.workflow_execution")
local Result = require("cmake-tools.result")
local Types = require("cmake-tools.types")
local cmake_utils = require("cmake-tools.utils")
local states = {}
local callback_operations = setmetatable({}, { __mode = "k" })
local EXECUTION_MARKER = "_nvim_config_execution_wrapped_v1"

local function pack(...)
	return { n = select("#", ...), ... }
end

local function canonical(path)
	if type(path) ~= "string" or path == "" or path:find("%z") then
		return nil
	end
	local absolute = vim.fn.fnamemodify(path, ":p")
	return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

local function emit_changed()
	vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
end

local function publish(root, state)
	states[root] = state
	emit_changed()
end

local function call(method, label)
	if type(method) ~= "function" then
		return nil, label .. " is unavailable"
	end
	local ok, value = xpcall(method, debug.traceback)
	if not ok then
		return nil, label .. " failed: " .. tostring(value)
	end
	return value
end

local function invalid_state(root, build, preset, err)
	publish(root, {
		build_dir = build,
		preset = preset,
		valid = false,
		error = tostring(err),
	})
	return false, tostring(err)
end

function M.sync(cmake)
	if type(cmake) ~= "table" then
		return false, "CMake adapter is unavailable"
	end
	local config, config_err = call(cmake.get_config, "CMake configuration")
	if type(config) ~= "table" then
		return false, config_err or "CMake configuration is unavailable"
	end
	local root = canonical(config.cwd)
	if not root then
		return false, "CMake root is unavailable"
	end

	local raw_build, build_err = call(cmake.get_build_directory, "CMake build directory")
	local build = canonical(raw_build)
	if not build then
		return invalid_state(root, nil, nil, build_err or "CMake build directory is unavailable")
	end

	local preset
	if cmake.get_configure_preset ~= nil then
		local preset_err
		preset, preset_err = call(cmake.get_configure_preset, "CMake configure preset")
		if preset_err then
			return invalid_state(root, build, nil, preset_err)
		end
	end

	local invoked, synced, sync_err = xpcall(function()
		return clangd.set_cmake(root, build)
	end, debug.traceback)
	if not invoked then
		sync_err = synced
		synced = false
	end
	local valid = synced == true
	local err = valid and nil or tostring(sync_err or "clangd rejected the CMake build directory")
	publish(root, {
		build_dir = build,
		preset = preset,
		valid = valid,
		error = err,
	})
	return valid, err
end

local function successful(result)
	if type(result) ~= "table" or type(result.is_ok) ~= "function" then
		return false
	end
	local ok, value = pcall(result.is_ok, result)
	return ok and value == true
end

local function synchronize_once(cmake, operation)
	if operation.synced then
		return nil
	end
	operation.synced = true
	local invoked, synced, err = xpcall(function()
		return M.sync(cmake)
	end, debug.traceback)
	if not invoked then
		return tostring(synced)
	end
	if synced then
		return nil
	end
	return tostring(err or "CMake synchronization failed")
end

local function install_generate_wrapper(cmake)
	if cmake._nvim_config_generate_wrapped then
		return
	end
	cmake._nvim_config_generate_wrapped = true
	local generate = cmake.generate
	cmake.generate = function(options, callback)
		local operation = type(callback) == "function" and callback_operations[callback] or nil
		if not operation then
			operation = { depth = 0, synced = false }
		end
		operation.depth = operation.depth + 1

		local completed = false
		local wrapped_callback
		wrapped_callback = function(result)
			if completed then
				return
			end
			completed = true
			local sync_problem = successful(result) and synchronize_once(cmake, operation) or nil
			callback_operations[wrapped_callback] = nil
			operation.depth = operation.depth - 1
			if sync_problem then
				pcall(
					vim.notify,
					"CMake generated, but clangd synchronization failed: " .. sync_problem,
					vim.log.levels.WARN,
					{ title = "CMake" }
				)
			end
			if callback then
				return callback(result)
			end
		end
		callback_operations[wrapped_callback] = operation

		local returned = pack(xpcall(function()
			return generate(options, wrapped_callback)
		end, debug.traceback))
		if not returned[1] then
			if not completed then
				callback_operations[wrapped_callback] = nil
				operation.depth = operation.depth - 1
			end
			error(returned[2], 0)
		end
		return unpack(returned, 2, returned.n)
	end
end

local function install_generate_command(cmake)
	vim.api.nvim_create_user_command("CMakeGenerate", function(options)
		return cmake.generate(options)
	end, {
		nargs = "*",
		bang = true,
		desc = "CMake configure",
		force = true,
	})
end

local function execution_options(cwd)
	if type(cwd) ~= "string" or cwd == "" or cwd:find("\0", 1, true) then
		return nil, "execution cwd is unavailable"
	end
	return { root = cwd }
end

local function denied_result(message)
	return Result:new(Types.CMAKE_RUN_FAILED, nil, message)
end

local function reject_execution(callback, capability, err)
	local message = ("CMake %s execution denied: %s"):format(capability, tostring(err))
	workflow.notify("CMake", message, vim.log.levels.ERROR)
	if type(callback) == "function" then
		callback(denied_result(message))
	end
end

local function authorize_execution(callback, capability, cwd)
	local options, options_err = execution_options(cwd)
	if not options then
		reject_execution(callback, capability, options_err)
		return false
	end
	local granted, grant_err = workflow.grant(capability, options)
	if not granted then
		reject_execution(callback, capability, grant_err)
		return false
	end
	return true
end

local function install_execution_wrappers()
	local utils = cmake_utils
	if utils[EXECUTION_MARKER] then
		return
	end
	if type(utils.execute) ~= "function" or type(utils.run) ~= "function" then
		error("cmake-tools central execution APIs are unavailable", 0)
	end

	local execute = utils.execute
	utils.execute = function(cmd, env_script, env, args, cwd, executor, callback)
		if not authorize_execution(callback, "build", cwd) then
			return
		end
		return execute(cmd, env_script, env, args, cwd, executor, callback)
	end

	local run = utils.run
	utils.run = function(cmd, env_script, env, args, cwd, runner, callback)
		local normalized = type(cmd) == "string" and cmd:gsub("\\", "/") or ""
		local capability = normalized:match("([^/]+)$") == "ctest" and "test" or "build"
		if not authorize_execution(callback, capability, cwd) then
			return
		end
		return run(cmd, env_script, env, args, cwd, runner, callback)
	end

	utils[EXECUTION_MARKER] = true
end

function M.setup(cmake)
	install_execution_wrappers()
	install_generate_wrapper(cmake)
	install_generate_command(cmake)
end

function M.status(root)
	root = canonical(root)
	return root and states[root] and vim.deepcopy(states[root]) or nil
end

M._states = states

return M
