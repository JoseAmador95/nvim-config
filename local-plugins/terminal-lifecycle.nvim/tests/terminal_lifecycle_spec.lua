vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/terminal-lifecycle.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	repo .. "/local-plugins/_shared/lua/?.lua",
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	package.path,
}, ";")

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

local function fake_backend(options)
	local backend = {
		opened = {},
		stop_count = 0,
		dispose_count = 0,
		last_lines_limit = nil,
		options = options or {},
	}
	function backend.open(spec, callbacks)
		local handle = {
			buf = vim.api.nvim_create_buf(false, true),
			visible = true,
			lines = { "retained output" },
			callbacks = callbacks,
			show_count = 0,
			focus_count = 0,
			hide_count = 0,
		}
		backend.opened[#backend.opened + 1] = { spec = spec, handle = handle }
		vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, handle.lines)
		callbacks.on_buffer(handle.buf)
		if backend.options.dispose_during_open then
			callbacks.on_dispose()
		end
		if backend.options.quick_exit ~= nil then
			callbacks.on_exit(backend.options.quick_exit)
		end
		return handle
	end
	function backend.buffer(handle)
		return handle.buf
	end
	function backend.visible(handle)
		return handle.visible
	end
	function backend.show(handle)
		handle.visible = true
		handle.show_count = handle.show_count + 1
		if backend.options.exit_during_show ~= nil then
			handle.callbacks.on_exit(backend.options.exit_during_show)
		end
		return true
	end
	function backend.focus(handle)
		handle.focus_count = handle.focus_count + 1
		return true
	end
	function backend.hide(handle)
		handle.visible = false
		handle.hide_count = handle.hide_count + 1
		return true
	end
	function backend.stop(handle)
		backend.stop_count = backend.stop_count + 1
		if backend.options.exit_during_stop ~= nil then
			handle.callbacks.on_exit(backend.options.exit_during_stop)
		end
		return true
	end
	function backend.dispose(handle)
		backend.dispose_count = backend.dispose_count + 1
		handle.visible = false
		return true
	end
	function backend.lines(handle, max_lines)
		backend.last_lines_limit = max_lines
		return vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
	end
	return backend
end

local terminal = require("terminal_lifecycle")
local notices = {}

