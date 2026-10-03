-- Real frozen Git model, presenter and store integration for engine changes.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("config.local_plugins").setup()
local review = require("config.native_review")
local host = require("config.code_review")
local adapter = require("config.review_structural_diff")
local gumtree_adapter = require("config.review_gumtree")
if vim.env.NVIM_REVIEW_PARSER_ROOT then
	vim.opt.runtimepath:append(vim.env.NVIM_REVIEW_PARSER_ROOT)
end
local controller, presenter, store = review.controller, review.presenter, review.store
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
local state_home = vim.fn.tempname()
assert(vim.fn.mkdir(state_home, "p", 448) == 1)
local source = fixture .. "/sample.lua"
local failures, count = {}, 0
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message)
	notifications[#notifications + 1] = tostring(message)
end
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
end
local function git(args)
	local cmd = { "git", "-C", fixture }
	vim.list_extend(cmd, args)
	local result = vim.system(cmd, { text = true }):wait()
	assert(result.code == 0, result.stderr)
end
local old_text = "local a = 30\nlocal keep = true\nreturn a\n"
local new_text = "local a = 60\nlocal extra = 1\nlocal keep = true\nreturn a\n"
for line = 1, 12 do
	local context = "-- unchanged context " .. line .. "\n"
	old_text, new_text = old_text .. context, new_text .. context
end
local moved_block = "local alpha = 1\nlocal beta = 2\nreturn alpha + beta\n"
local moved_context = ""
for line = 1, 20 do
	moved_context = moved_context .. "-- shared context " .. line .. "\n"
end
git({ "init", "-q" })
vim.fn.writefile(vim.split(old_text, "\n", { trimempty = true }), source)
vim.fn.writefile(vim.split(moved_block .. moved_context, "\n", { trimempty = true }), fixture .. "/zz-moved.lua")
git({ "add", "sample.lua", "zz-moved.lua" })
git({ "-c", "user.name=Review Test", "-c", "user.email=review@example.invalid", "commit", "-qm", "fixture" })
vim.fn.writefile(vim.split(new_text, "\n", { trimempty = true }), source)
vim.fn.writefile(vim.split(moved_context .. moved_block, "\n", { trimempty = true }), fixture .. "/zz-moved.lua")
vim.fn.writefile({ "new text file" }, fixture .. "/zz-other.txt")
local originals = {
	load = store.load,
	save = store.save,
	list = store.list,
	compose = review.editor.compose,
	has_active = review.editor.has_active,
	analyze = adapter.analyze,
	gumtree_analyze = gumtree_adapter.analyze,
	select = vim.ui.select,
}
for _, name in ipairs({ "load", "save", "list" }) do
	store[name] = function(repo_root, value, options)
		if name == "list" then
			return originals[name](repo_root, { state_home = state_home })
		end
		return originals[name](repo_root, value, vim.tbl_extend("force", options or {}, { state_home = state_home }))
	end
end
local pending, cancelled = {}, 0
adapter.analyze = function(request, callback)
	local operation = { request = request, callback = callback }
	pending[#pending + 1] = operation
	return function()
		operation.cancelled = true
		cancelled = cancelled + 1
	end
end
local function output()
	local alignment = { { 0, 0 }, { vim.NIL, 1 } }
	for line = 1, #vim.split(old_text, "\n", { trimempty = true }) do
		alignment[#alignment + 1] = { line, line + 1 }
	end
	return vim.json.encode({
		language = "Lua",
		path = "sample.lua",
		status = "changed",
		aligned_lines = alignment,
		chunks = {
			{
				{
					lhs = {
						line_number = 0,
						changes = { { start = 10, ["end"] = 12, content = "30", highlight = "normal" } },
					},
					rhs = {
						line_number = 0,
						changes = { { start = 10, ["end"] = 12, content = "60", highlight = "normal" } },
					},
				},
				{
					rhs = {
						line_number = 1,
						changes = { { start = 0, ["end"] = 15, content = "local extra = 1", highlight = "normal" } },
					},
				},
			},
		},
	})
end
local workspace
host.setup()
test("Main is default and engine command/mapping are registered", function()
	assert(vim.fn.exists(":ReviewEngine") == 2)
	assert(
		vim.fn.maparg(" rD", "n") == "<Cmd>ReviewEngine<CR>"
			or vim.fn.maparg(" rD", "n"):lower() == "<cmd>reviewengine<cr>"
	)
	workspace = assert(controller.open({ kind = "working" }, fixture))
	assert(controller.present(workspace.entry_identity))
	assert(controller.status().engine == "main")
	assert(workspace.mode_state.presentation.origin_engine.id == "main")
	assert(workspace.mode_state.presentation.origin_engine.version:find("builtin-v2", 1, true))
end)
test("default Main and switching back to Main retain exact move decorations", function()
	local initial = workspace.entry_identity
	local moved
	for _, item in ipairs(workspace.model.entries) do
		if item.path == "zz-moved.lua" then
			moved = item.identity
		end
	end
	assert(moved)
	local function check_main()
		local shown = workspace.mode_state.presentation
		assert(shown.selected_engine == "main" and shown.origin_engine.id == "main")
		assert(#shown.relations == 1, "controller discarded Main move relations")
		local labels = {}
		for _, decoration in ipairs(shown.decorations) do
			for _, mark in
				ipairs(vim.api.nvim_buf_get_extmarks(decoration.buf, decoration.namespace, 0, -1, { details = true }))
			do
				for _, label in ipairs(mark[4].virt_text or {}) do
					labels[#labels + 1] = label[1]
				end
			end
		end
		local text = table.concat(labels, "\n")
		assert(text:find("M1 move → NEW", 1, true) and text:find("M1 move → OLD", 1, true))
	end
	assert(controller.present(moved))
	check_main()
	assert(controller.engine("patience"))
	assert(controller.engine("main"))
	check_main()
	assert(controller.present(initial))
end)

test("Picker reuses native review style and unavailable engines retain the view", function()
	local before = workspace.mode_state.presentation
	vim.ui.select = function(items, opts, callback)
		assert(opts.kind == "native_review" and opts.prompt == "Review diff engine")
		assert(items[1].id == "main" and items[2].id == "difftastic")
		callback(items[2])
	end
	assert(controller.engine())
	assert(controller.status().engine == "main" and workspace.mode_state.presentation == before)
	pending[#pending].callback(nil, "Difftastic unavailable")
	assert(controller.status().engine == "main" and workspace.mode_state.presentation == before)
	assert(notifications[#notifications]:find("unavailable", 1, true))
end)
test("Difftastic receives materialized exact snapshots and replaces inline detail", function()
	assert(controller.engine("difftastic"))
	local operation = pending[#pending]
	assert(getmetatable(operation.request.entry) == nil)
	assert(operation.request.entry.old_text == old_text and operation.request.entry.new_text == new_text)
	operation.callback(output())
	local shown = workspace.mode_state.presentation
	assert(controller.status().engine == "difftastic" and shown.origin_engine.id == "difftastic")
	assert(shown.origin_engine.version == "0.71.0" and shown.structural)
	assert(shown.intraline.old[1].start_col == 10 and shown.intraline.old[1].end_col == 12)
	assert(shown.projection.by_source.old[2] and shown.projection.by_source.new[3])
	assert(workspace.model.entries[1].old_text == old_text)
end)
test("Split maps frozen sources and unanchorable filler rows without native diff", function()
	assert(controller.layout("split"))
	local shown = workspace.mode_state.presentation
	assert(not vim.wo[shown.left.win].diff and not vim.wo[shown.right.win].diff)
	local other_buf = vim.api.nvim_create_buf(false, true)
	local other_win = vim.api.nvim_open_win(other_buf, true, {
		relative = "editor",
		row = 0,
		col = 0,
		width = 20,
		height = 3,
		style = "minimal",
	})
	assert(not presenter.capture_location(workspace.mode_state), "non-source focus inherited a split source cursor")
	vim.api.nvim_win_close(other_win, true)
	vim.api.nvim_buf_delete(other_buf, { force = true })
	assert(vim.bo[shown.left.buf].modifiable == false and vim.bo[shown.right.buf].modifiable == false)
	assert(vim.api.nvim_buf_get_lines(shown.left.buf, 0, -1, false)[3] == "local keep = true")
	assert(shown.left.projection.rows[2].kind == "filler" and not shown.left.projection.rows[2].anchorable)
	assert(not presenter.resolve_range(workspace.mode_state, 1, 2, shown.generation, "old", shown.left.win))
	for _, context in ipairs({ "hunks", "full" }) do
		assert(controller.context(context))
		shown = workspace.mode_state.presentation
		for _, pane in ipairs({ shown.left, shown.right }) do
			vim.wo[pane.win].wrap = false
			vim.wo[pane.win].scrolloff = 0
			vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
			vim.api.nvim_win_call(pane.win, function()
				vim.cmd("normal! zt")
			end)
		end
		vim.cmd("redraw!")
		local left = vim.fn.screenpos(shown.left.win, 3, 1)
		local right = vim.fn.screenpos(shown.right.win, 3, 1)
		assert(left.row > 0 and left.row == right.row, "AST-matched rows are visually misaligned in " .. context)
		vim.api.nvim_win_set_width(shown.left.win, 32)
		vim.api.nvim_exec_autocmds("VimResized", {})
		vim.wait(20, function()
			return false
		end, 5)
		vim.cmd("redraw!")
		assert(vim.fn.screenpos(shown.left.win, 3, 1).row == vim.fn.screenpos(shown.right.win, 3, 1).row)
	end
end)
test("Comments and replies capture effective origin; composer blocks switches", function()
	local active = true
	review.editor.has_active = function()
		return active
	end
	local before = workspace.mode_state.presentation
	assert(not controller.engine("main"))
	assert(workspace.mode_state.presentation == before and workspace.engine == "difftastic")
	active = false
	review.editor.compose = function(opts, callback)
		assert(callback("engine comment", false, "issue"))
		return true
	end
	controller.general_comment()
	local item = workspace.session.items[#workspace.session.items]
	assert(item.origin_engine.id == "difftastic" and item.origin_engine.version == "0.71.0")
	assert(controller.engine("main"))
	controller.reply(item.id)
	local reply = workspace.session.items[#workspace.session.items]
	assert(reply.reply_to == item.id and reply.origin_engine.id == "main")
	controller.edit(item.id)
	assert(workspace.session.items[1].origin_engine.id == "difftastic")
	local snapshot = controller.snapshot()
	assert(snapshot.items[1].origin_engine.id == "difftastic")
	local exported = assert(review.export.render(workspace.session))
	assert(exported:find("Origin engine: `difftastic`", 1, true) and exported:find("Origin engine: `main`", 1, true))
end)
test("Text fallback remains selected per file and captures Main provenance", function()
	assert(controller.engine("difftastic"))
	pending[#pending].callback(
		vim.json.encode({ language = "Text (exceeded DFT_BYTE_LIMIT)", path = "sample.lua", status = "changed" })
	)
	local shown = workspace.mode_state.presentation
	assert(workspace.engine == "difftastic" and shown.origin_engine.id == "main", vim.inspect(notifications))
	assert(
		shown.fallback_reason and vim.wo[shown.left.win].winbar:find("effective:main", 1, true),
		vim.inspect({
			fallback = shown.fallback_reason,
			winbar = vim.wo[shown.left.win].winbar,
			notices = notifications,
		})
	)
	controller.general_comment()
	assert(workspace.session.items[#workspace.session.items].origin_engine.id == "main")
end)
test("Malformed results and superseded completion never replace a live view", function()
	assert(controller.engine("main"))
	local before = workspace.mode_state.presentation
	assert(controller.engine("difftastic"))
	pending[#pending].callback("{broken")
	assert(
		workspace.mode_state.presentation == before and workspace.engine == "main",
		vim.inspect({
			same = workspace.mode_state.presentation == before,
			engine = workspace.engine,
			notices = notifications,
		})
	)
	assert(controller.engine("difftastic"))
	local stale = pending[#pending]
	assert(controller.engine("main"))
	before = workspace.mode_state.presentation
	assert(stale.cancelled and cancelled > 0)
	stale.callback(output())
	assert(workspace.mode_state.presentation == before and workspace.engine == "main")
end)
test("AST-equivalent formatting keeps commentable full source with no byte detail", function()
	assert(controller.engine("difftastic"))
	pending[#pending].callback(vim.json.encode({ language = "Lua", path = "sample.lua", status = "unchanged" }))
	assert(controller.layout("inline") and controller.context("full"))
	local shown = workspace.mode_state.presentation
	assert(#shown.intraline.old == 0 and #shown.intraline.new == 0 and #shown.projection.hunks == 0)
	assert(shown.projection.by_source.old[1] and shown.projection.by_source.new[1])
	assert(vim.wo[shown.inline.win].winbar:find("No structural changes", 1, true))
end)
test("Split comments keep canonical coordinates and reveal hidden rows in both panes", function()
	assert(controller.engine("difftastic"))
	pending[#pending].callback(output())
	assert(controller.layout("split") and controller.context("full"))
	local shown = workspace.mode_state.presentation
	local total = #workspace.session.items
	vim.api.nvim_set_current_win(shown.left.win)
	controller.comment(2, 2, "issue")
	controller.comment(1, 3, "issue")
	assert(#workspace.session.items == total, "filler selections created source comments")
	controller.comment(11, 11, "issue")
	local lhs = workspace.session.items[#workspace.session.items]
	assert(lhs.anchor.side == "left" and lhs.anchor.start_line == 10 and lhs.anchor.end_line == 10)
	assert(lhs.anchor.context:find("-- unchanged context 7", 1, true))
	vim.api.nvim_set_current_win(shown.right.win)
	controller.comment(11, 11, "issue")
	local rhs = workspace.session.items[#workspace.session.items]
	assert(rhs.anchor.side == "right" and rhs.anchor.start_line == 11 and rhs.anchor.end_line == 11)
	assert(lhs.origin_engine.id == "difftastic" and rhs.origin_engine.id == "difftastic")
	assert(controller.context("hunks"))
	local function concealed(pane)
		for _, decoration in ipairs(workspace.mode_state.presentation.decorations) do
			if decoration.buf == pane.buf then
				for _, hidden in ipairs(decoration.omitted or {}) do
					if hidden.first <= 11 and hidden.last >= 11 then
						return true
					end
				end
			end
		end
		return false
	end
	shown = workspace.mode_state.presentation
	assert(concealed(shown.left) and concealed(shown.right))
	assert(controller.jump(lhs.id))
	shown = workspace.mode_state.presentation
	assert(not concealed(shown.left) and not concealed(shown.right))
	local location = assert(presenter.capture_location(workspace.mode_state))
	assert(location.side == "old" and location.line == 10)
	assert(controller.jump(rhs.id))
	location = assert(presenter.capture_location(workspace.mode_state))
	assert(location.side == "new" and location.line == 11)
	assert(controller.engine("main"))
	assert(lhs.origin_engine.id == "difftastic" and rhs.origin_engine.id == "difftastic")
end)
test("four engines retain layout, context, comments and refresh behavior", function()
	gumtree_adapter.analyze = function(_, callback)
		callback('{"matches":[],"actions":[]}')
		return function() end
	end
	adapter.analyze = function(_, callback)
		callback(output())
		return function() end
	end
	local expected = { "main", "difftastic", "gumtree", "patience" }
	assert(vim.deep_equal(vim.fn.getcompletion("ReviewEngine ", "cmdline"), expected))
	local preserved = workspace.session.items[1].origin_engine.id
	for _, id in ipairs(expected) do
		assert(controller.engine(id))
		assert(workspace.engine == id and workspace.mode_state.presentation.origin_engine.id == id)
		for _, layout in ipairs({ "inline", "split" }) do
			for _, context in ipairs({ "hunks", "full" }) do
				assert(controller.layout(layout) and controller.context(context))
				local shown = workspace.mode_state.presentation
				assert(shown.layout == layout and shown.context == context and shown.origin_engine.id == id)
				assert((shown.projected ~= nil) == (id == "patience" or id == "difftastic"))
				assert(shown.entry.old_text == old_text and shown.entry.new_text == new_text)
			end
		end
		local before = workspace.mode_state.presentation
		review.editor.has_active = function()
			return true
		end
		assert(not controller.engine(id == "main" and "patience" or "main"))
		assert(before == workspace.mode_state.presentation)
		review.editor.has_active = function()
			return false
		end
		controller.general_comment()
		local comment = workspace.session.items[#workspace.session.items]
		assert(comment.origin_engine.id == id)
		controller.reply(comment.id)
		assert(workspace.session.items[#workspace.session.items].origin_engine.id == id)
		assert(controller.refresh())
		assert(workspace.engine == id and workspace.mode_state.presentation.origin_engine.id == id)
		assert(controller.present(workspace.entry_identity))
		assert(controller.mode("off") and controller.mode("on"))
		assert(workspace.engine == id and workspace.mode_state.presentation.origin_engine.id == id)
		assert(controller.suspend_for_session() and controller.restore_after_session())
		assert(workspace.engine == id and workspace.mode_state.presentation.origin_engine.id == id)
	end
	assert(workspace.session.items[1].origin_engine.id == preserved)
	local markdown = assert(review.export.render(workspace.session))
	for _, id in ipairs(expected) do
		assert(markdown:find("Origin engine: `" .. id .. "`", 1, true))
	end
end)
test("GumTree selection survives unsupported files with visible Main provenance", function()
	assert(controller.refresh(), vim.inspect(notifications))
	local lua_entry, other
	for _, item in ipairs(workspace.model.entries) do
		if item.path == "sample.lua" then
			lua_entry = item.identity
		elseif item.path == "zz-other.txt" then
			other = item.identity
		end
	end
	assert(lua_entry and other)
	assert(controller.engine("gumtree"))
	assert(controller.present(other))
	local shown = workspace.mode_state.presentation
	assert(workspace.engine == "gumtree" and shown.origin_engine.id == "main" and shown.fallback_reason)
	local pane = shown.inline or shown.right or shown.left
	assert(vim.wo[pane.win].winbar:find("effective:main", 1, true))
	controller.general_comment()
	assert(workspace.session.items[#workspace.session.items].origin_engine.id == "main")
	assert(controller.present(lua_entry))
	assert(workspace.engine == "gumtree" and workspace.mode_state.presentation.origin_engine.id == "gumtree")
end)

test("GumTree errors and superseded completion retain the previous view", function()
	assert(controller.engine("main"))
	local done, cancelled_gumtree
	gumtree_adapter.analyze = function(_, callback)
		done = callback
		return function()
			cancelled_gumtree = true
		end
	end
	local before = workspace.mode_state.presentation
	assert(controller.engine("gumtree"))
	done("{broken")
	assert(workspace.mode_state.presentation == before and workspace.engine == "main")
	assert(controller.engine("gumtree"))
	local stale = done
	assert(controller.engine("patience"))
	before = workspace.mode_state.presentation
	assert(cancelled_gumtree)
	stale('{"matches":[],"actions":[]}')
	assert(workspace.mode_state.presentation == before and workspace.engine == "patience")
end)

controller.teardown()
for name, value in pairs(originals) do
	if name == "gumtree_analyze" then
		gumtree_adapter.analyze = value
	elseif name == "analyze" then
		adapter.analyze = value
	elseif name == "compose" or name == "has_active" then
		review.editor[name] = value
	elseif name == "select" then
		vim.ui.select = value
	else
		store[name] = value
	end
end
vim.notify = original_notify
vim.fn.delete(fixture, "rf")
vim.fn.delete(state_home, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("native_review_engines_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
