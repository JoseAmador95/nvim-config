vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local history = require("config.navigation_history")
local editor = require("config.editor")
local paths = {}

local function make_file(label)
	local path = vim.fn.tempname() .. "-" .. label
	assert(vim.fn.writefile({ label .. " one", label .. " two", label .. " three" }, path) == 0)
	paths[#paths + 1] = path
	return path
end

local function current_path()
	return vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) or vim.fs.normalize(vim.api.nvim_buf_get_name(0))
end

local function reset_editor()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modified = false
		end
	end
	pcall(vim.cmd, "silent! tabonly!")
	pcall(vim.cmd, "silent! only!")
	vim.cmd("enew!")
	history.reset()
end

test("semantic history restores exact locations across existing tabs", function()
	reset_editor()
	local first = make_file("first")
	local second = make_file("second")
	local third = make_file("third")

	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	vim.api.nvim_win_set_cursor(0, { 2, 1 })
	editor.open_file_in_tab(second, { lnum = 2, col = 2 })
	vim.api.nvim_win_set_cursor(0, { 3, 2 })
	editor.open_file_in_tab(third, { lnum = 2, col = 1 })

	local snapshot = history.snapshot()
	equal(3, #snapshot.entries, "semantic transitions did not form one browser-style stack")
	equal(3, snapshot.index, "history index did not follow the destination")

	assert(history.back({ fallback = false }), "could not navigate back to the second file")
	equal(vim.uv.fs_realpath(second), current_path(), "back did not restore the second file")
	equal({ 3, 2 }, vim.api.nvim_win_get_cursor(0), "back lost the exact second-file cursor")

	assert(history.back({ fallback = false }), "could not navigate back to the first file")
	equal(vim.uv.fs_realpath(first), current_path(), "second back did not restore the first file")
	equal({ 2, 1 }, vim.api.nvim_win_get_cursor(0), "second back lost the exact first-file cursor")

	assert(history.forward({ fallback = false }), "could not navigate forward")
	equal(vim.uv.fs_realpath(second), current_path(), "forward did not restore the second file")
	equal({ 3, 2 }, vim.api.nvim_win_get_cursor(0), "forward lost the exact second-file cursor")
end)

test("same-file semantic jumps retain both cursor positions", function()
	reset_editor()
	local path = make_file("same-file")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	vim.api.nvim_win_set_cursor(0, { 1, 2 })
	editor.open_file_in_tab(path, { lnum = 3, col = 4 })

	equal(2, #history.snapshot().entries, "same-file jump was deduplicated")
	assert(history.back({ fallback = false }), "could not go back within one file")
	equal({ 1, 2 }, vim.api.nvim_win_get_cursor(0), "same-file back lost its origin")
	assert(history.forward({ fallback = false }), "could not go forward within one file")
	equal({ 3, 3 }, vim.api.nvim_win_get_cursor(0), "same-file forward lost its destination")
end)

test("new semantic navigation truncates forward history", function()
	reset_editor()
	local first = make_file("branch-first")
	local second = make_file("branch-second")
	local third = make_file("branch-third")
	local branch = make_file("branch-new")

	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	editor.open_file_in_tab(second, { lnum = 2, col = 1 })
	editor.open_file_in_tab(third, { lnum = 3, col = 1 })
	assert(history.back({ fallback = false }), "could not establish backward branch point")
	vim.api.nvim_win_set_cursor(0, { 1, 4 })
	editor.open_file_in_tab(branch, { lnum = 2, col = 3 })

	local snapshot = history.snapshot()
	equal(3, #snapshot.entries, "forward history survived a new navigation branch")
	equal(vim.uv.fs_realpath(branch), snapshot.entries[3].path, "new destination is not the history tip")
	assert(not history.forward({ fallback = false }), "forward traversed a discarded branch")
	assert(history.back({ fallback = false }), "could not return from the new branch")
	equal(vim.uv.fs_realpath(second), current_path(), "branch back did not restore its origin")
	equal({ 1, 4 }, vim.api.nvim_win_get_cursor(0), "branch origin cursor was not refreshed")
end)

test("history restores the exact split when a file has multiple windows", function()
	reset_editor()
	local first = make_file("split-first")
	local second = make_file("split-second")

	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	editor.open_file_in_tab(second, { lnum = 2, col = 1 })
	assert(history.back({ fallback = false }), "could not return to the split fixture")
	vim.cmd("vsplit")
	local preferred_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(preferred_win, { 3, 4 })

	editor.open_file_in_tab(second, { lnum = 1, col = 1 })
	assert(history.back({ fallback = false }), "could not restore the split fixture")
	equal(preferred_win, vim.api.nvim_get_current_win(), "history restored a different window showing the same file")
	equal({ 3, 4 }, vim.api.nvim_win_get_cursor(0), "history lost the preferred split cursor")
end)

test("closed tabs are reopened without recording a recursive transition", function()
	reset_editor()
	local first = make_file("reopen-first")
	local second = make_file("reopen-second")
	local third = make_file("reopen-third")

	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	editor.open_file_in_tab(second, { lnum = 3, col = 2 })
	local second_tab = vim.api.nvim_get_current_tabpage()
	editor.open_file_in_tab(third, { lnum = 2, col = 1 })
	local third_tab = vim.api.nvim_get_current_tabpage()

	vim.api.nvim_set_current_tabpage(second_tab)
	vim.cmd("tabclose")
	vim.api.nvim_set_current_tabpage(third_tab)
	assert(history.back({ fallback = false }), "closed semantic destination was not reopened")
	equal(vim.uv.fs_realpath(second), current_path(), "reopened history landed on the wrong file")
	equal({ 3, 1 }, vim.api.nvim_win_get_cursor(0), "reopened history lost its cursor")
	equal(3, #history.snapshot().entries, "history restoration recorded itself")
end)

test("setup exposes commands and back-forward mappings", function()
	history.reset()
	assert(not history.back({ fallback = false }), "empty semantic history unexpectedly navigated")
	equal(0, #history.snapshot().entries, "an empty traversal seeded semantic history")
	history.setup()
	for _, command in ipairs({ "NavigationBack", "NavigationForward", "NavigationHistory" }) do
		equal(2, vim.fn.exists(":" .. command), command .. " was not registered")
	end
	equal("Navigation back", vim.fn.maparg("<C-o>", "n", false, true).desc, "back mapping")
	equal("Navigation forward", vim.fn.maparg("<C-i>", "n", false, true).desc, "forward mapping")
end)

for _, path in ipairs(paths) do
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == path then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	vim.fn.delete(path)
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("navigation_history_spec: %d tests passed", count))
vim.cmd("quitall!")
