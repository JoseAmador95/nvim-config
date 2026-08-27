vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

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

local mode = require("config.review_mode")
local lsp_navigation = require("config.lsp_navigation")
local presenter = require("config.review_presenter")
local review_lsp = require("config.review_lsp")

local BLOCKED_NORMAL_MAPPINGS = {
	"gd",
	"gD",
	"gi",
	"gr",
	"K",
	"gO",
	"gri",
	"grn",
	"grr",
	"grt",
	"grx",
	"gra",
	"<C-k>",
	"<leader>lr",
	"<leader>ca",
}
local BLOCKED_VISUAL_MAPPINGS = { "gra", "<leader>ca" }
local GUARD_DESCRIPTION = "Historical review buffer has no LSP"

local function buffer_mapping(buf, mode_name, lhs)
	return vim.api.nvim_buf_call(buf, function()
		return vim.fn.maparg(lhs, mode_name, false, true)
	end)
end

local function assert_mapping(buf, mode_name, lhs, description)
	local mapping = buffer_mapping(buf, mode_name, lhs)
	assert(
		mapping.buffer == 1 and mapping.desc == description,
		("unexpected %s %s mapping in buffer %d: %s"):format(mode_name, lhs, buf, vim.inspect(mapping))
	)
end

local function assert_review_guards(buf, definition_description)
	for _, lhs in ipairs(BLOCKED_NORMAL_MAPPINGS) do
		assert_mapping(buf, "n", lhs, lhs == "gd" and definition_description or GUARD_DESCRIPTION)
	end
	for _, lhs in ipairs(BLOCKED_VISUAL_MAPPINGS) do
		assert_mapping(buf, "x", lhs, GUARD_DESCRIPTION)
	end
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
local path = fixture .. "/sample.lua"
assert(vim.fn.writefile({ "one", "new", "three" }, path) == 0)
local fold_path = fixture .. "/folds.lua"
local fold_disk_lines = {
	"one",
	"two",
	"three",
	"disk",
	"five",
	"six",
	"seven",
	"eight",
	"nine",
	"ten",
	"eleven",
	"twelve",
	"thirteen",
	"fourteen",
}
assert(vim.fn.writefile(fold_disk_lines, fold_path) == 0)
local cursor_path = fixture .. "/cursor.lua"
local cursor_disk_lines = {
	"line 01",
	"line 02",
	"line 03 new",
	"line 04",
	"line 05",
	"line 06",
	"line 07",
	"line 08",
	"line 09 new",
	"line 10",
	"line 11",
	"line 12",
}
assert(vim.fn.writefile(cursor_disk_lines, cursor_path) == 0)

local function entry(new_text)
	local old_text = "one\nold\nthree\n"
	new_text = new_text or "one\nnew\nthree\n"
	return {
		identity = "history\0sample.lua\0sample.lua",
		status = "M",
		old_path = "sample.lua",
		new_path = "sample.lua",
		path = "sample.lua",
		old_text = old_text,
		new_text = new_text,
		old_oid = string.rep("1", 40),
		new_oid = string.rep("2", 40),
		old_mode = "100644",
		new_mode = "100644",
		hunks = vim.diff(old_text, new_text, { result_type = "indices" }),
		binary = false,
		submodule = false,
		metadata_only = false,
		added = false,
		deleted = false,
	}
end

local function fold_entry()
	local old_text = table.concat(fold_disk_lines, "\n") .. "\n"
	local new_lines = vim.deepcopy(fold_disk_lines)
	new_lines[4] = "historical"
	local new_text = table.concat(new_lines, "\n") .. "\n"
	return {
		identity = "history\0folds.lua\0folds.lua",
		status = "M",
		old_path = "folds.lua",
		new_path = "folds.lua",
		path = "folds.lua",
		old_text = old_text,
		new_text = new_text,
		old_oid = string.rep("3", 40),
		new_oid = string.rep("4", 40),
		old_mode = "100644",
		new_mode = "100644",
		hunks = vim.diff(old_text, new_text, { result_type = "indices" }),
		binary = false,
		submodule = false,
		metadata_only = false,
		added = false,
		deleted = false,
	}
end

