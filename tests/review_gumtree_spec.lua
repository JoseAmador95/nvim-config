vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local failures, count, cleanups = {}, 0, {}
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	for _, cleanup in ipairs(cleanups) do
		cleanup()
	end
	cleanups = {}
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function request()
	return {
		entry = { path = "-- frozen name.lua", old_text = "local before = 1\r\n", new_text = "local after = 1" },
		trees = {
			old = '<root><tree type="identifier" label="before" pos="6" length="6"/></root>',
			new = '<root><tree type="identifier" label="after" pos="6" length="5"/></root>',
		},
	}
end

local function read(path)
	local fd = assert(vim.uv.fs_open(path, "r", 0))
	local stat = assert(vim.uv.fs_fstat(fd))
	local text = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return text
end

local function timer()
	return {
		start = function(self, timeout, interval, callback)
			self.timeout, self.interval, self.callback = timeout, interval, callback
			return 0
		end,
		stop = function(self)
			self.stopped = true
		end,
		close = function(self)
			self.closed = true
		end,
	}
end

local function fixture()
	package.loaded["config.review_gumtree"] = nil
	local adapter = require("config.review_gumtree")
	local calls = { resolutions = 0, kills = {}, groups = {}, callbacks = {}, timer = timer() }
	adapter._resolve = function()
		calls.resolutions = calls.resolutions + 1
		return "/verified/bin/gumtree"
	end
	local mkdtemp = adapter._mkdtemp
	adapter._mkdtemp = function()
		local directory, err = mkdtemp()
		calls.directory = directory
		return directory, err
	end
	adapter._kill_group = function(pid)
		calls.groups[#calls.groups + 1] = pid
		return 0
	end
	adapter._new_timer = function()
		return calls.timer
	end
	adapter._system = function(argv, options, on_exit)
		calls.argv, calls.options, calls.exit = argv, options, on_exit
		return {
			pid = 43210,
			kill = function(_, signal)
				calls.kills[#calls.kills + 1] = signal
			end,
		}
	end
	function calls:run(input)
		self.cancel = adapter.analyze(input == nil and request() or input, function(output, err)
			assert(not vim.in_fast_event())
			self.callbacks[#self.callbacks + 1] = { output = output, err = err }
		end)
		return self.cancel
	end
	function calls:wait()
		assert(
			vim.wait(1000, function()
				return #self.callbacks > 0
			end, 1),
			"missing scheduled completion"
		)
		return self.callbacks[1]
	end
	function calls:clean()
		assert(self.directory and not vim.uv.fs_lstat(self.directory), "owned temporary trees remain")
	end
	cleanups[#cleanups + 1] = function()
		if calls.cancel then
			calls.cancel()
		end
		if calls.exit then
			calls.exit({ code = 0, signal = 9 })
		end
		if calls.directory then
			vim.fn.delete(calls.directory, "rf")
		end
	end
	return adapter, calls
end

test("loading does not activate tool lifecycle or probe external processes", function()
	local original_core, original_preload, original_system =
		package.loaded["config.tool_bootstrap"], package.preload["config.tool_bootstrap"], vim.system
	package.loaded["config.tool_bootstrap"] = nil
	package.preload["config.tool_bootstrap"] = function()
		error("loaded lifecycle at startup")
	end
	vim.system = function()
		error("spawned at startup")
	end
	package.loaded["config.review_gumtree"] = nil
	local ok, adapter = pcall(require, "config.review_gumtree")
	package.loaded["config.tool_bootstrap"], package.preload["config.tool_bootstrap"], vim.system =
		original_core, original_preload, original_system
	assert(ok and type(adapter.analyze) == "function", adapter)
end)

test("exact trees use 0700 directories 0600 files fixed argv and private Java temp", function()
	local _, calls = fixture()
	local input = request()
	calls:run(input)
	assert(calls.resolutions == 1)
	assert(bit.band(vim.uv.fs_stat(calls.directory).mode, 511) == 448)
	assert(bit.band(vim.uv.fs_stat(calls.directory .. "/java").mode, 511) == 448)
	for _, side in ipairs({ "old", "new" }) do
		local path = calls.directory .. "/" .. side .. ".xml"
		assert(bit.band(vim.uv.fs_stat(path).mode, 511) == 384)
		assert(read(path) == input.trees[side])
	end
	assert(vim.deep_equal(calls.argv, {
		"/verified/bin/gumtree",
		"textdiff",
		"-m",
		"gumtree-simple",
		"-f",
		"JSON",
		"-x",
		"/bin/cat $FILE",
		calls.directory .. "/old.xml",
		calls.directory .. "/new.xml",
	}))
	assert(calls.options.cwd == calls.directory and calls.options.clear_env and calls.options.detach)
	assert(calls.options.text == false and calls.options.timeout == 5000)
	assert(vim.deep_equal(calls.options.env, {
		PATH = "/usr/bin:/bin",
		LANG = "C.UTF-8",
		LC_ALL = "C.UTF-8",
		GUMTREE_JAVA_TMPDIR = calls.directory .. "/java",
		TMPDIR = calls.directory .. "/java",
		HOME = calls.directory,
	}))
	input.trees.old = "mutated later"
	assert(read(calls.directory .. "/old.xml") ~= input.trees.old)
	vim.fn.writefile({ "Java temporary generator" }, calls.directory .. "/java/gumtree-internal.xml")
	calls.options.stdout(nil, '{"matches":[],"actions":[]}')
	calls.exit({ code = 0, signal = 0 })
	assert(#calls.callbacks == 0)
	assert(calls:wait().output == '{"matches":[],"actions":[]}')
	assert(#calls.kills == 0 and vim.deep_equal(calls.groups, { 43210 }))
	assert(calls.timer.closed and calls.timer.stopped)
	calls:clean()
end)

test("default resolution uses only the registered managed tool", function()
	local original = package.loaded["config.tool_bootstrap"]
	local invoked
	package.loaded["config.tool_bootstrap"] = {
		resolve = function(name, executable)
			invoked = { name, executable }
			return "/managed/gumtree"
		end,
	}
	package.loaded["config.review_gumtree"] = nil
	local adapter = require("config.review_gumtree")
	local ok, value = pcall(adapter._resolve)
	package.loaded["config.tool_bootstrap"] = original
	assert(ok and value == "/managed/gumtree", value)
	assert(vim.deep_equal(invoked, { "gumtree", "gumtree" }))
end)

test("invalid requests and input bounds fail before resolution", function()
	for _, input in ipairs({
		false,
		{},
		{ entry = {}, trees = {} },
		{ entry = { old_text = false, new_text = "" }, trees = { old = "x", new = "y" } },
		{ entry = { old_text = string.rep("x", 1024 * 1024), new_text = "x" }, trees = { old = "x", new = "y" } },
		{ entry = { old_text = "", new_text = "" }, trees = { old = string.rep("x", 16 * 1024 * 1024), new = "y" } },
	}) do
		local _, calls = fixture()
		calls:run(input)
		assert(calls:wait().err and calls.resolutions == 0 and calls.argv == nil and calls.directory == nil)
	end
end)

test("missing managed tool reports the explicit install command without temp files", function()
	for _, throwing in ipairs({ false, true }) do
		local adapter, calls = fixture()
		adapter._resolve = function()
			if throwing then
				error("injected resolution failure")
			end
			return nil, "not installed"
		end
		calls:run()
		assert(calls:wait().err:find(":NvimConfigToolsInstall gumtree", 1, true))
		assert(calls.directory == nil and calls.argv == nil)
	end
end)

test("temporary directory failure and whitespace paths never start GumTree", function()
	local adapter, calls = fixture()
	adapter._mkdtemp = function()
		return nil, "injected failure"
	end
	calls:run()
	assert(calls:wait().err:find("injected failure", 1, true) and calls.argv == nil)
	local another, whitespace = fixture()
	another._mkdtemp = function()
		local path = assert(vim.uv.fs_mkdtemp("/tmp/nvim gumtree-XXXXXX"))
		whitespace.directory = path
		return path
	end
	whitespace:run()
	assert(whitespace:wait().err:find("whitespace-free", 1, true) and whitespace.argv == nil)
	whitespace:clean()
end)

test("spawn failures and bounded stderr clean all owned input trees", function()
	local adapter, calls = fixture()
	adapter._system = function()
		error("injected spawn failure")
	end
	calls:run()
	assert(calls:wait().err:find("injected spawn failure", 1, true))
	calls:clean()
	local _, failed = fixture()
	failed:run()
	failed.options.stderr(nil, string.rep("e", 4096))
	failed.exit({ code = 2, signal = 0 })
	local result = failed:wait()
	assert(result.err:find("exit 2", 1, true) and #result.err < 2200 and not result.output)
	failed:clean()
end)

test("overflow read failure and timeout kill the entire process group before cleanup", function()
	for _, scenario in ipairs({ "overflow", "read", "timeout" }) do
		local _, calls = fixture()
		calls:run()
		if scenario == "overflow" then
			calls.options.stdout(nil, string.rep("x", 4 * 1024 * 1024))
			calls.options.stderr(nil, string.rep("x", 4 * 1024 * 1024))
			assert(#calls.kills == 0)
			calls.options.stderr(nil, "overflow")
		elseif scenario == "read" then
			calls.options.stdout("injected read failure")
		else
			assert(calls.timer.timeout == 5000 and calls.timer.interval == 0)
			calls.timer.callback()
		end
		assert(vim.deep_equal(calls.kills, { 9 }) and vim.deep_equal(calls.groups, { 43210 }))
		assert(vim.uv.fs_lstat(calls.directory), "deleted Java tmp before observing exit")
		assert(#calls.callbacks == 0)
		calls.options.stdout(nil, "late output")
		calls.exit({ code = 0, signal = 9 })
		local result = calls:wait()
		assert(not result.output and result.err)
		if scenario == "overflow" then
			assert(result.err:find("8 MiB", 1, true))
		end
		if scenario == "timeout" then
			assert(result.err:find("5000 ms", 1, true))
		end
		calls:clean()
	end
end)

test("cancelled and already queued completions never publish stale results", function()
	for _, queued in ipairs({ false, true }) do
		local _, calls = fixture()
		local cancel = calls:run()
		if queued then
			calls.exit({ code = 0, signal = 0 })
		end
		cancel()
		cancel()
		calls.options.stdout(nil, "late")
		calls.exit({ code = 0, signal = 9 })
		vim.wait(10, function()
			return false
		end, 1)
		assert(#calls.callbacks == 0 and #calls.groups == 1)
		assert(#calls.kills == (queued and 0 or 1))
		calls:clean()
	end
end)

test("duplicate or invalid completions cannot publish twice", function()
	for _, completion in ipairs({ {}, { code = "0", signal = 0 }, { code = 124, signal = 15 } }) do
		local _, calls = fixture()
		calls:run()
		calls.exit(completion)
		calls.exit({ code = 0, signal = 0 })
		assert(calls:wait().err and #calls.callbacks == 1)
		calls:clean()
	end
end)

test("timer creation and startup failures kill owned children and await exit", function()
	for _, failing_start in ipairs({ false, true }) do
		local adapter, calls = fixture()
		if failing_start then
			calls.timer.start = function()
				return nil, "injected timer failure"
			end
		else
			adapter._new_timer = function()
				error("injected timer failure")
			end
		end
		calls:run()
		assert(vim.deep_equal(calls.kills, { 9 }) and #calls.groups == 1)
		calls.exit({ code = 0, signal = 9 })
		assert(calls:wait().err:find("injected timer failure", 1, true))
		calls:clean()
	end
end)

test("cleanup removes nested JVM artifacts without following foreign symlinks", function()
	local _, calls = fixture()
	calls:run()
	local foreign = assert(vim.uv.fs_mkdtemp("/tmp/nvim-gumtree-foreign-XXXXXX"))
	cleanups[#cleanups + 1] = function()
		vim.fn.delete(foreign, "rf")
	end
	vim.fn.writefile({ "retained" }, foreign .. "/sentinel")
	assert(vim.uv.fs_mkdir(calls.directory .. "/java/nested", 448))
	vim.fn.writefile({ "temporary" }, calls.directory .. "/java/nested/generated.xml")
	assert(vim.uv.fs_symlink(foreign, calls.directory .. "/java/foreign"))
	calls.exit({ code = 0, signal = 0 })
	calls:wait()
	calls:clean()
	assert(read(foreign .. "/sentinel") == "retained\n")
end)

local function real_cancellation(shutdown)
	local sandbox = assert(vim.uv.fs_mkdtemp("/tmp/nvim-gumtree-process-XXXXXX"))
	cleanups[#cleanups + 1] = function()
		vim.fn.delete(sandbox, "rf")
	end
	local executable = sandbox .. "/fake-gumtree"
	vim.fn.writefile(
		{ "#!/bin/sh", "sleep 30 &", 'printf "%s\\n" "$!" > ' .. sandbox .. "/child", 'wait "$!"' },
		executable
	)
	assert(vim.uv.fs_chmod(executable, 448))
	package.loaded["config.review_gumtree"] = nil
	local adapter = require("config.review_gumtree")
	adapter._resolve = function()
		return executable
	end
	local directory, called
	local mkdtemp = adapter._mkdtemp
	adapter._mkdtemp = function()
		directory = assert(mkdtemp())
		return directory
	end
	local cancel = adapter.analyze(request(), function()
		called = true
	end)
	cleanups[#cleanups + 1] = cancel
	assert(vim.wait(2000, function()
		return vim.uv.fs_stat(sandbox .. "/child") ~= nil
	end, 5))
	local child = assert(tonumber(read(sandbox .. "/child")))
	assert(vim.uv.kill(child, 0) == 0)
	if shutdown then
		vim.api.nvim_exec_autocmds("VimLeavePre", { group = "NvimReviewGumTreeProcesses" })
	else
		cancel()
	end
	assert(
		vim.wait(2000, function()
			return not vim.uv.fs_lstat(directory)
		end, 5),
		"real owned trees were retained"
	)
	assert(
		vim.wait(2000, function()
			return vim.uv.kill(child, 0) == nil
		end, 5),
		"owned child survived cancellation"
	)
	assert(not called)
end

test("real detached process cancellation also terminates its owned child", function()
	real_cancellation(false)
end)

test("editor exit waits for owned process termination before removing trees", function()
	real_cancellation(true)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("review_gumtree_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
