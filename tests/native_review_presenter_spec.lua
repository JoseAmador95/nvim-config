-- Host-adapter contract coverage for the extracted native review runtime.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local failures = {}
local count = 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
end

local native_review = require("config.native_review")
local mode = native_review.mode
local lsp_navigation = require("config.lsp_navigation")
local presenter = native_review.presenter
local review_lsp = native_review.lsp

local function configure_hunk_context(value)
	return require("native_review").setup({
		repo = require("config.repo"),
		fs = require("config.fs"),
		editor = require("config.editor"),
		tabs = require("config.tabs"),
		lsp_navigation = lsp_navigation,
		hunk_context = value,
	})
end

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
local UNIFIED_READ_ONLY_MAPPINGS = {
	K = "Review hover in current source",
	gD = "Review declaration in current source",
	gd = "Review definition in current source",
	gi = "Review implementation in current source",
	gr = "Review references in current source",
	gri = "Review implementation in current source",
	grr = "Review references in current source",
	grt = "Review type definition in current source",
}

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

local function assert_unified_lsp_mappings(buf)
	for _, lhs in ipairs(BLOCKED_NORMAL_MAPPINGS) do
		assert_mapping(buf, "n", lhs, UNIFIED_READ_ONLY_MAPPINGS[lhs] or GUARD_DESCRIPTION)
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
	"line 03",
	"line 04",
	"line 05 new",
	"line 06",
	"line 07",
	"line 08",
	"line 09",
	"line 10",
	"line 11",
	"line 12",
	"line 13",
	"line 14",
	"line 15",
	"line 16 new",
	"line 17",
	"line 18",
	"line 19",
	"line 20",
}
assert(vim.fn.writefile(cursor_disk_lines, cursor_path) == 0)
local symbol_path = fixture .. "/symbol.lua"
local symbol_disk_lines = { "local function outer()" }
for index = 2, 17 do
	symbol_disk_lines[index] = ("  local value_%02d = %d"):format(index, index)
end
symbol_disk_lines[18] = "end"
assert(vim.fn.writefile(symbol_disk_lines, symbol_path) == 0)

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
	old_lines[5] = "line 05 old"
	old_lines[16] = "line 16 old"
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

