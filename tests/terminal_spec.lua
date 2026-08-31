vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local terminal_plugin = repo .. "/local-plugins/terminal-lifecycle.nvim"
vim.opt.runtimepath:prepend(terminal_plugin)
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
	terminal_plugin .. "/lua/?.lua",
	terminal_plugin .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
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
		key = assert(terminal._key("host", repo, id)),
		launch = { argv = { "printf", "%s", "hello world" }, cwd = repo, env = { PHASE = "two" } },
		policy = { dispose_on_success = true, dispose_on_stop = false },
		view = { layout = "bottom", title = id },
		metadata = { runtime = "host", root = repo, id = id },
	}, overrides or {})
end

test("specs require arrays, absolute directories, and explicit string env", function()
	for _, case in ipairs({
		{ launch = { argv = "printf hello" } },
		{ launch = { argv = {} } },
		{ launch = { cwd = "relative" } },
		{ launch = { cwd = "/definitely/missing" } },
		{ launch = { env = false } },
		{ launch = { env = { BAD = 1 } } },
		{ view = { layout = "popup" } },
	}) do
		local _, err = terminal._normalize(vim.tbl_deep_extend("force", spec("invalid"), case))
		assert(type(err) == "string" and err ~= "")
	end
end)

test("an empty environment map opens the default shell", function()
	local shell = terminal.shell_spec(repo)
	local normalized = assert(terminal._normalize(shell))
	assert(
		next(normalized.launch.env) == nil and not vim.islist(normalized.launch.env),
		"empty env did not remain a map"
	)
	assert(
		vim.deep_equal(normalized.view.passthrough, { "<Tab>", "<S-Tab>" }),
		"shell completion keys are not passed through"
	)
	local record = assert(terminal.open(shell))
	assert(record and #opened == 1, "default shell did not open")
	assert(next(opened[1].opts.env) == nil and not vim.islist(opened[1].opts.env), "Snacks received an empty list")
	terminal._reset()
	opened = {}
end)

test("embedded LazyGit keeps its edit preset and adds process-local blocking GH_EDITOR", function()
	local old_devcontainer = package.loaded["config.devcontainer"]
	local old_repo = package.loaded["config.repo"]
	local old_terminal = package.loaded["config.terminal"]
	local old_fs = package.loaded["config.fs"]
	local old_executable = vim.fn.executable
	local old_systemlist = vim.fn.systemlist
	local old_filereadable = vim.fn.filereadable
	local captured
	local generated

	package.loaded["config.devcontainer"] = {
		in_workspace = function()
			return false
		end,
	}
	package.loaded["config.repo"] = {
		current_root = function()
			return repo
		end,
	}
	package.loaded["config.terminal"] = {
		toggle = function(options)
			captured = options
			return {}
		end,
	}
	package.loaded["config.fs"] = {
		write_binary_atomic = function(path, data)
			generated = { path = path, data = data }
			return true
		end,
	}
	vim.fn.executable = function(name)
		return name == "lazygit" and 1 or 0
	end
	vim.fn.systemlist = function()
		return { "/missing/lazygit/config" }
	end
	vim.fn.filereadable = function()
		return 0
	end

	local lazygit = dofile(repo .. "/lua/plugins/lazygit.lua")
	lazygit.keys[1][2]()
	assert(captured and captured.launch.cwd == repo and captured.launch.argv[1] == "lazygit")
	assert(captured.launch.env.LG_CONFIG_FILE == generated.path)
	assert(generated.data:find("editPreset: nvim%-remote"), "LazyGit edit preset changed")
	assert(
		captured.launch.env.GH_EDITOR
			== vim.fn.shellescape(repo .. "/scripts/devcontainer-editor") .. " editor-open --wait-editor",
		"LazyGit GH_EDITOR did not contain only the fixed helper and mode"
	)

	package.loaded["config.devcontainer"] = old_devcontainer
	package.loaded["config.repo"] = old_repo
	package.loaded["config.terminal"] = old_terminal
	package.loaded["config.fs"] = old_fs
	vim.fn.executable = old_executable
	vim.fn.systemlist = old_systemlist
	vim.fn.filereadable = old_filereadable
end)

test("Dev Container opens Bash with the explicit interactive completion rc", function()
	local previous = vim.env.NVIM_DEVCONTAINER
	vim.env.NVIM_DEVCONTAINER = "1"
	local bash = vim.fn.exepath("bash")
	assert(bash ~= "", "test host has no Bash")
	local shell = terminal.shell_spec(repo)
	vim.env.NVIM_DEVCONTAINER = previous
	assert(
		vim.deep_equal(shell.launch.argv, { bash, "--rcfile", terminal._devcontainer_bashrc, "-i" }),
		"Dev Container shell is not explicit interactive Bash"
	)
	local bashrc = vim.uv.fs_stat(terminal._devcontainer_bashrc)
	assert(bashrc and bashrc.type == "file", "Dev Container Bash rc is missing")
end)

test("toggle creates visibly, then hides and restores one process", function()
	local value = spec("shell")
	local record = assert(terminal.toggle(value))
	assert(#opened == 1 and opened[1].win.visible, "first toggle hid the newly-created terminal")
	assert(vim.deep_equal(opened[1].argv, value.launch.argv), "argv was not passed as an array")
	assert(opened[1].opts.cwd == repo and vim.deep_equal(opened[1].opts.env, value.launch.env))
	assert(opened[1].opts.win.position == "bottom" and opened[1].opts.win.height == 0.35)
	terminal.toggle(value)
	assert(not record.handle.visible and terminal.status(value).running, "hide killed the process")
	terminal.toggle(value)
	assert(record.handle.visible and #opened == 1, "show created a duplicate terminal")
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

test("changed launch is rejected until explicit restart and failed output remains available", function()
	local value = spec("restart")
	local first = assert(terminal.open(value))
	local changed = spec("restart", { launch = { argv = { "printf", "changed" } } })
	local stopped_before = #stopped
	local reopened, open_err = terminal.open(changed)
	assert(reopened == nil and open_err:find("restart explicitly", 1, true), "changed argv was not rejected")
	assert(terminal.status(value).running and #stopped == stopped_before, "changed argv silently stopped the process")
	local second = assert(terminal.restart(changed))
	assert(second ~= first and #stopped == stopped_before + 1, "explicit restart did not replace the process")
	second.handle.events.TermClose(second.handle, { status = 7 })
	local status = terminal.status(changed)
	assert(status.exists and not status.running and status.state == "exited-retained" and status.exit_code == 7)
	assert(#notices > 0 and notices[#notices].message:find("retained", 1, true))
	assert(type(terminal.lines(changed)) == "table", "failed output buffer was discarded")
end)

test("successful short-lived terminals are reaped", function()
	local value = spec("success")
	local record = assert(terminal.open(value))
	record.handle.events.TermClose(record.handle, { status = 0 })
	local status = terminal.status(value)
	assert(not status.exists and status.state == "disposed", "successful terminal remained registered")
end)

test("stop retains output until explicit dispose", function()
	local value = spec("stopped")
	local record = assert(terminal.open(value))
	assert(terminal.stop(value) == record, "stop failed")
	local status = terminal.status(value)
	assert(status.exists and not status.running and status.state == "exited-retained")
	assert(type(terminal.lines(value)) == "table", "stop discarded output")
	assert(terminal.dispose(value) == record and terminal.status(value).state == "disposed")
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
	vim.api.nvim_set_current_buf(record.handle.buf)
	vim.api.nvim_buf_set_lines(record.handle.buf, 0, -1, false, { "lua/config/terminal.lua:10:2: probe" })
	local gf
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(record.handle.buf, "n")) do
		if map.lhs == "gf" then
			gf = map.callback
		end
	end
	assert(type(gf) == "function", "gf mapping is missing")
	gf()
	assert(
		opened_location and opened_location.path == repo .. "/lua/config/terminal.lua",
		"unexpected opened location: " .. vim.inspect(opened_location)
	)
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