local function cursor_entry()
	local old_lines = vim.deepcopy(cursor_disk_lines)
	old_lines[3] = "line 03 old"
	old_lines[9] = "line 09 old"
	local old_text = table.concat(old_lines, "\n") .. "\n"
	local new_text = table.concat(cursor_disk_lines, "\n") .. "\n"
	return {
		identity = "history\0cursor.lua\0cursor.lua",
		status = "M",
		layer = "history",
		old_path = "cursor.lua",
		new_path = "cursor.lua",
		path = "cursor.lua",
		old_text = old_text,
		new_text = new_text,
		old_oid = string.rep("5", 40),
		new_oid = string.rep("6", 40),
		old_mode = "100644",
		new_mode = "100644",
		hunks = vim.diff(old_text, new_text, { result_type = "indices" }),
		binary = false,
		submodule = false,
		metadata_only = false,
		added = false,
		deleted = false,
	}
end

local function setup_state(configure_window, selected_path, relative_path)
	vim.cmd("silent! only")
	vim.cmd("edit! " .. vim.fn.fnameescape(selected_path or path))
	if configure_window then
		configure_window(vim.api.nvim_get_current_win())
	end
	relative_path = relative_path or "sample.lua"
	local workspace = {
		root = vim.uv.fs_realpath(fixture),
		model = { entries = { { old_path = relative_path, new_path = relative_path } } },
	}
	local state = mode.new(workspace)
	assert(mode.enable(state))
	return state, vim.api.nvim_get_current_buf()
end

local function setup_fold_state()
	return setup_state(function(win)
		vim.wo[win].foldmethod = "manual"
		vim.wo[win].foldenable = true
		vim.wo[win].foldcolumn = "2"
		vim.wo[win].foldlevel = 0
		vim.api.nvim_win_call(win, function()
			vim.cmd("silent! normal! zE")
			vim.cmd("1,2fold")
			vim.cmd("5,6fold")
			vim.cmd("normal! ggzo")
		end)
	end, fold_path, "folds.lua")
end

local function setup_cursor_state()
	local state, buf = setup_state(function(win)
		vim.wo[win].winbar = "%#Title#ordinary %% cursor%*"
	end, cursor_path, "cursor.lua")
	state.workspace.scope = { kind = "branch", label = "topic%ready" }
	state.workspace.mode_on = true
	state.workspace.inline_comments = false
	return state, buf, cursor_entry()
end