local function alignment_entry()
	local old_lines = {}
	for index = 1, 24 do
		old_lines[index] = ("ALIGN_%02d"):format(index)
	end
	local new_lines = {}
	for index, line in ipairs(old_lines) do
		if index ~= 18 and index ~= 19 then
			new_lines[#new_lines + 1] = line
		end
		if index == 7 then
			new_lines[#new_lines + 1] = "ALIGN_INSERT_A"
			new_lines[#new_lines + 1] = "ALIGN_INSERT_B"
		end
	end
	local old_text = table.concat(old_lines, "\n") .. "\n"
	local new_text = table.concat(new_lines, "\n") .. "\n"
	return {
		identity = "history\0alignment.lua\0alignment.lua",
		status = "M",
		layer = "history",
		old_path = "alignment.lua",
		new_path = "alignment.lua",
		path = "alignment.lua",
		old_text = old_text,
		new_text = new_text,
		hunks = vim.diff(old_text, new_text, { result_type = "indices" }),
		metadata_only = false,
		added = false,
		deleted = false,
	}
end

local function boundary_entry()
	local old_lines = {}
	for index = 1, 12 do
		old_lines[index] = ("BOUNDARY_%02d"):format(index)
	end
	local new_lines = { "BOUNDARY_INSERT_A", "BOUNDARY_INSERT_B" }
	for index = 1, 10 do
		new_lines[#new_lines + 1] = old_lines[index]
	end
	local old_text = table.concat(old_lines, "\n") .. "\n"
	local new_text = table.concat(new_lines, "\n") .. "\n"
	return {
		identity = "history\0boundary.lua\0boundary.lua",
		status = "M",
		layer = "history",
		old_path = "boundary.lua",
		new_path = "boundary.lua",
		path = "boundary.lua",
		old_text = old_text,
		new_text = new_text,
		hunks = vim.diff(old_text, new_text, { result_type = "indices" }),
		metadata_only = false,
		added = false,
		deleted = false,
	}
end

local function symbol_entry(changed_lines)
	local old_lines = vim.deepcopy(symbol_disk_lines)
	for _, index in ipairs(changed_lines) do
		old_lines[index] = ("  local value_%02d = 'old'"):format(index)
	end
	local old_text = table.concat(old_lines, "\n") .. "\n"
	local new_text = table.concat(symbol_disk_lines, "\n") .. "\n"
	return {
		identity = "history\0symbol.lua\0symbol.lua",
		status = "M",
		layer = "history",
		old_path = "symbol.lua",
		new_path = "symbol.lua",
		path = "symbol.lua",
		old_text = old_text,
		new_text = new_text,
		old_oid = string.rep("7", 40),
		new_oid = string.rep("8", 40),
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

local function decoration_for(state, win)
	for _, item in ipairs(state.presentation.decorations) do
		if item.win == win then
			return item
		end
	end
	return nil
end

local function band_details(item, band)
	local mark = vim.api.nvim_buf_get_extmark_by_id(item.buf, item.namespace, band.id, { details = true })
	assert(#mark > 0, "stored hunk band extmark is missing")
	return mark[3]
end

local function band_text(item, band)
	local details = band_details(item, band)
	return details.virt_lines[1][1][1], details
end

local function review_text_width(win)
	local info = vim.fn.getwininfo(win)[1] or {}
	return vim.api.nvim_win_get_width(win) - (tonumber(info.textoff) or 0)
end

local function assert_full_width_bands(item)
	local expected = review_text_width(item.win)
	for _, band in ipairs(item.bands) do
		local text, details = band_text(item, band)
		assert(
			vim.fn.strdisplaywidth(text) == expected,
			("hunk band %d is %d cells, expected %d"):format(band.id, vim.fn.strdisplaywidth(text), expected)
		)
		assert(details.virt_lines_leftcol ~= true, "hunk band covered the owning window's gutters")
		assert((details.virt_lines_above == true) == band.above, "hunk band edge changed during refresh")
		assert(details.virt_lines[1][1][2] == "NvimReviewNativeHunkBand")
		assert(band.rendered_width == expected, "hunk band width cache drifted from its rendered text")
	end
end

local function screen_rows(win)
	local position = vim.api.nvim_win_get_position(win)
	local values = {}
	for offset = 0, vim.api.nvim_win_get_height(win) do
		local value = ""
		for column = position[2] + 1, position[2] + vim.api.nvim_win_get_width(win) do
			local character = vim.fn.screenchar(position[1] + offset + 1, column)
			value = value .. (character > 0 and vim.fn.nr2char(character) or " ")
		end
		values[#values + 1] = vim.trim(value)
	end
	return values
end

local function screen_row(rows, text)
	for row, value in ipairs(rows) do
		if value == text then
			return row
		end
	end
	return nil
end

local function flush_scheduled()
	local done = false
	vim.schedule(function()
		done = true
	end)
	assert(
		vim.wait(200, function()
			return done
		end, 1),
		"scheduled review work did not complete"
	)
end

local function assert_same_screen_row(left, right, left_text, right_text)
	right_text = right_text or left_text
	local left_row = screen_row(left, left_text)
	local right_row = screen_row(right, right_text)
	assert(
		left_row and right_row,
		("missing screen rows for %s / %s:\nleft=%s\nright=%s"):format(
			left_text,
			right_text,
			vim.inspect(left),
			vim.inspect(right)
		)
	)
	assert(
		left_row == right_row,
		("screen rows drifted for %s / %s: %d / %d"):format(left_text, right_text, left_row, right_row)
	)
end

local function review_screen_rows(presentation)
	for _, side in ipairs({ presentation.left, presentation.right }) do
		vim.wo[side.win].number = false
		vim.wo[side.win].relativenumber = false
		vim.wo[side.win].statuscolumn = ""
		vim.wo[side.win].signcolumn = "no"
		vim.wo[side.win].wrap = false
		vim.api.nvim_win_set_cursor(side.win, { 1, 0 })
		vim.api.nvim_win_call(side.win, function()
			vim.cmd("normal! zt")
		end)
	end
	vim.cmd("diffupdate")
	vim.cmd("redraw!")
	return screen_rows(presentation.left.win), screen_rows(presentation.right.win)
end

local function assert_decoration_scopes(state, excluded_win)
	for _, item in ipairs(state.presentation.decorations) do
		local wins = vim.api.nvim__ns_get(item.namespace).wins
		if item.scoped then
			assert(
				vim.deep_equal(wins, { item.win }),
				"decoration namespace escaped its review window: " .. vim.inspect(wins)
			)
			assert(
				not excluded_win or not vim.tbl_contains(wins, excluded_win),
				"ordinary sibling received review decorations"
			)
		else
			assert(state.presentation.layout == "inline" and item.buf == state.presentation.inline.buf)
			assert(vim.deep_equal(wins, {}), "unified scratch unexpectedly scoped its private namespace")
			assert(
				not excluded_win or vim.api.nvim_win_get_buf(excluded_win) ~= item.buf,
				"ordinary sibling received the unified projection buffer"
			)
		end
	end
end

local function assert_namespaces_unscoped(decorations)
	for _, item in ipairs(decorations) do
		assert(
			vim.deep_equal(vim.api.nvim__ns_get(item.namespace).wins, {}),
			"cleared decoration namespace kept a window"
		)
	end
end

local function assert_transient_immutable(buf)
	assert(mode.active_for_buffer(buf) == nil, "scratch buffer became active current review source")
	vim.api.nvim_buf_call(buf, function()
		vim.cmd("noautocmd setlocal noreadonly")
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "readonly" })
		vim.cmd("noautocmd setlocal modifiable")
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "modifiable" })
	end)
	assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable, "scratch buffer escaped protection")
	assert(not pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { "mutated" }))
end

test("inline hunks use configured context and keep only the review window out of concealed gaps", function()
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
		local projection_buf = state.presentation.inline.buf
		assert(projection_buf ~= buf and vim.api.nvim_win_get_buf(review_win) == projection_buf)
		assert_decoration_scopes(state, ordinary_win)
		assert(vim.o.diffopt == "internal,filler,closeoff,context:7", "inline hunks mutated diffopt")
		local guard =
			assert(state.presentation.cursor_guards[review_win], "inline hunks did not install a cursor guard")
		assert(guard.win == review_win and guard.buf == projection_buf and type(guard.generation) == "number")
		assert(state.presentation.hunk_context == 3)
		assert(vim.deep_equal(guard.sections, {
			{ first = 2, hunks = { 1 }, last = 9 },
			{ first = 14, hunks = { 2 }, last = 21 },
		}))
		assert(vim.api.nvim_win_get_cursor(review_win)[1] == 2, "leading context was not clamped")
		assert(vim.wo[review_win].concealcursor == "nvic")
		local winbar = vim.wo[review_win].winbar
		for _, fragment in ipairs({
			"REV ON",
			"branch:topic%%ready",
			"history",
			"inline/hunks",
			"comments:off",
			"OLD │ NEW",
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

		assert(move_and_fire(review_win, projection_buf, 9) == 9)
		assert(move_and_fire(review_win, projection_buf, 10) == 14, "forward section exit did not jump forward")
		assert(move_and_fire(review_win, projection_buf, 14) == 14)
		assert(move_and_fire(review_win, projection_buf, 13) == 9, "backward section exit did not jump backward")
		assert(
			move_and_fire(review_win, projection_buf, 12) == 14,
			"direct gap jump did not choose the nearest boundary"
		)
		assert(move_and_fire(review_win, projection_buf, 11) == 9, "direct gap jump chose the wrong boundary")
		assert(move_and_fire(review_win, projection_buf, 1) == 2, "leading gap did not clamp to the first section")
		assert(move_and_fire(review_win, projection_buf, 22) == 21, "trailing gap did not clamp to the last section")
		assert(presenter.reveal_rows(state, { 11 }, guard.generation))
		assert(move_and_fire(review_win, projection_buf, 11) == 11, "explicitly revealed comment row stayed concealed")
		assert(vim.deep_equal(guard.sections, {
			{ first = 2, last = 9 },
			{ first = 11, last = 11 },
			{ first = 14, last = 21 },
		}))

		assert(move_and_fire(review_win, projection_buf, 5) == 5)
		assert(presenter.prev_hunk(state) and vim.api.nvim_win_get_cursor(review_win)[1] == 17, "[h lost wrapping")
		assert(presenter.next_hunk(state) and vim.api.nvim_win_get_cursor(review_win)[1] == 5, "]h lost wrapping")

		assert(move_and_fire(ordinary_win, buf, 10) == 10, "guard trapped an ordinary window of the same buffer")
		assert(vim.wo[ordinary_win].winbar == "ordinary sibling", "review changed an ordinary window winbar")

		local old_generation = guard.generation
		assert(presenter.toggle_context(state))
		assert(
			not guard.active and next(state.presentation.cursor_guards) == nil,
			"full context retained the old guard"
		)
		assert(state.presentation.context == "full" and vim.o.diffopt == "internal,filler,closeoff,context:7")
		local full_buf = state.presentation.inline.buf
		assert_decoration_scopes(state, ordinary_win)
		for _, details in ipairs(decoration_details(state)) do
			assert(details.conceal_lines == nil, "full context retained a concealed range")
			for _, virtual in ipairs(details.virt_lines or {}) do
				assert(not (virtual[1] and virtual[1][1] or ""):find("HUNK", 1, true))
			end
		end
		assert(move_and_fire(review_win, full_buf, 10) == 10, "full context still trapped the cursor")

		assert(presenter.toggle_context(state))
		local replacement =
			assert(state.presentation.cursor_guards[review_win], "hunk context did not recreate the guard")
		assert(replacement.generation ~= old_generation, "presentation generation was reused")
		assert(replacement.buf == state.presentation.inline.buf)
		assert_decoration_scopes(state, ordinary_win)
		local cleared_decorations = vim.deepcopy(state.presentation.decorations)
		presenter.clear(state)
		assert_namespaces_unscoped(cleared_decorations)
		assert(not presenter.refresh_winbars(state), "winbar refresh claimed an absent presentation")
		assert(not replacement.active and state.presentation == nil, "clear retained the cursor guard")
		assert(vim.wo[review_win].winbar == "%#Title#ordinary %% cursor%*", "clear did not restore winbar")
		assert(move_and_fire(review_win, buf, 10) == 10, "cleared presentation still trapped the cursor")
	end, debug.traceback)
	vim.o.diffopt = previous_diffopt
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	if ordinary_win and vim.api.nvim_win_is_valid(ordinary_win) then
		vim.api.nvim_win_close(ordinary_win, true)
	end
	assert(ok, err)
end)

test("inline hunk scrolling retains the same rows as a complete redraw", function()
	local state = setup_state()
	local win = state.origin.win
	local previous_scrolloff = vim.o.scrolloff
	local previous_cursorline = vim.wo[win].cursorline
	local ok, err = xpcall(function()
		vim.o.scrolloff = 10
		vim.wo[win].cursorline = true
		local selected = entry()
		local old, new = {}, {}
		for index = 1, 200 do
			old[index] = ("ORIGINAL_LINE_%03d %s"):format(index, string.rep("x", index % 36))
			new[index] = old[index]
		end
		for _, index in ipairs({ 5, 25, 40, 75, 100, 130, 160, 180, 195 }) do
			new[index] = ("CHANGED_LINE_%03d"):format(index)
		end
		selected.old_text = table.concat(old, "\n") .. "\n"
		selected.new_text = table.concat(new, "\n") .. "\n"
		selected.hunks = vim.diff(selected.old_text, selected.new_text, { result_type = "indices" })
		assert(presenter.show(state, selected, { layout = "inline", context = "hunks" }))
		local buf = state.presentation.inline.buf
		local commands = {}
		for _, command in ipairs({ "j", "k" }) do
			for _ = 1, 28 do
				commands[#commands + 1] = command
			end
		end
		for _ = 1, 13 do
			commands[#commands + 1] = "\005"
		end
		vim.list_extend(commands, { "\025", "\025", "\004", "zz", "zt", "zb", "gg", "G" })
		vim.cmd("redraw!")
		for index, command in ipairs(commands) do
			local before = vim.fn.winsaveview()
			vim.api.nvim_feedkeys(command, "xt", false)
			vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
			local after = vim.fn.winsaveview()
			if
				before.topline ~= after.topline
				or before.topfill ~= after.topfill
				or before.leftcol ~= after.leftcol
				or before.skipcol ~= after.skipcol
			then
				-- Script-driven input does not run the main loop's WinScrolled dispatch.
				vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win), modeline = false })
			end
			flush_scheduled()
			vim.cmd("redraw")
			local actual = screen_rows(win)
			vim.cmd("redraw!")
			local expected = screen_rows(win)
			-- The ruler in the statusline has its own deferred refresh policy.
			table.remove(actual)
			table.remove(expected)
			assert(
				vim.deep_equal(actual, expected),
				("scroll step %d (%s) left stale rows:\nactual=%s\nexpected=%s"):format(
					index,
					vim.inspect(command),
					vim.inspect(actual),
					vim.inspect(expected)
				)
			)
		end
		assert(vim.o.scrolloff == 10, "review scrolling changed the user's scrolloff")
	end, debug.traceback)
	pcall(mode.disable, state)
	vim.o.scrolloff = previous_scrolloff
	vim.wo[win].cursorline = previous_cursorline
	assert(ok, err)
end)

test("inline hunk redraws are coalesced and stop with their owning presentation", function()
	local state, source, selected = setup_cursor_state()
	local win = state.origin.win
	local original_redraw = vim.api.nvim__redraw
	local redraws = {}
	local function scroll(target)
		vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(target or win), modeline = false })
	end
	local ok, err = xpcall(function()
		assert(presenter.show(state, selected))
		flush_scheduled()
		vim.api.nvim__redraw = function(options)
			if options.win == win and options.valid == false then
				redraws[#redraws + 1] = options
			end
			return original_redraw(options)
		end
		scroll(win + 100000)
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.presentation.inline.buf })
		flush_scheduled()
		assert(#redraws == 0, "ordinary cursor movement or another window invalidated review rows")
		scroll()
		scroll()
		assert(#redraws == 0, "review redraw ran inside WinScrolled")
		flush_scheduled()
		assert(vim.deep_equal(redraws, { { win = win, valid = false } }), vim.inspect(redraws))
		redraws = {}
		scroll()
		assert(presenter.toggle_context(state))
		flush_scheduled()
		scroll()
		flush_scheduled()
		assert(#redraws == 0, "old or full-context presentation invalidated rows")
		assert(presenter.toggle_context(state))
		scroll()
		vim.api.nvim_win_set_buf(win, source)
		flush_scheduled()
		assert(#redraws == 0, "queued redraw touched a replacement buffer")
		assert(presenter.show(state, selected, { layout = "split", context = "hunks" }))
		scroll()
		flush_scheduled()
		assert(#redraws == 0, "split review installed the inline redraw workaround")
		assert(presenter.show(state, selected))
		scroll()
		presenter.clear(state)
		flush_scheduled()
		scroll()
		flush_scheduled()
		assert(#redraws == 0, "cleared presentation kept a redraw callback")
	end, debug.traceback)
	vim.api.nvim__redraw = original_redraw
	pcall(mode.disable, state)
	assert(ok, err)
end)

test("inline isolation avoids namespace scoping while split remains fail-closed", function()
	local state, real = setup_state()
	local original_ns_set = vim.api.nvim__ns_set
	local ok, err = xpcall(function()
		vim.api.nvim__ns_set = function()
			error("simulated namespace failure")
		end
		assert(presenter.show(state, entry(), { layout = "inline", context = "full" }))
		local inline = state.presentation.inline
		assert(inline.buf ~= real and vim.api.nvim_win_get_buf(inline.win) == inline.buf)
		local item = assert(decoration_for(state, inline.win))
		assert(not item.scoped and vim.deep_equal(vim.api.nvim__ns_get(item.namespace).wins, {}))
		presenter.clear(state)

		local shown, show_err = presenter.show(state, entry(), { layout = "split", context = "full" })
		assert(shown == nil and show_err:find("simulated namespace failure", 1, true), show_err)
		assert(state.presentation == nil and vim.api.nvim_win_get_buf(state.origin.win) == real)
	end, debug.traceback)
	vim.api.nvim__ns_set = original_ns_set
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	assert(ok, err)
end)

test("presenter reads the single configured hunk context for its visibility plan", function()
	configure_hunk_context(1)
	local state, _, selected = setup_cursor_state()
	local called, shown, show_err = pcall(presenter.show, state, selected)
	configure_hunk_context(3)
	assert(called and shown, show_err)
	local guard = assert(state.presentation.cursor_guards[state.origin.win])
	assert(state.presentation.hunk_context == 1)
	assert(vim.deep_equal(guard.sections, {
		{ first = 4, hunks = { 1 }, last = 7 },
		{ first = 16, hunks = { 2 }, last = 19 },
	}))
	mode.disable(state)
end)

test("hunk bands use silent Tree-sitter textobject symbols only when declarations are hidden", function()
	vim.treesitter.query.set("lua", "textobjects", "[(function_declaration) @function.outer]")
	local state = setup_state(nil, symbol_path, "symbol.lua")
	assert(presenter.show(state, symbol_entry({ 3 }), { layout = "inline", context = "hunks" }))
	local first_header
	for _, details in ipairs(decoration_details(state)) do
		for _, virtual in ipairs(details.virt_lines or {}) do
			local text = virtual[1] and virtual[1][1] or ""
			if text:find(" HUNK 1/1 ", 1, true) == 1 then
				first_header = text
			end
		end
	end
	assert(first_header and not first_header:find("function outer", 1, true), vim.inspect(first_header))

	assert(presenter.show(state, symbol_entry({ 12 }), { layout = "inline", context = "hunks" }))
	local hidden_header
	for _, details in ipairs(decoration_details(state)) do
		for _, virtual in ipairs(details.virt_lines or {}) do
			local text = virtual[1] and virtual[1][1] or ""
			if text:find(" HUNK 1/1 ", 1, true) == 1 then
				hidden_header = text
			end
		end
	end
	assert(hidden_header and hidden_header:find("HUNK 1/1 · function outer", 1, true), vim.inspect(hidden_header))
	mode.disable(state)
end)

test("native hunk bands fill only the text area and refresh in place", function()
	local state, buf, selected = setup_cursor_state()
	local review_win = state.origin.win
	local sibling
	local sign_namespace = vim.api.nvim_create_namespace("nvim_review_presenter_band_sign_test")
	local original_set_extmark = vim.api.nvim_buf_set_extmark
	local legacy_highlight = vim.api.nvim_get_hl(0, { name = "NvimReviewHunkBand", link = true })
	local native_highlight = vim.api.nvim_get_hl(0, { name = "NvimReviewNativeHunkBand", link = true })
	local ok, err = xpcall(function()
		vim.api.nvim_set_current_win(review_win)
		vim.cmd("rightbelow vsplit")
		sibling = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(review_win)
		vim.api.nvim_win_set_width(review_win, 36)
		vim.wo[review_win].number = true
		vim.wo[review_win].foldcolumn = "1"
		vim.wo[review_win].statuscolumn = ""

		assert(presenter.show(state, selected, { layout = "inline", context = "hunks" }))
		local presentation = state.presentation
		local item = assert(decoration_for(state, review_win))
		local projection_buf = item.buf
		assert(#item.bands == 4 and presentation.band_refresh_autocmd, "hunk bands lack refresh ownership")
		assert_full_width_bands(item)
		local original_ids = vim.tbl_map(function(band)
			return band.id
		end, item.bands)

		item.bands[1].label = " HUNK 1/2 · function " .. string.rep("界🚀", 40) .. " "
		assert(presenter.refresh_bands(state))
		assert(presentation.band_refresh_pending, "band refresh was not scheduled")
		assert(
			vim.wait(200, function()
				return not presentation.band_refresh_pending
			end, 5),
			"scheduled band refresh did not run"
		)
		local fitted = band_text(item, item.bands[1])
		assert(vim.trim(fitted):sub(-3) == "…", "long Unicode label was not ellipsized: " .. fitted)
		assert(pcall(vim.str_utfindex, fitted), "band truncation produced invalid UTF-8")
		assert_full_width_bands(item)

		local before_resize = review_text_width(review_win)
		vim.api.nvim_win_set_width(review_win, vim.api.nvim_win_get_width(review_win) - 7)
		local refresh_calls = 0
		local band_ids = {}
		for _, id in ipairs(original_ids) do
			band_ids[id] = true
		end
		vim.api.nvim_buf_set_extmark = function(target_buf, namespace, row, column, options)
			if target_buf == item.buf and namespace == item.namespace and options.id and band_ids[options.id] then
				refresh_calls = refresh_calls + 1
			end
			return original_set_extmark(target_buf, namespace, row, column, options)
		end
		vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
		assert(presenter.refresh_bands(state) and presenter.refresh_bands(state), "refresh did not coalesce")
		assert(
			vim.wait(200, function()
				return not presentation.band_refresh_pending
			end, 5),
			"resize refresh did not run"
		)
		vim.api.nvim_buf_set_extmark = original_set_extmark
		assert(refresh_calls == #item.bands, "coalesced refresh updated a band more than once")
		assert(review_text_width(review_win) < before_resize, "window resize did not reduce the text area")
		assert(
			vim.deep_equal(
				original_ids,
				vim.tbl_map(function(band)
					return band.id
				end, item.bands)
			),
			"resize replaced hunk band extmark IDs"
		)
		assert_full_width_bands(item)

		local before_sign = review_text_width(review_win)
		local generic_refresh_calls = 0
		vim.api.nvim_buf_set_extmark = function(target_buf, namespace, row, column, options)
			if target_buf == item.buf and namespace == item.namespace and options.id and band_ids[options.id] then
				generic_refresh_calls = generic_refresh_calls + 1
			end
			return original_set_extmark(target_buf, namespace, row, column, options)
		end
		for _ = 1, 3 do
			vim.api.nvim_buf_set_extmark(projection_buf, sign_namespace, 4, 0, {
				sign_hl_group = "ErrorMsg",
				sign_text = "!!",
			})
		end
		vim.cmd("redraw!")
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = projection_buf, modeline = false })
		assert(presentation.band_refresh_pending, "generic sign-gutter refresh was not scheduled")
		assert(
			vim.wait(200, function()
				return not presentation.band_refresh_pending
			end, 5),
			"sign-gutter refresh did not run"
		)
		assert(generic_refresh_calls == #item.bands, "generic refresh did not update each changed-width band once")
		assert(review_text_width(review_win) < before_sign, "automatic sign gutter did not grow")
		local signed_width = review_text_width(review_win)
		assert(
			vim.deep_equal(
				original_ids,
				vim.tbl_map(function(band)
					return band.id
				end, item.bands)
			),
			"sign-gutter refresh replaced hunk band extmark IDs"
		)
		assert_full_width_bands(item)

		generic_refresh_calls = 0
		vim.api.nvim_exec_autocmds("CursorHold", { buffer = projection_buf, modeline = false })
		assert(presentation.band_refresh_pending, "no-op generic refresh was not scheduled")
		assert(
			vim.wait(200, function()
				return not presentation.band_refresh_pending
			end, 5),
			"no-op generic refresh did not run"
		)
		assert(generic_refresh_calls == 0, "unchanged-width generic refresh rewrote hunk extmarks")

		vim.api.nvim_buf_clear_namespace(projection_buf, sign_namespace, 0, -1)
		vim.cmd("redraw!")
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = projection_buf, modeline = false })
		assert(presentation.band_refresh_pending, "sign-removal refresh was not scheduled")
		assert(
			vim.wait(200, function()
				return not presentation.band_refresh_pending
			end, 5),
			"sign-removal refresh did not run"
		)
		vim.api.nvim_buf_set_extmark = original_set_extmark
		assert(generic_refresh_calls == #item.bands, "sign removal did not update each changed-width band once")
		assert(review_text_width(review_win) > signed_width, "sign removal did not release gutter width")
		assert(
			vim.deep_equal(
				original_ids,
				vim.tbl_map(function(band)
					return band.id
				end, item.bands)
			),
			"generic sign removal replaced hunk band extmark IDs"
		)
		assert_full_width_bands(item)

		vim.api.nvim_set_hl(0, "NvimReviewHunkBand", { link = "ErrorMsg" })
		vim.api.nvim_set_hl(0, "NvimReviewNativeHunkBand", { link = "ErrorMsg" })
		vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "native-review-band-test", modeline = false })
		assert(
			vim.api.nvim_get_hl(0, { name = "NvimReviewNativeHunkBand", link = true }).link == "ErrorMsg",
			"ColorScheme replaced a user-defined native hunk band"
		)
		assert(
			vim.api.nvim_get_hl(0, { name = "NvimReviewHunkBand", link = true }).link == "ErrorMsg",
			"native presenter collided with the legacy Diffview band group"
		)
		vim.cmd("highlight clear NvimReviewNativeHunkBand")
		vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "native-review-band-fallback", modeline = false })
		assert(
			vim.api.nvim_get_hl(0, { name = "NvimReviewNativeHunkBand", link = true }).link == "StatusLine",
			"ColorScheme did not restore the visible native hunk band fallback"
		)
		assert_full_width_bands(item)

		local refresh_autocmd = presentation.band_refresh_autocmd
		local stale_calls = 0
		vim.api.nvim_buf_set_extmark = function(target_buf, namespace, row, column, options)
			if options.id then
				stale_calls = stale_calls + 1
			end
			return original_set_extmark(target_buf, namespace, row, column, options)
		end
		assert(presenter.refresh_bands(state))
		assert(presenter.toggle_context(state), "could not toggle hunk context to full")
		assert(state.presentation.context == "full" and state.presentation.band_refresh_autocmd == nil)
		for _, full_item in ipairs(state.presentation.decorations) do
			assert(#full_item.bands == 0, "full context retained native hunk bands")
		end
		vim.wait(30, function()
			return false
		end, 5)
		vim.api.nvim_buf_set_extmark = original_set_extmark
		assert(stale_calls == 0, "queued hunk refresh repainted after a context toggle")
		assert(#vim.api.nvim_get_autocmds({ id = refresh_autocmd }) == 0, "toggle retained the old refresh hook")
		assert(not presenter.refresh_bands(state), "full context scheduled a hunk band refresh")

		assert(presenter.toggle_context(state), "could not toggle full context back to hunks")
		presentation = state.presentation
		assert(presenter.refresh_bands(state))
		stale_calls = 0
		vim.api.nvim_buf_set_extmark = function(target_buf, namespace, row, column, options)
			if options.id then
				stale_calls = stale_calls + 1
			end
			return original_set_extmark(target_buf, namespace, row, column, options)
		end
		presenter.clear(state)
		vim.wait(30, function()
			return false
		end, 5)
		vim.api.nvim_buf_set_extmark = original_set_extmark
		assert(stale_calls == 0 and state.presentation == nil, "queued hunk refresh repainted after clear")
		assert(not presenter.refresh_bands(state), "cleared presenter accepted a band refresh")
	end, debug.traceback)
	vim.api.nvim_buf_set_extmark = original_set_extmark
	vim.api.nvim_set_hl(0, "NvimReviewHunkBand", legacy_highlight)
	vim.api.nvim_set_hl(0, "NvimReviewNativeHunkBand", native_highlight)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, sign_namespace, 0, -1)
	end
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	if sibling and vim.api.nvim_win_is_valid(sibling) then
		vim.api.nvim_win_close(sibling, true)
	end
	assert(ok, err)
end)

test("inline hunks without hunks install neither concealment nor cursor guard", function()
	local state, buf, selected = setup_cursor_state()
	selected.old_text = selected.new_text
	selected.hunks = {}
	assert(presenter.show(state, selected))
	local projection_buf = state.presentation.inline.buf
	assert(next(state.presentation.cursor_guards) == nil)
	for _, details in ipairs(decoration_details(state)) do
		assert(details.conceal_lines == nil and details.virt_lines == nil, "empty diff added hunk presentation")
	end
	assert(move_and_fire(state.origin.win, projection_buf, 6) == 6, "empty diff trapped the cursor")
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

test("split code panes enforce absolute line numbers and restore invocation options", function()
	local original_statuscolumn = "%s"
	local state = setup_state(function(win)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = true
		vim.wo[win].statuscolumn = original_statuscolumn
	end)
	local ok, err = xpcall(function()
		assert(presenter.show(state, entry(), { layout = "split", context = "full" }))
		local presentation = state.presentation
		for _, side in ipairs({ presentation.left, presentation.right }) do
			assert(vim.wo[side.win].number, side.side .. " split pane did not show line numbers")
			assert(not vim.wo[side.win].relativenumber, side.side .. " split pane retained relative line numbers")
			assert(vim.wo[side.win].statuscolumn == "", side.side .. " split pane retained a custom status column")
		end
		presenter.clear(state)
		assert(not vim.wo[state.origin.win].number, "split cleanup did not restore nonumber")
		assert(vim.wo[state.origin.win].relativenumber, "split cleanup did not restore relativenumber")
		assert(
			vim.wo[state.origin.win].statuscolumn == original_statuscolumn,
			"split cleanup did not restore statuscolumn"
		)
	end, debug.traceback)
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	assert(ok, err)
end)

test("split highlight namespaces are side-local and restore only their own ownership", function()
	local state, buf = setup_state()
	local origin_win = state.origin.win
	local sibling
	local prior_namespace = vim.api.nvim_create_namespace("nvim_review_presenter_prior_highlights")
	local sibling_namespace = vim.api.nvim_create_namespace("nvim_review_presenter_sibling_highlights")
	local foreign_namespace = vim.api.nvim_create_namespace("nvim_review_presenter_foreign_highlights")
	local ok, err = xpcall(function()
		vim.api.nvim_win_set_hl_ns(origin_win, prior_namespace)
		vim.api.nvim_set_current_win(origin_win)
		vim.cmd("rightbelow vsplit")
		sibling = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_hl_ns(sibling, sibling_namespace)
		vim.api.nvim_set_current_win(origin_win)

		assert(presenter.show(state, entry(), { layout = "inline", context = "hunks" }))
		local inline_item = assert(decoration_for(state, origin_win))
		assert(vim.api.nvim_get_hl_ns({ winid = origin_win }) == prior_namespace)
		assert(not inline_item.split_highlight_namespace, "inline rendering activated its decoration namespace")
		assert(vim.api.nvim_get_hl_ns({ winid = sibling }) == sibling_namespace)

		assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
		local presentation = state.presentation
		local left_item = assert(decoration_for(state, presentation.left.win))
		local right_item = assert(decoration_for(state, presentation.right.win))
		assert(left_item.previous_hl_namespace == prior_namespace, "left side did not record the exact prior namespace")
		assert(vim.api.nvim_get_hl_ns({ winid = presentation.left.win }) == left_item.namespace)
		assert(vim.api.nvim_get_hl_ns({ winid = presentation.right.win }) == right_item.namespace)
		assert(vim.api.nvim_get_hl_ns({ winid = sibling }) == sibling_namespace)
		assert_decoration_scopes(state, sibling)
		for _, group in ipairs({ "DiffAdd", "DiffChange", "DiffText", "DiffTextAdd" }) do
			assert(vim.tbl_isempty(vim.api.nvim_get_hl(left_item.namespace, { name = group, link = true })))
			assert(vim.tbl_isempty(vim.api.nvim_get_hl(right_item.namespace, { name = group, link = true })))
		end
		assert(vim.api.nvim_get_hl(left_item.namespace, { name = "DiffDelete", link = true }).link == "Normal")
		assert(vim.api.nvim_get_hl(right_item.namespace, { name = "DiffDelete", link = true }).link == "Normal")
		assert(
			vim.api.nvim_get_hl(left_item.namespace, { name = "NvimReviewNativeDiffOld", link = true }).link
				== "NvimReviewNativeDiffOld"
		)
		assert(
			vim.api.nvim_get_hl(right_item.namespace, { name = "NvimReviewNativeDiffNew", link = true }).link
				== "NvimReviewNativeDiffNew"
		)
		assert(
			vim.tbl_isempty(
				vim.api.nvim_get_hl(left_item.namespace, { name = "NvimReviewNativeHunkBand", link = true })
			),
			"left split shadowed the global hunk band customization"
		)
		assert(
			vim.tbl_isempty(
				vim.api.nvim_get_hl(right_item.namespace, { name = "NvimReviewNativeHunkBand", link = true })
			),
			"right split shadowed the global hunk band customization"
		)

		presenter.clear(state)
		assert(vim.api.nvim_get_hl_ns({ winid = origin_win }) == prior_namespace, "clear lost the prior namespace")
		assert(vim.api.nvim_get_hl_ns({ winid = sibling }) == sibling_namespace)

		assert(presenter.show(state, entry("one\nhistorical\nthree\n"), { layout = "split", context = "full" }))
		vim.api.nvim_win_set_hl_ns(origin_win, foreign_namespace)
		presenter.clear(state)
		assert(
			vim.api.nvim_get_hl_ns({ winid = origin_win }) == foreign_namespace,
			"clear clobbered a third-party highlight namespace replacement"
		)
		assert(vim.api.nvim_get_hl_ns({ winid = sibling }) == sibling_namespace)
	end, debug.traceback)
	pcall(presenter.clear, state)
	if vim.api.nvim_win_is_valid(origin_win) then
		vim.api.nvim_win_set_hl_ns(origin_win, -1)
	end
	if sibling and vim.api.nvim_win_is_valid(sibling) then
		vim.api.nvim_win_set_hl_ns(sibling, -1)
		vim.api.nvim_win_close(sibling, true)
	end
	pcall(mode.disable, state)
	assert(vim.api.nvim_buf_is_valid(buf))
	assert(ok, err)
end)

test("inline uses one protected unified buffer with cursorable OLD and NEW rows", function()
	local original_statuscolumn = "%=%l "
	local state, real = setup_state(function(win)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = true
		vim.wo[win].numberwidth = 7
		vim.wo[win].statuscolumn = original_statuscolumn
	end)
	local original_tab = state.origin.tab
	assert(presenter.show(state, entry(), { layout = "inline", context = "hunks" }))
	local presentation = state.presentation
	local inline = presentation.inline
	local unified = inline.buf
	assert(unified ~= real and inline.side == "unified" and not inline.real)
	assert(vim.api.nvim_get_current_tabpage() == original_tab and #vim.api.nvim_list_tabpages() == 1)
	assert(review_lsp.blocked(unified) and vim.b[unified].nvim_review_role == "unified")
	assert(review_lsp._mirrors[unified], "unified review did not start its CURRENT diagnostic mirror")
	assert_unified_lsp_mappings(unified)
	assert(vim.b[unified].nvim_review_projection_generation == presentation.generation)
	assert(vim.bo[unified].readonly and not vim.bo[unified].modifiable)
	assert_transient_immutable(unified)
	assert(not vim.wo[state.origin.win].foldenable, "inline review retained unrelated manual folds")
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(unified, 0, -1, false), { "one", "old", "new", "three" }))
	assert(vim.deep_equal(
		vim.tbl_map(function(row)
			return row.kind
		end, presentation.projection.rows),
		{ "context", "old", "new", "context" }
	))

	local line_highlights = {}
	local has_band = false
	for _, item in ipairs(presentation.decorations) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true })) do
			local details = mark[4]
			if details.hl_group == "NvimReviewNativeDiffOld" or details.hl_group == "NvimReviewNativeDiffNew" then
				line_highlights[mark[2] + 1] = details.hl_group
			end
			for _, virtual in ipairs(details.virt_lines or {}) do
				local text = virtual[1] and virtual[1][1] or ""
				has_band = has_band or text:find("HUNK", 1, true) ~= nil
			end
		end
	end
	assert(
		vim.deep_equal(line_highlights, { [2] = "NvimReviewNativeDiffOld", [3] = "NvimReviewNativeDiffNew" }),
		vim.inspect(line_highlights)
	)
	assert(has_band, "inline hunk boundary bands are missing")

	vim.api.nvim_win_set_cursor(inline.win, { 1, 0 })
	local context_target = assert(presenter.current_target(state))
	assert(context_target.side == "new" and context_target.line == 1 and context_target.old_line == 1)
	vim.api.nvim_win_set_cursor(inline.win, { 2, 0 })
	local old_target = assert(presenter.current_target(state))
	assert(old_target.side == "old" and old_target.anchor_side == "left" and old_target.line == 2)
	vim.api.nvim_win_set_cursor(inline.win, { 3, 0 })
	local new_target = assert(presenter.current_target(state))
	assert(new_target.side == "new" and new_target.anchor_side == "right" and new_target.line == 2)
	local old_range = assert(presenter.resolve_range(state, 2, 2, presentation.generation))
	assert(old_range.side == "old" and old_range.anchor_side == "left" and old_range.start_line == 2)
	local mixed, mixed_err = presenter.resolve_range(state, 2, 3, presentation.generation)
	assert(mixed == nil and mixed_err:find("crosses OLD-only and NEW-only", 1, true), mixed_err)
	local shared_old = assert(presenter.resolve_range(state, 1, 1, presentation.generation, "left"))
	assert(shared_old.side == "old" and shared_old.anchor_side == "left" and shared_old.start_line == 1)
	local old_context = assert(presenter.locate_anchor(state, {
		kind = "range",
		layer = "history",
		path = "sample.lua",
		side = "left",
		start_line = 1,
		end_line = 2,
	}, presentation.generation))
	assert(old_context.display_line == 1 and old_context.side == "old" and old_context.path == "sample.lua")
	assert(vim.deep_equal(
		presenter.rows_for_anchor(state, {
			kind = "range",
			path = "sample.lua",
			side = "left",
			start_line = 1,
			end_line = 2,
		}, presentation.generation),
		{ 1, 2 }
	))
	local new_location = assert(presenter.locate_anchor(state, {
		kind = "range",
		path = "sample.lua",
		side = "right",
		start_line = 2,
	}, presentation.generation))
	assert(new_location.display_line == 3 and new_location.side == "new")

	local mapping = buffer_mapping(unified, "n", "]h")
	assert(mapping.desc == "Next review hunk")
	vim.api.nvim_win_set_cursor(inline.win, { 4, 0 })
	assert(presenter.next_hunk(state) and vim.api.nvim_win_get_cursor(inline.win)[1] == 2)
	assert(vim.wo[inline.win].number and not vim.wo[inline.win].relativenumber)
	assert(vim.wo[inline.win].statuscolumn:find("native_review.presenter", 1, true))
	local sign_namespace = vim.api.nvim_create_namespace("nvim_review_unified_gutter_sign")
	vim.api.nvim_buf_set_extmark(unified, sign_namespace, 1, 0, {
		sign_hl_group = "DiagnosticInfo",
		sign_text = "C>",
	})
	vim.cmd("redraw!")
	local evaluated = vim.api.nvim_eval_statusline(vim.wo[inline.win].statuscolumn, {
		highlights = true,
		use_statuscol_lnum = 2,
		winid = inline.win,
	})
	assert(evaluated.str:find("C>", 1, true), vim.inspect(evaluated))
	assert(evaluated.str:find("2", 1, true) and evaluated.str:find("│", 1, true), vim.inspect(evaluated))

	local generation = presentation.generation
	assert(presenter.toggle_context(state))
	assert(review_lsp._mirrors[unified] == nil, "replaced unified review retained its diagnostic mirror")
	assert(vim.api.nvim_win_get_cursor(state.presentation.inline.win)[1] == 2, "context toggle lost the display row")
	local stale, stale_err = presenter.source_at(state, 2, generation)
	assert(stale == nil and stale_err:find("generation changed", 1, true), stale_err)
	for _, details in ipairs(decoration_details(state)) do
		for _, virtual in ipairs(details.virt_lines or {}) do
			local text = virtual[1] and virtual[1][1] or ""
			assert(not text:find("HUNK", 1, true), "full context retained hunk boundary bands")
		end
	end
	local replacement = state.presentation.inline.buf
	assert(review_lsp._mirrors[replacement], "replacement unified review has no diagnostic mirror")
	presenter.clear(state)
	assert(review_lsp._mirrors[replacement] == nil, "cleared unified review retained its diagnostic mirror")
	assert(vim.api.nvim_win_get_buf(state.origin.win) == real)
	assert(not vim.wo[state.origin.win].number and vim.wo[state.origin.win].relativenumber)
	assert(vim.wo[state.origin.win].numberwidth == 7 and vim.wo[state.origin.win].statuscolumn == original_statuscolumn)
	mode.disable(state)
