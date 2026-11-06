-- Run the pinned Lua engine outside the editor so expensive diffs are cancellable.
local M = {}
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
source = vim.fn.fnamemodify(source, ":p")
local worker = vim.fs.joinpath(vim.fs.dirname(source), "review_diffbandit_worker.lua")
local MAX_OUTPUT_BYTES = 8 * 1024 * 1024

M._system = vim.system
M._new_timer = vim.uv.new_timer
M._resolve = function()
	local root = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "diffbandit.nvim")
	if not vim.uv.fs_stat(root .. "/lua/diffbandit/diff/init.lua") then
		return nil, "Diffbandit is unavailable; run :Lazy install diffbandit.nvim"
	end
	return root
end

function M.analyze(request, callback)
	local state = { stdout = {}, stderr = {}, bytes = 0 }
	local function stop_timer()
		if state.timer then
			state.timer:stop()
			state.timer:close()
			state.timer = nil
		end
	end
	local function kill()
		state.kill_pending = true
		if state.process and not state.exited then
			pcall(state.process.kill, state.process, 9)
		end
	end
	local function finish(output, err)
		if state.done or state.cancelled then
			return
		end
		state.done = true
		stop_timer()
		state.stdout, state.stderr = {}, {}
		vim.schedule(function()
			if not state.cancelled then
				callback(output, err)
			end
		end)
	end
	local function cancel()
		if state.cancelled then
			return
		end
		state.cancelled = true
		stop_timer()
		if not state.done then
			kill()
		end
		state.stdout, state.stderr = {}, {}
	end
	local root, resolve_err = M._resolve()
	if not root then
		finish(nil, resolve_err)
		return cancel
	end
	local encoded, input =
		pcall(vim.json.encode, { old_text = request.entry.old_text, new_text = request.entry.new_text })
	if not encoded then
		finish(nil, "Cannot encode frozen Diffbandit sources: " .. tostring(input))
		return cancel
	end
	local timed, timer_err = pcall(function()
		state.timer = assert(M._new_timer())
		assert(state.timer:start(5000, 0, function()
			kill()
			finish(nil, "Diffbandit analysis exceeded 5 seconds")
		end) == 0)
	end)
	if not timed then
		finish(nil, "Cannot start Diffbandit deadline: " .. tostring(timer_err))
		return cancel
	end
	local function capture(stream)
		return function(err, data)
			if state.done or state.cancelled then
				return
			end
			if err or (data and #data > MAX_OUTPUT_BYTES - state.bytes) then
				kill()
				finish(
					nil,
					err and ("Cannot read Diffbandit " .. stream .. ": " .. err) or "Diffbandit output exceeded 8 MiB"
				)
			elseif data then
				state.bytes = state.bytes + #data
				state[stream][#state[stream] + 1] = data
			end
		end
	end
	local ok, process = pcall(M._system, {
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"-i",
		"NONE",
		"--noplugin",
		"-n",
		"-l",
		worker,
		root,
	}, {
		cwd = "/",
		clear_env = true,
		env = { HOME = vim.env.HOME, PATH = "/usr/bin:/bin", NVIM_LOG_FILE = "/dev/null" },
		stdin = input,
		stdout = capture("stdout"),
		stderr = capture("stderr"),
	}, function(result)
		state.exited = true
		if result.code == 0 then
			finish(table.concat(state.stdout))
		else
			finish(nil, "Diffbandit analysis failed: " .. table.concat(state.stderr):sub(1, 2048))
		end
	end)
	if not ok then
		finish(nil, "Cannot start Diffbandit: " .. tostring(process))
	else
		state.process = process
		if state.kill_pending then
			kill()
		end
	end
	return cancel
end

return M
