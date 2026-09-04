vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/log-workbench.nvim"
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0
local temporary = {}

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function temporary_file(lines)
	local path = vim.fn.tempname() .. ".log"
	assert(vim.fn.writefile(lines, path) == 0)
	temporary[#temporary + 1] = path
	return path
end

local function wait_for(predicate, message)
	assert(vim.wait(3000, predicate, 10), message)
end

local watcher_handles = {}
local function watcher()
	local handle = { closed = false }
	function handle:start(_, _, callback)
		self.callback = callback
		watcher_handles[#watcher_handles + 1] = self
		return 0
	end
	function handle:stop()
		self.stopped = true
		return 0
	end
	function handle:is_closing()
		return self.closed
	end
	function handle:close()
		self.closed = true
	end
	return handle
end

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, options)
	notifications[#notifications + 1] = { message = tostring(message), level = level, options = options }
end

package.loaded["config.local_config"] = {
	plugin = function(key, fallback)
		if key == "log_workbench" then
			return { poll_interval_ms = 500, max_lines = 3, max_bytes = 128 }
		end
		return fallback
	end,
}

require("config.viewer_commands")
assert(package.loaded["config.log_patterns"] == nil, "viewer command registration loaded the log match adapter")
assert(package.loaded["log_workbench.matches"] == nil, "viewer command registration initialized log matches")
local log_watch = require("config.log_watch")
assert(log_watch.setup({
	new_fs_poll = watcher,
	new_fs_event = watcher,
	notify = vim.notify,
}))

test("host command opens a distinct tail buffer and restores the untouched source", function()
	local path = temporary_file({ "one", "two" })
	vim.cmd.edit(vim.fn.fnameescape(path))
	local source = vim.api.nvim_get_current_buf()
	local source_lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
	equal(2, vim.fn.exists(":LogWatchCurrentFile"), "host follow command is missing")
	equal(2, vim.fn.exists(":LogHlAdd"), "host pattern command is missing")

	log_watch.command({ args = "on" })
	local tail = vim.api.nvim_get_current_buf()
	assert(tail ~= source, "follow reused the source buffer")
	assert(vim.startswith(vim.api.nvim_buf_get_name(tail), "tail://"))
	equal("nofile", vim.bo[tail].buftype)
	wait_for(function()
		return vim.deep_equal(vim.api.nvim_buf_get_lines(tail, 0, -1, false), { "one", "two" })
	end, "tail content did not load")
	equal(source_lines, vim.api.nvim_buf_get_lines(source, 0, -1, false), "source contents changed")
	equal(false, vim.bo[source].readonly, "source readonly state changed")
	equal(true, vim.bo[source].modifiable, "source modifiable state changed")

	log_watch.command({ args = "off" })
	equal(source, vim.api.nvim_get_current_buf(), "stopping did not return to the source")
	equal(false, vim.api.nvim_buf_is_valid(tail), "tail buffer survived stop")
	equal({}, log_watch.status())
end)

test("auto-session suspends tails before serialization and restores them afterward", function()
	local path = temporary_file({ "session", "tail" })
	vim.cmd.edit(vim.fn.fnameescape(path))
	local source = vim.api.nvim_get_current_buf()
	log_watch.command({ args = "on" })
	local tail = vim.api.nvim_get_current_buf()
	wait_for(function()
		return #log_watch.status() == 1
	end, "follow session did not start")

	local original_code_review = package.loaded["config.code_review"]
	local original_preload = package.preload["config.code_review"]
	local original_schedule = vim.schedule
	package.loaded["config.code_review"] = nil
	package.preload["config.code_review"] = function()
		error("fixture unavailable")
	end
	local scheduled = {}
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end
	local auto_session = require("plugins.auto-session")
	local pre_save = auto_session.opts.pre_save_cmds[1]
	assert(pre_save(), "auto-session pre-save rejected the normal source")
	equal(source, vim.api.nvim_get_current_buf(), "tail was still visible during serialization")
	equal(false, vim.api.nvim_buf_is_valid(tail), "tail buffer survived session suspension")
	equal({}, log_watch.status(), "watcher survived session suspension")

	local session_path = vim.fn.tempname() .. ".vim"
	temporary[#temporary + 1] = session_path
	vim.cmd("mksession! " .. vim.fn.fnameescape(session_path))
	local serialized = table.concat(vim.fn.readfile(session_path), "\n")
	assert(not serialized:find("tail://", 1, true), "ephemeral tail URI entered the session file")
	equal(1, #scheduled, "log restoration was not scheduled exactly once")
	scheduled[1]()
	wait_for(function()
		return #log_watch.status() == 1
	end, "tail was not restored after session serialization")
	assert(vim.startswith(vim.api.nvim_buf_get_name(0), "tail://"), "restored window does not show the tail")
	log_watch.command({ args = "off" })

	package.loaded["config.code_review"] = original_code_review
	package.preload["config.code_review"] = original_preload
	vim.schedule = original_schedule
end)

test("host color UI drives plugin extmarks while log-highlight remains external", function()
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "INFO", "ERROR marker", "ERROR second" })
	local patterns = require("config.log_patterns")
	assert(package.loaded["log_workbench.matches"] == nil, "loading the host log adapter initialized log matches")
	assert(patterns.add("exact", { args = "red ERROR" }))
	local state = vim.b[buf].log_pattern_state
	equal(1, #state.patterns)
	equal("red", state.patterns[1].color_key)
	local match_core = require("log_workbench.matches")
	equal(2, #match_core.locations(buf))
	equal(2, #vim.api.nvim_buf_get_extmarks(buf, match_core.namespace(), 0, -1, {}))
	patterns.clear({ args = "red" })
	equal({}, match_core.locations(buf))

	local syntax_spec = require("plugins.log-highlight")
	equal("fei6409/log-highlight.nvim", syntax_spec[1], "external syntax backend changed")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("host commands distinguish explicit patterns from visual ranges", function()
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"stale selection",
		"prefix marker suffix",
		"another stale line",
	})
	local match_core = require("log_workbench.matches")

	-- Visual marks outlive Visual mode and must not override a new command argument.
	assert(vim.fn.setpos("'<", { buf, 1, 1, 0 }) == 0)
	assert(vim.fn.setpos("'>", { buf, 3, 18, 0 }) == 0)
	vim.api.nvim_cmd({ cmd = "LogHlAdd", args = { "red", "marker" } }, {})
	local entries = match_core.list(buf)
	equal(1, #entries)
	equal("marker", entries[1].text)

	vim.cmd("LogHlClear")
	local notification_count = #notifications
	vim.api.nvim_cmd({ cmd = "LogHlAdd", args = { "red" } }, {})
	equal({}, match_core.list(buf), "a command without a range reused stale visual marks")
	equal(notification_count + 1, #notifications)
	assert(notifications[#notifications].message:find("Pattern is required", 1, true))

	-- A real visual range remains supported, including a partial single-line selection.
	assert(vim.fn.setpos("'<", { buf, 2, 8, 0 }) == 0)
	assert(vim.fn.setpos("'>", { buf, 2, 13, 0 }) == 0)
	vim.cmd("'<,'>LogHlAdd blue")
	entries = match_core.list(buf)
	equal(1, #entries)
	equal("marker", entries[1].text)

	vim.cmd("LogHlClear")
	vim.cmd("'<,'>LogHlRegex green")
	entries = match_core.list(buf)
	equal(1, #entries)
	equal("regex", entries[1].kind)
	equal("marker", entries[1].text)

	-- The core still rejects intentionally selected multi-line patterns.
	vim.cmd("LogHlClear")
	assert(vim.fn.setpos("'<", { buf, 1, 1, 0 }) == 0)
	assert(vim.fn.setpos("'>", { buf, 2, 6, 0 }) == 0)
	notification_count = #notifications
	vim.cmd("'<,'>LogHlAdd purple")
	equal({}, match_core.list(buf))
	equal(notification_count + 1, #notifications)
	assert(notifications[#notifications].message:find("patterns must be single-line", 1, true))

	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("local plugin has no host imports, commands, mappings, or syntax dependency", function()
	for _, path in ipairs(vim.fn.glob(plugin .. "/lua/**/*.lua", false, true)) do
		local contents = table.concat(vim.fn.readfile(path), "\n")
		assert(not contents:match([[require%s*%(%s*["']config%.]]), path .. " imports config.*")
		assert(not contents:find("nvim_create_user_command", 1, true), path .. " creates a global command")
		assert(not contents:find("vim.keymap.set", 1, true), path .. " creates a mapping")
		assert(not contents:find("log%-highlight", 1), path .. " loads the syntax backend")
	end
end)

log_watch.teardown()
vim.notify = original_notify
for _, path in ipairs(temporary) do
	vim.fn.delete(path, "rf")
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("log_workbench_spec: %d host contract tests passed"):format(count))
vim.cmd("quitall!")