local function setup_backend(options)
	terminal._reset()
	notices = {}
	local backend = fake_backend(options)
	terminal.setup({
		backend = backend,
		schedule = function(callback)
			callback()
		end,
		notify = function(message, level)
			notices[#notices + 1] = { message = message, level = level }
		end,
	})
	return backend
end

local function spec(key, overrides)
	return vim.tbl_deep_extend("force", {
		key = key,
		launch = {
			argv = { "printf", "%s", "hello world" },
			cwd = repo,
			env = { PHASE = "two" },
		},
		policy = { dispose_on_success = true, dispose_on_stop = false },
		view = { layout = "bottom", title = key, passthrough = {}, hide_keys = {} },
		metadata = { owner = "test" },
	}, overrides or {})
end

test("normalized specs reject unsafe launch values", function()
	setup_backend()
	for _, value in ipairs({
		{ key = "" },
		{ launch = { argv = "printf" } },
		{ launch = { argv = {} } },
		{ launch = { argv = { "", "value" } } },
		{ launch = { argv = { "printf", "bad\0value" } } },
		{ launch = { cwd = "relative" } },
		{ launch = { cwd = "/definitely/missing" } },
		{ launch = { env = false } },
		{ launch = { env = { BAD = 1 } } },
		{ policy = { dispose_on_stop = "yes" } },
		{ injected = true },
		{ launch = { injected = true } },
	}) do
		local _, err = terminal._normalize(vim.tbl_deep_extend("force", spec("invalid"), value))
		assert(type(err) == "string" and err ~= "", "invalid spec was accepted")
	end
end)

test("empty argument values are preserved after the executable", function()
	local backend = setup_backend()
	local value = spec("empty-argument", { launch = { argv = { "printf", "%s", "" } } })
	local normalized = assert(terminal._normalize(value))
	assert(vim.deep_equal(normalized.launch.argv, value.launch.argv), "normalization changed exact argv")
	assert(terminal.open(value))
	assert(
		#backend.opened == 1 and vim.deep_equal(backend.opened[1].spec.launch.argv, value.launch.argv),
		"backend did not receive exact argv"
	)
end)

test("open and toggle reuse one running process and tag its buffer ephemeral", function()
	local backend = setup_backend()
	local value = spec("toggle")
	local record = assert(terminal.open(value))
	assert(record.state == "running", "open did not settle in running")
	assert(#backend.opened == 1, "backend opened more than one process")
	assert(vim.b[record.buf].terminal_lifecycle.ephemeral == true, "structured ephemeral tag is missing")
	assert(vim.b[record.buf].terminal_lifecycle_ephemeral == true, "session exclusion tag is missing")
	assert(terminal.status(value).state == "running", "status did not expose the exact state")
	assert(terminal.toggle(value) == record and not record.handle.visible, "toggle did not hide the process view")
	assert(terminal.toggle(value) == record and record.handle.visible, "toggle did not restore the process view")
	assert(#backend.opened == 1, "toggle created a duplicate process")
end)

test("a changed launch is rejected and explicit restart waits for process exit", function()
	local backend = setup_backend()
	local first = assert(terminal.open(spec("changed")))
	local changed = spec("changed", { launch = { argv = { "printf", "changed" } } })
	local reopened, err = terminal.open(changed)
	assert(reopened == nil and err:find("restart explicitly", 1, true), "changed launch was not rejected")
	assert(#backend.opened == 1 and backend.stop_count == 0, "changed launch silently replaced the process")
	assert(terminal.restart(changed) == first)
	local pending = terminal.status(changed)
	assert(first.state == "running" and pending.stop_pending and pending.restart_pending)
	assert(not pending.accepting_input and #backend.opened == 1 and backend.stop_count == 1)
	first.handle.callbacks.on_exit(0)
	local second = assert(terminal.open(changed))
	assert(first.state == "disposed" and second ~= first and second.state == "running")
	assert(#backend.opened == 2 and backend.stop_count == 1 and backend.dispose_count == 1)
end)

test("failure output is retained with an exited-retained status", function()
	local backend = setup_backend()
	local value = spec("failure")
	local record = assert(terminal.open(value))
	backend.opened[1].handle.callbacks.on_exit(7)
	local status = terminal.status(value)
	assert(record.state == "exited-retained" and status.state == "exited-retained" and status.exit_code == 7)
	assert(vim.deep_equal(assert(terminal.lines(value)), { "retained output" }), "failure output was discarded")
	assert(backend.dispose_count == 0, "failure disposed the visual backend")
	assert(#notices == 1 and notices[1].message:find("retained", 1, true), "failure retention was not reported")
end)

test("quick success during starting settles as disposed", function()
	local backend = setup_backend({ quick_exit = 0 })
	local value = spec("quick-success")
	local record = assert(terminal.open(value))
	assert(record.state == "disposed" and terminal.status(value).state == "disposed")
	assert(backend.dispose_count == 1, "quick success left its backend view alive")
end)

test("quick failure during starting settles with retained output", function()
	local backend = setup_backend({ quick_exit = 19 })
	local value = spec("quick-failure")
	local record = assert(terminal.open(value))
	assert(record.state == "exited-retained" and terminal.status(value).exit_code == 19)
	assert(vim.deep_equal(assert(terminal.lines(value)), { "retained output" }))
	assert(backend.dispose_count == 0, "quick failure discarded its backend view")
end)

test("a synchronous exit while showing never focuses or revives a disposed terminal", function()
	local backend = setup_backend({ exit_during_show = 0 })
	local record = assert(terminal.open(spec("show-exit")))
	assert(record.state == "disposed" and terminal.status(record).state == "disposed")
	assert(record.handle.focus_count == 0, "focus ran after show synchronously disposed the terminal")
	assert(record.visible == false, "show revived the disposed terminal visibility")
	assert(backend.dispose_count == 1, "the disposed terminal view was not closed exactly once")
end)

test("a synchronous failure while showing retains output without stale focus", function()
	local backend = setup_backend({ exit_during_show = 9 })
	local record = assert(terminal.open(spec("show-failure")))
	assert(record.state == "exited-retained" and terminal.status(record).exit_code == 9)
	assert(record.handle.focus_count == 0, "focus ran after show synchronously observed process exit")
	assert(backend.dispose_count == 0, "synchronous failure discarded its retained output")
end)

test("lines are tail-bounded and returned as caller-owned copies", function()
	terminal._reset()
	local backend = fake_backend()
	terminal.setup({
		backend = backend,
		max_output_lines = 2,
		schedule = function(callback)
			callback()
		end,
	})
	local record = assert(terminal.open(spec("bounded-lines")))
	vim.api.nvim_buf_set_lines(record.buf, 0, -1, false, { "one", "two", "three", "four" })
	local lines = assert(terminal.lines(record))
	assert(backend.last_lines_limit == 2, "the backend did not receive the configured read bound")
	assert(vim.deep_equal(lines, { "three", "four" }), "terminal output did not retain the bounded tail")
	lines[1] = "mutated"
	assert(vim.deep_equal(assert(terminal.lines(record)), { "three", "four" }), "terminal lines share backend state")
	local ok = pcall(terminal.setup, { backend = backend, max_output_lines = 0 })
	assert(not ok and terminal.effective_config().max_output_lines == 2, "invalid output bound mutated setup state")
	ok = pcall(terminal.setup, { backend = backend, max_output_lines = 100001 })
	assert(not ok and terminal.effective_config().max_output_lines == 2, "unsafe output bound escaped validation")
end)

test("stop remains pending until exit and then retains output", function()
	local backend = setup_backend()
	local value = spec("stop")
	local record = assert(terminal.open(value))
	assert(terminal.stop(value) == record and record.state == "running")
	local pending = terminal.status(value)
	assert(pending.stop_pending and not pending.accepting_input)
	assert(backend.stop_count == 1 and backend.dispose_count == 0, "stop settled before process exit")
	record.handle.callbacks.on_exit(0)
	assert(record.state == "exited-retained")
	assert(vim.deep_equal(assert(terminal.lines(value)), { "retained output" }))
	assert(terminal.dispose(value) == record and record.state == "disposed")
	assert(backend.dispose_count == 1 and terminal.status(value).state == "disposed")
end)

test("dispose-on-stop policy closes the view only after exit", function()
	local backend = setup_backend()
	local value = spec("stop-dispose", { policy = { dispose_on_stop = true } })
	local record = assert(terminal.open(value))
	assert(terminal.stop(value) == record and record.state == "running")
	assert(backend.stop_count == 1 and backend.dispose_count == 0)
	record.handle.callbacks.on_exit(0)
	assert(record.state == "disposed" and backend.dispose_count == 1)
end)

test("repeated restart coalesces and launches the latest spec exactly once", function()
	local backend = setup_backend()
	local first = assert(terminal.open(spec("coalesced")))
	local second_spec = spec("coalesced", { launch = { argv = { "printf", "second" } } })
	local final_spec = spec("coalesced", { launch = { argv = { "printf", "final" } } })
	assert(terminal.restart(second_spec) == first)
	assert(terminal.restart(final_spec) == first)
	assert(backend.stop_count == 1 and #backend.opened == 1)
	first.handle.callbacks.on_exit(0)
	assert(#backend.opened == 2 and vim.deep_equal(backend.opened[2].spec.launch.argv, { "printf", "final" }))
	first.handle.callbacks.on_exit(0)
	assert(#backend.opened == 2, "duplicate exit created another replacement")
end)

test("dispose wins over a queued restart without requesting a second stop", function()
	local backend = setup_backend()
	local first = assert(terminal.open(spec("dispose-wins")))
	local changed = spec("dispose-wins", { launch = { argv = { "printf", "changed" } } })
	assert(terminal.restart(changed) == first)
	assert(terminal.dispose(first) == first)
	local pending = terminal.status(first)
	assert(pending.dispose_pending and not pending.restart_pending and backend.stop_count == 1)
	first.handle.callbacks.on_exit(0)
	assert(first.state == "disposed" and #backend.opened == 1 and backend.dispose_count == 1)
end)

test("synchronous exit during stop settles through the same state machine", function()
	local backend = setup_backend({ exit_during_stop = 0 })
	local value = spec("sync-stop")
	local record = assert(terminal.open(value))
	assert(terminal.stop(value) == record)
	assert(record.state == "exited-retained" and not terminal.status(value).stop_pending)
	assert(backend.stop_count == 1 and backend.dispose_count == 0)
end)

test("live backend disposal requests stop and remains tracked until exit", function()
	local backend = setup_backend()
	local value = spec("backend-dispose")
	local record = assert(terminal.open(value))
	record.handle.callbacks.on_dispose()
	local pending = terminal.status(value)
	assert(record.state == "running" and pending.dispose_pending and backend.stop_count == 1)
	record.handle.callbacks.on_exit(0)
	assert(record.state == "disposed" and terminal.status(value).state == "disposed")
end)

test("backend disposal during open waits for the handle before requesting stop", function()
	local backend = setup_backend({ dispose_during_open = true })
	local value = spec("dispose-during-open")
	local record = assert(terminal.open(value))
	local pending = terminal.status(value)
	assert(record.state == "running" and pending.dispose_pending and not pending.accepting_input)
	assert(backend.stop_count == 1 and backend.dispose_count == 0)
	record.handle.callbacks.on_exit(0)
	assert(record.state == "disposed" and backend.dispose_count == 1)
end)

test("backend replacement does not redirect existing records", function()
	local first_backend = setup_backend()
	local first = assert(terminal.open(spec("first-backend")))
	local second_backend = fake_backend()
	terminal.setup({
		backend = second_backend,
		schedule = function(callback)
			callback()
		end,
	})
	assert(terminal.dispose(first) == first)
	assert(first_backend.stop_count == 1 and first_backend.dispose_count == 0)
	assert(second_backend.stop_count == 0 and second_backend.dispose_count == 0)
	first.handle.callbacks.on_exit(0)
	assert(first_backend.dispose_count == 1)
	assert(terminal.open(spec("second-backend")))
	assert(#first_backend.opened == 1 and #second_backend.opened == 1)
end)

test("configuration, mappings, events, and stop timeout stay observable without fake exit", function()
	terminal._reset()
	local initial = terminal.status()
	assert(initial.configured == false and #initial.terminals == 0)
	assert(terminal.effective_config().stop_timeout_ms == 5000)
	assert(terminal.effective_config().max_output_lines == 10000)
	local backend = fake_backend()
	local deferred = {}
	local events = {}
	terminal.setup({
		backend = backend,
		stop_timeout_ms = 7,
		max_output_lines = 11,
		buffer_mappings = { close = "x", open_location = false },
		defer = function(callback, milliseconds)
			assert(milliseconds == 7)
			deferred[#deferred + 1] = callback
		end,
		on_state_change = function(event)
			events[#events + 1] = vim.deepcopy(event)
			event.key = "mutated"
			error("observer failure")
		end,
	})
	local record = assert(terminal.open(spec("timeout")))
	local mappings = {}
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(record.buf, "n")) do
		mappings[mapping.lhs] = true
	end
	assert(mappings.x and not mappings.q and not mappings.gf, "configured buffer mappings were not exact")
	local effective = terminal.effective_config()
	assert(
		effective.stop_timeout_ms == 7 and effective.max_output_lines == 11 and effective.buffer_mappings.close == "x"
	)
	effective.buffer_mappings.close = "mutated"
	assert(terminal.effective_config().buffer_mappings.close == "x", "effective config shares state")
	local before = terminal.status(record)
	local ok, err = pcall(terminal.setup, { backend = backend, injected = true })
	assert(not ok and tostring(err):find("unknown option: injected", 1, true))
	assert(vim.deep_equal(before, terminal.status(record)), "rejected setup mutated a terminal")
	ok, err = pcall(terminal.setup, { backend = { open = function() end } })
	assert(not ok and tostring(err):find("backend requires show", 1, true), "incomplete backend was accepted")
	assert(vim.deep_equal(before, terminal.status(record)), "incomplete backend setup mutated a terminal")

	assert(terminal.stop(record) == record and #deferred == 1)
	deferred[1]()
	local timed_out = terminal.status(record)
	assert(timed_out.stop_timed_out and timed_out.stop_pending)
	assert(timed_out.state == "running" and timed_out.exit_code == nil, "timeout fabricated process exit")
	assert(#backend.opened == 1 and backend.dispose_count == 0, "timeout restarted or disposed the process")
	assert(events[#events].reason == "stop-timeout", "timeout state event was not emitted")
	assert(terminal.status(record).key == "timeout", "observer mutated internal state")
	record.handle.callbacks.on_exit(0)
	assert(record.state == "exited-retained")
	assert(terminal.dispose(record))
	assert(terminal.teardown() and terminal.teardown(), "teardown was not repeatable")
end)

test("list and filtered dispose_all are deterministic and caller-owned", function()
	local backend = setup_backend()
	local second = assert(terminal.open(spec("z", { metadata = { group = "keep" } })))
	local first = assert(terminal.open(spec("a", { metadata = { group = "dispose" } })))
	local listed = terminal.list()
	assert(#listed == 2 and listed[1].key == "a" and listed[2].key == "z")
	listed[1].metadata.group = "mutated"
	assert(terminal.status(first).metadata.group == "dispose", "list shares record metadata")
	local disposed = assert(terminal.dispose_all({ metadata = { group = "dispose" } }))
	assert(#disposed == 1 and disposed[1].key == "a" and disposed[1].dispose_pending)
	assert(backend.stop_count == 1 and terminal.status(second).dispose_pending == false)
	first.handle.callbacks.on_exit(0)
	assert(terminal.status("a").state == "disposed" and terminal.status("z").state == "running")
end)

terminal._reset()

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("terminal_lifecycle_spec: %d tests passed", count))
vim.cmd("quitall!")
