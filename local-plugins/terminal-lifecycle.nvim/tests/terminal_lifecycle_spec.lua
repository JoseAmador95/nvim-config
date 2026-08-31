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
	function backend.lines(handle)
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

test("a changed launch is rejected until restart is explicit", function()
	local backend = setup_backend()
	local first = assert(terminal.open(spec("changed")))
	local changed = spec("changed", { launch = { argv = { "printf", "changed" } } })
	local reopened, err = terminal.open(changed)
	assert(reopened == nil and err:find("restart explicitly", 1, true), "changed launch was not rejected")
	assert(#backend.opened == 1 and backend.stop_count == 0, "changed launch silently replaced the process")
	local second = assert(terminal.restart(changed))
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

test("stop retains output and dispose closes it explicitly", function()
	local backend = setup_backend()
	local value = spec("stop")
	local record = assert(terminal.open(value))
	assert(terminal.stop(value) == record and record.state == "exited-retained")
	assert(backend.stop_count == 1 and backend.dispose_count == 0, "stop disposed retained output")
	assert(vim.deep_equal(assert(terminal.lines(value)), { "retained output" }))
	assert(terminal.dispose(value) == record and record.state == "disposed")
	assert(backend.dispose_count == 1 and terminal.status(value).state == "disposed")
end)

test("dispose-on-stop policy closes the retained view", function()
	local backend = setup_backend()
	local value = spec("stop-dispose", { policy = { dispose_on_stop = true } })
	local record = assert(terminal.open(value))
	assert(terminal.stop(value) == record and record.state == "disposed")
	assert(backend.stop_count == 1 and backend.dispose_count == 1)
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
	assert(first_backend.stop_count == 1 and first_backend.dispose_count == 1)
	assert(second_backend.stop_count == 0 and second_backend.dispose_count == 0)
	assert(terminal.open(spec("second-backend")))
	assert(#first_backend.opened == 1 and #second_backend.opened == 1)
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
