vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local directories = {}
local cancellations = {}
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	for _, cancel in ipairs(cancellations) do
		cancel()
	end
	cancellations = {}
	for _, path in ipairs(directories) do
		vim.fn.delete(path, "rf")
	end
	directories = {}
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function request(overrides)
	return vim.tbl_deep_extend("force", {
		entry = {
			path = "file.lua",
			old_path = "file.lua",
			new_path = "file.lua",
			old_mode = "100644",
			new_mode = "100755",
			old_oid = string.rep("a", 40),
			new_oid = string.rep("b", 40),
			old_text = "local answer = 1\r\n",
			new_text = "local answer = 2\r\n",
		},
		width = 117,
		background = "dark",
	}, overrides or {})
end

local function fake_timer()
	local timer = { closed = false, stopped = false }
	function timer:start(timeout, interval, callback)
		self.timeout, self.interval, self.callback = timeout, interval, callback
		return 0
	end
	function timer:stop()
		self.stopped = true
	end
	function timer:close()
		self.closed = true
	end
	return timer
end

local function fixture()
	package.loaded["config.review_structural_diff"] = nil
	local adapter = require("config.review_structural_diff")
	local calls = { kills = {}, callbacks = {}, resolutions = 0, timer = fake_timer() }
	adapter._resolve = function()
		calls.resolutions = calls.resolutions + 1
		return "/verified/bin/difft"
	end
	local mkdtemp = adapter._mkdtemp
	adapter._mkdtemp = function()
		local path, err = mkdtemp()
		if path then
			directories[#directories + 1] = path
			calls.directory = path
		end
		return path, err
	end
	adapter._new_timer = function()
		return calls.timer
	end
	adapter._system = function(argv, options, on_exit)
		calls.argv, calls.options, calls.exit = argv, options, on_exit
		return {
			kill = function(_, signal)
				calls.kills[#calls.kills + 1] = signal
			end,
		}
	end
	function calls:run(input)
		local cancel = adapter.run(input or request(), function(output, err)
			assert(not vim.in_fast_event(), "adapter callback ran in a fast event")
			self.callbacks[#self.callbacks + 1] = { output = output, err = err }
		end)
		cancellations[#cancellations + 1] = cancel
		return cancel
	end
	function calls:wait()
		assert(
			vim.wait(1000, function()
				return #self.callbacks > 0
			end, 1),
			"adapter did not schedule a completion"
		)
		return self.callbacks[1]
	end
	function calls:clean()
		assert(self.directory and vim.uv.fs_lstat(self.directory) == nil, "private snapshots were retained")
	end
	return adapter, calls
end

local function read_binary(path)
	local fd = assert(vim.uv.fs_open(path, "r", 0))
	local stat = assert(vim.uv.fs_fstat(fd))
	local bytes = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return bytes
end

test("loading the adapter does not activate tool lifecycle or probe a process", function()
	local original_core = package.loaded["config.tool_bootstrap"]
	local original_preload = package.preload["config.tool_bootstrap"]
	local original_system = vim.system
	package.loaded["config.tool_bootstrap"] = nil
	package.preload["config.tool_bootstrap"] = function()
		error("adapter loaded tool lifecycle at startup")
	end
	vim.system = function()
		error("adapter spawned a startup probe")
	end
	package.loaded["config.review_structural_diff"] = nil
	local ok, result = pcall(require, "config.review_structural_diff")
	vim.system = original_system
	package.loaded["config.tool_bootstrap"] = original_core
	package.preload["config.tool_bootstrap"] = original_preload
	assert(ok, result)
	assert(type(result.run) == "function")
end)

test("explicit execution resolves only the registered difftastic command", function()
	local adapter, calls = fixture()
	local original_core = package.loaded["config.tool_bootstrap"]
	package.loaded["config.tool_bootstrap"] = {
		resolve = function(name, executable)
			assert(name == "difftastic" and executable == "difft")
			calls.resolutions = calls.resolutions + 1
			return nil, "not-attested"
		end,
	}
	-- Retain the production deferred-resolution boundary for this one call.
	adapter._resolve = assert(loadfile(repo .. "/lua/config/review_structural_diff.lua"))()._resolve
	local ok, err = xpcall(function()
		calls:run()
		assert(calls.resolutions == 1 and calls.argv == nil and calls.directory == nil)
		assert(#calls.callbacks == 0, "missing-tool error was synchronous")
		local result = calls:wait()
		assert(result.output == nil and result.err:find(":NvimConfigToolsInstall difftastic", 1, true))
		assert(result.err:find("not-attested", 1, true))
	end, debug.traceback)
	package.loaded["config.tool_bootstrap"] = original_core
	assert(ok, err)
end)

test("frozen bytes use private files and safe argv with modes and object IDs", function()
	local _, calls = fixture()
	local input =
		request({ entry = { path = "-- odd name.lua", old_path = "-- odd name.lua", new_path = "-- odd name.lua" } })
	input.entry.old_text = "old\0bytes\r\nno final newline"
	input.entry.new_text = "new\0bytes\n"
	calls:run(input)
	assert(calls.resolutions == 1)
	assert(bit.band(vim.uv.fs_stat(calls.directory).mode, 511) == 448)
	for _, side in ipairs({ "old", "new" }) do
		local path = calls.directory .. "/" .. side
		assert(bit.band(vim.uv.fs_stat(path).mode, 511) == 384)
		assert(read_binary(path) == input.entry[side .. "_text"], "snapshot bytes were rewritten")
	end
	assert(vim.deep_equal(calls.argv, {
		"/verified/bin/difft",
		"--display=side-by-side-show-both",
		"--color=always",
		"--background=dark",
		"--width=117",
		"--strip-cr=off",
		"--",
		"-- odd name.lua",
		calls.directory .. "/old",
		string.rep("a", 40),
		"100644",
		calls.directory .. "/new",
		string.rep("b", 40),
		"100755",
	}))
	input.entry.old_text = "later source mutation"
	assert(read_binary(calls.directory .. "/old") == "old\0bytes\r\nno final newline")
	calls.options.stdout(nil, "\27[31mNo syntactic changes\27[0m\n")
	calls.exit({ code = 0, signal = 0 })
	assert(#calls.callbacks == 0, "process completion was synchronous")
	local result = calls:wait()
	assert(result.output == "\27[31mNo syntactic changes\27[0m\n" and result.err == nil)
	calls.exit({ code = 0, signal = 0 })
	assert(#calls.callbacks == 1, "process completion published twice")
	assert(calls.timer.closed and calls.timer.stopped)
	calls:clean()
end)

test("rename labels use the nine-argument Git form and explicit light background", function()
	local _, calls = fixture()
	calls:run(request({ background = "light", entry = { old_path = "old thing.py", new_path = "-renamed.py" } }))
	assert(#calls.argv == 16)
	assert(calls.argv[4] == "--background=light")
	assert(calls.argv[8] == "old thing.py" and calls.argv[15] == "-renamed.py" and calls.argv[16] == "")
	assert(calls.options.cwd == calls.directory)
	assert(calls.options.timeout == 5000 and calls.options.text == false)
	assert(calls.options.clear_env == true)
	assert(vim.deep_equal(calls.options.env, {
		PATH = "/verified/bin:/usr/bin:/bin",
		LANG = "C",
		LC_ALL = "C",
		TERM = "xterm-256color",
	}))
	calls.exit({ code = 0, signal = 0 })
	assert(calls:wait().output == "")
	calls:clean()
end)

test("added and deleted frozen sides keep zero modes without reading live paths", function()
	for _, side in ipairs({ "old", "new" }) do
		local _, calls = fixture()
		local input = request()
		input.entry.path = "nonexistent path.c"
		input.entry.old_path, input.entry.new_path = nil, nil
		input.entry[side .. "_mode"] = "000000"
		input.entry[side .. "_oid"] = nil
		input.entry[side .. "_text"] = ""
		calls:run(input)
		assert(calls.argv[8] == "nonexistent path.c" and #calls.argv == 14)
		assert(calls.argv[side == "old" and 10 or 13] == "0000000")
		assert(calls.argv[side == "old" and 11 or 14] == "000000")
		assert(read_binary(calls.directory .. "/" .. side) == "")
		calls.exit({ code = 0, signal = 0 })
		calls:wait()
		calls:clean()
	end
end)

test("invalid snapshots and arguments fail before tool resolution", function()
	for _, change in ipairs({
		{ entry = { old_text = false } },
		{ entry = { new_text = false } },
		{ width = 0 },
		{ width = 1.5 },
		{ width = 0 / 0 },
		{ background = "auto" },
		{ entry = { old_path = "bad\0path" } },
		{ entry = { old_mode = "100999" } },
		{ entry = { new_oid = "invalid" } },
	}) do
		local _, calls = fixture()
		calls:run(request(change))
		assert(calls.resolutions == 0 and calls.directory == nil and calls.argv == nil)
		assert(calls:wait().err ~= nil)
	end
end)

test("resolver exceptions return actionable scheduled errors", function()
	local adapter, calls = fixture()
	adapter._resolve = function()
		error("injected resolve failure")
	end
	calls:run()
	local result = calls:wait()
	assert(result.err:find("injected resolve failure", 1, true))
	assert(result.err:find(":NvimConfigToolsInstall difftastic", 1, true))
	assert(calls.directory == nil and calls.argv == nil)
end)

test("temporary-directory errors and exceptions do not spawn", function()
	for _, throwing in ipairs({ false, true }) do
		local adapter, calls = fixture()
		adapter._mkdtemp = function()
			if throwing then
				error("injected temp failure")
			end
			return nil, "injected temp failure"
		end
		calls:run()
		assert(calls:wait().err:find("injected temp failure", 1, true))
		assert(calls.argv == nil)
	end
end)

test("spawn exceptions clean both private inputs", function()
	local adapter, calls = fixture()
	adapter._system = function()
		error("injected spawn failure")
	end
	calls:run()
	assert(calls:wait().err:find("injected spawn failure", 1, true))
	calls:clean()
end)

test("failed processes expose bounded stderr and clean snapshots", function()
	local _, calls = fixture()
	calls:run()
	calls.options.stdout(nil, "partial output")
	calls.options.stderr(nil, string.rep("x", 4096) .. "\n")
	calls.exit({ code = 2, signal = 0 })
	local result = calls:wait()
	assert(result.output == nil and result.err:find("exit 2", 1, true))
	assert(#result.err < 2200 and #calls.kills == 0)
	calls:clean()
end)

test("combined stdout and stderr are capped before publishing", function()
	local _, calls = fixture()
	calls:run()
	calls.options.stdout(nil, string.rep("a", 4 * 1024 * 1024))
	calls.options.stderr(nil, string.rep("b", 4 * 1024 * 1024))
	assert(#calls.kills == 0, "the inclusive 8 MiB boundary was rejected")
	calls.options.stderr(nil, "overflow")
	assert(vim.deep_equal(calls.kills, { 9 }))
	local result = calls:wait()
	assert(result.output == nil and result.err:find("8 MiB", 1, true))
	calls.options.stdout(nil, "late output")
	calls.exit({ code = 0, signal = 0 })
	assert(#calls.callbacks == 1)
	calls:clean()
end)

test("stream read failures terminate and clean the subprocess", function()
	local _, calls = fixture()
	calls:run()
	calls.options.stdout("read failure", nil)
	assert(calls:wait().err:find("read failure", 1, true))
	assert(vim.deep_equal(calls.kills, { 9 }))
	calls:clean()
end)

test("the independent deadline kills a process that ignores the system timeout", function()
	local _, calls = fixture()
	calls:run()
	assert(calls.timer.timeout == 5000 and calls.timer.interval == 0)
	calls.timer.callback()
	assert(vim.deep_equal(calls.kills, { 9 }))
	assert(calls:wait().err:find("timed out after 5000 ms", 1, true))
	assert(calls.timer.closed and calls.timer.stopped)
	calls.exit({ code = 0, signal = 0 })
	assert(#calls.callbacks == 1)
	calls:clean()
end)

test("system timeout exit results clean up and report the deadline", function()
	local _, calls = fixture()
	calls:run()
	calls.exit({ code = 124, signal = 15 })
	assert(calls:wait().err:find("timed out after 5000 ms", 1, true))
	calls:clean()
end)

test("cancellation kills once, removes private inputs, and suppresses late callbacks", function()
	local _, calls = fixture()
	local cancel = calls:run()
	cancel()
	cancel()
	assert(vim.deep_equal(calls.kills, { 9 }))
	assert(calls.timer.closed and calls.timer.stopped)
	calls:clean()
	calls.options.stdout(nil, "late output")
	calls.exit({ code = 0, signal = 0 })
	vim.wait(20, function()
		return false
	end, 1)
	assert(#calls.callbacks == 0)
end)

test("cancellation suppresses an already scheduled completion without killing a closed process", function()
	local _, calls = fixture()
	local cancel = calls:run()
	calls.options.stdout(nil, "ready output")
	calls.exit({ code = 0, signal = 0 })
	cancel()
	vim.wait(20, function()
		return false
	end, 1)
	assert(#calls.callbacks == 0 and #calls.kills == 0)
	calls:clean()
end)

test("timer setup failures terminate the process and clean snapshots", function()
	for _, failing_start in ipairs({ false, true }) do
		local adapter, calls = fixture()
		if failing_start then
			calls.timer.start = function()
				return nil, "injected timer start failure"
			end
		else
			adapter._new_timer = function()
				error("injected timer creation failure")
			end
		end
		calls:run()
		assert(calls:wait().err:find("injected timer", 1, true))
		assert(vim.deep_equal(calls.kills, { 9 }))
		calls:clean()
	end
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_structural_diff_spec: %d tests passed", count))
vim.cmd("quitall!")
