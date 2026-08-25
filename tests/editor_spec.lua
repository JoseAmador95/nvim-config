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

local editor = require("config.editor")
local history = require("config.navigation_history")
local tabs = require("config.tabs")
local paths = {}

local function make_file(label)
	local path = vim.fn.tempname() .. "-" .. label
	assert(vim.fn.writefile({ label .. " one", label .. " two", label .. " three" }, path) == 0)
	paths[#paths + 1] = path
	return path
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
	tabs.unmark_home(vim.api.nvim_get_current_tabpage())
	tabs.unmark_transient(vim.api.nvim_get_current_tabpage())
	history.reset()
end

test("source opening never reuses a file shown only in a transient tab", function()
	reset_editor()
	local path = make_file("transient-only")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local transient = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_transient(transient, "Review: transient-only"), "could not mark source fixture transient")

	editor.open_file_in_tab(path, { lnum = 2, col = 3 })
	local current = vim.api.nvim_get_current_tabpage()
	assert(current ~= transient, "source opening reused the transient tab")
	assert(not tabs.is_transient(current), "source opening created another transient tab")
	equal(2, #vim.api.nvim_list_tabpages(), "source opening did not create a normal tab")
	equal({ 2, 2 }, vim.api.nvim_win_get_cursor(0), "source opening lost its cursor target")
end)

test("source opening prefers an existing normal tab over a duplicate transient view", function()
	reset_editor()
	local path = make_file("normal-and-transient")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local normal = vim.api.nvim_get_current_tabpage()
	vim.cmd("tab split")
	local transient = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_transient(transient, "Review: duplicate"), "could not mark duplicate transient")

	editor.open_file_in_tab(path, { lnum = 3, col = 2 })
	equal(normal, vim.api.nvim_get_current_tabpage(), "source opening did not prefer the normal tab")
	equal(2, #vim.api.nvim_list_tabpages(), "source opening created an unnecessary tab")
	equal({ 3, 1 }, vim.api.nvim_win_get_cursor(0), "normal tab reuse lost its cursor target")
end)

test("normal semantic navigation remains recorded when the destination also has a transient view", function()
	reset_editor()
	local origin_path = make_file("record-origin")
	local target_path = make_file("record-target")
	vim.cmd("edit! " .. vim.fn.fnameescape(origin_path))
	local origin = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabedit " .. vim.fn.fnameescape(target_path))
	local transient = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_transient(transient, "Review: recorded target"), "could not mark semantic fixture transient")
	vim.api.nvim_set_current_tabpage(origin)
	history.reset()

	editor.open_file_in_tab(target_path, { lnum = 2, col = 1 })
	local destination = vim.api.nvim_get_current_tabpage()
	assert(destination ~= transient and not tabs.is_transient(destination), "semantic destination reused transient UI")
	local snapshot = history.snapshot()
	equal(2, #snapshot.entries, "normal semantic transition was not recorded")
	equal(vim.uv.fs_realpath(origin_path), snapshot.entries[1].path, "semantic origin changed")
	equal(vim.uv.fs_realpath(target_path), snapshot.entries[2].path, "semantic destination changed")
end)

test("review composer opens with save and cancel mappings", function()
	reset_editor()
	local result = "pending"
	local interrupted = false
	require("config.review_editor").compose({ title = "Fixture", body = "Draft" }, function(body, was_interrupted)
		result = body
		interrupted = was_interrupted == true
	end)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	assert(require("config.review_editor").has_active())
	assert(vim.api.nvim_win_get_config(win).relative == "editor")
	for _, mapping in ipairs({ "q", "<Esc>", "<C-s>" }) do
		assert(vim.fn.maparg(mapping, "n", false, true).buffer == 1, mapping .. " is not buffer-local")
	end
	vim.api.nvim_win_close(win, true)
	assert(result == "Draft" and interrupted and not vim.api.nvim_buf_is_valid(buf))
	assert(not require("config.review_editor").has_active())
end)

test("review composer remains open when its submit callback rejects the save", function()
	reset_editor()
	local accept = false
	local calls = 0
	require("config.review_editor").compose({ title = "Fixture", body = "Keep this" }, function(body)
		assert(body == "Keep this")
		calls = calls + 1
		return accept
	end)
	vim.cmd("stopinsert")
	local submit = vim.fn.maparg("<C-s>", "n", false, true).callback
	assert(type(submit) == "function")
	submit()
	assert(calls == 1 and require("config.review_editor").has_active())
	accept = true
	submit()
	assert(calls == 2 and not require("config.review_editor").has_active())
end)

test("review composer can persist synchronously before global teardown", function()
	reset_editor()
	local body
	local interrupted
	local editor = require("config.review_editor")
	editor.compose({ title = "Fixture", body = "Exit draft" }, function(value, was_interrupted)
		body = value
		interrupted = was_interrupted
		return true
	end)
	assert(editor.persist_active())
	assert(body == "Exit draft" and interrupted == true)
	assert(not editor.has_active())
end)

test("review composer uses durable fallback when teardown submission is rejected", function()
	reset_editor()
	local recovered
	local editor = require("config.review_editor")
	editor.compose({
		title = "Fixture",
		body = "Rejected exit draft",
		recover = function(body)
			recovered = body
			return true
		end,
	}, function()
		return false
	end)
	assert(editor.persist_active())
	assert(recovered == "Rejected exit draft")
	assert(not editor.has_active())
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

print(string.format("editor_spec: %d tests passed", count))
vim.cmd("quitall!")
