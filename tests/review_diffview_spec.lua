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

local diffview = require("config.review_diffview")
local review_context = require("config.review_context")
local tabs = require("config.tabs")
local root = "/tmp/review-diffview"
local oid = string.rep("a", 40)

local function adapter()
	return {
		ctx = { toplevel = root },
		get_command = function()
			return { "git" }
		end,
	}
end

local function workspace(kind)
	kind = kind or "working"
	return {
		root = root,
		scope = {
			kind = kind,
			label = "Fixture scope",
			diffview_args = kind == "working" and {} or { oid },
			file_history_range = oid .. "^!",
		},
	}
end

test("exact Diffview argv preserves roots, ranges, and selected paths", function()
	local working_command, working_args = diffview._build_args(workspace(), "files")
	assert(working_command == "DiffviewOpen")
	assert(vim.deep_equal(working_args, { "-C" .. root }))
	local value = workspace("commit")
	local command, args = diffview._build_args(value, "files", "lua/config/a b.lua")
	assert(command == "DiffviewOpen")
	assert(vim.deep_equal(args, {
		"-C" .. root,
		oid,
		"--selected-file=lua/config/a b.lua",
	}))
	command, args = diffview._build_args(value, "history")
	assert(command == "DiffviewFileHistory")
	assert(vim.deep_equal(args, { "-C" .. root, "--range=" .. oid .. "^!" }))
	command, args = diffview._build_args(value, "history", "-danger.lua")
	assert(vim.deep_equal(args, { "-C" .. root, "--range=" .. oid .. "^!", ":(literal)-danger.lua" }))
	command, args = diffview._build_args(value, "history", "+danger.lua")
	assert(vim.deep_equal(args, { "-C" .. root, "--range=" .. oid .. "^!", ":(literal)+danger.lua" }))
	command, args = diffview._build_args(value, "history", "lua/config/*.lua")
	assert(vim.deep_equal(args, { "-C" .. root, "--range=" .. oid .. "^!", ":(literal)lua/config/*.lua" }))
	local opened, err = diffview.open(workspace(), "history", nil, {
		command = function()
			error("working history must not execute")
		end,
	})
	assert(not opened and err:find("frozen commit range", 1, true))
end)

test("review views fail before Diffview when inherited Git routing could change repositories", function()
	local previous = vim.env.GIT_DIR
	vim.env.GIT_DIR = "/tmp/redirected-review.git"
	local called = false
	local opened, err = diffview.open(workspace(), "files", nil, {
		command = function()
			called = true
		end,
	})
	vim.env.GIT_DIR = previous
	assert(not opened and not called)
	assert(err:find("GIT_DIR", 1, true) and err:find("unset", 1, true))
end)

