vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/tab-first.nvim"
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/native-review.nvim")
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

local review_editor = require("config.native_review").editor

local function review_source_fixture()
	local lines = {}
	for index = 1, 20 do
		lines[index] = "anchor fixture " .. index
	end
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(), lines
end

local function reservation(buf)
	local found
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, review_editor._namespace, 0, -1, { details = true })) do
		if mark[4].virt_lines then
			assert(not found, "review editor leaked more than one source reservation")
			found = mark
		end
	end
	return found
end

local function inline_footer(source_win, body_win)
	local found
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if win ~= body_win then
			local config = vim.api.nvim_win_get_config(win)
			if config.relative == "win" and config.win == source_win and config.focusable == false then
				assert(not found, "inline composer opened more than one footer")
				found = win
			end
		end
	end
	return found
end

local function window_text(win)
	return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

local function border_text(value)
	if type(value) == "string" then
		return value
	end
	local chunks = {}
	for _, chunk in ipairs(value or {}) do
		chunks[#chunks + 1] = type(chunk) == "table" and chunk[1] or tostring(chunk)
	end
	return table.concat(chunks)
end

local function chunk_highlight(value, needle)
	for _, chunk in ipairs(type(value) == "table" and value or {}) do
		if type(chunk) == "table" and tostring(chunk[1]):find(needle, 1, true) then
			return chunk[2]
		end
	end
	return nil
end

local function invoke_cycle_and_assert_insert(mapping, message)
	assert(mapping.buffer == 1 and type(mapping.callback) == "function", message .. " mapping is missing")
	local queued
	local original_schedule = vim.schedule
	vim.schedule = function(callback)
		queued = callback
	end
	mapping.callback()
	vim.schedule = original_schedule
	assert(type(queued) == "function", message .. " did not schedule its Insert transition")
	local entered_insert = false
	local original_cmd = vim.cmd
	vim.cmd = function(command)
		if command == "startinsert" then
			entered_insert = true
			return
		end
		return original_cmd(command)
	end
	queued()
	vim.cmd = original_cmd
	assert(entered_insert, message .. " did not request Insert mode")
end

local function namespace_marks(buf)
	return vim.api.nvim_buf_get_extmarks(buf, review_editor._namespace, 0, -1, { details = true })
end

local function namespace_windows()
	if type(vim.api.nvim__ns_get) == "function" then
		return vim.api.nvim__ns_get(review_editor._namespace).wins
	end
	return nil
end

test("range composer uses a focused body and separate reserved footer", function()
	reset_editor()
	local source_win, source_buf, source_lines = review_source_fixture()
	local result = "pending"
	local interrupted = false
	assert(review_editor.compose({
		title = "Fixture",
		body = "Draft",
		style = "minimal",
		source_win = source_win,
		anchor_line = 2,
		anchor = { kind = "range", start_line = 2, end_line = 2 },
	}, function(body, was_interrupted)
		result = body
		interrupted = was_interrupted == true
	end))
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local config = vim.api.nvim_win_get_config(win)
	local footer = assert(inline_footer(source_win, win), "inline footer is missing")
	local footer_buf = vim.api.nvim_win_get_buf(footer)
	local footer_config = vim.api.nvim_win_get_config(footer)
	assert(review_editor.has_active())
	assert(config.relative == "win" and config.win == source_win)
	equal({ 1, 0 }, config.bufpos, "composer was not attached below the one-based source anchor")
	assert(config.border == "none" and config.height == 1)
	local mark = assert(reservation(source_buf), "source reservation is missing")
	assert(mark[2] == 1 and #mark[4].virt_lines == 2, "source reservation does not include the footer")
	assert(footer_config.relative == "win" and footer_config.win == source_win)
	equal({ 1, 0 }, footer_config.bufpos, "footer was not attached to the range endpoint")
	assert(footer_config.row == 2 and footer_config.height == 1 and footer_config.focusable == false)
	assert(vim.wo[footer].wrap == false and vim.bo[buf].filetype == "markdown")
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "composer mutated source text")
	assert(window_text(footer):find("Fixture", 1, true) and window_text(footer):find("<C-s> / <CR><CR> save", 1, true))
	assert(not window_text(footer):find("<Tab> type", 1, true))
	assert(vim.fn.strdisplaywidth(window_text(footer)) <= config.width)
	assert(#namespace_marks(buf) == 0, "inline instructions still overlap the Markdown body")
	for _, mapping in ipairs({ "q", "<Esc>", "<C-s>", "<CR><CR>" }) do
		assert(vim.fn.maparg(mapping, "n", false, true).buffer == 1, mapping .. " is not buffer-local")
	end
	assert(vim.fn.maparg("<CR><CR>", "n", false, true).nowait == 0, "double Enter unexpectedly uses nowait")
	assert(vim.fn.maparg("<CR>", "i", false, true).buffer ~= 1, "Insert Enter stopped being an ordinary newline")
	vim.api.nvim_win_close(win, true)
	assert(result == "Draft" and interrupted and not vim.api.nvim_buf_is_valid(buf))
	assert(not vim.api.nvim_win_is_valid(footer) and not vim.api.nvim_buf_is_valid(footer_buf))
	assert(not review_editor.has_active() and not reservation(source_buf))
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "teardown mutated source text")
end)

test("card composer owns one inline float with type-colored chrome and two reserved rows", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	assert(review_editor.compose({
		title = "New",
		body = "Card draft",
		style = "card",
		type_cycle = true,
		selected_type = "issue",
		source_win = source_win,
		anchor = { kind = "range", start_line = 3, end_line = 3 },
	}, function()
		return true
	end))
	local composer = vim.api.nvim_get_current_win()
	local config = vim.api.nvim_win_get_config(composer)
	assert(not inline_footer(source_win, composer), "card composer created a second visual footer")
	assert(type(config.border) == "table" and #config.border == 8)
	assert(config.width == vim.api.nvim_win_get_width(source_win) - (vim.fn.getwininfo(source_win)[1].textoff or 0) - 2)
	assert(#reservation(source_buf)[4].virt_lines == config.height + 2)
	assert(chunk_highlight(config.title, "issue") == "NvimReviewCommentIssue")
	assert(chunk_highlight(config.footer, "issue") == "NvimReviewCommentIssue")
	assert(config.border[1][2] == "NvimReviewCommentIssue" and config.border[8][2] == "NvimReviewCommentIssue")
	vim.cmd("stopinsert")
	invoke_cycle_and_assert_insert(vim.fn.maparg("<Tab>", "n", false, true), "Normal-mode card Tab")
	config = vim.api.nvim_win_get_config(composer)
	assert(chunk_highlight(config.title, "suggestion") == "NvimReviewCommentSuggestion")
	assert(chunk_highlight(config.footer, "suggestion") == "NvimReviewCommentSuggestion")
	assert(config.border[1][2] == "NvimReviewCommentSuggestion")
	vim.cmd("stopinsert")
	vim.fn.maparg("q", "n", false, true).callback()
	assert(not review_editor.has_active() and not reservation(source_buf))
end)

test("range reservation renders only in its source window", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	vim.cmd("vsplit")
	local sibling = vim.api.nvim_get_current_win()
	assert(vim.api.nvim_win_get_buf(sibling) == source_buf)
	assert(review_editor.compose({
		title = "Scoped",
		body = "Only the source window reserves this",
		style = "minimal",
		source_win = source_win,
		anchor = { kind = "range", start_line = 2, end_line = 2 },
	}, function()
		return true
	end))
	local scoped = namespace_windows()
	if scoped then
		equal({ source_win }, scoped, "inline reservation namespace escaped to the same-buffer sibling")
	end
	assert(reservation(source_buf), "scoped inline reservation is missing")
	vim.cmd("stopinsert")
	vim.fn.maparg("q", "n", false, true).callback()
	local unscoped = namespace_windows()
	if unscoped then
		equal({}, unscoped, "inline teardown retained its source-window namespace scope")
	end
	assert(not reservation(source_buf) and not review_editor.has_active())
	vim.api.nvim_win_close(sibling, true)
end)

test("review composer rejects invalid sources and canonical anchor kinds cleanly", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local notifications = {}
	local original_notify = vim.notify
	vim.notify = function(message)
		notifications[#notifications + 1] = message
	end
	assert(
		not review_editor.compose(
			{ body = "Missing source", anchor_line = 1, anchor = { kind = "range", start_line = 1, end_line = 1 } },
			function() end
		)
	)
	assert(not review_editor.compose({ body = "Missing anchor", source_win = source_win }, function() end))
	assert(
		not review_editor.compose(
			{ body = "Unsupported", source_win = source_win, anchor = { kind = "thread" } },
			function() end
		)
	)
	assert(
		not review_editor.compose(
			{ body = "Missing range", source_win = source_win, anchor = { kind = "range" } },
			function() end
		)
	)
	assert(not review_editor.compose({
		body = "Outside source",
		source_win = source_win,
		anchor_line = 99,
		anchor = { kind = "range", start_line = 99, end_line = 99 },
	}, function() end))
	vim.notify = original_notify
	assert(#notifications == 5 and not review_editor.has_active() and not reservation(source_buf))
	assert(notifications[2] == "Review editor anchor kind is missing")
	assert(notifications[3] == "Review editor anchor kind is not supported: thread")
end)

test("inline namespace scope failure leaves no editor resources", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local api_name
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		api_name = "nvim_win_add_ns"
	elseif type(vim.api.nvim__ns_set) == "function" then
		api_name = "nvim__ns_set"
	end
	assert(api_name, "Neovim has no window-scoped namespace API")
	local original_scope = vim.api[api_name]
	local original_notify = vim.notify
	local notifications = {}
	local buffers_before = #vim.api.nvim_list_bufs()
	local windows_before = #vim.api.nvim_list_wins()
	vim.api[api_name] = function()
		error("simulated editor namespace failure")
	end
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	local called, opened = pcall(review_editor.compose, {
		title = "Scope failure",
		body = "Must not leak",
		source_win = source_win,
		anchor = { kind = "range", start_line = 3, end_line = 3 },
	}, function() end)
	vim.api[api_name] = original_scope
	vim.notify = original_notify
	assert(called and not opened, opened)
	assert(notifications[#notifications]:find("simulated editor namespace failure", 1, true))
	assert(#vim.api.nvim_list_bufs() == buffers_before and #vim.api.nvim_list_wins() == windows_before)
	assert(not review_editor.has_active() and #namespace_marks(source_buf) == 0)
	local unscoped = namespace_windows()
	if unscoped then
		equal({}, unscoped, "scope failure retained a source-window association")
	end
end)

test("rejected review save keeps the editor and reservation until acceptance", function()
	reset_editor()
	local source_win, source_buf, source_lines = review_source_fixture()
	local accept = false
	local calls = 0
	assert(review_editor.compose({
		title = "Fixture",
		body = "Keep this",
		source_win = source_win,
		anchor_line = 3,
		anchor = { kind = "range", start_line = 3, end_line = 3 },
	}, function(body)
		assert(body == "Keep this")
		calls = calls + 1
		return accept
	end))
	vim.cmd("stopinsert")
	local submit = vim.fn.maparg("<C-s>", "n", false, true).callback
	local submit_double_enter = vim.fn.maparg("<CR><CR>", "n", false, true).callback
	assert(type(submit) == "function")
	assert(type(submit_double_enter) == "function")
	local before = assert(reservation(source_buf))[1]
	submit()
	assert(calls == 1 and review_editor.has_active())
	assert(reservation(source_buf)[1] == before, "rejected save discarded or replaced its reservation")
	submit_double_enter()
	assert(calls == 2 and review_editor.has_active())
	assert(reservation(source_buf)[1] == before, "rejected double-Enter save discarded its reservation")
	accept = true
	submit_double_enter()
	assert(calls == 3 and not review_editor.has_active() and not reservation(source_buf))
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "save mutated source text")
end)

test("empty double-Enter save keeps the editor and reservation", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local calls = 0
	local notifications = {}
	local original_notify = vim.notify
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	assert(review_editor.compose({
		title = "Empty",
		source_win = source_win,
		anchor_line = 3,
		anchor = { kind = "range", start_line = 3, end_line = 3 },
	}, function()
		calls = calls + 1
		return true
	end))
	vim.cmd("stopinsert")
	local buf = vim.api.nvim_get_current_buf()
	local submit_double_enter = vim.fn.maparg("<CR><CR>", "n", false, true).callback
	submit_double_enter()
	assert(calls == 0 and review_editor.has_active() and reservation(source_buf))
	assert(notifications[#notifications] == "Review comment cannot be empty")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "accepted" })
	submit_double_enter()
	vim.notify = original_notify
	assert(calls == 1 and not review_editor.has_active() and not reservation(source_buf))
end)

test("review composer persists synchronously and recovers one rejected teardown", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local submitted = 0
	local recovered = 0
	assert(review_editor.compose({
		title = "Fixture",
		body = "Rejected exit draft",
		source_win = source_win,
		anchor_line = 4,
		anchor = { kind = "range", start_line = 4, end_line = 4 },
		recover = function(body)
			assert(body == "Rejected exit draft")
			recovered = recovered + 1
			return true
		end,
	}, function(body, interrupted)
		assert(body == "Rejected exit draft" and interrupted == true)
		submitted = submitted + 1
		return false
	end))
	assert(review_editor.persist_active())
	assert(submitted == 1 and recovered == 1)
	assert(not review_editor.has_active() and not reservation(source_buf))
end)

test("prepare close cancels an empty composer without submitting it", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local calls = 0
	local cancelled
	assert(review_editor.prepare_close())
	assert(review_editor.compose({
		title = "Empty close",
		source_win = source_win,
		anchor = { kind = "general" },
	}, function(body)
		calls = calls + 1
		cancelled = body
		return true
	end))
	assert(review_editor.prepare_close())
	assert(calls == 1 and cancelled == nil)
	assert(not review_editor.has_active() and not reservation(source_buf))
end)

test("prepare close vetoes teardown until a nonempty draft is saved or recovered", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local recover = false
	local submitted = 0
	local recovered = 0
	assert(review_editor.compose({
		title = "Close recovery",
		body = "Keep me",
		source_win = source_win,
		anchor = { kind = "general" },
		recover = function(body)
			assert(body == "Keep me")
			recovered = recovered + 1
			return recover
		end,
	}, function(body, interrupted)
		assert(body == "Keep me" and interrupted == true)
		submitted = submitted + 1
		return false
	end))
	assert(not review_editor.prepare_close())
	assert(submitted == 1 and recovered == 1 and review_editor.has_active())
	assert(reservation(source_buf) == nil, "modal composer unexpectedly reserved source rows")
	recover = true
	assert(review_editor.prepare_close())
	assert(submitted == 2 and recovered == 2 and not review_editor.has_active())
end)

test("minimal composer cycles type in Normal and Insert modes and preserves the colored badge", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local submitted_type
	local recovered_type
	assert(review_editor.compose({
		title = "New",
		body = "Typed draft",
		style = "minimal",
		source_win = source_win,
		anchor_line = 5,
		anchor = { kind = "range", start_line = 5, end_line = 5 },
		type_cycle = true,
		selected_type = "issue",
		recover = function(body, selected_type)
			assert(body == "Typed draft")
			recovered_type = selected_type
			return true
		end,
	}, function(_, _, selected_type)
		submitted_type = selected_type
		return false
	end))
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local footer = assert(inline_footer(source_win, win))
	vim.cmd("stopinsert")
	local tab = vim.fn.maparg("<Tab>", "n", false, true)
	local insert_tab = vim.fn.maparg("<Tab>", "i", false, true)
	local insert_backtab = vim.fn.maparg("<S-Tab>", "i", false, true)
	assert(tab.buffer == 1 and type(tab.callback) == "function")
	assert(insert_tab.buffer == 1 and type(insert_tab.callback) == "function")
	assert(insert_backtab.buffer == 1 and type(insert_backtab.callback) == "function")
	invoke_cycle_and_assert_insert(tab, "Normal-mode Tab")
	assert(
		window_text(footer):find("New ◆ suggestion", 1, true)
			and window_text(footer):find("<Tab>/<S-Tab> type", 1, true)
	)
	local marks = vim.api.nvim_buf_get_extmarks(
		vim.api.nvim_win_get_buf(footer),
		review_editor._footer_namespace,
		0,
		-1,
		{ details = true }
	)
	assert(#marks == 1 and marks[1][4].hl_group == "NvimReviewCommentSuggestion")
	invoke_cycle_and_assert_insert(insert_backtab, "Insert-mode Shift-Tab")
	assert(window_text(footer):find("New ● issue", 1, true))
	invoke_cycle_and_assert_insert(insert_tab, "Insert-mode Tab")
	assert(window_text(footer):find("New ◆ suggestion", 1, true))
	assert(review_editor.persist_active())
	assert(submitted_type == "suggestion" and recovered_type == "suggestion")
	assert(not review_editor.has_active() and not reservation(source_buf))
end)

test("review composer grows from one to six screen rows and scrolls overflow", function()
	reset_editor()
	local source_win, source_buf, source_lines = review_source_fixture()
	assert(review_editor.compose({
		title = "Anchored",
		body = "one",
		style = "minimal",
		source_win = source_win,
		anchor_range = { first = 4, last = 6 },
		anchor = { kind = "range", start_line = 4, end_line = 6 },
	}, function()
		return true
	end))
	local float = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local footer = assert(inline_footer(source_win, float))
	assert(vim.api.nvim_win_get_height(float) == 1 and #reservation(source_buf)[4].virt_lines == 2)
	assert(vim.api.nvim_win_get_config(footer).row == 2)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf, modeline = false })
	assert(vim.api.nvim_win_get_height(float) == 3 and #reservation(source_buf)[4].virt_lines == 4)
	assert(vim.api.nvim_win_get_config(footer).row == 4)
	local overflow = {}
	for index = 1, 9 do
		overflow[index] = "draft line " .. index
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, overflow)
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf, modeline = false })
	local capped_height = vim.api.nvim_win_get_height(float)
	local capped_reservation = #reservation(source_buf)[4].virt_lines
	assert(
		capped_height == 6 and capped_reservation == 7,
		("overflow geometry was height=%d reservation=%d lines=%d autocmds=%d"):format(
			capped_height,
			capped_reservation,
			vim.api.nvim_buf_line_count(buf),
			#vim.api.nvim_get_autocmds({ event = "TextChanged", buffer = buf })
		)
	)
	local footer_config = vim.api.nvim_win_get_config(footer)
	assert(footer_config.row == 7 and footer_config.height == 1 and footer_config.focusable == false)
	assert(vim.wo[footer].wrap == false and #namespace_marks(buf) == 0)
	vim.api.nvim_win_set_cursor(float, { #overflow, 0 })
	vim.cmd("redraw")
	local view = vim.api.nvim_win_call(float, vim.fn.winsaveview)
	assert(view.topline > 1, "content beyond six rows did not scroll")
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "resize mutated source text")
	vim.cmd("stopinsert")
	vim.fn.maparg("<Esc>", "n", false, true).callback()
	assert(not review_editor.has_active() and not reservation(source_buf))
end)

test("inline resize keeps a compact footer below the body and footer closure tears down once", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	vim.cmd("vsplit")
	vim.api.nvim_win_set_width(source_win, 42)
	local callbacks = 0
	assert(review_editor.compose({
		title = "A deliberately long review title",
		body = string.rep("wrapped text ", 12),
		style = "minimal",
		type_cycle = true,
		selected_type = "issue",
		source_win = source_win,
		anchor = { kind = "range", start_line = 8, end_line = 8 },
	}, function(body, interrupted)
		assert(body == string.rep("wrapped text ", 12) and interrupted == true)
		callbacks = callbacks + 1
		return true
	end))
	local body_win = vim.api.nvim_get_current_win()
	local footer = assert(inline_footer(source_win, body_win))
	local before = vim.api.nvim_win_get_config(body_win)
	vim.api.nvim_win_set_width(source_win, 28)
	vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
	local body_config = vim.api.nvim_win_get_config(body_win)
	local footer_config = vim.api.nvim_win_get_config(footer)
	assert(body_config.width < before.width and body_config.height <= 6)
	assert(footer_config.width == body_config.width and footer_config.row == body_config.height + 1)
	assert(#reservation(source_buf)[4].virt_lines == body_config.height + 1)
	assert(vim.fn.strdisplaywidth(window_text(footer)) <= body_config.width)
	assert(window_text(footer):find("issue", 1, true) and window_text(footer):find("<C-s>", 1, true))
	assert(window_text(footer):find("save", 1, true), "compact footer lost its save semantics")
	vim.api.nvim_win_close(footer, true)
	assert(callbacks == 1 and not review_editor.has_active() and not reservation(source_buf))
	assert(not vim.api.nvim_win_is_valid(body_win), "footer closure left the Markdown body open")
end)

test("three-row EOF composer keeps its realized body and footer adjacent through resize", function()
	reset_editor()
	local _, source_buf, source_lines = review_source_fixture()
	vim.cmd("botright 3split")
	local source_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(source_win, { #source_lines, 0 })
	local source_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
	local draft = {}
	for index = 1, 10 do
		draft[index] = "EOF draft line " .. index
	end
	assert(review_editor.compose({
		title = "EOF",
		body = table.concat(draft, "\n"),
		style = "minimal",
		source_win = source_win,
		anchor = { kind = "range", start_line = #source_lines, end_line = #source_lines },
	}, function()
		return true
	end))
	local body_win = vim.api.nvim_get_current_win()
	local footer = assert(inline_footer(source_win, body_win))
	local function assert_eof_geometry(expected_height)
		local body_height = vim.api.nvim_win_get_height(body_win)
		local body_position = vim.api.nvim_win_get_position(body_win)
		local footer_position = vim.api.nvim_win_get_position(footer)
		local footer_config = vim.api.nvim_win_get_config(footer)
		assert(body_height == expected_height and body_height >= 1 and body_height <= 6)
		assert(footer_position[1] == body_position[1] + body_height, "EOF footer is not adjacent to the body")
		assert(footer_config.row == body_height + 1 and vim.api.nvim_win_get_height(footer) == 1)
		assert(#reservation(source_buf)[4].virt_lines == body_height + 1)
		local source_position = vim.api.nvim_win_get_position(source_win)
		assert(
			footer_position[1] <= source_position[1] + vim.api.nvim_win_get_height(source_win) - 1,
			"EOF footer is clipped outside the source grid"
		)
		assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), { #source_lines, 0 }))
	end
	assert_eof_geometry(1)
	local adjusted_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
	assert(adjusted_view.topline >= source_view.topline and adjusted_view.leftcol == source_view.leftcol)

	vim.api.nvim_win_set_height(source_win, 4)
	vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
	assert_eof_geometry(2)
	local expanded_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
	assert(expanded_view.topline == adjusted_view.topline and expanded_view.leftcol == adjusted_view.leftcol)

	vim.api.nvim_win_set_height(source_win, 3)
	vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
	assert_eof_geometry(1)
	vim.cmd("stopinsert")
	vim.fn.maparg("<Esc>", "n", false, true).callback()
	assert(not review_editor.has_active() and not reservation(source_buf))
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "EOF resize mutated source text")
	local unscoped = namespace_windows()
	if unscoped then
		equal({}, unscoped, "EOF teardown retained its namespace scope")
	end
end)

test("file and general anchors use one centered rounded modal without source reservations", function()
	reset_editor()
	local source_win, source_buf = review_source_fixture()
	local sentinel = vim.api.nvim_buf_set_extmark(source_buf, review_editor._namespace, 0, 0, {
		virt_text = { { "sentinel", "Comment" } },
	})
	local accepted = false
	local calls = 0
	local selected
	assert(review_editor.compose({
		title = "Edit",
		body = "short",
		style = "minimal",
		type_cycle = true,
		selected_type = "issue",
		source_win = source_win,
		anchor_line = 4,
		anchor_range = { first = 2, last = 4 },
		anchor = { kind = "file", path = "fixture.lua" },
	}, function(body, _, selected_type)
		assert(body and body ~= "")
		calls = calls + 1
		selected = selected_type
		return accepted
	end))
	local modal = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local initial = vim.api.nvim_win_get_config(modal)
	assert(initial.relative == "editor" and initial.border ~= "none")
	assert(initial.height == 1 and initial.width <= math.min(88, vim.o.columns - 2))
	assert(initial.row == math.floor((vim.o.lines - initial.height - 2) / 2))
	assert(initial.col == math.floor((vim.o.columns - initial.width - 2) / 2))
	assert(border_text(initial.title):find("Edit", 1, true) and border_text(initial.title):find("issue", 1, true))
	assert(border_text(initial.footer):find("<Tab>/<S-Tab> type", 1, true))
	assert(border_text(initial.footer):find("<C-s>/↵↵ save", 1, true))
	assert(vim.bo[buf].filetype == "markdown" and not inline_footer(source_win, modal))
	assert(not reservation(source_buf) and #namespace_marks(source_buf) == 1)
	assert(namespace_marks(source_buf)[1][1] == sentinel, "modal creation replaced the source namespace")
	assert(
		not review_editor.compose({ source_win = source_win, anchor = { kind = "general" } }, function() end),
		"second modal bypassed the one-active-composer guard"
	)

	vim.cmd("stopinsert")
	local tab = vim.fn.maparg("<Tab>", "n", false, true)
	assert(tab.buffer == 1 and type(tab.callback) == "function")
	assert(vim.fn.maparg("<Tab>", "i", false, true).buffer == 1)
	tab.callback()
	local cycled_title = border_text(vim.api.nvim_win_get_config(modal).title)
	assert(cycled_title:find("Edit", 1, true) and cycled_title:find("suggestion", 1, true))
	vim.fn.maparg("<C-s>", "n", false, true).callback()
	assert(calls == 1 and selected == "suggestion" and review_editor.has_active())
	assert(not reservation(source_buf) and namespace_marks(source_buf)[1][1] == sentinel)

	local overflow = {}
	for index = 1, 25 do
		overflow[index] = string.rep("modal content ", 12) .. index
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, overflow)
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf, modeline = false })
	vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
	local expanded = vim.api.nvim_win_get_config(modal)
	assert(expanded.relative == "editor" and expanded.width > initial.width and expanded.width <= 88)
	assert(expanded.height > initial.height and expanded.height <= 18)
	assert(expanded.col >= 0 and expanded.col + expanded.width + 2 <= vim.o.columns)
	assert(expanded.row >= 0 and expanded.row + expanded.height + 2 <= vim.o.lines)
	assert(not reservation(source_buf) and namespace_marks(source_buf)[1][1] == sentinel)
	accepted = true
	vim.fn.maparg("<CR><CR>", "n", false, true).callback()
	assert(calls == 2 and selected == "suggestion" and not review_editor.has_active())
	assert(not reservation(source_buf) and namespace_marks(source_buf)[1][1] == sentinel)

	local cancelled = "pending"
	assert(review_editor.compose({
		title = "Reply",
		body = "general draft",
		selected_type = "suggestion",
		source_win = source_win,
		anchor = { kind = "general" },
	}, function(body)
		cancelled = body
		return true
	end))
	local general_modal = vim.api.nvim_get_current_win()
	local reply_config = vim.api.nvim_win_get_config(general_modal)
	assert(reply_config.relative == "editor")
	assert(chunk_highlight(reply_config.title, "suggestion") == "NvimReviewCommentSuggestion")
	assert(chunk_highlight(reply_config.footer, "suggestion") == "NvimReviewCommentSuggestion")
	assert(vim.fn.maparg("<Tab>", "n", false, true).buffer ~= 1)
	assert(vim.fn.maparg("<Tab>", "i", false, true).buffer ~= 1)
	assert(not inline_footer(source_win, general_modal) and not reservation(source_buf))
	vim.cmd("stopinsert")
	vim.fn.maparg("q", "n", false, true).callback()
	assert(cancelled == nil and not review_editor.has_active())
	assert(#namespace_marks(source_buf) == 1 and namespace_marks(source_buf)[1][1] == sentinel)
	vim.api.nvim_buf_del_extmark(source_buf, review_editor._namespace, sentinel)
end)

test("source loss interrupts and recovers exactly once", function()
	reset_editor()
	local _, source_buf, source_lines = review_source_fixture()
	vim.cmd("vsplit")
	local source_win = vim.api.nvim_get_current_win()
	local callbacks = 0
	local recoveries = 0
	assert(review_editor.compose({
		title = "Source loss",
		body = "Recover me",
		source_win = source_win,
		anchor_line = 7,
		anchor = { kind = "range", start_line = 7, end_line = 7 },
		recover = function(body)
			assert(body == "Recover me")
			recoveries = recoveries + 1
			return true
		end,
	}, function(body, interrupted)
		assert(body == "Recover me" and interrupted == true)
		callbacks = callbacks + 1
		return false
	end))
	vim.api.nvim_win_close(source_win, true)
	assert(callbacks == 1 and recoveries == 1, "source teardown called callback or recovery more than once")
	assert(not review_editor.has_active() and not reservation(source_buf))
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "source loss mutated source text")
end)

test("source buffer replacement interrupts and recovers a modal editor", function()
	reset_editor()
	local source_win, source_buf, source_lines = review_source_fixture()
	local callbacks = 0
	local recoveries = 0
	assert(review_editor.compose({
		title = "Source replacement",
		body = "Recover replacement",
		source_win = source_win,
		anchor = { kind = "general" },
		recover = function(body)
			assert(body == "Recover replacement")
			recoveries = recoveries + 1
			return true
		end,
	}, function(body, interrupted)
		assert(body == "Recover replacement" and interrupted == true)
		callbacks = callbacks + 1
		return false
	end))
	local replacement = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(source_win, replacement)
	vim.wait(1000, function()
		return not review_editor.has_active()
	end, 10)
	assert(callbacks == 1 and recoveries == 1, "source replacement did not recover exactly once")
	assert(not reservation(source_buf), "source replacement leaked its reservation")
	equal(source_lines, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "source replacement mutated text")
	vim.api.nvim_buf_delete(replacement, { force = true })
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
