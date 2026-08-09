vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local original_snacks = package.loaded.snacks
local original_editor = package.loaded["config.editor"]
local original_jobwait = vim.fn.jobwait
local original_jobstop = vim.fn.jobstop
local original_chan_send = vim.api.nvim_chan_send
local original_schedule = vim.schedule
local original_notify = vim.notify

local opened = {}
local sent = {}
local stopped = {}
local notices = {}

local function fake_win(opts, index)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.b[buf].terminal_job_id = 7000 + index
	local win = {
		buf = buf,
		visible = true,
		events = {},
		show_count = 0,
		hide_count = 0,
		close_count = 0,
	}
	function win:buf_valid()
		return vim.api.nvim_buf_is_valid(self.buf)
	end
	function win:valid()
		return self.visible and self:buf_valid()
	end
	function win:show()
		self.visible = true
		self.show_count = self.show_count + 1
		return self
	end
	function win:focus()
		vim.api.nvim_set_current_buf(self.buf)
		return self
	end
	function win:hide()
		self.visible = false
		self.hide_count = self.hide_count + 1
		return self
	end
	function win:close()
		self.visible = false
		self.close_count = self.close_count + 1
		return self
	end
	function win:on(event, callback)
		self.events[event] = callback
	end
	if opts.win.on_buf then
		opts.win.on_buf(win)
	end
	return win
end

local snacks = {
	terminal = {
		open = function(argv, opts)
			local win = fake_win(opts, #opened + 1)
			opened[#opened + 1] = { argv = vim.deepcopy(argv), opts = vim.deepcopy(opts), win = win }
			return win
		end,
	},
}

package.loaded.snacks = snacks
vim.fn.jobwait = function()
	return { -1 }
end
vim.fn.jobstop = function(job)
	stopped[#stopped + 1] = job
	return 1
end
vim.api.nvim_chan_send = function(job, payload)
	sent[#sent + 1] = { job = job, payload = payload }
end
vim.schedule = function(callback)
	callback()
end
vim.notify = function(message, level)
	notices[#notices + 1] = { message = message, level = level }
end

local terminal = require("config.terminal")
local function spec(id, overrides)
	return vim.tbl_deep_extend("force", {
		runtime = "host",
		root = repo,
		id = id,
		argv = { "printf", "%s", "hello world" },
		cwd = repo,
		env = { PHASE = "two" },
		layout = "bottom",
		title = id,
	}, overrides or {})
end

test("specs require arrays, absolute directories, and explicit string env", function()
	for _, case in ipairs({
		{ argv = "printf hello" },
		{ argv = {} },
		{ root = "relative" },
		{ cwd = "/definitely/missing" },
		{ env = false },
		{ env = { BAD = 1 } },
		{ layout = "popup" },
	}) do
		local _, err = terminal._normalize(vim.tbl_deep_extend("force", spec("invalid"), case))
		assert(type(err) == "string" and err ~= "")
	end
end)

test("an empty environment map opens the default shell", function()
	local shell = terminal.shell_spec(repo)
	local normalized = assert(terminal._normalize(shell))
	assert(next(normalized.env) == nil and not vim.islist(normalized.env), "empty env did not remain a map")
	assert(
		vim.deep_equal(normalized.passthrough, { "<Tab>", "<S-Tab>" }),
		"shell completion keys are not passed through"
	)
	local record = assert(terminal.open(shell))
	assert(record and #opened == 1, "default shell did not open")
	assert(next(opened[1].opts.env) == nil and not vim.islist(opened[1].opts.env), "Snacks received an empty list")
	terminal._reset()
	opened = {}
end)

test("toggle creates visibly, then hides and restores one process", function()
	local value = spec("shell")
	local record = assert(terminal.toggle(value))
	assert(#opened == 1 and opened[1].win.visible, "first toggle hid the newly-created terminal")
	assert(vim.deep_equal(opened[1].argv, value.argv), "argv was not passed as an array")
	assert(opened[1].opts.cwd == repo and vim.deep_equal(opened[1].opts.env, value.env))
	assert(opened[1].opts.win.position == "bottom" and opened[1].opts.win.height == 0.35)
	terminal.toggle(value)
	assert(not record.win.visible and terminal.status(value).running, "hide killed the process")
	terminal.toggle(value)
	assert(record.win.visible and #opened == 1, "show created a duplicate terminal")
	assert(terminal.send(value, "print(1)"))
	assert(sent[#sent].payload == "print(1)\n")
end)

test("identity includes runtime, canonical root, and id", function()
	assert(terminal.open(spec("one")))
	assert(terminal.open(spec("two")))
	assert(#opened == 3, "different ids did not create distinct processes")
	assert(terminal.open(spec("one")))
	assert(#opened == 3, "same identity created a duplicate process")
end)

test("changed launch contract restarts and failed output remains available", function()
	local value = spec("restart")
	local first = assert(terminal.open(value))
	local changed = spec("restart", { argv = { "printf", "changed" } })
	local second = assert(terminal.open(changed))
	assert(second ~= first and #stopped == 1, "changed argv did not restart the process")
	second.win.events.TermClose(second.win, { status = 7 })
	local status = terminal.status(changed)
	assert(status.exists and not status.running and status.exit_code == 7)
	assert(#notices > 0 and notices[#notices].message:find("retained", 1, true))
	assert(type(terminal.lines(changed)) == "table", "failed output buffer was discarded")
end)

test("successful short-lived terminals are reaped", function()
	local value = spec("success")
	local record = assert(terminal.open(value))
	record.win.events.TermClose(record.win, { status = 0 })
	assert(not terminal.status(value).exists, "successful terminal remained registered")
end)

test("gf opens a contained location through the shared tab primitive", function()
	local opened_location
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path, position)
			opened_location = { path = path, position = position }
		end,
	}
	local value = spec("gf")
	local record = assert(terminal.open(value))
	vim.api.nvim_set_current_buf(record.win.buf)
	vim.api.nvim_buf_set_lines(record.win.buf, 0, -1, false, { "lua/config/terminal.lua:10:2: probe" })
	local gf
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(record.win.buf, "n")) do
		if map.lhs == "gf" then
			gf = map.callback
		end
	end
	assert(type(gf) == "function", "gf mapping is missing")
	gf()
	assert(opened_location and opened_location.path == repo .. "/lua/config/terminal.lua")
	assert(opened_location.position.lnum == 10 and opened_location.position.col == 2)
end)

package.loaded.snacks = original_snacks
package.loaded["config.editor"] = original_editor
vim.fn.jobwait = original_jobwait
vim.fn.jobstop = original_jobstop
vim.api.nvim_chan_send = original_chan_send
vim.schedule = original_schedule
vim.notify = original_notify

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("terminal_spec: %d tests passed", count))
vim.cmd("quitall!")
