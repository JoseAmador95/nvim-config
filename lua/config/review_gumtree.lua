-- Explicit execution of the managed GumTree/JRE bundle on private frozen ASTs.
local deferred = require("config.deferred")

local M = {}
local uv = vim.uv
local TIMEOUT_MS = 5000
local MAX_OUTPUT_BYTES = 8 * 1024 * 1024
local MAX_TREE_BYTES = 16 * 1024 * 1024
local active = {}
local shutdown_installed = false

M._system = vim.system
M._new_timer = uv.new_timer
M._mkdtemp = function()
	-- GumTree splits its fixed external generator command on spaces, without a
	-- shell. Its Java-created $FILE therefore needs a whitespace-free directory.
	return uv.fs_mkdtemp("/tmp/nvim-review-gumtree-XXXXXX")
end
M._resolve = function()
	return deferred.load("config.tool_bootstrap").resolve("gumtree", "gumtree")
end
M._kill_group = function(pid)
	return uv.kill(-pid, 9)
end

local function detail(message)
	return tostring(message or ""):sub(1, 2048):gsub("%s+$", "")
end

local function valid_path(path)
	return type(path) == "string" and path:sub(1, 1) == "/" and not path:find("[%z\1-\31\127]")
end

local function validate(request)
	if type(request) ~= "table" or type(request.entry) ~= "table" or type(request.trees) ~= "table" then
		return nil, "GumTree requires a frozen entry and exported syntax trees"
	end
	local bytes = 0
	for _, side in ipairs({ "old", "new" }) do
		if
			type(request.entry[side .. "_text"]) ~= "string"
			or type(request.trees[side]) ~= "string"
			or request.trees[side] == ""
		then
			return nil, "GumTree requires both frozen sources and exported XML strings"
		end
		bytes = bytes + #request.trees[side]
	end
	if #request.entry.old_text + #request.entry.new_text > 1024 * 1024 or bytes > MAX_TREE_BYTES then
		return nil, "GumTree frozen sources or exported trees exceed the input limits"
	end
	return true
end

local function write_private(path, text)
	local fd, err = uv.fs_open(path, "wx", 384)
	if not fd then
		return nil, err
	end
	local secured, secure_err = uv.fs_fchmod(fd, 384)
	if not secured then
		pcall(uv.fs_close, fd)
		return nil, secure_err
	end
	local offset = 0
	while offset < #text do
		local written, write_err = uv.fs_write(fd, text:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, fd)
			return nil, write_err or "zero-byte write"
		end
		offset = offset + written
	end
	return uv.fs_close(fd)
end

local function remove_owned(path)
	local stat, stat_err, code = uv.fs_lstat(path)
	if not stat then
		return code == "ENOENT", stat_err
	end
	if stat.type ~= "directory" then
		return uv.fs_unlink(path) -- Includes symlinks: never traverse their targets.
	end
	local scan, scan_err = uv.fs_scandir(path)
	if not scan then
		return nil, scan_err
	end
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		local removed, remove_err = remove_owned(path .. "/" .. name)
		if not removed then
			return nil, remove_err
		end
	end
	return uv.fs_rmdir(path)
end

local function install_shutdown()
	if shutdown_installed then
		return
	end
	shutdown_installed = true
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("NvimReviewGumTreeProcesses", { clear = true }),
		callback = function()
			for _, shutdown in pairs(active) do
				shutdown()
			end
		end,
	})
end