local function move_and_fire(win, buf, line)
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_cursor(win, { line, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
	return vim.api.nvim_win_get_cursor(win)[1]
end

local function setup_nested_fold_state()
	return setup_state(function(win)
		vim.wo[win].foldmethod = "manual"
		vim.wo[win].foldenable = true
		vim.wo[win].foldcolumn = "2"
		vim.wo[win].foldlevel = 0
		vim.api.nvim_win_call(win, function()
			vim.cmd("silent! normal! zE")
			vim.cmd("1,12fold")
			vim.cmd("normal! ggzo")
			vim.cmd("1,5fold")
			vim.cmd("normal! ggzo")
			vim.api.nvim_win_set_cursor(win, { 6, 0 })
			vim.cmd("normal! zc")
		end)
	end, fold_path, "folds.lua")
end

local function assert_nested_folds(win)
	vim.api.nvim_win_call(win, function()
		assert(vim.fn.foldlevel(1) == 2 and vim.fn.foldlevel(5) == 2, "inner manual fold was not recreated")
		assert(vim.fn.foldlevel(6) == 1 and vim.fn.foldlevel(12) == 1, "outer manual fold has the wrong range")
		assert(vim.fn.foldlevel(13) == 0, "outer manual fold extends past line 12")
		assert(vim.fn.foldclosedend(1) == 12, "outer manual fold did not remain closed")
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.cmd("normal! zo")
		assert(vim.fn.foldclosed(1) == -1, "inner manual fold did not remain open")
		vim.api.nvim_win_set_cursor(win, { 6, 0 })
		vim.cmd("normal! zc")
	end)
end

local function decoration_details(state)
	local values = {}
	for _, item in ipairs(state.presentation.decorations) do
		if vim.api.nvim_buf_is_valid(item.buf) then
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true })) do
				values[#values + 1] = mark[4]
			end
		end
	end
	return values
end

test("inline hunks use zero context and keep the exact review window out of concealed gaps", function()
	local state, buf, selected = setup_cursor_state()
	local review_win = state.origin.win
	local ordinary_win
	local previous_diffopt = vim.o.diffopt
	local ok, err = xpcall(function()
		vim.api.nvim_set_current_win(review_win)
		vim.cmd("rightbelow vsplit")
		ordinary_win = vim.api.nvim_get_current_win()
		assert(vim.api.nvim_win_get_buf(ordinary_win) == buf)
		vim.wo[ordinary_win].winbar = "ordinary sibling"
		vim.api.nvim_set_current_win(review_win)

		vim.o.diffopt = "internal,filler,closeoff,context:7"
		assert(presenter.show(state, selected))
		assert(vim.o.diffopt == "internal,filler,closeoff,context:7", "inline hunks mutated diffopt")
		local guard = assert(state.presentation.cursor_guard, "inline hunks did not install a cursor guard")
		assert(guard.win == review_win and guard.buf == buf and type(guard.generation) == "number")
		assert(vim.deep_equal(guard.sections, { { first = 3, last = 3 }, { first = 9, last = 9 } }))
		assert(vim.api.nvim_win_get_cursor(review_win)[1] == 3, "leading context was not clamped")
		assert(vim.wo[review_win].concealcursor == "nvic")
		local winbar = vim.wo[review_win].winbar
		for _, fragment in ipairs({
			"REV ON",
			"branch:topic%%ready",
			"history",
			"inline/hunks",
			"comments:off",
			"CURRENT",
			"cursor.lua",
		}) do
			assert(winbar:find(fragment, 1, true), "review winbar lacks " .. fragment .. ": " .. winbar)
		end
		state.workspace.inline_comments = true
		assert(presenter.refresh_winbars(state), "active review winbar did not refresh")
		assert(vim.wo[review_win].winbar:find("comments:on", 1, true))
		assert(vim.wo[ordinary_win].winbar == "ordinary sibling", "winbar refresh touched an ordinary window")
		state.workspace.inline_comments = false
		assert(presenter.refresh_winbars(state))

		assert(move_and_fire(review_win, buf, 4) == 9, "forward hunk exit did not jump forward")
		assert(move_and_fire(review_win, buf, 8) == 3, "backward hunk exit did not jump backward")
		assert(move_and_fire(review_win, buf, 6) == 9, "equidistant direct jump did not prefer forward")
		assert(move_and_fire(review_win, buf, 5) == 3, "direct gap jump did not choose the nearest boundary")
		assert(move_and_fire(review_win, buf, 1) == 3, "leading gap did not clamp to the first hunk")
		assert(move_and_fire(review_win, buf, 12) == 9, "trailing gap did not clamp to the last hunk")

		assert(move_and_fire(review_win, buf, 3) == 3)
		assert(presenter.prev_hunk(state) and vim.api.nvim_win_get_cursor(review_win)[1] == 9, "[h lost wrapping")
		assert(presenter.next_hunk(state) and vim.api.nvim_win_get_cursor(review_win)[1] == 3, "]h lost wrapping")

		assert(move_and_fire(ordinary_win, buf, 6) == 6, "guard trapped an ordinary window of the same buffer")
		assert(vim.wo[ordinary_win].winbar == "ordinary sibling", "review changed an ordinary window winbar")

		local old_generation = guard.generation
		assert(presenter.toggle_context(state))
		assert(not guard.active and state.presentation.cursor_guard == nil, "full context retained the old guard")
		assert(state.presentation.context == "full" and vim.o.diffopt == "internal,filler,closeoff,context:7")
		for _, details in ipairs(decoration_details(state)) do
			assert(details.conceal_lines == nil, "full context retained a concealed range")
			for _, virtual in ipairs(details.virt_lines or {}) do
				assert(not (virtual[1] and virtual[1][1] or ""):find("HUNK", 1, true))
			end
		end
		assert(move_and_fire(review_win, buf, 6) == 6, "full context still trapped the cursor")

		assert(presenter.toggle_context(state))
		local replacement = assert(state.presentation.cursor_guard, "hunk context did not recreate the guard")
		assert(replacement.generation ~= old_generation, "presentation generation was reused")
		presenter.clear(state)
		assert(not presenter.refresh_winbars(state), "winbar refresh claimed an absent presentation")
		assert(not replacement.active and state.presentation == nil, "clear retained the cursor guard")
		assert(vim.wo[review_win].winbar == "%#Title#ordinary %% cursor%*", "clear did not restore winbar")
		assert(move_and_fire(review_win, buf, 6) == 6, "cleared presentation still trapped the cursor")
	end, debug.traceback)
	vim.o.diffopt = previous_diffopt
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	if ordinary_win and vim.api.nvim_win_is_valid(ordinary_win) then
		vim.api.nvim_win_close(ordinary_win, true)
	end
	assert(ok, err)
end)

test("inline hunks without hunks install neither concealment nor cursor guard", function()
	local state, buf, selected = setup_cursor_state()
	selected.old_text = selected.new_text
	selected.hunks = {}
	assert(presenter.show(state, selected))
	assert(state.presentation.cursor_guard == nil)
	for _, details in ipairs(decoration_details(state)) do
		assert(details.conceal_lines == nil and details.virt_lines == nil, "empty diff added hunk presentation")
	end
	assert(move_and_fire(state.origin.win, buf, 6) == 6, "empty diff trapped the cursor")
	presenter.clear(state)
	mode.disable(state)
end)

test("split winbars identify both sides and restore the ordinary origin winbar", function()
	local original = "%#Comment#ordinary %% split%*"
	local state = setup_state(function(win)
		vim.wo[win].winbar = original
	end)
	state.workspace.scope = { kind = "commit", label = "HEAD%exact" }
	state.workspace.mode_on = false
	state.workspace.inline_comments = true
	local selected = entry()
	selected.layer = "staged"
	assert(presenter.show(state, selected, { layout = "split", context = "full" }))
	local left = vim.wo[state.presentation.left.win].winbar
	local right = vim.wo[state.presentation.right.win].winbar
	for _, value in ipairs({ left, right }) do
		for _, fragment in ipairs({ "REV OFF", "commit:HEAD%%exact", "staged", "split/full", "comments:on" }) do
			assert(value:find(fragment, 1, true), "split winbar lacks " .. fragment .. ": " .. value)
		end
	end
	assert(left:find("OLD", 1, true) and left:find("sample.lua", 1, true))
	assert(right:find("CURRENT", 1, true) and right:find("sample.lua", 1, true))
	presenter.clear(state)
	assert(vim.wo[state.origin.win].winbar == original, "origin winbar was not restored")
	mode.disable(state)
end)

test("inline reuses only the exact real current buffer and renders deleted virtual lines", function()
	local state, real = setup_state()
	local original_tab = state.origin.tab
	assert(presenter.show(state, entry(), { layout = "inline", context = "hunks" }))
	assert(state.presentation.inline.buf == real and state.presentation.inline.real)
	assert(vim.api.nvim_get_current_tabpage() == original_tab and #vim.api.nvim_list_tabpages() == 1)
	assert(not review_lsp.blocked(real) and vim.bo[real].readonly and not vim.bo[real].modifiable)
	assert(not vim.wo[state.origin.win].foldenable, "inline review retained unrelated manual folds")
	local has_add = false
	local has_delete_virtual = false
	local has_band = false
	for _, details in ipairs(decoration_details(state)) do
		has_add = has_add or details.line_hl_group == "DiffAdd"
		for _, virtual in ipairs(details.virt_lines or {}) do
			local text = virtual[1] and virtual[1][1] or ""
			local highlight = virtual[1] and virtual[1][2]
			has_delete_virtual = has_delete_virtual or highlight == "DiffDelete"
			has_band = has_band or text:find("HUNK", 1, true) ~= nil
		end
	end
	assert(has_add and has_delete_virtual and has_band, "inline diff decorations are incomplete")
	local target = presenter.current_target(state)
	assert(target and target.buf == real and target.side == "new")
	assert(presenter.next_hunk(state))
	assert(presenter.toggle_context(state))
	for _, details in ipairs(decoration_details(state)) do
		for _, virtual in ipairs(details.virt_lines or {}) do
			local text = virtual[1] and virtual[1][1] or ""
			assert(not text:find("HUNK", 1, true), "full context retained hunk boundary bands")
		end
	end
	presenter.clear(state)
	assert(vim.api.nvim_win_get_buf(state.origin.win) == real)
	mode.disable(state)
end)

test("inline full context opens all manual folds and restores every fold option", function()
	local state = setup_state(function(win)
		vim.wo[win].foldmethod = "manual"
		vim.wo[win].foldenable = true
		vim.wo[win].foldcolumn = "2"
		vim.wo[win].foldlevel = 0
		vim.api.nvim_win_call(win, function()
			vim.cmd("1,2fold")
		end)
	end)
	local win = state.origin.win
	assert(vim.fn.foldclosed(1) == 1, "manual fold fixture is not closed")
	assert(presenter.show(state, entry(), { layout = "inline", context = "full" }))
	assert(not vim.wo[win].foldenable, "full context left manual folds enabled")
	assert(vim.fn.foldclosed(1) == -1, "full context still hides lines behind a fold")
	presenter.clear(state)
	assert(vim.wo[win].foldmethod == "manual")
	assert(vim.wo[win].foldenable)
	assert(vim.wo[win].foldcolumn == "2")
	assert(vim.wo[win].foldlevel == 0)
	assert(vim.fn.foldclosed(1) == 1, "cleanup did not restore the closed manual fold")
	mode.disable(state)
end)

test("inline historical snapshot restores exact manual fold states", function()
	local state, origin_buf = setup_fold_state()
	local win = state.origin.win
	assert(vim.fn.foldclosed(1) == -1 and vim.fn.foldclosed(5) == 5, "manual fold fixture has the wrong state")
	assert(presenter.show(state, fold_entry(), { layout = "inline", context = "full" }))
	assert(state.presentation.inline.buf ~= origin_buf, "historical content did not use a snapshot buffer")
	presenter.clear(state)
	local restored = {
		buf = vim.api.nvim_win_get_buf(win),
		foldmethod = vim.wo[win].foldmethod,
		foldenable = vim.wo[win].foldenable,
		foldlevel = vim.wo[win].foldlevel,
		first = vim.fn.foldclosed(1),
		second = vim.fn.foldclosed(5),
	}
	mode.disable(state)
	assert(restored.buf == origin_buf, "cleanup did not restore the ordinary buffer")
	assert(restored.foldmethod == "manual" and restored.foldenable and restored.foldlevel == 0)
	assert(restored.first == -1, "cleanup closed the manually opened fold")
	assert(restored.second == 5, "cleanup opened the manually closed fold")
end)

test("inline disable restores nested same-start manual folds exactly", function()
	local state, origin_buf = setup_nested_fold_state()
	local win = state.origin.win
	assert_nested_folds(win)
	assert(presenter.show(state, fold_entry(), { layout = "inline", context = "full" }))
	assert(state.presentation.inline.buf ~= origin_buf, "historical content did not use a snapshot buffer")
	mode.disable(state)
	assert(vim.api.nvim_win_get_buf(win) == origin_buf, "disable did not restore the ordinary buffer")
	assert(vim.wo[win].foldmethod == "manual" and vim.wo[win].foldenable and vim.wo[win].foldlevel == 0)
	assert_nested_folds(win)
end)

test("inline recognizes an exact CRLF current buffer", function()
	local handle = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_write(handle, "one\r\nnew\r\nthree\r\n", 0))
	assert(vim.uv.fs_close(handle))
	local state, real = setup_state()
	local value = entry("one\r\nnew\r\nthree\r\n")
	value.old_text = "one\r\nold\r\nthree\r\n"
	value.hunks = vim.diff(value.old_text, value.new_text, { result_type = "indices" })
	assert(presenter.show(state, value, { layout = "inline", context = "full" }))
	assert(state.presentation.inline.buf == real and state.presentation.inline.real)
	mode.disable(state)
	assert(vim.fn.writefile({ "one", "new", "three" }, path) == 0)
	state = setup_state()
	assert(presenter.show(state, value, { layout = "split", context = "full" }))
	for _, side in ipairs({ state.presentation.left, state.presentation.right }) do
		assert(vim.bo[side.buf].fileformat == "dos", "CRLF snapshot lost its file format")
		for _, line in ipairs(vim.api.nvim_buf_get_lines(side.buf, 0, -1, false)) do
			assert(not line:find("\r", 1, true), "CRLF snapshot displays a literal carriage return")
		end
	end
	mode.disable(state)
end)

test("inline places pure middle deletions after the preceding unchanged line", function()
	local state = setup_state()
	local value = entry("one\nthree\n")
	value.hunks = vim.diff(value.old_text, value.new_text, { result_type = "indices" })
	assert(vim.deep_equal(value.hunks, { { 2, 1, 1, 0 } }), vim.inspect(value.hunks))
	assert(presenter.show(state, value, { layout = "inline", context = "full" }))
	local deletion
	for _, item in ipairs(state.presentation.decorations) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true })) do
			local details = mark[4]
			if details.virt_lines and details.virt_lines[1][1][2] == "DiffDelete" then
				deletion = { row = mark[2], details = details }
			end
		end
	end
	assert(deletion and deletion.row == 0, vim.inspect(deletion))
	assert(not deletion.details.virt_lines_above, "middle deletion was placed above the preceding line")
	mode.disable(state)
