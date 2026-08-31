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

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		table.insert(failures, name .. "\n" .. err)
	end
end

local function make_file(lines)
	local path = vim.fn.tempname()
	assert(vim.fn.writefile(lines, path) == 0, "could not create temporary file")
	return path
end

local function delete_file_buffer(path)
	local buf = vim.fn.bufnr(path)
	if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	vim.fn.delete(path)
end

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, opts)
	table.insert(notifications, { message = tostring(message), level = level, opts = opts })
end

local original_new_fs_poll = vim.uv.new_fs_poll
local poll_mode = "ok"
local poll_callback
local poll_creations = 0

vim.uv.new_fs_poll = function()
	poll_creations = poll_creations + 1
	local handle = { closed = false, stopped = false }

	function handle:start(_, _, callback)
		poll_callback = callback
		if poll_mode == "fail" then
			return nil, "simulated start failure", "EFAIL"
		end
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

local log_watch = require("config.log_watch")

test("LogWatch refuses modified buffers without mutation", function()
	local path = make_file({ "disk" })
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].filetype = "text"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })

	local creations_before = poll_creations
	log_watch.command({ args = "on" })

	equal(creations_before, poll_creations, "a watcher must not be created")
	equal({ "unsaved" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "buffer contents changed")
	equal("text", vim.bo[buf].filetype, "filetype changed")
	equal(true, vim.bo[buf].modifiable, "modifiable changed")
	equal(false, vim.bo[buf].readonly, "readonly changed")
	equal(true, vim.bo[buf].modified, "modified changed")
	assert(notifications[#notifications].message:find("unsaved changes", 1, true), "missing refusal notification")

	delete_file_buffer(path)
end)

test("LogWatch restores exact state and ignores a late callback", function()
	local path = make_file({ "first", "second" })
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].filetype = "text"
	vim.bo[buf].readonly = true
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	poll_mode = "ok"
	poll_callback = nil

	log_watch.command({ args = "on" })
	local tail = vim.api.nvim_get_current_buf()
	assert(tail ~= buf, "watch mode reused the source buffer")
	equal("log", vim.bo[tail].filetype, "tail did not set log filetype")
	equal("text", vim.bo[buf].filetype, "source filetype changed")
	assert(poll_callback, "watch callback was not registered")

	log_watch.command({ args = "off" })
	equal(buf, vim.api.nvim_get_current_buf(), "source buffer was not restored")
	equal(false, vim.api.nvim_buf_is_valid(tail), "tail buffer survived stop")
	equal("text", vim.bo[buf].filetype, "filetype was not restored")
	equal(false, vim.bo[buf].modifiable, "modifiable was not restored")
	equal(true, vim.bo[buf].readonly, "readonly was not restored")
	equal(false, vim.bo[buf].modified, "modified was not restored")

	poll_callback(nil)
	local drained = false
	vim.schedule(function()
		drained = true
	end)
	assert(
		vim.wait(1000, function()
			return drained
		end, 10),
		"scheduled callback did not drain"
	)

	equal("text", vim.bo[buf].filetype, "late callback changed filetype")
	equal(false, vim.bo[buf].modifiable, "late callback changed modifiable")
	equal(true, vim.bo[buf].readonly, "late callback changed readonly")

	delete_file_buffer(path)
end)

test("LogWatch startup failure preserves buffer state", function()
	local path = make_file({ "disk" })
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].filetype = "text"
	vim.bo[buf].readonly = true
	vim.bo[buf].modifiable = false
	poll_mode = "fail"

	log_watch.command({ args = "on" })
	equal("text", vim.bo[buf].filetype, "filetype changed after watcher failure")
	equal(false, vim.bo[buf].modifiable, "modifiable changed after watcher failure")
	equal(true, vim.bo[buf].readonly, "readonly changed after watcher failure")
	assert(notifications[#notifications].message:find("simulated start failure", 1, true), "missing failure detail")

	delete_file_buffer(path)
end)

vim.uv.new_fs_poll = original_new_fs_poll
vim.notify = original_notify

test("editor reuses a file in a non-current split", function()
	local target = make_file({ "first", "second", "third" })
	local other = make_file({ "other" })
	vim.cmd("edit! " .. vim.fn.fnameescape(target))
	local target_win = vim.api.nvim_get_current_win()
	vim.cmd("vsplit " .. vim.fn.fnameescape(other))
	assert(vim.api.nvim_get_current_win() ~= target_win, "test setup did not leave the target split")

	local tab_count = #vim.api.nvim_list_tabpages()
	require("config.editor").open_file_in_tab(target, { lnum = 2, col = 2 })

	equal(tab_count, #vim.api.nvim_list_tabpages(), "navigation created a duplicate tab")
	equal(target_win, vim.api.nvim_get_current_win(), "navigation did not focus the target split")
	equal({ 2, 1 }, vim.api.nvim_win_get_cursor(target_win), "navigation did not set the requested cursor")

	vim.cmd("silent! only!")
	delete_file_buffer(other)
	delete_file_buffer(target)
end)

test("trailing whitespace cleanup preserves complete per-window views", function()
	local lines = {}
	for index = 1, 80 do
		lines[index] = string.format("line-%03d", index)
	end
	lines[5] = lines[5] .. "   "
	lines[75] = lines[75] .. "\t "

	local path = make_file(lines)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local buf = vim.api.nvim_get_current_buf()
	local first_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(first_win, { 20, 0 })
	vim.cmd("normal! $zt")

	vim.cmd("vsplit")
	local second_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(second_win, { 60, 0 })
	vim.cmd("normal! $zt")

	local before = {}
	for _, win in ipairs({ first_win, second_win }) do
		before[win] = vim.api.nvim_win_call(win, function()
			return vim.fn.winsaveview()
		end)
		assert(before[win].curswant == 2147483647, "test did not establish a virtual end-of-line column")
	end

	assert(require("config.whitespace").trim(buf), "cleanup was unexpectedly skipped")
	equal("line-005", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1], "spaces were not removed")
	equal("line-075", vim.api.nvim_buf_get_lines(buf, 74, 75, false)[1], "mixed whitespace was not removed")

	for _, win in ipairs({ first_win, second_win }) do
		local after = vim.api.nvim_win_call(win, function()
			return vim.fn.winsaveview()
		end)
		equal(before[win], after, "cleanup changed a window view")
	end

	vim.cmd("silent! only!")
	delete_file_buffer(path)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("core_spec: %d tests passed", 5))
vim.cmd("quitall!")