end)

test("unified renames retain distinct OLD and NEW paths across layout toggles", function()
	local state, real = setup_state()
	local selected = entry()
	selected.old_path = "before.lua"
	selected.identity = "history\0before.lua\0sample.lua"
	local window_count = #vim.api.nvim_tabpage_list_wins(state.origin.tab)
	assert(presenter.show(state, selected, { layout = "inline", context = "full" }))
	local presentation = state.presentation
	local inline = presentation.inline
	assert(inline.side == "unified" and not inline.real and inline.buf ~= real)
	assert(#vim.api.nvim_tabpage_list_wins(state.origin.tab) == window_count, "inline rename opened a split")
	assert(vim.wo[inline.win].winbar:find("before.lua → sample.lua", 1, true))
	local old = assert(presenter.source_at(state, 2, presentation.generation))
	local new = assert(presenter.source_at(state, 3, presentation.generation))
	assert(old.side == "old" and old.path == "before.lua")
	assert(new.side == "new" and new.path == "sample.lua")
	assert(assert(presenter.locate_anchor(state, {
		kind = "range",
		path = "before.lua",
		side = "left",
		start_line = 2,
	})).display_line == 2)
	assert(presenter.toggle_layout(state))
	assert(state.presentation.layout == "split" and state.presentation.left and state.presentation.right)
	assert(presenter.toggle_layout(state))
	assert(state.presentation.layout == "inline" and state.presentation.inline.side == "unified")
	presenter.clear(state)
	assert(vim.api.nvim_win_get_buf(state.origin.win) == real)
	mode.disable(state)
end)

test("logical locations survive unified projection rebuilds and reveal concealed rows", function()
	local state, _, selected = setup_cursor_state()
	assert(presenter.show(state, selected, { layout = "inline", context = "full" }))
	local full = state.presentation
	local source_line = 10
	local display_line = assert(full.projection.by_source.new[source_line])
	vim.api.nvim_set_current_win(full.inline.win)
	vim.api.nvim_win_set_cursor(full.inline.win, { display_line, 3 })
	local location = assert(presenter.capture_location(state))
	assert(vim.deep_equal(location, {
		entry_identity = selected.identity,
		layer = "history",
		side = "new",
		path = selected.new_path,
		line = source_line,
		col = 4,
	}))

	assert(presenter.show(state, selected, { layout = "inline", context = "hunks" }))
	local hunks = state.presentation
	local target_line = assert(hunks.projection.by_source.new[source_line])
	local before = vim.api.nvim_win_get_cursor(hunks.inline.win)
	local stale, stale_err = presenter.restore_location(state, location, hunks.generation + 1)
	assert(stale == nil and stale_err:find("generation changed", 1, true), stale_err)
	assert(vim.deep_equal(vim.api.nvim_win_get_cursor(hunks.inline.win), before))
	assert(presenter.restore_location(state, location, hunks.generation))
	assert(vim.api.nvim_get_current_win() == hunks.inline.win)
	assert(vim.deep_equal(vim.api.nvim_win_get_cursor(hunks.inline.win), { target_line, 3 }))
	assert(move_and_fire(hunks.inline.win, hunks.inline.buf, target_line) == target_line)
	mode.disable(state)
end)

test("logical split locations restore exact OLD and NEW source cursors", function()
	local state = setup_state()
	local selected = entry()
	assert(presenter.show(state, selected, { layout = "split", context = "full" }))
	local presentation = state.presentation
	local left = assert(presentation.left)
	local right = assert(presentation.right)

	vim.api.nvim_set_current_win(right.win)
	vim.api.nvim_win_set_cursor(right.win, { 3, 2 })
	local new_location = assert(presenter.capture_location(state))
	assert(new_location.side == "new" and new_location.path == selected.new_path)
	assert(new_location.line == 3 and new_location.col == 3)

	vim.api.nvim_set_current_win(left.win)
	vim.api.nvim_win_set_cursor(left.win, { 2, 1 })
	local old_location = assert(presenter.capture_location(state))
	assert(old_location.side == "old" and old_location.path == selected.old_path)
	assert(old_location.line == 2 and old_location.col == 2)

	assert(presenter.restore_location(state, new_location, presentation.generation))
	assert(vim.api.nvim_get_current_win() == right.win)
	assert(vim.deep_equal(vim.api.nvim_win_get_cursor(right.win), { 3, 2 }))
	assert(presenter.restore_location(state, old_location, presentation.generation))
	assert(vim.api.nvim_get_current_win() == left.win)
	assert(vim.deep_equal(vim.api.nvim_win_get_cursor(left.win), { 2, 1 }))
	mode.disable(state)
end)

test("unified context retains the restored OLD logical side", function()
	local state = setup_state()
	local selected = entry()
	selected.old_path = "before.lua"
	selected.new_path = "after.lua"
	selected.path = selected.new_path
	selected.identity = "history\0before.lua\0after.lua"
	assert(presenter.show(state, selected, { layout = "split", context = "full" }))
	local left = assert(state.presentation.left)
	vim.api.nvim_set_current_win(left.win)
	vim.api.nvim_win_set_cursor(left.win, { 1, 1 })
	local old_context = assert(presenter.capture_location(state))
	assert(old_context.side == "old" and old_context.path == selected.old_path and old_context.line == 1)

	assert(presenter.show(state, selected, { layout = "inline", context = "full", side = "old" }))
	local presentation = state.presentation
	assert(presenter.restore_location(state, old_context, presentation.generation))
	local restored = assert(presenter.capture_location(state))
	assert(vim.deep_equal(restored, old_context), "unified context changed the restored OLD identity")
	local inline = presentation.inline
	vim.api.nvim_win_set_cursor(inline.win, { 2, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = inline.buf })
	vim.api.nvim_win_set_cursor(inline.win, { 1, 1 })
	local revisited = assert(presenter.capture_location(state))
	assert(revisited.side == "new" and revisited.path == selected.new_path, "departed logical side remained sticky")
	mode.disable(state)
end)

test("empty unified entries retain the restored OLD logical side", function()
	local state = setup_state()
	local selected = entry("")
	selected.old_text = ""
	selected.old_path = "before.txt"
	selected.new_path = "after.txt"
	selected.path = selected.new_path
	selected.identity = "history\0before.txt\0after.txt"
	selected.hunks = {}
	assert(presenter.show(state, selected, { layout = "split", context = "full" }))
	local left = assert(state.presentation.left)
	vim.api.nvim_set_current_win(left.win)
	vim.api.nvim_win_set_cursor(left.win, { 1, 0 })
	local old_empty = assert(presenter.capture_location(state))
	assert(old_empty.side == "old" and old_empty.path == selected.old_path and old_empty.line == 0)

	assert(presenter.show(state, selected, { layout = "inline", context = "full", side = "old" }))
	assert(presenter.restore_location(state, old_empty, state.presentation.generation))
	assert(vim.deep_equal(presenter.capture_location(state), old_empty), "empty projection changed the OLD identity")
	mode.disable(state)
end)

test("unified projections retain restored file-level locations on an empty side", function()
	for _, fixture in ipairs({
		{ side = "old", old_text = "", new_text = "new line\n", path = "before.txt" },
		{ side = "new", old_text = "old line\n", new_text = "", path = "after.txt" },
	}) do
		local state = setup_state()
		local selected = entry(fixture.new_text)
		selected.old_text = fixture.old_text
		selected.old_path = "before.txt"
		selected.new_path = "after.txt"
		selected.path = selected.new_path
		selected.identity = "history\0before.txt\0after.txt"
		selected.hunks = vim.diff(selected.old_text, selected.new_text, { result_type = "indices" })
		assert(presenter.show(state, selected, { layout = "split", context = "full" }))
		local pane = assert(fixture.side == "old" and state.presentation.left or state.presentation.right)
		vim.api.nvim_set_current_win(pane.win)
		vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
		local file_location = assert(presenter.capture_location(state))
		assert(file_location.side == fixture.side and file_location.path == fixture.path and file_location.line == 0)

		assert(presenter.show(state, selected, { layout = "inline", context = "full", side = fixture.side }))
		assert(presenter.restore_location(state, file_location, state.presentation.generation))
		local inline = state.presentation.inline
		local cursor = vim.api.nvim_win_get_cursor(inline.win)
		local line = vim.api.nvim_buf_get_lines(inline.buf, cursor[1] - 1, cursor[1], false)[1] or ""
		vim.api.nvim_win_set_cursor(inline.win, { cursor[1], math.min(3, #line) })
		local unified_location = assert(presenter.capture_location(state))
		assert(
			vim.deep_equal(unified_location, file_location),
			fixture.side .. " file-level location was not canonical"
		)

		assert(presenter.show(state, selected, { layout = "split", context = "full", side = fixture.side }))
		assert(presenter.restore_location(state, unified_location, state.presentation.generation))
		assert(
			vim.deep_equal(presenter.capture_location(state), file_location),
			fixture.side .. " file-level location changed after split restoration"
		)
		mode.disable(state)
	end
end)

test("unified pure insertions are real rows at BOF and after unchanged rows", function()
	local state = setup_state()
	local selected = entry()
	selected.old_text = "one\nthree\n"
	selected.new_text = "zero\none\ntwo\nthree\n"
	selected.hunks = vim.diff(selected.old_text, selected.new_text, { result_type = "indices" })
	assert(vim.deep_equal(selected.hunks, { { 0, 0, 1, 1 }, { 1, 0, 3, 1 } }), vim.inspect(selected.hunks))
	assert(presenter.show(state, selected, { layout = "inline", context = "full" }))
	local buf = state.presentation.inline.buf
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "zero", "one", "two", "three" }))
	assert(vim.deep_equal(
		vim.tbl_map(function(row)
			return row.kind
		end, state.presentation.projection.rows),
		{ "new", "context", "new", "context" }
	))
	local additions = {}
	for _, item in ipairs(state.presentation.decorations) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true })) do
			local details = mark[4]
			if details.hl_group == "NvimReviewNativeDiffNew" then
				additions[#additions + 1] = mark[2] + 1
			end
		end
	end
	table.sort(additions)
	assert(vim.deep_equal(additions, { 1, 3 }), vim.inspect(additions))
	assert(review_lsp.blocked(buf))
	assert(assert(presenter.source_at(state, 1)).side == "new")
	assert(assert(presenter.source_at(state, 3)).source_line == 3)
	mode.disable(state)
end)