---Run the fixed XML generator under the verified JRE; never install or probe.
---@param request table
---@param callback fun(output: string?, err: string?)
---@return function cancel
function M.analyze(request, callback)
	local state = { stdout = {}, stderr = {}, bytes = 0 }
	local function close_timer()
		if state.timer then
			pcall(state.timer.stop, state.timer)
			pcall(state.timer.close, state.timer)
			state.timer = nil
		end
	end
	local function cleanup()
		close_timer()
		active[state] = nil
		if state.directory then
			local ok, removed, err = pcall(remove_owned, state.directory)
			if not ok or not removed then
				return "Cannot remove private GumTree temporary trees: " .. detail(ok and err or removed)
			end
			state.directory = nil
		end
	end
	local function kill_group()
		state.kill_pending = true
		if state.process and not state.group_killed then
			state.group_killed = true
			local pid = state.process.pid
			if type(pid) == "number" and pid > 0 and pid % 1 == 0 then
				pcall(M._kill_group, pid)
			end
			if not state.process_done then
				pcall(state.process.kill, state.process, 9)
			end
		end
	end
	local function finish(output, err)
		if state.finished then
			return
		end
		state.finished = true
		local cleanup_err = cleanup()
		state.stdout, state.stderr = {}, {}
		if cleanup_err then
			output, err = nil, cleanup_err
		end
		vim.schedule(function()
			if not state.cancelled then
				callback(output, err)
			end
		end)
	end
	local function abort(message)
		if state.finished or state.cancelled or state.failure then
			return
		end
		state.failure = message
		close_timer()
		kill_group()
		-- Wait for process exit before removing Java's temporary directory, so
		-- a still-running JVM cannot recreate artifacts after cleanup.
		if not state.spawning and (not state.process or state.process_done) then
			finish(nil, message)
		end
	end
	local function cancel()
		if state.cancelled then
			return
		end
		state.cancelled = true
		close_timer()
		if not state.finished then
			kill_group()
			if not state.spawning and (not state.process or state.process_done) then
				finish(nil, "GumTree cancelled")
			end
		end
	end
	local valid, request_err = validate(request)
	if not valid then
		finish(nil, request_err)
		return cancel
	end
	local resolved, executable, resolve_err = pcall(M._resolve)
	if not resolved or not valid_path(executable) then
		finish(
			nil,
			"GumTree is unavailable; run :NvimConfigToolsInstall gumtree"
				.. ((resolve_err or not resolved) and (": " .. detail(resolved and resolve_err or executable)) or "")
		)
		return cancel
	end
	local made, directory, make_err = pcall(M._mkdtemp)
	if not made or not directory then
		finish(nil, "Cannot create private GumTree trees: " .. detail(made and make_err or directory))
		return cancel
	end
	state.directory = directory
	if not valid_path(directory) or directory:find("%s") then
		finish(nil, "GumTree requires a whitespace-free private temporary directory")
		return cancel
	end
	local secured, secure_err = uv.fs_chmod(directory, 448)
	if not secured then
		finish(nil, "Cannot secure private GumTree trees: " .. detail(secure_err))
		return cancel
	end
	local java_dir = directory .. "/java"
	local made_java, java_err = uv.fs_mkdir(java_dir, 448)
	if not made_java then
		finish(nil, "Cannot create private GumTree Java directory: " .. detail(java_err))
		return cancel
	end
	for _, side in ipairs({ "old", "new" }) do
		local written, write_err = write_private(directory .. "/" .. side .. ".xml", request.trees[side])
		if not written then
			finish(nil, "Cannot write frozen GumTree tree: " .. detail(write_err))
			return cancel
		end
	end
	install_shutdown()
	active[state] = function()
		cancel()
		-- VimLeavePre cannot wait for scheduled process callbacks.
		if state.process and not state.process_done then
			pcall(state.process.wait, state.process, 1000)
		end
		if not state.process or state.process_done then
			cleanup()
		end
	end
	local function capture(stream)
		return function(err, data)
			if state.finished or state.cancelled or state.failure then
				return
			end
			if err then
				abort("Cannot read GumTree " .. stream .. ": " .. detail(err))
			elseif data and data ~= "" then
				if #data > MAX_OUTPUT_BYTES - state.bytes then
					abort("GumTree output exceeded the 8 MiB limit")
				else
					state.bytes = state.bytes + #data
					state[stream][#state[stream] + 1] = data
				end
			end
		end
	end
	state.spawning = true
	local spawned, process = pcall(M._system, {
		executable,
		"textdiff",
		"-m",
		"gumtree-simple",
		"-f",
		"JSON",
		"-x",
		"/bin/cat $FILE",
		directory .. "/old.xml",
		directory .. "/new.xml",
	}, {
		cwd = directory,
		clear_env = true,
		env = {
			PATH = "/usr/bin:/bin",
			LANG = "C.UTF-8",
			LC_ALL = "C.UTF-8",
			GUMTREE_JAVA_TMPDIR = java_dir,
			TMPDIR = java_dir,
			HOME = directory,
		},
		text = false,
		detach = true,
		timeout = TIMEOUT_MS,
		stdout = capture("stdout"),
		stderr = capture("stderr"),
	}, function(result)
		if state.process_done then
			return
		end
		state.process_done = true
		kill_group() -- Also retire any child generator left after the leader exits.
		if state.failure or state.cancelled then
			finish(nil, state.failure or "GumTree cancelled")
		elseif type(result) ~= "table" or type(result.code) ~= "number" or type(result.signal) ~= "number" then
			finish(nil, "Invalid GumTree process completion")
		elseif result.code == 124 then
			finish(nil, "GumTree timed out after 5000 ms")
		elseif result.code ~= 0 or result.signal ~= 0 then
			local stderr = detail(table.concat(state.stderr))
			finish(
				nil,
				("GumTree failed (exit %s, signal %s)%s"):format(
					tostring(result.code),
					tostring(result.signal),
					stderr ~= "" and (": " .. stderr) or ""
				)
			)
		else
			finish(table.concat(state.stdout), nil)
		end
	end)
	state.spawning = false
	if not spawned then
		finish(nil, "Cannot start GumTree: " .. detail(process))
		return cancel
	end
	state.process = process
	if state.kill_pending then
		kill_group()
	end
	if not state.finished and not state.cancelled and not state.failure then
		local timer_ok, timer = pcall(M._new_timer)
		if not timer_ok or not timer then
			abort("Cannot create GumTree timeout timer: " .. detail(timer))
			return cancel
		end
		state.timer = timer
		local started, start_result, start_err = pcall(timer.start, timer, TIMEOUT_MS, 0, function()
			abort("GumTree timed out after 5000 ms")
		end)
		if not started or not start_result then
			abort("Cannot start GumTree timeout timer: " .. detail(started and start_err or start_result))
		end
	end
	return cancel
end

return M