end)

test("split uses isolated old and snapshot buffers when current bytes differ", function()
	local state, origin_buf = setup_state()
	local wins_before = #vim.api.nvim_tabpage_list_wins(state.origin.tab)
	local previous_scrollopt = vim.o.scrollopt
	vim.o.scrollopt = "ver"
	assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
	local presentation = state.presentation
	assert(presentation.left and presentation.right and presentation.right.buf ~= origin_buf)
	assert(#vim.api.nvim_tabpage_list_wins(state.origin.tab) == wins_before + 1)
	assert(vim.api.nvim_get_current_win() == presentation.right.win, "split did not focus the right side")
	assert(vim.wo[presentation.left.win].diff and vim.wo[presentation.right.win].diff, "split is not a native diff")
	assert(
		vim.wo[presentation.left.win].scrollbind and vim.wo[presentation.right.win].scrollbind,
		"split diff scrolling is not synchronized"
	)
	assert(not vim.wo[presentation.left.win].foldenable and not vim.wo[presentation.right.win].foldenable)
	for _, side in ipairs({ presentation.left, presentation.right }) do
		assert(vim.bo[side.buf].buftype == "nofile" and not vim.bo[side.buf].buflisted)
		assert(not vim.bo[side.buf].swapfile and vim.bo[side.buf].readonly and not vim.bo[side.buf].modifiable)
		assert(review_lsp.blocked(side.buf))
	end
	local has_delete = false
	local has_add = false
	for _, details in ipairs(decoration_details(state)) do
		has_delete = has_delete or details.line_hl_group == "DiffDelete"
		has_add = has_add or details.line_hl_group == "DiffAdd"
	end
	assert(has_delete and has_add, "split sides lost old/red or new/green highlights")
	local right_win = presentation.right.win
	presenter.clear(state)
	assert(not vim.api.nvim_win_is_valid(right_win) and vim.api.nvim_win_get_buf(state.origin.win) == origin_buf)
	assert(not vim.wo[state.origin.win].diff, "origin window kept review diff state")
	assert(vim.o.scrollopt == "ver", "split changed the global scroll options")
	vim.o.scrollopt = previous_scrollopt
	mode.disable(state)
end)

test("clearing a split restores window options without replacing a user-selected buffer", function()
	local state = setup_state()
	assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
	local replacement = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(state.origin.win, replacement)
	vim.wo[state.origin.win].diff = true
	vim.wo[state.origin.win].scrollbind = true
	presenter.clear(state)
	assert(vim.api.nvim_win_get_buf(state.origin.win) == replacement)
	assert(not vim.wo[state.origin.win].diff and not vim.wo[state.origin.win].scrollbind)
	mode.disable(state)
	vim.api.nvim_buf_delete(replacement, { force = true })
end)

test("clearing a split restores a reused right window and preserves unrelated scroll options", function()
	local state = setup_state()
	local previous_scrollopt = vim.o.scrollopt
	vim.o.scrollopt = "ver"
	assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
	local right_win = state.presentation.right.win
	local replacement = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(right_win, replacement)
	vim.wo[right_win].diff = true
	vim.wo[right_win].scrollbind = true
	vim.o.scrollopt = "ver,hor,jump"
	presenter.clear(state)
	assert(vim.api.nvim_win_is_valid(right_win) and vim.api.nvim_win_get_buf(right_win) == replacement)
	assert(not vim.wo[right_win].diff and not vim.wo[right_win].scrollbind)
	assert(vim.o.scrollopt == "ver,jump", "review cleanup removed or retained the wrong scroll options")
	assert(state.window_snapshots[right_win] == nil, "review kept ownership of the reused right window")
	local user_wrap = not vim.wo[right_win].wrap
	vim.wo[right_win].wrap = user_wrap
	mode.disable(state)
	assert(vim.wo[right_win].wrap == user_wrap, "later review teardown changed the returned right window")
	vim.api.nvim_win_close(right_win, true)
	vim.api.nvim_buf_delete(replacement, { force = true })
	vim.o.scrollopt = previous_scrollopt
end)

test("clearing adopts the right split when the origin window was closed", function()
	local state, origin_buf = setup_state()
	local old_origin = state.origin.win
	local origin_options = vim.deepcopy(state.window_snapshots[old_origin].options)
	assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
	local left_buf = state.presentation.left.buf
	local right_buf = state.presentation.right.buf
	local right_win = state.presentation.right.win
	vim.api.nvim_win_close(old_origin, true)
	assert(not vim.api.nvim_win_is_valid(old_origin) and vim.api.nvim_win_is_valid(right_win))
	local cleared, clear_err = pcall(presenter.clear, state)
	assert(cleared, clear_err)
	assert(state.origin.win == right_win, "surviving right window was not adopted")
	assert(vim.api.nvim_get_current_win() == right_win, "adopted window did not regain focus")
	assert(vim.api.nvim_win_get_buf(right_win) == origin_buf, "adopted window kept a review buffer")
	for name, value in pairs(origin_options) do
		assert(vim.wo[right_win][name] == value, "adopted window option changed: " .. name)
	end
	assert(not vim.api.nvim_buf_is_valid(left_buf), "old review buffer survived cleanup")
	assert(not vim.api.nvim_buf_is_valid(right_buf), "new review snapshot survived cleanup")
	mode.disable(state)
	assert(vim.api.nvim_win_is_valid(right_win), "disable closed the adopted origin")
	assert(vim.api.nvim_win_get_buf(right_win) == origin_buf)
	assert(vim.bo[origin_buf].modifiable and not vim.bo[origin_buf].readonly)
	assert(mode.enable(state), "review could not be enabled again after adopting the window")
	assert(presenter.show(state, entry(), { layout = "inline", context = "full" }))
	mode.disable(state)
	assert(vim.api.nvim_win_get_buf(right_win) == origin_buf and vim.bo[origin_buf].modifiable)
end)

test("layout and context toggles adopt the right survivor after the left window closes", function()
	local state, origin_buf = setup_nested_fold_state()
	local old_origin = state.origin.win
	assert(presenter.show(state, fold_entry(), { layout = "split", context = "full" }))
	local first_right = state.presentation.right.win
	vim.api.nvim_win_close(old_origin, true)

	local called, toggled, toggle_err = pcall(presenter.toggle_context, state)
	assert(called, toggled)
	assert(toggled, toggle_err)
	assert(state.origin.win == first_right, "context toggle did not adopt the first right survivor")
	assert(state.presentation.layout == "split" and state.presentation.context == "hunks")
	assert(vim.api.nvim_get_current_win() == state.presentation.right.win, "context toggle lost right-side focus")

	local second_left = state.presentation.left.win
	local second_right = state.presentation.right.win
	vim.api.nvim_win_close(second_left, true)
	called, toggled, toggle_err = pcall(presenter.toggle_layout, state)
	assert(called, toggled)
	assert(toggled, toggle_err)
	assert(state.origin.win == second_right, "layout toggle did not adopt the second right survivor")
	assert(state.presentation.layout == "inline" and state.presentation.context == "hunks")
	assert(vim.api.nvim_get_current_win() == second_right, "layout toggle lost adopted-window focus")

	mode.disable(state)
	assert(vim.api.nvim_win_get_buf(second_right) == origin_buf, "toggle cleanup did not restore the ordinary buffer")
	assert(vim.wo[second_right].foldmethod == "manual" and vim.wo[second_right].foldcolumn == "2")
	assert_nested_folds(second_right)
end)

test("adopted origin window restores nested same-start manual folds and states", function()
	local state, origin_buf = setup_nested_fold_state()
	local old_origin = state.origin.win
	assert(presenter.show(state, fold_entry(), { layout = "split", context = "full" }))
	local right_win = state.presentation.right.win
	vim.api.nvim_win_close(old_origin, true)
	presenter.clear(state)
	local restored = {
		origin = state.origin.win,
		buf = vim.api.nvim_win_get_buf(right_win),
		foldmethod = vim.wo[right_win].foldmethod,
		foldenable = vim.wo[right_win].foldenable,
	}
	assert(restored.origin == right_win and restored.buf == origin_buf)
	assert(restored.foldmethod == "manual" and restored.foldenable)
	assert_nested_folds(right_win)
	mode.disable(state)
end)

test("split hunk context uses synchronized native diff folds", function()
	local state = setup_state()
	assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "hunks" }))
	local presentation = state.presentation
	assert(vim.wo[presentation.left.win].diff and vim.wo[presentation.right.win].diff)
	assert(vim.wo[presentation.left.win].foldmethod == "diff" and vim.wo[presentation.right.win].foldmethod == "diff")
	assert(vim.wo[presentation.left.win].foldenable and vim.wo[presentation.right.win].foldenable)
	mode.disable(state)