test("unified added and deleted files expose only their existing source side", function()
	local state, real = setup_state()
	local added = entry()
	added.status = "A"
	added.old_path = nil
	added.old_text = ""
	added.added = true
	added.hunks = vim.diff(added.old_text, added.new_text, { result_type = "indices" })
	assert(presenter.show(state, added, { layout = "inline", context = "full" }))
	assert(state.presentation.inline.side == "unified" and state.presentation.inline.buf ~= real)
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(state.presentation.inline.buf, 0, -1, false), {
		"one",
		"new",
		"three",
	}))
	for line = 1, 3 do
		local source = assert(presenter.source_at(state, line))
		assert(source.side == "new" and source.path == added.new_path)
	end

	local deleted = entry("")
	deleted.status = "D"
	deleted.new_path = nil
	deleted.path = deleted.old_path
	deleted.deleted = true
	deleted.hunks = vim.diff(deleted.old_text, deleted.new_text, { result_type = "indices" })
	assert(presenter.show(state, deleted, { layout = "inline", context = "full" }))
	assert(state.presentation.inline.side == "unified")
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(state.presentation.inline.buf, 0, -1, false), {
		"one",
		"old",
		"three",
	}))
	for line = 1, 3 do
		local source = assert(presenter.source_at(state, line))
		assert(source.side == "old" and source.path == deleted.old_path)
	end

	local empty_old = entry()
	empty_old.old_text = ""
	empty_old.hunks = vim.diff(empty_old.old_text, empty_old.new_text, { result_type = "indices" })
	assert(presenter.show(state, empty_old, { layout = "inline", context = "full" }))
	local old_file = assert(presenter.locate_anchor(state, {
		kind = "file",
		path = empty_old.old_path,
		side = "left",
	}))
	assert(old_file.display_line == 1 and old_file.source_line == 0 and old_file.side == "old")

	local empty_new = entry("")
	empty_new.hunks = vim.diff(empty_new.old_text, empty_new.new_text, { result_type = "indices" })
	assert(presenter.show(state, empty_new, { layout = "inline", context = "full" }))
	local new_file = assert(presenter.locate_anchor(state, {
		kind = "file",
		path = empty_new.new_path,
		side = "right",
	}))
	assert(new_file.display_line == 1 and new_file.source_line == 0 and new_file.side == "new")
	assert(review_lsp.blocked(state.presentation.inline.buf))
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