test("owned views receive a stable transient title and expose layer-sensitive targets", function()
	local value = workspace()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local previous_no_replace = vim.env.GIT_NO_REPLACE_OBJECTS
	local previous_optional_locks = vim.env.GIT_OPTIONAL_LOCKS
	local previous_lazy_fetch = vim.env.GIT_NO_LAZY_FETCH
	local previous_graft = vim.env.GIT_GRAFT_FILE
	local previous_shallow = vim.env.GIT_SHALLOW_FILE
	local view = {
		tabpage = tabpage,
		adapter = adapter(),
		infer_cur_file = function()
			return {
				path = "lua/new.lua",
				oldpath = "lua/old.lua",
				kind = "staged",
				status = "R",
			}
		end,
	}
	local win = vim.api.nvim_get_current_win()
	local pane = {
		id = win,
		is_nulled = function()
			return false
		end,
		is_file_open = function()
			return true
		end,
	}
	view.cur_layout = { a = pane, b = pane }
	local captured
	assert(diffview.open(value, "files", nil, {
		command = function(specification)
			assert(vim.env.GIT_NO_REPLACE_OBJECTS == "1")
			assert(vim.env.GIT_OPTIONAL_LOCKS == "0" and vim.env.GIT_NO_LAZY_FETCH == "1")
			assert(
				vim.env.GIT_GRAFT_FILE == "/dev/null/nvim-review-grafts"
					and vim.env.GIT_SHALLOW_FILE == "/dev/null/nvim-review-shallow"
			)
			captured = specification
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	assert(vim.env.GIT_NO_REPLACE_OBJECTS == previous_no_replace)
	assert(vim.env.GIT_OPTIONAL_LOCKS == previous_optional_locks)
	assert(vim.env.GIT_NO_LAZY_FETCH == previous_lazy_fetch)
	assert(vim.env.GIT_GRAFT_FILE == previous_graft and vim.env.GIT_SHALLOW_FILE == previous_shallow)
	assert(captured.cmd == "DiffviewOpen")
	assert(diffview.workspace(tabpage) == value)
	assert(tabs.transient_title(tabpage) == "Review · Fixture scope · Hunks")
	local isolated_command = view.adapter:get_command()
	assert(isolated_command[1] == "env" and isolated_command[#isolated_command] == "git")
	assert(vim.tbl_contains(isolated_command, "GIT_OPTIONAL_LOCKS=0"))
	assert(vim.tbl_contains(isolated_command, "GIT_NO_LAZY_FETCH=1"))
	assert(vim.tbl_contains(isolated_command, "GIT_NO_REPLACE_OBJECTS=1"))
	assert(vim.tbl_contains(isolated_command, "GIT_GRAFT_FILE=/dev/null/nvim-review-grafts"))
	assert(vim.tbl_contains(isolated_command, "GIT_SHALLOW_FILE=/dev/null/nvim-review-shallow"))
	local shallow_index = vim.fn.index(isolated_command, "GIT_SHALLOW_FILE")
	assert(shallow_index > 0 and isolated_command[shallow_index] == "-u")

	vim.w[win].nvim_review_diff_symbol = "a"
	local target = assert(diffview.current_target({ view = view, win = win }))
	assert(target.path == "lua/old.lua" and target.current_path == "lua/new.lua")
	assert(target.side == "left" and target.layer == "staged")
	pane.is_nulled = function()
		return true
	end
	local missing, missing_err = diffview.current_target({ view = view, win = win })
	assert(not missing and missing_err:find("missing diff side", 1, true))
	pane.is_nulled = function()
		return false
	end
	local previous_git_dir = vim.env.GIT_DIR
	vim.env.GIT_DIR = "/tmp/late-review-redirect.git"
	local redirected, redirected_err = diffview.current_target({ view = view, win = win })
	assert(not redirected and redirected_err:find("GIT_DIR", 1, true))
	assert(not diffview.select_file("lua/new.lua", "staged", nil, { view = view }))
	vim.env.GIT_DIR = previous_git_dir
	view.infer_cur_file = function()
		return { path = "lua/conflict.lua", kind = "conflicting", status = "U" }
	end
	local conflict, conflict_err = diffview.current_target({ view = view, win = win })
	assert(not conflict and conflict_err:find("unresolved conflict", 1, true))

	diffview._on_view_closed(view)
	assert(diffview.workspace(tabpage) == nil and not tabs.is_transient(tabpage))
end)

test("mutating mappings are guarded only while a review view is active", function()
	local calls = 0
	local refreshes = 0
	local code_opens = 0
	local close_arguments = -1
	local guarded = diffview.guard(function()
		calls = calls + 1
	end)
	local refresh = diffview.refresh_or(function()
		refreshes = refreshes + 1
	end)
	local code = diffview.code_or(function()
		code_opens = code_opens + 1
	end)
	local close = diffview.close_or(function(...)
		close_arguments = select("#", ...)
	end)
	guarded()
	refresh()
	code()
	close({ bang = false })
	assert(calls == 1, "ordinary Diffview action was blocked")
	assert(refreshes == 1, "ordinary Diffview refresh was intercepted")
	assert(code_opens == 1, "ordinary Diffview source action was intercepted")
	assert(close_arguments == 0, "raw DiffviewClose received Neovim command metadata as its tabpage")

	local value = workspace()
	local view = { tabpage = vim.api.nvim_get_current_tabpage(), adapter = adapter() }
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	diffview.set_controller({
		refresh = function()
			refreshes = refreshes + 10
		end,
		code = function()
			code_opens = code_opens + 10
		end,
	})
	guarded()
	refresh()
	code()
	assert(calls == 1, "review-owned mutating action was allowed")
	assert(refreshes == 11, "review refresh bypassed its controller")
	assert(code_opens == 11, "review source action bypassed its controller")
	diffview._on_view_closed(view)
end)

test("review help routes only in owned views", function()
	local calls = {}
	local routed = diffview.help_or(function(value)
		calls[#calls + 1] = "ordinary:" .. value
		return "ordinary"
	end, function(value)
		calls[#calls + 1] = "review:" .. value
		return "review"
	end)
	assert(routed("first") == "ordinary")
	assert(vim.deep_equal(calls, { "ordinary:first" }))

	local value = workspace()
	local view = { tabpage = vim.api.nvim_get_current_tabpage(), adapter = adapter() }
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	assert(routed("second") == "review")
	assert(vim.deep_equal(calls, { "ordinary:first", "review:second" }))
	diffview._on_view_closed(view)
end)

test("panel entry selection focuses only review-owned views", function()
	local selected = {}
	local focused = {}
	local select_entry = diffview.focus_entry_or(function(...)
		selected[#selected + 1] = { ... }
		return "selected"
	end, function(...)
		focused[#focused + 1] = { ... }
		return "focused"
	end)
	assert(select_entry("ordinary", 1) == "selected")
	assert(vim.deep_equal(selected, { { "ordinary", 1 } }) and #focused == 0)

	local value = workspace()
	local view = { tabpage = vim.api.nvim_get_current_tabpage(), adapter = adapter() }
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	assert(select_entry("review", 2) == "focused")
	assert(#selected == 1 and vim.deep_equal(focused, { { "review", 2 } }))
	diffview._on_view_closed(view)
end)

test("layout cycling is review-only and protects inline buffers", function()
	local calls = {}
	local fallback_calls = 0
	diffview.layout_or(function()
		fallback_calls = fallback_calls + 1
	end)()
	assert(fallback_calls == 1, "ordinary Diffview did not retain its layout cycle")
	local changed, err = diffview.layout({
		view = { cur_layout = { name = "diff2_horizontal" } },
		set_layout = function(name)
			return function()
				calls[#calls + 1] = name
			end
		end,
	})
	assert(not changed and err:find("not a review workspace", 1, true) and #calls == 0)

	local value = workspace()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local previous = {
		diff = vim.wo[win].diff,
		modifiable = vim.bo[buf].modifiable,
		readonly = vim.bo[buf].readonly,
		symbol = vim.w[win].nvim_review_diff_symbol,
	}
	local view = { tabpage = tabpage, adapter = adapter() }
	vim.wo[win].diff = false
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.w[win].nvim_review_diff_symbol = nil
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))

	local original_lib = package.loaded["diffview.lib"]
	package.loaded["diffview.lib"] = {
		get_current_view = function()
			return view
		end,
	}
	diffview.hooks().diff_buf_win_enter(buf, win, { symbol = "b", layout_name = "diff1_inline" })
	package.loaded["diffview.lib"] = original_lib
	assert(not vim.bo[buf].modifiable and vim.bo[buf].readonly, "inline review buffer remained writable")
	local original_layout = diffview.layout
	local routed = 0
	diffview.layout = function()
		routed = routed + 1
		return true
	end
	diffview.layout_or(function()
		fallback_calls = fallback_calls + 1
	end)()
	diffview.layout = original_layout
	assert(routed == 1 and fallback_calls == 1, "review layout mapping used the ordinary Diffview cycle")

	changed, err = diffview.layout({
		view = { cur_layout = { name = "diff2_horizontal" } },
		set_layout = function(name)
			return function()
				calls[#calls + 1] = name
			end
		end,
	})
	assert(changed and err == nil and calls[1] == "diff1_inline", "side-by-side did not switch to inline")
	changed, err = diffview.layout({
		view = { cur_layout = { name = "diff1_inline" } },
		set_layout = function(name)
			return function()
				calls[#calls + 1] = name
			end
		end,
	})
	assert(changed and err == nil and calls[2] == "diff2_horizontal", "inline did not switch to side-by-side")
	changed, err = diffview.layout({
		view = { cur_layout = { name = "diff3_horizontal" } },
		set_layout = function()
			error("merge layout must not be converted")
		end,
	})
	assert(not changed and err:find("unavailable", 1, true), "merge layout did not fail clearly")
	diffview._on_view_closed(view)
	assert(vim.bo[buf].modifiable and not vim.bo[buf].readonly, "source options were not restored")

	vim.wo[win].diff = previous.diff
	vim.bo[buf].modifiable = previous.modifiable
	vim.bo[buf].readonly = previous.readonly
	vim.w[win].nvim_review_diff_symbol = previous.symbol
end)

test("review context toggles independently, updates titles, and rejects conflict layouts", function()
	local value = workspace("commit")
	value.session = { items = { { id = "unchanged" } } }
	local session_before = vim.deepcopy(value.session)
	local tabpage = vim.api.nvim_get_current_tabpage()
	local view = {
		tabpage = tabpage,
		adapter = adapter(),
		cur_layout = { name = "diff2_horizontal" },
	}
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	assert(value.context_mode == nil and tabs.transient_title(tabpage):find("· Hunks", 1, true))

	local applied = {}
	local notifications = {}
	local original_notify = vim.notify
	vim.notify = function(message)
		notifications[#notifications + 1] = message
	end
	local ok, err = xpcall(function()
		local changed, context_err = diffview.context(nil, {
			view = view,
			apply = function(workspace_value)
				applied[#applied + 1] = workspace_value.context_mode
			end,
		})
		assert(changed and context_err == nil and value.context_mode == "full")
		assert(applied[1] == "full" and notifications[#notifications] == "Review context: Full")
		assert(tabs.transient_title(tabpage) == "Review · Fixture scope · Full")

		changed, context_err = diffview.context("hunks", {
			view = view,
			apply = function(workspace_value)
				applied[#applied + 1] = workspace_value.context_mode
			end,
		})
		assert(changed and context_err == nil and value.context_mode == "hunks")
		assert(applied[2] == "hunks" and notifications[#notifications] == "Review context: Hunks")
		assert(vim.deep_equal(value.session, session_before), "transient context leaked into persisted review state")

		local invalid, invalid_err = diffview.context("wide", { view = view })
		assert(not invalid and invalid_err == "Usage: ReviewContext [hunks|full]")
		assert(value.context_mode == "hunks" and #applied == 2)

		view.cur_layout.name = "diff3_horizontal"
		local conflict, conflict_err = diffview.context("full", {
			view = view,
			apply = function()
				error("unsupported context must not apply")
			end,
		})
		assert(not conflict and conflict_err:find("diff3/diff4 conflict", 1, true))
		assert(value.context_mode == "hunks", "conflict layout mutated context state")
		view.cur_layout.name = "diff2_horizontal"
		assert(diffview.context("full", {
			view = view,
			apply = function(workspace_value)
				applied[#applied + 1] = workspace_value.context_mode
			end,
		}))
		assert(value.context_mode == "full" and applied[3] == "full")

		diffview._on_view_closed(view)
		local reopened = {
			tabpage = tabpage,
			adapter = adapter(),
			cur_layout = { name = "diff1_inline" },
		}
		assert(diffview.open(value, "history", nil, {
			command = function()
				diffview._on_view_opened(reopened)
			end,
			schedule = function(callback)
				callback()
			end,
		}))
		assert(value.context_mode == "full" and value.view_mode == "history")
		assert(tabs.transient_title(tabpage) == "Review · Fixture scope · Full")
		diffview._on_view_closed(reopened)
	end, debug.traceback)
	vim.notify = original_notify
	assert(ok, err)
end)

test("review side-by-side layouts color old and current modified lines by pane", function()
	local value = workspace()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local previous_winhighlight = vim.wo[win].winhighlight
	local view = { tabpage = tabpage, adapter = adapter() }
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))

	local original_lib = package.loaded["diffview.lib"]
	package.loaded["diffview.lib"] = {
		get_current_view = function()
			return view
		end,
	}
	vim.wo[win].winhighlight = "DiffAdd:ExistingAdd,DiffDelete:ExistingDelete,CursorLine:ExistingCursor"
	diffview.hooks().diff_buf_win_enter(buf, win, { symbol = "a", layout_name = "diff2_horizontal" })
	assert(
		vim.wo[win].winhighlight
			== "DiffAdd:ExistingAdd,DiffDelete:ExistingDelete,CursorLine:ExistingCursor,DiffChange:DiffviewDiffAddAsDelete,DiffText:DiffviewDiffAddAsDelete,DiffTextAdd:DiffviewDiffAddAsDelete"
	)

	diffview.hooks().diff_buf_win_enter(buf, win, { symbol = "b", layout_name = "diff2_vertical_pinned" })
	assert(
		vim.wo[win].winhighlight
			== "DiffAdd:ExistingAdd,DiffDelete:ExistingDelete,CursorLine:ExistingCursor,DiffChange:DiffviewDiffAdd,DiffText:DiffviewDiffAdd,DiffTextAdd:DiffviewDiffAdd"
	)
	package.loaded["diffview.lib"] = original_lib
	diffview._on_view_closed(view)
	vim.wo[win].winhighlight = previous_winhighlight
end)

test("review diff colors deduplicate sources, restore inline semantics, and preserve merge layouts", function()
	local value = workspace()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local previous_winhighlight = vim.wo[win].winhighlight
	local view = { tabpage = tabpage, adapter = adapter() }
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))

	local original_lib = package.loaded["diffview.lib"]
	package.loaded["diffview.lib"] = {
		get_current_view = function()
			return view
		end,
	}
	local merge_winhighlight = "DiffChange:MergeChange,DiffText:MergeText,DiffTextAdd:MergeTextAdd"
	vim.wo[win].winhighlight = merge_winhighlight
	diffview.hooks().diff_buf_win_enter(buf, win, { symbol = "a", layout_name = "diff3_horizontal" })
	assert(vim.wo[win].winhighlight == merge_winhighlight)

	vim.wo[win].winhighlight = table.concat({
		"DiffChange:FirstChange",
		"Normal:ReviewNormal",
		"DiffText:FirstText",
		"DiffChange:DuplicateChange",
		"DiffTextAdd:FirstTextAdd",
		"DiffText:DuplicateText",
		"DiffAdd:DiffviewDiffAdd",
		"DiffDelete:DiffviewDiffDelete",
	}, ",")
	diffview.hooks().diff_buf_win_enter(buf, win, { symbol = "a", layout_name = "diff2_horizontal_pinned" })
	assert(
		vim.wo[win].winhighlight
			== "DiffChange:DiffviewDiffAddAsDelete,Normal:ReviewNormal,DiffText:DiffviewDiffAddAsDelete,DiffTextAdd:DiffviewDiffAddAsDelete,DiffAdd:DiffviewDiffAdd,DiffDelete:DiffviewDiffDelete"
	)
	diffview.hooks().diff_buf_win_enter(buf, win, { symbol = "b", layout_name = "diff1_inline" })
	assert(
		vim.wo[win].winhighlight
			== "DiffChange:DiffviewDiffChange,Normal:ReviewNormal,DiffText:DiffviewDiffText,DiffAdd:DiffviewDiffAdd,DiffDelete:DiffviewDiffDelete"
	)
	package.loaded["diffview.lib"] = original_lib
	diffview._on_view_closed(view)
	vim.wo[win].winhighlight = previous_winhighlight
end)

test("review diff colors do not touch ordinary Diffview windows", function()
	local win = vim.api.nvim_get_current_win()
	local previous_winhighlight = vim.wo[win].winhighlight
	local expected = "DiffChange:OrdinaryChange,DiffText:OrdinaryText,DiffAdd:OrdinaryAdd"
	vim.wo[win].winhighlight = expected
	diffview.hooks().diff_buf_win_enter(vim.api.nvim_get_current_buf(), win, {
		symbol = "a",
		layout_name = "diff2_vertical",
	})
	assert(vim.wo[win].winhighlight == expected)
	vim.wo[win].winhighlight = previous_winhighlight
end)

test("inline hunk bands cover additions, changes, deletions, and adjacent boundaries", function()
	local bands, malformed = review_context._build_bands({
		{ 0, 0, 1, 2 },
		{ 4, 1, 3, 1 },
		{ 7, 2, 0, 0 },
		{ 9, 2, 5, 0 },
	}, 5, 48)
	assert(not malformed and #bands == 8)
	local expected_header = "HUNK 1/4 · -0,0 +1,2"
	assert(bands[1].text:sub(1, #expected_header) == expected_header)
	assert(vim.fn.strdisplaywidth(bands[1].text) == 48)
	assert(bands[1].row == 0 and bands[1].above and bands[1].priority == 50 and not bands[1].right_gravity)
	assert(bands[2].row == 1 and not bands[2].above and bands[2].priority == 200 and bands[2].right_gravity)
	assert(bands[2].text:find("END HUNK 1/4", 1, true) == 1)
	assert(
		bands[3].row == 2 and bands[3].above and not bands[3].right_gravity,
		"adjacent modification header lost its pre-hunk boundary"
	)
	assert(
		bands[4].row == 2 and not bands[4].above and bands[4].right_gravity,
		"adjacent modification footer lost its post-hunk boundary"
	)
	assert(
		bands[5].row == 0
			and bands[5].above
			and bands[6].row == 0
			and bands[6].above
			and not bands[5].right_gravity
			and bands[6].right_gravity,
		"BOF deletion bands do not bracket Diffview's existing extmark by gravity"
	)
	assert(
		bands[7].row == 4
			and not bands[7].above
			and bands[8].row == 4
			and not bands[8].above
			and not bands[7].right_gravity
			and bands[8].right_gravity,
		"middle/EOF deletion bands do not bracket Diffview's existing extmark by gravity"
	)
	local empty = review_context._build_bands({}, 1, 20)
	assert(#empty == 0, "an unchanged file received hunk bands")
	local deletions = review_context._build_bands({ { 1, 1, 3, 0 }, { 8, 2, 5, 0 } }, 5, 30)
	assert(deletions[1].row == 2 and not deletions[1].above, "middle deletion used the wrong anchor")
	assert(deletions[3].row == 4 and not deletions[3].above, "EOF deletion used the wrong anchor")
	local invalid, invalid_flag = review_context._build_bands({ { 1, 2, 3 } }, 3, 20)
	assert(#invalid == 0 and invalid_flag, "malformed cached hunks were not rejected safely")
end)

test("context application preserves views, restores diff folds, and scopes inline bands", function()
	review_context.setup()
	local original_win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_get_current_buf()
	local original_options = {
		foldenable = vim.wo[original_win].foldenable,
		foldlevel = vim.wo[original_win].foldlevel,
		foldmethod = vim.wo[original_win].foldmethod,
	}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(
		buf,
		0,
		-1,
		false,
		vim.tbl_map(function(index)
			return ("line %02d with context"):format(index)
		end, vim.fn.range(1, 40))
	)
	vim.api.nvim_win_set_buf(original_win, buf)
	vim.wo[original_win].foldmethod = "marker"
	vim.wo[original_win].foldlevel = 7
	vim.wo[original_win].foldenable = true
	vim.api.nvim_win_set_cursor(original_win, { 24, 4 })
	vim.cmd("normal! zt")
	local before = vim.fn.winsaveview()
	local value = { context_mode = "full", tabpage = vim.api.nvim_get_current_tabpage() }

	local ok, err = xpcall(function()
		review_context.apply_window(value, buf, original_win, "diff2_horizontal")
		assert(not vim.wo[original_win].foldenable)
		assert(vim.wo[original_win].foldmethod == "marker" and vim.wo[original_win].foldlevel == 7)
		assert(vim.deep_equal(vim.fn.winsaveview(), before), "Full context moved the side-by-side viewport")

		value.context_mode = "hunks"
		review_context.apply_window(value, buf, original_win, "diff2_horizontal")
		assert(vim.wo[original_win].foldmethod == "diff")
		assert(vim.wo[original_win].foldlevel == 0 and vim.wo[original_win].foldenable)
		assert(vim.deep_equal(vim.fn.winsaveview(), before), "Hunks context moved the side-by-side viewport")
		review_context.apply_window(value, buf, original_win, "diff1_inline", {
			get_hunks = function()
				return nil
			end,
		})
		assert(
			review_context._namespace(original_win) == nil and review_context._decorations[original_win] == nil,
			"nil/binary cached hunks allocated a band namespace"
		)

		vim.cmd("vsplit")
		local inline_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(inline_win, buf)
		vim.api.nvim_win_set_width(inline_win, 46)
		local inline_before = vim.fn.winsaveview()
		review_context.apply_window(value, buf, inline_win, "diff1_inline", {
			get_hunks = function()
				return { { 8, 2, 8, 2 }, { 30, 3, 30, 0 } }
			end,
		})
		local namespace = assert(review_context._namespace(inline_win))
		local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
		assert(#marks == 4, "inline hunks did not receive one header and footer each")
		for _, mark in ipairs(marks) do
			local text = mark[4].virt_lines[1][1][1]
			if text:find("HUNK ", 1, true) == 1 then
				assert(not mark[4].right_gravity, "rendered hunk header lost left gravity")
			elseif text:find("END HUNK ", 1, true) == 1 then
				assert(mark[4].right_gravity, "rendered hunk footer lost right gravity")
			end
		end
		assert(vim.deep_equal(vim.fn.winsaveview(), inline_before), "inline bands moved the viewport")
		assert(review_context._decorations[inline_win].buf == buf)
		if type(vim.api.nvim__ns_get) == "function" and type(vim.api.nvim_win_add_ns) ~= "function" then
			local scope = vim.api.nvim__ns_get(namespace)
			assert(vim.deep_equal(scope.wins, { inline_win }), "band namespace was not scoped to its inline window")
			assert(not vim.tbl_contains(scope.wins, original_win), "bands leaked into a sibling sharing the buffer")
		end

		vim.api.nvim_win_set_width(inline_win, 55)
		vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
		marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
		local chunks = marks[1][4].virt_lines[1]
		assert(
			vim.fn.strdisplaywidth(chunks[1][1])
				== vim.api.nvim_win_get_width(inline_win) - vim.fn.getwininfo(inline_win)[1].textoff,
			"resize did not rebuild full-width hunk bands"
		)

		value.context_mode = "full"
		review_context.apply_window(value, buf, inline_win, "diff1_inline")
		assert(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0)
		assert(review_context._decorations[inline_win] == nil and review_context._namespace(inline_win) == nil)
		vim.api.nvim_win_close(inline_win, true)

		vim.api.nvim_set_hl(0, "NvimReviewHunkBand", { link = "ErrorMsg" })
		vim.api.nvim_exec_autocmds("ColorScheme", { modeline = false })
		local highlight = vim.api.nvim_get_hl(0, { name = "NvimReviewHunkBand", link = true })
		assert(highlight.link == "StatusLine", "hunk band highlight is not theme-derived and neutral")
	end, debug.traceback)

	review_context.clear_workspace()
	if vim.api.nvim_win_is_valid(original_win) then
		vim.api.nvim_set_current_win(original_win)
		vim.api.nvim_win_set_buf(original_win, original_buf)
		vim.wo[original_win].foldmethod = original_options.foldmethod
		vim.wo[original_win].foldlevel = original_options.foldlevel
		vim.wo[original_win].foldenable = original_options.foldenable
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	assert(ok, err)
end)

test("inline edge maintenance includes bands without accumulating scroll state", function()
	review_context.setup()
	local win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_win_get_buf(win)
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}
	for index = 1, 40 do
		lines[index] = ("edge line %02d"):format(index)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_win_set_buf(win, buf)
	local plugin_namespace = vim.api.nvim_create_namespace("nvim_review_edge_plugin_fixture")
	local hunks
	local dependencies = {
		get_hunks = function()
			return hunks
		end,
	}
	local value = { context_mode = "hunks", tabpage = vim.api.nvim_get_current_tabpage() }
	local function set_view(topline, topfill)
		vim.api.nvim_win_call(win, function()
			local view = vim.fn.winsaveview()
			view.topline = topline
			view.topfill = topfill
			vim.fn.winrestview(view)
		end)
	end
	local function current_view()
		return vim.api.nvim_win_call(win, vim.fn.winsaveview)
	end

	local ok, err = xpcall(function()
		vim.api.nvim_buf_set_extmark(buf, plugin_namespace, 39, 0, {
			virt_lines = {
				{ { "deleted eof 1", "DiffDelete" } },
				{ { "deleted eof 2", "DiffDelete" } },
				{ { "deleted eof 3", "DiffDelete" } },
			},
			priority = 100,
		})
		hunks = { { 41, 3, 40, 0 } }
		vim.api.nvim_win_set_cursor(win, { 40, 0 })
		local height = vim.api.nvim_win_get_height(win)
		local plugin_topline = math.min(40, math.max(1, 40 - (height - 1 - math.min(3, height - 1))))
		set_view(plugin_topline, 0)
		review_context.apply_window(value, buf, win, "diff1_inline", dependencies)
		local record = review_context._decorations[win]
		assert(record.plugin_eof_below == 3 and record.eof_below == 5)
		local expected_topline = math.min(40, math.max(1, 40 - (height - 1 - math.min(5, height - 1))))
		assert(current_view().topline >= expected_topline, "EOF header/footer remained clipped below the last line")
		assert(vim.api.nvim_win_get_cursor(win)[1] == 40, "EOF visibility correction moved the cursor")

		vim.api.nvim_buf_clear_namespace(buf, plugin_namespace, 0, -1)
		vim.api.nvim_buf_set_extmark(buf, plugin_namespace, 0, 0, {
			virt_lines = {
				{ { "deleted bof 1", "DiffDelete" } },
				{ { "deleted bof 2", "DiffDelete" } },
			},
			virt_lines_above = true,
			priority = 100,
		})
		hunks = { { 1, 2, 0, 0 } }
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		set_view(1, 2)
		review_context.apply_window(value, buf, win, "diff1_inline", dependencies)
		record = review_context._decorations[win]
		assert(record.plugin_bof_topfill == 2 and record.bof_topfill == 4)
		assert(current_view().topfill == 4, "BOF topfill omitted the two review bands")

		review_context._rebuild_bands()
		vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
		assert(current_view().topfill == 4, "BOF topfill accumulated across rebuild/resize")

		set_view(1, 2)
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
		assert(
			vim.wait(100, function()
				return current_view().topfill == 4
			end, 10),
			"scheduled edge correction did not run after Diffview's CursorMoved adjustment"
		)

		value.context_mode = "full"
		review_context.apply_window(value, buf, win, "diff1_inline")
		assert(current_view().topfill == 2, "Full context did not restore plugin-only BOF topfill")
		assert(review_context._decorations[win] == nil and review_context._namespace(win) == nil)
	end, debug.traceback)

	review_context.clear_workspace()
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, plugin_namespace, 0, -1)
	end
	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_buf(win, original_buf)
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	assert(ok, err)
end)

test("working file selection distinguishes staged, unstaged, untracked, and renamed entries", function()
	local value = workspace()
	local entries = {
		{ path = "lua/shared.lua", kind = "staged", status = "M" },
		{ path = "lua/shared.lua", kind = "working", status = "M" },
		{ path = "lua/new.lua", kind = "working", status = "?" },
		{ path = "lua/renamed.lua", oldpath = "lua/original.lua", kind = "staged", status = "R" },
	}
	local selected
	local view = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		adapter = adapter(),
		files = {
			iter = function()
				return ipairs(entries)
			end,
		},
		set_file = function(_, entry)
			selected = entry
		end,
	}
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	assert(diffview.select_file("lua/shared.lua", "unstaged", nil, { view = view }))
	assert(selected == entries[2])
	assert(diffview.select_file("lua/new.lua", "untracked", nil, { view = view }))
	assert(selected == entries[3])
	assert(diffview.select_file("lua/original.lua", "staged", nil, { view = view }))
	assert(selected == entries[4])
	assert(not diffview.select_file("lua/shared.lua", "untracked", nil, { view = view }))
	diffview._on_view_closed(view)
end)

test("comment target focus reveals a line hidden inside a review fold", function()
	local value = workspace("commit")
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_win_get_buf(win)
	local original_options = {
		foldenable = vim.wo[win].foldenable,
		foldlevel = vim.wo[win].foldlevel,
		foldmethod = vim.wo[win].foldmethod,
		symbol = vim.w[win].nvim_review_diff_symbol,
	}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- {{{", "one", "target", "three", "-- }}}", "tail" })
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].foldmethod = "marker"
	vim.wo[win].foldlevel = 0
	vim.wo[win].foldenable = true
	local entry = { path = "lua/folded.lua", status = "M" }
	local view = {
		tabpage = tabpage,
		adapter = adapter(),
		files = {
			iter = function()
				return ipairs({ entry })
			end,
		},
		set_file = function() end,
	}
	local ok, err = xpcall(function()
		assert(diffview.open(value, "files", nil, {
			command = function()
				diffview._on_view_opened(view)
			end,
			schedule = function(callback)
				callback()
			end,
		}))
		vim.w[win].nvim_review_diff_symbol = "b"
		assert(vim.fn.foldclosed(3) == 1, "fold fixture did not start closed")
		assert(diffview.select_file("lua/folded.lua", "historical", {
			side = "right",
			line = 3,
			column = 1,
		}, {
			view = view,
			defer = function(callback)
				callback()
			end,
		}))
		assert(vim.api.nvim_win_get_cursor(win)[1] == 3)
		assert(vim.fn.foldclosed(3) == -1, "focus_target did not reveal the hidden comment line")
		diffview._on_view_closed(view)
	end, debug.traceback)
	if diffview.workspace(tabpage) then
		diffview._on_view_closed(view)
	end
	vim.api.nvim_win_set_buf(win, original_buf)
	vim.wo[win].foldmethod = original_options.foldmethod
	vim.wo[win].foldlevel = original_options.foldlevel
	vim.wo[win].foldenable = original_options.foldenable
	vim.w[win].nvim_review_diff_symbol = original_options.symbol
	vim.api.nvim_buf_delete(buf, { force = true })
	assert(ok, err)
end)

test("file-history selection preserves the current commit and can find another path", function()
	local value = workspace("range")
	local current = { path = "lua/shared.lua", status = "M", commit = { hash = "current" } }
	local older = { path = "lua/shared.lua", status = "M", commit = { hash = "older" } }
	local other = { path = "lua/other.lua", status = "A", commit = { hash = "other" } }
	local selected
	local view = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		adapter = adapter(),
		panel = {
			cur_item = { {}, current },
			entries = {
				{ files = { older } },
				{ files = { other } },
			},
		},
		set_file = function(_, entry)
			selected = entry
		end,
	}
	assert(diffview.open(value, "history", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	assert(diffview.select_file("lua/shared.lua", "historical", { revision = "current" }, { view = view }))
	assert(selected == current, "history restore moved to a different commit with the same path")
	assert(diffview.select_file("lua/shared.lua", "historical", { revision = "older" }, { view = view }))
	assert(selected == older)
	assert(diffview.select_file("lua/other.lua", "historical", { revision = "other" }, { view = view }))
	assert(selected == other)
	diffview._on_view_closed(view)
end)

test("close owns the whole review view even while its file panel is focused", function()
	local value = workspace()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local old_diff = vim.wo[win].diff
	vim.wo[win].diff = true
	local closed = 0
	local cleared
	local entered = 0
	local view = {
		tabpage = tabpage,
		adapter = adapter(),
	}
	diffview.set_controller({
		clear_buffers = function(_, buffers)
			cleared = buffers
		end,
		view_enter = function()
			entered = entered + 1
		end,
	})
	assert(diffview.open(value, "files", nil, {
		command = function()
			diffview._on_view_opened(view)
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	diffview.hooks().view_leave(view)
	assert(vim.deep_equal(cleared, { vim.api.nvim_get_current_buf() }))
	diffview.hooks().view_enter(view)
	assert(entered == 1)
	assert(diffview.close({
		close = function()
			closed = closed + 1
			diffview._on_view_closed(view)
		end,
	}))
	vim.wo[win].diff = old_diff
	assert(closed == 1 and diffview.workspace(tabpage) == nil)
	assert(vim.deep_equal(cleared, { vim.api.nvim_get_current_buf() }))
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_diffview_spec: %d tests passed", count))
vim.cmd("quitall!")
