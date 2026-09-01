vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
local plugin = repo .. "/local-plugins/log-workbench.nvim"
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

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
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

local function write_raw(path, data)
	local fd, open_err = vim.uv.fs_open(path, "w", 384)
	assert(fd, open_err)
	local written, write_err = vim.uv.fs_write(fd, data, 0)
	assert(written == #data, write_err)
	assert(vim.uv.fs_close(fd))
end

local function append_raw(path, data)
	local fd, open_err = vim.uv.fs_open(path, "a", 384)
	assert(fd, open_err)
	local written, write_err = vim.uv.fs_write(fd, data, -1)
	assert(written == #data, write_err)
	assert(vim.uv.fs_close(fd))
end

local function buffer_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function wait_for(predicate, message)
	assert(vim.wait(3000, predicate, 10), message)
end

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, options)
	notifications[#notifications + 1] = { message = tostring(message), level = level, options = options }
end

package.loaded["config.local_config"] = {
	plugin = function(key, default)
		if key == "log_workbench" then
			return { poll_interval_ms = 500, max_lines = 3, max_bytes = 64 }
		end
		return default
	end,
}

local poll_callbacks = {}
local latest_poll_callback
local original_new_fs_poll = vim.uv.new_fs_poll
vim.uv.new_fs_poll = function()
	local handle = { closed = false }
	function handle:start(path, _, callback)
		poll_callbacks[path] = callback
		latest_poll_callback = callback
		return 0
	end
	function handle:stop()
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

-- Delay read delivery so repeated poll events exercise the one-read/coalescing
-- invariant deterministically.
local original_fs_read = vim.uv.fs_read
local active_reads = 0
local maximum_active_reads = 0
vim.uv.fs_read = function(fd, length, offset, callback)
	if not callback then
		return original_fs_read(fd, length, offset)
	end
	active_reads = active_reads + 1
	maximum_active_reads = math.max(maximum_active_reads, active_reads)
	return original_fs_read(fd, length, offset, function(err, data)
		local timer = vim.uv.new_timer()
		timer:start(30, 0, function()
			timer:stop()
			timer:close()
			active_reads = active_reads - 1
			callback(err, data)
		end)
	end)
end

local log_watch = require("config.log_watch")

local function trigger(path, previous, current)
	local callback = assert(poll_callbacks[path] or latest_poll_callback, "missing poll callback")
	callback(nil, previous, current)
end

test("LogWatch tails incrementally, carries partial lines, and pins every tail window", function()
	local path = vim.fn.tempname()
	write_raw(path, "one\ntwo\nthree\nfour\nfive")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local source = vim.api.nvim_get_current_buf()
	vim.bo[source].filetype = "text"
	vim.bo[source].readonly = false
	vim.bo[source].modifiable = true

	log_watch.command({ args = "on" })
	local buf = vim.api.nvim_get_current_buf()
	assert(buf ~= source, "follow reused the source buffer")
	wait_for(function()
		return vim.deep_equal(buffer_lines(buf), { "three", "four", "five" })
	end, "initial bounded tail did not load")
	equal("log", vim.bo[buf].filetype, "watch filetype")
	equal(false, vim.bo[buf].modifiable, "watch modifiable")
	equal(true, vim.bo[buf].readonly, "watch readonly")
	equal("text", vim.bo[source].filetype, "source filetype changed")
	equal(true, vim.bo[source].modifiable, "source modifiable changed")
	equal(false, vim.bo[source].readonly, "source readonly changed")

	local stationary_win = vim.api.nvim_get_current_win()
	vim.cmd("vsplit")
	local tail_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(stationary_win, { 1, 0 })
	vim.api.nvim_win_set_cursor(tail_win, { 3, 0 })

	local previous = vim.uv.fs_stat(path)
	append_raw(path, "-part")
	local current = vim.uv.fs_stat(path)
	trigger(path, previous, current)
	trigger(path, previous, current)
	wait_for(function()
		return buffer_lines(buf)[3] == "five-part"
	end, "partial append did not update the existing final line")
	equal(1, vim.api.nvim_win_get_cursor(stationary_win)[1], "non-tail window moved")
	equal(3, vim.api.nvim_win_get_cursor(tail_win)[1], "tail window was not pinned")

	previous = current
	append_raw(path, "-done\nsix\n")
	current = vim.uv.fs_stat(path)
	trigger(path, previous, current)
	wait_for(function()
		return vim.deep_equal(buffer_lines(buf), { "four", "five-part-done", "six" })
	end, "completed partial/new line did not append within the line bound")
	equal(3, vim.api.nvim_win_get_cursor(tail_win)[1], "tail split did not follow appended lines")
	equal(1, maximum_active_reads, "more than one file read was active")

	log_watch.command({ args = "off" })
	equal(source, vim.api.nvim_get_current_buf(), "source buffer was not restored")
	equal(false, vim.api.nvim_buf_is_valid(buf), "ephemeral tail buffer survived stop")

	vim.cmd("silent! only!")
	vim.api.nvim_buf_delete(source, { force = true })
	vim.fn.delete(path)
end)

test("LogWatch reloads bounded content after rotation and delete/recreate", function()
	local path = vim.fn.tempname()
	local rotated = path .. ".old"
	write_raw(path, "before-a\nbefore-b")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local source = vim.api.nvim_get_current_buf()
	log_watch.command({ args = "on" })
	local buf = vim.api.nvim_get_current_buf()
	assert(buf ~= source, "follow reused the source buffer")
	wait_for(function()
		return vim.deep_equal(buffer_lines(buf), { "before-a", "before-b" })
	end, "initial file did not load")

	local previous = vim.uv.fs_stat(path)
	write_raw(path, "truncated")
	local current = vim.uv.fs_stat(path)
	trigger(path, previous, current)
	wait_for(function()
		return vim.deep_equal(buffer_lines(buf), { "truncated" })
	end, "copy-truncated file did not replace the buffer")

	previous = current
	assert(vim.uv.fs_rename(path, rotated))
	write_raw(path, "rotated-a\nrotated-b")
	current = vim.uv.fs_stat(path)
	trigger(path, previous, current)
	wait_for(function()
		return vim.deep_equal(buffer_lines(buf), { "rotated-a", "rotated-b" })
	end, "rotated file did not replace the buffer")

	previous = current
	assert(vim.uv.fs_unlink(path))
	trigger(path, previous, nil)
	vim.wait(100, function()
		return false
	end, 10)
	equal({ "rotated-a", "rotated-b" }, buffer_lines(buf), "deletion destroyed the last readable tail")

	write_raw(path, "recreated")
	current = vim.uv.fs_stat(path)
	trigger(path, nil, current)
	wait_for(function()
		return vim.deep_equal(buffer_lines(buf), { "recreated" })
	end, "recreated file did not reload")

	log_watch.command({ args = "off" })
	append_raw(path, "-late")
	trigger(path, current, vim.uv.fs_stat(path))
	vim.wait(100, function()
		return false
	end, 10)
	equal(false, vim.api.nvim_buf_is_valid(buf), "stale poll callback recreated a stopped tail")
	equal({}, log_watch.status(), "stale poll callback recreated a watcher")

	vim.api.nvim_buf_delete(source, { force = true })
	vim.fn.delete(path)
	vim.fn.delete(rotated)
end)

vim.uv.fs_read = original_fs_read
vim.uv.new_fs_poll = original_new_fs_poll
vim.notify = original_notify

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("log_watch_spec: %d tests passed", count))
vim.cmd("quitall!")