test("unified projection retains exact CRLF metadata while split snapshots stay native", function()
	local handle = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_write(handle, "one\r\nnew\r\nthree\r\n", 0))
	assert(vim.uv.fs_close(handle))
	local state, real = setup_state()
	local value = entry("one\r\nnew\r\nthree\r\n")
	value.old_text = "one\r\nold\r\nthree\r\n"
	value.hunks = vim.diff(value.old_text, value.new_text, { result_type = "indices" })
	assert(presenter.show(state, value, { layout = "inline", context = "full" }))
	assert(state.presentation.inline.buf ~= real and state.presentation.inline.side == "unified")
	for _, source in pairs(state.presentation.projection.sources) do
		assert(source.fileformat == "dos" and source.endofline)
	end
	for _, line in ipairs(vim.api.nvim_buf_get_lines(state.presentation.inline.buf, 0, -1, false)) do
		assert(not line:find("\r", 1, true), "CRLF projection displays a literal carriage return")
	end
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

test("unified pure middle deletions are real OLD rows after preceding context", function()
	local state = setup_state()
	local value = entry("one\nthree\n")
	value.hunks = vim.diff(value.old_text, value.new_text, { result_type = "indices" })
	assert(vim.deep_equal(value.hunks, { { 2, 1, 1, 0 } }), vim.inspect(value.hunks))
	assert(presenter.show(state, value, { layout = "inline", context = "full" }))
	local buf = state.presentation.inline.buf
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "old", "three" }))
	assert(state.presentation.projection.rows[2].kind == "old")
	local deletion_row
	for _, item in ipairs(state.presentation.decorations) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true })) do
			local details = mark[4]
			if details.hl_group == "NvimReviewNativeDiffOld" then
				deletion_row = mark[2] + 1
			end
		end
	end
	assert(deletion_row == 2, vim.inspect(deletion_row))
	local source = assert(presenter.source_at(state, 2))
	assert(source.side == "old" and source.source_line == 2)
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
	vim.api.nvim_set_current_win(presentation.left.win)
	vim.api.nvim_win_set_cursor(presentation.left.win, { 2, 0 })
	assert(vim.api.nvim_get_current_line() == "old", "historical line is not a real focusable old-side row")
	assert(vim.b[presentation.left.buf].nvim_review_side == "left")
	assert(vim.b[presentation.left.buf].nvim_review_role == "old")
	vim.api.nvim_set_current_win(presentation.right.win)
	for _, side in ipairs({ presentation.left, presentation.right }) do
		assert(vim.bo[side.buf].buftype == "nofile" and not vim.bo[side.buf].buflisted)
		assert(not vim.bo[side.buf].swapfile and vim.bo[side.buf].readonly and not vim.bo[side.buf].modifiable)
		assert(review_lsp.blocked(side.buf))
		assert_transient_immutable(side.buf)
	end
	assert_decoration_scopes(state)
	local has_delete = false
	local has_add = false
	for _, details in ipairs(decoration_details(state)) do
		has_delete = has_delete or details.hl_group == "NvimReviewNativeDiffOld"
		has_add = has_add or details.hl_group == "NvimReviewNativeDiffNew"
	end
	assert(has_delete and has_add, "split sides lost old/red or new/green highlights")
	local right_win = presentation.right.win
	local scratch_buffers = { presentation.left.buf, presentation.right.buf }
	local cleared_decorations = vim.deepcopy(presentation.decorations)
	presenter.clear(state)
	assert_namespaces_unscoped(cleared_decorations)
	for _, buf in ipairs(scratch_buffers) do
		assert(mode.enforce_protection(buf) == false, "cleared scratch retained transient ownership")
	end
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

