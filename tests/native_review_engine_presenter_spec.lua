-- Structural split geometry must preserve canonical sources and screen rows.
-- Run with -c 'lua dofile(...)': changing screen dimensions under -l precedes
-- Neovim's screen allocation and can make redraw index the wrong grid size.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.o.lines = 44
vim.o.columns = 140
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("config.local_plugins").setup()
local review = require("config.native_review")
local difftastic = require("native_review.difftastic")
local textual = require("native_review.textual")
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
local failures, count = {}, 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
end
local function entry(old, new)
	return {
		identity = "history\0sample.lua\0sample.lua",
		layer = "history",
		status = "M",
		old_path = "sample.lua",
		new_path = "sample.lua",
		path = "sample.lua",
		old_text = old,
		new_text = new,
		old_oid = string.rep("1", 40),
		new_oid = string.rep("2", 40),
		old_mode = "100644",
		new_mode = "100644",
		hunks = vim.diff(old, new, { result_type = "indices" }),
	}
end
local function line_change(line, text)
	return { line_number = line - 1, changes = { { start = 0, ["end"] = #text, content = text, highlight = "normal" } } }
end
local function verify_case(old, new, alignment, chunks, matched, from_inline)
	vim.cmd("enew!")
	local value = entry(old, new)
	local analysis = assert(difftastic.normalize(value, {
		language = "Lua",
		path = "sample.lua",
		status = "changed",
		aligned_lines = alignment,
		chunks = { chunks },
	}))
	analysis.origin_engine = { id = "difftastic", version = "0.71.0" }
	analysis.selected_engine = "difftastic"
	local state = review.mode.new({ root = fixture, model = { entries = { value } } })
	assert(review.mode.enable(state))
	local ok, err = xpcall(function()
		for _, context in ipairs({ "full", "hunks" }) do
			assert(review.presenter.show(state, value, {
				layout = from_inline and "inline" or "split",
				context = context,
				engine_result = analysis,
			}))
			if from_inline then
				assert(review.presenter.toggle_layout(state))
			end
			local p = state.presentation
			assert(#p.visibility.old == #p.visibility.new, "split panes disagree on structural section count")
			if from_inline then
				assert(#p.entry.hunks == 1 and #p.left.projection.hunks == 2 and #p.right.projection.hunks == 2)
				if context == "hunks" then
					assert(#p.visibility.old == 2 and #p.visibility.new == 2)
					for _, decoration in ipairs(p.decorations) do
						assert(#decoration.bands == 4, "both structural sections need start and end bands")
					end
				end
			end
			for _, pane in ipairs({ p.left, p.right }) do
				assert(not vim.wo[pane.win].diff and not vim.wo[pane.win].wrap)
				vim.wo[pane.win].scrolloff = 0
				vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
				vim.api.nvim_win_call(pane.win, function()
					vim.cmd("normal! zt")
				end)
			end
			local function assert_alignment()
				vim.wait(20, function()
					return false
				end, 5)
				vim.cmd("redraw!")
				for _, pair in ipairs(matched) do
					local lhs = vim.fn.screenpos(p.left.win, p.left.projection.by_source.old[pair[1]], 1)
					local rhs = vim.fn.screenpos(p.right.win, p.right.projection.by_source.new[pair[2]], 1)
					assert(
						lhs.row == rhs.row,
						("source rows %d/%d misaligned in %s: %d/%d"):format(
							pair[1],
							pair[2],
							context,
							lhs.row,
							rhs.row
						)
					)
				end
			end
			assert_alignment()
			vim.api.nvim_win_call(p.right.win, function()
				vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes("2<C-e>", true, false, true) }, bang = true })
			end)
			-- -l runs before VimEnter, when automatic WinScrolled delivery starts.
			vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(p.right.win) })
			assert_alignment()
			vim.api.nvim_win_set_width(p.left.win, 45)
			vim.api.nvim_exec_autocmds("VimResized", {})
			vim.wait(20, function()
				return false
			end, 5)
			assert_alignment()
		end
	end, debug.traceback)
	review.mode.disable(state)
	assert(ok, err)
end
local common = {}
for line = 1, 35 do
	common[line] = "local value_" .. line .. " = " .. line
end
local function text(lines)
	return table.concat(lines, "\n") .. "\n"
end
test("insertion-only hunks align both panes before and after scrolling", function()
	local new = vim.deepcopy(common)
	table.insert(new, 15, "local extra = 1")
	local alignment = {}
	for line = 0, 13 do
		alignment[#alignment + 1] = { line, line }
	end
	alignment[#alignment + 1] = { vim.NIL, 14 }
	for line = 14, #common do
		alignment[#alignment + 1] = { line, line + 1 }
	end
	verify_case(
		text(common),
		text(new),
		alignment,
		{ { rhs = line_change(15, "local extra = 1") } },
		{ { 14, 14 }, { 15, 16 }, { 16, 17 } }
	)
end)
test("deletion-only hunks align both panes before and after scrolling", function()
	local old = vim.deepcopy(common)
	table.insert(old, 15, "local extra = 1")
	local alignment = {}
	for line = 0, 13 do
		alignment[#alignment + 1] = { line, line }
	end
	alignment[#alignment + 1] = { 14, vim.NIL }
	for line = 14, #common do
		alignment[#alignment + 1] = { line + 1, line }
	end
	verify_case(
		text(old),
		text(common),
		alignment,
		{ { lhs = line_change(15, "local extra = 1") } },
		{ { 14, 14 }, { 16, 15 }, { 17, 16 } }
	)
end)
test("separate insertion and deletion hunks share visible geometry", function()
	local new, alignment, new_line = {}, {}, 1
	for old_line = 1, #common do
		if old_line == 10 then
			new[#new + 1] = "local extra = 1"
			alignment[#alignment + 1] = { vim.NIL, new_line - 1 }
			new_line = new_line + 1
		end
		if old_line == 25 then
			alignment[#alignment + 1] = { old_line - 1, vim.NIL }
		else
			new[#new + 1] = common[old_line]
			alignment[#alignment + 1] = { old_line - 1, new_line - 1 }
			new_line = new_line + 1
		end
	end
	alignment[#alignment + 1] = { #common, #new }
	verify_case(
		text(common),
		text(new),
		alignment,
		{ { rhs = line_change(10, "local extra = 1") }, { lhs = line_change(25, common[25]) } },
		{ { 9, 9 }, { 10, 11 }, { 24, 25 }, { 26, 26 } }
	)
end)
test("switching to split keeps structural sections independent of canonical Git hunks", function()
	local new, alignment = {}, {}
	for line, value in ipairs(common) do
		new[line] = value:gsub(" = ", "=")
		alignment[#alignment + 1] = { line - 1, line - 1 }
	end
	new[8], new[28] = "local value_8=80", "local value_28=280"
	alignment[#alignment + 1] = { #common, #new }
	local old_text, new_text = text(common), text(new)
	assert(#entry(old_text, new_text).hunks == 1, "formatting must coalesce canonical Git changes")
	verify_case(old_text, new_text, alignment, {
		{ lhs = line_change(8, common[8]), rhs = line_change(8, new[8]) },
		{ lhs = line_change(28, common[28]), rhs = line_change(28, new[28]) },
	}, { { 7, 7 }, { 8, 8 }, { 27, 27 }, { 28, 28 } }, true)
end)
test("CR-only bytes retain canonical single-line split coordinates", function()
	local value = entry("local a=1\rlocal b=2\r", "local a=1\rlocal b=3\r")
	local analysis = assert(difftastic.normalize(value, {
		language = "Lua",
		path = "sample.lua",
		status = "changed",
		aligned_lines = { { 0, 0 }, { 1, 1 } },
		chunks = {
			{
				{
					lhs = {
						line_number = 0,
						changes = { { start = 18, ["end"] = 19, content = "2", highlight = "normal" } },
					},
					rhs = {
						line_number = 0,
						changes = { { start = 18, ["end"] = 19, content = "3", highlight = "normal" } },
					},
				},
			},
		},
	}))
	analysis.origin_engine = { id = "difftastic", version = "0.71.0" }
	analysis.selected_engine = "difftastic"
	vim.cmd("enew!")
	local state = review.mode.new({ root = fixture, model = { entries = { value } } })
	assert(review.mode.enable(state))
	assert(review.presenter.show(state, value, { layout = "split", context = "full", engine_result = analysis }))
	local p = state.presentation
	assert(p.source_line_counts.old == 1 and p.source_line_counts.new == 1)
	assert(vim.api.nvim_buf_line_count(p.left.buf) == 1 and vim.api.nvim_buf_line_count(p.right.buf) == 1)
	assert(vim.api.nvim_buf_get_lines(p.left.buf, 0, -1, false)[1] == value.old_text)
	vim.api.nvim_set_current_win(p.right.win)
	vim.api.nvim_win_set_cursor(p.right.win, { 1, 18 })
	local location = assert(review.presenter.capture_location(state))
	assert(location.line == 1 and location.col == 19)
	review.mode.disable(state)
end)
test("textual moves survive every layout/context with exact anchors and labels", function()
	local block = "local alpha = 1\nlocal beta = 2\nreturn alpha + beta\n"
	local context = {}
	for line = 1, 20 do
		context[line] = "-- shared context " .. line .. "\n"
	end
	local middle = table.concat(context)
	local value = entry(block .. middle, middle .. block)
	local original = vim.deepcopy(value)
	local diffopt = vim.o.diffopt
	for _, id in ipairs({ "main", "patience", "gumtree" }) do
		local analysis = assert(id == "patience" and textual.patience(value) or textual.main(value))
		assert(#analysis.relations == 1)
		analysis.origin_engine = { id = id, version = "fixture" }
		analysis.selected_engine = id
		local state = review.mode.new({ root = fixture, model = { entries = { value } } })
		assert(review.mode.enable(state))
		local ok, err = xpcall(function()
			for _, layout in ipairs({ "inline", "split" }) do
				for _, visibility in ipairs({ "hunks", "full" }) do
					assert(
						review.presenter.show(
							state,
							value,
							{ layout = layout, context = visibility, engine_result = analysis }
						)
					)
					local p = state.presentation
					assert(not p.structural)
					assert((p.projected ~= nil) == (id == "patience"))
					assert(vim.o.diffopt == diffopt and vim.deep_equal(original, value))
					local labels = {}
					for _, decoration in ipairs(p.decorations) do
						for _, mark in
							ipairs(
								vim.api.nvim_buf_get_extmarks(
									decoration.buf,
									decoration.namespace,
									0,
									-1,
									{ details = true }
								)
							)
						do
							for _, text in ipairs(mark[4].virt_text or {}) do
								labels[#labels + 1] = text[1]
							end
						end
					end
					local joined = table.concat(labels, "\n")
					assert(
						joined:find("M1 move → NEW 21:1", 1, true) and joined:find("M1 move → OLD 1:1", 1, true),
						joined
					)
					for _, side in ipairs({ "old", "new" }) do
						local pane = layout == "inline" and p.inline or side == "old" and p.left or p.right
						local mapping = layout == "inline" and p.projection or pane.projection
						local source_line = side == "old" and 1 or 21
						local display = mapping and mapping.by_source[side][source_line] or source_line
						vim.api.nvim_set_current_win(pane.win)
						vim.api.nvim_win_set_cursor(pane.win, { display, 0 })
						vim.cmd("redraw!")
						local location = assert(review.presenter.capture_location(state))
						assert(location.line == source_line and location.side == side)
						if mapping then
							local range = assert(
								review.presenter.resolve_range(state, display, display, p.generation, side, pane.win)
							)
							assert(range.start_line == source_line and range.end_line == source_line)
						end
						assert(vim.fn.screenpos(pane.win, display, 1).row > 0)
					end
				end
			end
		end, debug.traceback)
		review.mode.disable(state)
		assert(ok, err)
	end
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("native_review_engine_presenter_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