end)

test("deleted and binary entries remain metadata-safe without a right pane", function()
	local state = setup_state()
	local deleted = entry("")
	deleted.status = "D"
	deleted.new_path = nil
	deleted.path = deleted.old_path
	deleted.deleted = true
	deleted.hunks = vim.diff(deleted.old_text, "", { result_type = "indices" })
	assert(presenter.show(state, deleted, { layout = "split", context = "hunks" }))
	assert(state.presentation.left and not state.presentation.right and presenter.current_target(state).side == "old")
	presenter.clear(state)

	local binary = entry("")
	binary.binary = true
	binary.metadata_only = true
	binary.hunks = {}
	assert(presenter.show(state, binary, { layout = "inline", context = "full" }))
	local buf = state.presentation.inline.buf
	assert(review_lsp.blocked(buf))
	local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	assert(first == "[binary file]")
	mode.disable(state)
end)

test("presenter FileType keeps historical guards and ordinary mappings", function()
	local global_description = "User global implementation mapping"
	vim.keymap.set("n", "gri", function() end, { desc = global_description })
	lsp_navigation.setup()
	review_lsp.setup()

	local state, source = setup_state()
	vim.keymap.set("n", "zx", function() end, { buffer = source, desc = "Ordinary source mapping" })
	vim.api.nvim_exec_autocmds("FileType", { buffer = source })

	assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
	local left = state.presentation.left.buf
	local right = state.presentation.right.buf
	assert(vim.bo[left].filetype == "lua" and vim.bo[right].filetype == "lua")
	local detach_client = vim.lsp.buf_detach_client
	vim.lsp.buf_detach_client = function()
		return true
	end
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = left, data = { client_id = 71 } })
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = right, data = { client_id = 72 } })
	vim.lsp.buf_detach_client = detach_client
	assert_review_guards(left, GUARD_DESCRIPTION)
	assert_review_guards(right, "Review definition in current source")

	vim.api.nvim_exec_autocmds("LspAttach", { buffer = source })
	assert(not review_lsp.blocked(source))
	assert_mapping(source, "n", "gd", "Go to definition")
	assert_mapping(source, "n", "zx", "Ordinary source mapping")
	local global_mapping
	for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
		if mapping.lhs == "gri" then
			global_mapping = mapping
			break
		end
	end
	assert(global_mapping and global_mapping.desc == global_description, vim.inspect(global_mapping))

	local marked_after_filetype = vim.api.nvim_create_buf(false, true)
	vim.bo[marked_after_filetype].filetype = "lua"
	assert(review_lsp.mark(marked_after_filetype, "old"))
	assert_review_guards(marked_after_filetype, GUARD_DESCRIPTION)
	vim.api.nvim_buf_delete(marked_after_filetype, { force = true })

	mode.disable(state)
	vim.keymap.del("n", "gri")
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("review_presenter_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