test("split hunk context keeps native alignment with custom visibility in both windows", function()
	local state, _, selected = setup_cursor_state()
	local previous_diffopt = vim.o.diffopt
	vim.o.diffopt = "internal,filler,closeoff,context:11"
	assert(presenter.show(state, selected, { layout = "split", context = "hunks" }))
	local presentation = state.presentation
	assert(vim.o.diffopt == "internal,filler,closeoff,context:11", "split hunks mutated diffopt")
	assert(vim.wo[presentation.left.win].diff and vim.wo[presentation.right.win].diff)
	assert(vim.wo[presentation.left.win].foldmethod == "diff" and vim.wo[presentation.right.win].foldmethod == "diff")
	assert(not vim.wo[presentation.left.win].foldenable and not vim.wo[presentation.right.win].foldenable)
	for _, side in ipairs({ presentation.left, presentation.right }) do
		assert(presentation.cursor_guards[side.win], "split side lacks its own cursor guard")
		assert(vim.wo[side.win].signcolumn == "auto:1-9")
		local fillchars = vim.api.nvim_win_call(side.win, function()
			return vim.opt_local.fillchars:get()
		end)
		assert(fillchars.diff == " ", "split diff filler is not blank")
	end
	mode.disable(state)
	vim.o.diffopt = previous_diffopt
end)

