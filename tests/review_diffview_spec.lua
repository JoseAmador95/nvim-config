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
	assert(tabs.transient_title(tabpage) == "Review · Fixture scope")
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
