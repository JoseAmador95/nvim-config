-- Explicit, bounded rendering of the review model's frozen snapshots.
local deferred = require("config.deferred")

local M = {}
local uv = vim.uv
local TIMEOUT_MS = 5000
local MAX_OUTPUT_BYTES = 8 * 1024 * 1024

-- Narrow seams keep subprocess and temporary-directory failures testable.
M._system = vim.system
M._new_timer = uv.new_timer
M._mkdtemp = function()
	return uv.fs_mkdtemp(vim.fs.joinpath(uv.os_tmpdir(), "nvim-review-difft-XXXXXX"))
end
M._resolve = function()
	return deferred.load("config.tool_bootstrap").resolve("difftastic", "difft")
end

local function valid_path(path)
	return type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
end

local function valid_mode(mode)
	return type(mode) == "string" and mode:match("^[0-7][0-7][0-7][0-7][0-7][0-7]$") ~= nil
end

local function valid_oid(oid)
	return type(oid) == "string" and #oid <= 64 and oid:match("^[0-9a-f]+$") ~= nil
end

local function validate(request)
	if type(request) ~= "table" or type(request.entry) ~= "table" then
		return nil, "Difftastic requires a frozen review entry"
	end
	local entry = request.entry
	if type(entry.old_text) ~= "string" or type(entry.new_text) ~= "string" then
		return nil, "Difftastic requires both frozen snapshot texts"
	end
	if
		type(request.width) ~= "number"
		or request.width < 1
		or request.width >= math.huge
		or request.width ~= math.floor(request.width)
	then
		return nil, "Difftastic requires a positive integer width"
	end
	if request.background ~= "dark" and request.background ~= "light" then
		return nil, "Difftastic requires a dark or light background"
	end
	local old_path = entry.old_path or entry.path or entry.new_path
	local new_path = entry.new_path or entry.path or entry.old_path
	if not valid_path(old_path) or not valid_path(new_path) then
		return nil, "Difftastic requires valid frozen logical paths"
	end
	local old_mode = entry.old_mode or "100644"
	local new_mode = entry.new_mode or "100644"
	local old_oid = entry.old_oid or "0000000"
	local new_oid = entry.new_oid or "0000000"
	if not valid_mode(old_mode) or not valid_mode(new_mode) or not valid_oid(old_oid) or not valid_oid(new_oid) then
		return nil, "Difftastic requires valid frozen modes and object identifiers"
	end
	return {
		old_path = old_path,
		new_path = new_path,
		old_mode = old_mode,
		new_mode = new_mode,
		old_oid = old_oid,
		new_oid = new_oid,
	}
end