test("split hunk rows stay aligned across insertion and deletion boundaries", function()
	local state = setup_state()
	local selected = alignment_entry()
	local original_laststatus = vim.o.laststatus
	local original_showtabline = vim.o.showtabline
	local ok, err = xpcall(function()
		vim.o.laststatus = 0
		vim.o.showtabline = 0
		assert(#selected.hunks == 2, vim.inspect(selected.hunks))
		for _, context in ipairs({ 3, 0 }) do
			configure_hunk_context(context)
			assert(presenter.show(state, selected, { layout = "split", context = "hunks" }))
			local presentation = state.presentation
			assert(presentation.hunk_context == context)
			assert(presentation.visibility_hunk_context == (context == 0 and 1 or context))
			local left, right = review_screen_rows(presentation)
			for index = 1, 2 do
				assert_same_screen_row(left, right, ("HUNK %d/2"):format(index))
				assert_same_screen_row(left, right, ("END HUNK %d/2"):format(index))
			end
			for _, line in ipairs({ "ALIGN_07", "ALIGN_08", "ALIGN_17", "ALIGN_20" }) do
				assert_same_screen_row(left, right, line)
			end
		end
	end, debug.traceback)
	configure_hunk_context(3)
	vim.o.laststatus = original_laststatus
	vim.o.showtabline = original_showtabline
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	assert(ok, err)
end)

test("split boundary hunks omit only bands without matching source anchors", function()
	local state = setup_state()
	local selected = boundary_entry()
	local original_laststatus = vim.o.laststatus
	local original_showtabline = vim.o.showtabline
	configure_hunk_context(1)
	local ok, err = xpcall(function()
		vim.o.laststatus = 0
		vim.o.showtabline = 0
		assert(#selected.hunks == 2, vim.inspect(selected.hunks))
		assert(presenter.show(state, selected, { layout = "split", context = "hunks" }))
		local left, right = review_screen_rows(state.presentation)
		assert(screen_row(left, "HUNK 1/2") == nil and screen_row(right, "HUNK 1/2") == nil)
		assert_same_screen_row(left, right, "END HUNK 1/2")
		assert_same_screen_row(left, right, "HUNK 2/2")
		assert(screen_row(left, "END HUNK 2/2") == nil and screen_row(right, "END HUNK 2/2") == nil)
		for _, line in ipairs({ "BOUNDARY_01", "BOUNDARY_10" }) do
			assert_same_screen_row(left, right, line)
		end
	end, debug.traceback)
	configure_hunk_context(3)
	vim.o.laststatus = original_laststatus
	vim.o.showtabline = original_showtabline
	pcall(presenter.clear, state)
	pcall(mode.disable, state)
	assert(ok, err)
end)

test("NEW definition locations reveal concealed rows in inline and split review layouts", function()
	local function concealed(item, row)
		for _, hidden in ipairs(item.omitted or {}) do
			if hidden.first <= row and row <= hidden.last then
				return true
			end
		end
		return false
	end

	for _, layout in ipairs({ "inline", "split" }) do
		local state, _, selected = setup_cursor_state()
		assert(presenter.show(state, selected, { layout = layout, context = "hunks" }))
		local presentation = state.presentation
		local target = layout == "inline" and presentation.inline or presentation.right
		local decoration
		for _, item in ipairs(presentation.decorations) do
			if item.buf == target.buf and item.win == target.win and #(item.omitted or {}) > 0 then
				decoration = item
				break
			end
		end
		assert(decoration, layout .. " review has no concealed NEW context fixture")

		local source_line
		local target_line
		if layout == "inline" then
			for line, display in pairs(presentation.projection.by_source.new) do
				if concealed(decoration, display) then
					source_line = line
					target_line = display
					break
				end
			end
		else
			source_line = decoration.omitted[1].first
			target_line = source_line
		end
		assert(source_line and target_line, layout .. " review has no concealed NEW line")
		local generation = presentation.generation
		local location = assert(presenter.reveal_new_location(state, selected.new_path, source_line, generation))
		assert(location.win == target.win and location.buf == target.buf and location.line == target_line)
		assert(not concealed(decoration, target_line), layout .. " definition row remained concealed")
		assert(move_and_fire(target.win, target.buf, target_line) == target_line)
		assert(state.presentation.layout == layout and state.presentation.context == "hunks")
		local stale, stale_err = presenter.reveal_new_location(state, selected.new_path, source_line, generation + 1)
		assert(stale == nil and stale_err:find("generation changed", 1, true), stale_err)
		mode.disable(state)
	end
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
	assert_transient_immutable(buf)
	local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	assert(first == "[binary file]")
	presenter.clear(state)
	binary.old_path = "before.bin"
	binary.new_path = "after.bin"
	binary.path = binary.new_path
	binary.identity = "history\0before.bin\0after.bin"
	binary.old_text = "\0old binary bytes"
	binary.new_text = "\0new binary bytes"
	assert(presenter.show(state, binary, { layout = "split", context = "full" }))
	local left = assert(state.presentation.left)
	vim.api.nvim_set_current_win(left.win)
	vim.api.nvim_win_set_cursor(left.win, { 1, 3 })
	local old_location = assert(presenter.capture_location(state))
	assert(
		old_location.side == "old"
			and old_location.path == binary.old_path
			and old_location.line == 0
			and old_location.col == 1
	)
	assert(presenter.show(state, binary, { layout = "inline", context = "full", side = "old" }))
	assert(state.presentation.inline.side == "old", "metadata inline view ignored the requested OLD side")
	assert(presenter.restore_location(state, old_location, state.presentation.generation))
	assert(vim.deep_equal(presenter.capture_location(state), old_location))
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
	local unified_role_at_filetype
	local role_group = vim.api.nvim_create_augroup("NvimReviewUnifiedFileTypeTest", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = role_group,
		pattern = "lua",
		callback = function(event)
			if vim.b[event.buf].nvim_review_role == "unified" then
				unified_role_at_filetype = vim.b[event.buf].nvim_review_role
			end
		end,
	})

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
	assert(presenter.show(state, entry(), { layout = "inline", context = "full" }))
	local unified = state.presentation.inline.buf
	assert(unified_role_at_filetype == "unified", "unified role was not present before FileType")
	assert(vim.bo[unified].filetype == "lua" and review_lsp.blocked(unified))
	assert_unified_lsp_mappings(unified)

	local marked_after_filetype = vim.api.nvim_create_buf(false, true)
	vim.bo[marked_after_filetype].filetype = "lua"
	assert(review_lsp.mark(marked_after_filetype, "old"))
	assert_review_guards(marked_after_filetype, GUARD_DESCRIPTION)
	vim.api.nvim_buf_delete(marked_after_filetype, { force = true })

	mode.disable(state)
	vim.api.nvim_del_augroup_by_id(role_group)
	vim.keymap.del("n", "gri")
end)

local function intraline_entry()
	local value = entry()
	value.old_text = "one\nlocal timeout = 30; retry = 2\nthree\n"
	value.new_text = "one\nlocal enabled = true\nlocal timeout = 60; retry = 4\nthree\n"
	value.hunks = vim.text.diff(value.old_text, value.new_text, { result_type = "indices" })
	return value
end

for _, layout in ipairs({ "inline", "split" }) do
	for _, context in ipairs({ "full", "hunks" }) do
		test(layout .. "/" .. context .. " maps precise characters to canonical OLD/NEW coordinates", function()
			local state = setup_state()
			local value = intraline_entry()
			local hunks = vim.deepcopy(value.hunks)
			local diffopt = vim.o.diffopt
			assert(presenter.show(state, value, { layout = layout, context = context }))
			local presentation = state.presentation
			local found = { old = {}, new = {} }
			for _, item in ipairs(presentation.decorations) do
				for _, mark in
					ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true }))
				do
					local details = mark[4]
					local side = details.hl_group == "NvimReviewNativeDiffOldText" and "old"
						or details.hl_group == "NvimReviewNativeDiffNewText" and "new"
					if side then
						local source_line = side == "old" and 2 or 3
						local display_line = layout == "inline" and presentation.projection.by_source[side][source_line]
							or source_line
						assert(mark[2] + 1 == display_line and details.priority == 150)
						local text = vim.api.nvim_buf_get_lines(item.buf, mark[2], mark[2] + 1, false)[1]
						found[side][#found[side] + 1] = text:sub(mark[3] + 1, details.end_col)
						vim.api.nvim_set_current_win(item.win)
						vim.api.nvim_win_set_cursor(item.win, { display_line, mark[3] })
						local location = assert(presenter.capture_location(state))
						assert(location.side == side and location.line == source_line and location.col == mark[3] + 1)
					end
				end
			end
			assert(vim.deep_equal(found, { old = { "3", "2" }, new = { "6", "4" } }), vim.inspect(found))
			assert(vim.deep_equal(value.hunks, hunks) and vim.o.diffopt == diffopt)
			local cached = state.intraline_cache
			assert(presenter.show(state, value, { layout = layout, context = context == "full" and "hunks" or "full" }))
			assert(state.intraline_cache == cached, "context change recomputed frozen characters")
			mode.disable(state)
		end)
	end
