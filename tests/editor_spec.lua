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
local review_source = require("config.review_source")
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
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		review_source.clear(tabpage)
	end
	review_source.prune()
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

test("review lineage follows a new semantic destination outside the reviewed repository", function()
	reset_editor()
	local origin_path = make_file("review-lineage-origin")
	local target_path = make_file("review-lineage-external")
	vim.cmd("edit! " .. vim.fn.fnameescape(origin_path))
	local origin_tab = vim.api.nvim_get_current_tabpage()
	local workspace = { root = "/tmp/review-lineage-repository" }
	local target = {
		current_path = "lua/config/example.lua",
		layer = "working",
		revision = "LOCAL",
		side = "right",
		line = 17,
		column = 4,
	}
	assert(review_source.set(origin_tab, workspace, target))

	editor.open_file_in_tab(target_path, { lnum = 2, col = 1 })
	local destination_tab = vim.api.nvim_get_current_tabpage()
	assert(destination_tab ~= origin_tab, "semantic navigation did not create a destination tab")
	local link = review_source.get(destination_tab)
	assert(link and link.workspace == workspace, "new destination lost its review workspace")
	equal(target, link.target, "new destination lost its exact review target")
	local snapshot = history.snapshot()
	equal(2, #snapshot.entries, "review lineage changed semantic history recording")
	equal(vim.uv.fs_realpath(origin_path), snapshot.entries[1].path, "review semantic origin changed")
	equal(vim.uv.fs_realpath(target_path), snapshot.entries[2].path, "review semantic destination changed")
end)

test("the newest navigation lineage replaces a reused destination link", function()
	reset_editor()
	local first_origin_path = make_file("review-lineage-first")
	local second_origin_path = make_file("review-lineage-second")
	local unlinked_origin_path = make_file("review-lineage-unlinked")
	local target_path = make_file("review-lineage-reused")
	vim.cmd("edit! " .. vim.fn.fnameescape(target_path))
	local destination_tab = vim.api.nvim_get_current_tabpage()
	local previous_workspace = { root = "/tmp/previous-review" }
	assert(review_source.set(destination_tab, previous_workspace, { current_path = "previous.lua" }))

	vim.cmd("tabedit " .. vim.fn.fnameescape(first_origin_path))
	local first_origin_tab = vim.api.nvim_get_current_tabpage()
	local first_workspace = { root = "/tmp/first-review" }
	assert(review_source.set(first_origin_tab, first_workspace, { current_path = "first.lua" }))
	editor.open_file_in_tab(target_path)
	assert(review_source.get(destination_tab).workspace == first_workspace)

	vim.cmd("tabedit " .. vim.fn.fnameescape(second_origin_path))
	local second_workspace = { root = "/tmp/second-review" }
	local second_target = { current_path = "second.lua", line = 9, column = 2 }
	assert(review_source.set(vim.api.nvim_get_current_tabpage(), second_workspace, second_target))
	editor.open_file_in_tab(target_path)
	local link = review_source.get(destination_tab)
	assert(link and link.workspace == second_workspace, "reused destination kept an older review")
	equal(second_target, link.target, "reused destination kept an older return target")

	vim.cmd("tabedit " .. vim.fn.fnameescape(unlinked_origin_path))
	review_source.clear(vim.api.nvim_get_current_tabpage())
	editor.open_file_in_tab(target_path)
	link = review_source.get(destination_tab)
	assert(link and link.workspace == second_workspace, "unlinked navigation cleared destination lineage")
	equal(second_target, link.target, "unlinked navigation changed the destination return target")
end)

test("review lineage follows source opening through the home tab", function()
	reset_editor()
	local origin_path = make_file("review-lineage-home-origin")
	local target_path = make_file("review-lineage-home-target")
	vim.cmd("edit! " .. vim.fn.fnameescape(origin_path))
	local origin_tab = vim.api.nvim_get_current_tabpage()
	local workspace = { root = "/tmp/home-review" }
	local target = { current_path = "home.lua", layer = "staged", line = 3, column = 1 }
	assert(review_source.set(origin_tab, workspace, target))
	vim.cmd("tabnew")
	local home_tab = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_home(home_tab), "could not create home-tab fixture")
	vim.api.nvim_set_current_tabpage(origin_tab)

	editor.open_file_in_tab(target_path)
	equal(home_tab, vim.api.nvim_get_current_tabpage(), "source opening did not reuse the home tab")
	local link = review_source.get(home_tab)
	assert(link and link.workspace == workspace, "home destination lost its review workspace")
	equal(target, link.target, "home destination lost its exact review target")
end)

test("review lineage migrates, clears, and prunes closed source tabs", function()
	reset_editor()
	local previous = { root = "/tmp/review-lineage-previous" }
	local replacement = { root = previous.root }
	local target = { current_path = "kept.lua", line = 5, column = 6 }
	local live_tab = vim.api.nvim_get_current_tabpage()
	assert(review_source.set(live_tab, previous, target))
	vim.cmd("tabnew")
	local closed_tab = vim.api.nvim_get_current_tabpage()
	assert(review_source.set(closed_tab, previous, target))
	vim.cmd("tabclose")
	equal(1, review_source.prune(), "closed source tab was not pruned")
	equal(1, review_source.migrate(previous, replacement), "live source lineage was not migrated")
	local link = review_source.get(live_tab)
	assert(link and link.workspace == replacement, "source lineage kept the replaced workspace")
	equal(target, link.target, "workspace migration changed the exact return target")
	equal(1, review_source.clear_workspace(replacement), "replacement lineage was not cleared")
	assert(review_source.get(live_tab) == nil, "review closure left source lineage behind")
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