local function write_snapshot(path, text, owned)
	local fd, open_err = uv.fs_open(path, "wx", 384) -- Exclusive 0600 file.
	if not fd then
		return nil, tostring(open_err)
	end
	owned[#owned + 1] = path
	local private, private_err = uv.fs_fchmod(fd, 384)
	if not private then
		pcall(uv.fs_close, fd)
		return nil, tostring(private_err)
	end
	local offset = 0
	while offset < #text do
		local written, write_err = uv.fs_write(fd, text:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, fd)
			return nil, tostring(write_err or "zero-byte write")
		end
		offset = offset + written
	end
	local closed, close_err = uv.fs_close(fd)
	if not closed then
		return nil, tostring(close_err)
	end
	return true
end

local function argv(executable, request, metadata, directory, analysis)
	local command = {
		executable,
		analysis and "--display=json" or "--display=side-by-side-show-both",
		analysis and "--color=never" or "--color=always",
		"--background=" .. request.background,
		"--width=" .. tostring(request.width),
		"--strip-cr=off",
		"--",
		metadata.old_path,
		directory .. "/old",
		metadata.old_oid,
		metadata.old_mode,
		directory .. "/new",
		metadata.new_oid,
		metadata.new_mode,
	}
	if metadata.old_path ~= metadata.new_path then
		command[#command + 1] = metadata.new_path
		command[#command + 1] = ""
	end
	return command
end

local function detail(message)
	return tostring(message or ""):sub(1, 2048):gsub("%s+$", "")
end

-- The cancellation handle also suppresses completion already queued for the UI.
local function execute(request, callback, analysis)
	local state = { files = {}, stdout = {}, stderr = {}, bytes = 0 }
	local function cleanup()
		if state.timer then
			pcall(state.timer.stop, state.timer)
			pcall(state.timer.close, state.timer)
			state.timer = nil
		end
		for _, path in ipairs(state.files) do
			pcall(uv.fs_unlink, path)
		end
		state.files = {}
		if state.directory then
			pcall(uv.fs_rmdir, state.directory)
			state.directory = nil
		end
	end
	local function terminate()
		state.kill_pending = true
		if state.process and not state.process_done then
			pcall(state.process.kill, state.process, 9)
		end
	end
	local function finish(output, err)
		if state.finished or state.cancelled then
			return
		end
		state.finished = true
		state.stdout = {}
		state.stderr = {}
		cleanup()
		vim.schedule(function()
			if not state.cancelled then
				callback(output, err)
			end
		end)
	end
	local function abort(message)
		if state.finished or state.cancelled then
			return
		end
		terminate()
		finish(nil, message)
	end
	local function cancel()
		if state.cancelled then
			return
		end
		state.cancelled = true
		if not state.finished then
			terminate()
		end
		state.stdout = {}
		state.stderr = {}
		cleanup()
	end
	local metadata, request_err = validate(request)
	if not metadata then
		finish(nil, request_err)
		return cancel
	end
	local resolved, executable, resolve_err = pcall(M._resolve)
	if not resolved or not valid_path(executable) then
		finish(
			nil,
			"Difftastic is unavailable; run :NvimConfigToolsInstall difftastic"
				.. ((resolve_err or not resolved) and (": " .. detail(resolved and resolve_err or executable)) or "")
		)
		return cancel
	end
	local made, directory, directory_err = pcall(M._mkdtemp)
	if not made or not directory then
		finish(nil, "Cannot create private Difftastic snapshots: " .. detail(made and directory_err or directory))
		return cancel
	end
	state.directory = directory
	local private, private_err = uv.fs_chmod(directory, 448) -- 0700 directory.
	if not private then
		finish(nil, "Cannot secure private Difftastic snapshots: " .. detail(private_err))
		return cancel
	end
	for _, side in ipairs({ "old", "new" }) do
		local written, write_err = write_snapshot(directory .. "/" .. side, request.entry[side .. "_text"], state.files)
		if not written then
			finish(nil, "Cannot write frozen Difftastic snapshot: " .. detail(write_err))
			return cancel
		end
	end
	local function capture(stream)
		return function(err, data)
			if state.finished or state.cancelled then
				return
			end
			if err then
				abort("Cannot read Difftastic " .. stream .. ": " .. detail(err))
			elseif data and data ~= "" then
				if #data > MAX_OUTPUT_BYTES - state.bytes then
					abort("Difftastic output exceeded the 8 MiB limit")
				else
					state.bytes = state.bytes + #data
					state[stream][#state[stream] + 1] = data
				end
			end
		end
	end
	local environment = {
		PATH = vim.fs.dirname(executable) .. ":/usr/bin:/bin",
		LANG = "C",
		LC_ALL = "C",
		TERM = "xterm-256color",
	}
	if analysis then
		environment.DFT_UNSTABLE = "yes"
	end
	local spawned, process = pcall(M._system, argv(executable, request, metadata, directory, analysis), {
		cwd = directory,
		clear_env = true,
		env = environment,
		text = false,
		timeout = TIMEOUT_MS,
		stdout = capture("stdout"),
		stderr = capture("stderr"),
	}, function(result)
		state.process_done = true
		if state.finished or state.cancelled then
			return
		end
		if result.code == 124 then
			finish(nil, "Difftastic timed out after 5000 ms")
		elseif result.code ~= 0 or result.signal ~= 0 then
			local stderr = detail(table.concat(state.stderr))
			finish(
				nil,
				("Difftastic failed (exit %s, signal %s)%s"):format(
					tostring(result.code),
					tostring(result.signal),
					stderr ~= "" and (": " .. stderr) or ""
				)
			)
		else
			finish(table.concat(state.stdout), nil)
		end
	end)
	if not spawned then
		finish(nil, "Cannot start Difftastic: " .. detail(process))
		return cancel
	end
	state.process = process
	if state.kill_pending and not state.process_done then
		terminate()
	end
	if not state.finished and not state.cancelled then
		local timer_ok, timer = pcall(M._new_timer)
		if not timer_ok or not timer then
			abort("Cannot create Difftastic timeout timer: " .. detail(timer))
			return cancel
		end
		state.timer = timer
		local started, start_result, start_err = pcall(timer.start, timer, TIMEOUT_MS, 0, function()
			abort("Difftastic timed out after 5000 ms")
		end)
		if not started or not start_result then
			abort("Cannot start Difftastic timeout timer: " .. detail(started and start_err or start_result))
		end
	end
	return cancel
end

-- Keep the human ANSI rendering separate from machine analysis.
function M.run(request, callback)
	return execute(request, callback, false)
end

---Analyze exact snapshots with the pinned unstable JSON contract.
---@param request table
---@param callback fun(output: string?, err: string?)
---@return function cancel
function M.analyze(request, callback)
	if type(request) == "table" then
		request = vim.tbl_extend("keep", request, { width = 80, background = "dark" })
	end
	return execute(request, callback, true)
end

return M