end

test("rendered changed characters remain distinct across themes and resizing", function()
	local state = setup_state()
	local value = intraline_entry()
	local previous = {}
	for _, name in ipairs({ "Normal", "DiffDelete", "DiffAdd", "DiagnosticError", "DiagnosticOk" }) do
		previous[name] = vim.api.nvim_get_hl(0, { name = name })
	end
	vim.o.termguicolors = true
	vim.api.nvim_set_hl(0, "Normal", { fg = 0xEEEEEE, bg = 0x101010 })
	vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0x302020 })
	vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x203020 })
	vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xFF6060 })
	vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0x60FF60 })
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "intraline-spec" })
	vim.api.nvim_set_hl(0, "NvimReviewIntralineTestSyntax", { fg = 0xC0FFEE })
	local syntax_namespace = vim.api.nvim_create_namespace("NvimReviewIntralineTestSyntax")
	-- Enable hlstate before rebuilding the grid; inspecting an existing grid
	-- while enabling it would leave old numeric attribute IDs in those cells.
	vim.api.nvim__inspect_cell(1, 0, 0)
	local function attribute(win, line, column)
		local position = vim.fn.screenpos(win, line, column)
		assert(position.row > 0 and position.col > 0, "expected visible source cell")
		return vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)[2]
	end
	for _, layout in ipairs({ "inline", "split" }) do
		assert(presenter.show(state, value, { layout = layout, context = "full" }))
		local presentation = state.presentation
		for _, item in ipairs(presentation.decorations) do
			for row, text in ipairs(vim.api.nvim_buf_get_lines(item.buf, 0, -1, false)) do
				vim.api.nvim_buf_set_extmark(item.buf, syntax_namespace, row - 1, 0, {
					end_col = #text,
					hl_group = "NvimReviewIntralineTestSyntax",
					priority = 100,
				})
			end
			vim.wo[item.win].number = false
			vim.wo[item.win].relativenumber = false
			vim.wo[item.win].statuscolumn = ""
			vim.wo[item.win].signcolumn = "no"
			vim.wo[item.win].cursorline = false
			vim.api.nvim_win_set_cursor(item.win, { 1, 0 })
		end
		vim.cmd("redraw!")
		for _, item in ipairs(presentation.decorations) do
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true })) do
				if (mark[4].hl_group or ""):find("Diff.*Text$") then
					local changed = attribute(item.win, mark[2] + 1, mark[3] + 1)
					local unchanged = attribute(item.win, mark[2] + 1, 2)
					assert(
						changed.background ~= unchanged.background,
						"changed character has the line's rendered background"
					)
					assert(
						changed.foreground == 0xC0FFEE and unchanged.foreground == 0xC0FFEE,
						"diff replaced syntax foreground"
					)
				end
			end
		end
	end
	local old = vim.api.nvim_get_hl(0, { name = "NvimReviewNativeDiffOldText" })
	assert(old.bg ~= previous.DiffDelete.bg and old.fg == nil and old.bold)
	vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xFFFF00 })
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "intraline-spec-updated" })
	local updated = vim.api.nvim_get_hl(0, { name = "NvimReviewNativeDiffOldText" })
	assert(updated.bg ~= old.bg and updated.fg == nil)
	vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0x302020 })
	vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0x203020 })
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "intraline-spec-equal-accent" })
	assert(vim.api.nvim_get_hl(0, { name = "NvimReviewNativeDiffOldText" }).bg ~= 0x302020)
	assert(vim.api.nvim_get_hl(0, { name = "NvimReviewNativeDiffNewText" }).bg ~= 0x203020)
	local cache = state.intraline_cache
	vim.api.nvim_win_set_width(state.presentation.left.win, 35)
	vim.api.nvim_exec_autocmds("VimResized", {})
	flush_scheduled()
	assert(state.intraline_cache == cache)
	mode.disable(state)
	for name, definition in pairs(previous) do
		vim.api.nvim_set_hl(0, name, definition)
	end
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "intraline-spec-restored" })
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
