-- Frozen Git sources, commands, canonical comments and store integration.
-- Allocate the screen first: -c 'lua dofile(...)'.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.o.lines = 44
vim.o.columns = 140
vim.g.mapleader = " "
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(
	vim.env.NVIM_CONFIG_MD_RENDER_ROOT or vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "md-render.nvim")
)
require("config.local_plugins").setup()
assert(require("config.markdown_view").configure_renderer())
local review = require("config.native_review")
local host = require("config.code_review")
local renderer = require("config.review_markdown")
local structural = require("config.review_structural_diff")
local diagram = require("config.diagram")
local diagram_image = require("config.diagram_image")
local controller, presenter, store = review.controller, review.presenter, review.store
local fixture, state_home = vim.fn.tempname(), vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
assert(vim.fn.mkdir(state_home, "p", 448) == 1)
local failures, count, notifications = {}, 0, {}
local originals = {
	notify = vim.notify,
	compose = review.editor.compose,
	has_active = review.editor.has_active,
	build_snapshot = renderer.build_snapshot,
	analyze = structural.analyze,
	load = store.load,
	save = store.save,
	list = store.list,
	snacks = _G.Snacks,
	image_load = diagram_image.load,
}
vim.notify = function(message)
	notifications[#notifications + 1] = tostring(message)
end
for _, name in ipairs({ "load", "save", "list" }) do
	store[name] = function(repo_root, value, options)
		if name == "list" then
			return originals[name](repo_root, { state_home = state_home })
		end
		return originals[name](repo_root, value, vim.tbl_extend("force", options or {}, { state_home = state_home }))
	end
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
local function write(path, text)
	local file = assert(io.open(fixture .. "/" .. path, "wb"))
	file:write(text)
	file:close()
end
local function git(args)
	local argv = { "git", "-C", fixture }
	vim.list_extend(argv, args)
	local result = vim.system(argv, { text = true }):wait()
	assert(result.code == 0, result.stderr)
end
local old = "# Title\n\nWait **30 seconds** before\ncontinuing.\n\n[docs][ref]\n\n[ref]: https://example.invalid/v1\n"
local new = old:gsub("30", "60"):gsub("/v1", "/v2")
local diagram_old = table.concat({
	"# Diagram",
	"",
	"```mermaid",
	"flowchart LR",
	"  A --> OLD",
	"```",
	"",
	"```plantuml",
	"@startuml",
	"Alice -> Bob: old",
	"@enduml",
	"```",
	"",
	"![preview](current.png)",
	"",
}, "\n")
local diagram_new = diagram_old:gsub("OLD", "NEW"):gsub("Bob: old", "Bob: new")
local table_old = "| Key | Value |\n| --- | --- |\n| alpha | stable |\n| delay | 30 |\n| gamma | stable |\n"
local table_new = table_old:gsub("30", "60")
local code_old = "```lua\nlocal stable = 1\nlocal value = 30\nreturn stable\n```\n"
local code_new = code_old:gsub("30", "60")
git({ "init", "-q" })
write("sample.md", old)
write("other.md", "Other old text\n")
write("deleted.md", "# Deleted\n\nOld text\n")
write("sample.lua", "return 30\n")
write("diagram.md", diagram_old)
write("table.md", table_old)
write("code.md", code_old)
git({ "add", "." })
git({ "-c", "user.name=Review Test", "-c", "user.email=review@example.invalid", "commit", "-qm", "fixture" })
write("sample.md", new)
write("other.md", "Other new text\n")
write("added.md", "# Added\n\nNew text\n")
write("sample.lua", "return 60\n")
write("diagram.md", diagram_new)
write("table.md", table_new)
write("code.md", code_new)
assert(vim.fn.delete(fixture .. "/deleted.md") == 0)
host.setup()
local workspace, left_comment, right_comment, hidden_comment
local composed = 0
review.editor.compose = function(_, callback)
	composed = composed + 1
	assert(callback("Markdown review comment " .. composed, false, "issue"))
	return true
end
local function select(path)
	for _, entry in ipairs(workspace.model.entries) do
		if entry.path == path then
			assert(controller.present(entry.identity))
			return entry
		end
	end
	error("missing fixture entry " .. path)
end
local function pane(side)
	local p = workspace.mode_state.presentation
	return p.inline or (side == "old" and p.left or p.right)
end
local function focus(side, source_line)
	local target = pane(side)
	local p = workspace.mode_state.presentation
	local projection = target.projection or p.projection
	local row = projection and assert(projection.by_source[side][source_line]) or source_line
	vim.api.nvim_set_current_win(target.win)
	vim.api.nvim_win_set_cursor(target.win, { row, 0 })
	return row
end
test("ReviewMarkdown registers its command, completion and mapping with source as default", function()
	assert(vim.fn.exists(":ReviewMarkdown") == 2)
	assert(vim.deep_equal(vim.fn.getcompletion("ReviewMarkdown ", "cmdline"), { "source", "render", "toggle" }))
	assert(vim.fn.maparg(" rM", "n"):lower() == "<cmd>reviewmarkdown<cr>")
	workspace = assert(controller.open({ kind = "working" }, fixture))
	select("sample.md")
	assert(controller.status().markdown_view == "source" and workspace.engine == "main")
	assert(controller.engine("patience"))
	assert(controller.layout("inline") and controller.context("full"))
	vim.cmd("ReviewMarkdown render")
	assert(controller.status().markdown_view == "render" and workspace.engine == "patience")
	assert(workspace.mode_state.presentation.origin_engine.id == "markdown-visual")
end)
test("rendering uses frozen Git text even when the live file changes", function()
	write("sample.md", new:gsub("60", "999"))
	select("sample.md")
	local p = workspace.mode_state.presentation
	local text = table.concat(vim.api.nvim_buf_get_lines(p.inline.buf, 0, -1, false), "\n")
	assert(text:find("60 seconds", 1, true) and not text:find("999", 1, true))
	assert(p.entry.old_text == old and p.entry.new_text == new)
	write("sample.md", new)
end)
test("rendered comments store whole original blocks and visual provenance on both sides", function()
	for _, side in ipairs({ "old", "new" }) do
		local row = focus(side, 4)
		controller.comment(row, row)
		local item = workspace.session.items[#workspace.session.items]
		assert(item.anchor.side == (side == "old" and "left" or "right"))
		assert(item.anchor.start_line == 3 and item.anchor.end_line == 4)
		assert(item.anchor.context:find("**", 1, true))
		assert(item.origin_engine.id == "markdown-visual" and item.origin_engine.version == renderer.version)
		if side == "old" then
			left_comment = item
		else
			right_comment = item
		end
	end
	local p = workspace.mode_state.presentation
	local first, last = p.projection.by_source.old[3], p.projection.by_source.new[4]
	local before = composed
	controller.comment(first, last)
	assert(composed == before, "mixed OLD/NEW selection opened a composer")
	local loaded = assert(originals.load(fixture, workspace.session.scope.id, { state_home = state_home }))
	assert(loaded.items[1].origin_engine.id == "markdown-visual" and loaded.items[1].anchor.end_line == 4)
	assert(review.export.render(loaded):find("Origin engine: `markdown-visual`", 1, true))
end)
test("source engine and block location survive source/render and layout changes", function()
	focus("old", 3)
	vim.api.nvim_win_set_cursor(pane("old").win, { vim.api.nvim_win_get_cursor(pane("old").win)[1], 5 })
	assert(controller.markdown("source"))
	local location = assert(presenter.capture_location(workspace.mode_state))
	assert(location.side == "old" and location.line == 3 and location.col == 1)
	assert(workspace.engine == "patience" and workspace.mode_state.presentation.origin_engine.id == "patience")
	assert(controller.markdown("render") and controller.layout("split"))
	location = assert(presenter.capture_location(workspace.mode_state))
	assert(location.side == "old" and location.line == 3)
	assert(controller.jump(right_comment.id))
	assert(controller.layout("inline") and controller.context("hunks"))
	location = assert(presenter.capture_location(workspace.mode_state))
	assert(location.side == "new" and location.line == 3)
	assert(left_comment.origin_engine.id == "markdown-visual")
end)
test("renderer, parser and source-engine failures retain the rendered presentation", function()
	local previous = workspace.mode_state.presentation
	renderer.build_snapshot = function()
		return nil, "deliberate renderer failure"
	end
	assert(not controller.markdown("render"))
	renderer.build_snapshot = originals.build_snapshot
	assert(workspace.mode_state.presentation == previous and workspace.markdown_view == "render")
	renderer.build_snapshot = function()
		return {}
	end
	assert(not controller.markdown("render"))
	renderer.build_snapshot = originals.build_snapshot
	assert(workspace.mode_state.presentation == previous and workspace.markdown_view == "render")
	local get_parser = vim.treesitter.get_string_parser
	vim.treesitter.get_string_parser = function()
		return nil
	end
	assert(not controller.markdown("render"))
	vim.treesitter.get_string_parser = get_parser
	assert(workspace.mode_state.presentation == previous)
	structural.analyze = function(_, callback)
		callback(nil, "deliberate engine failure")
		return function() end
	end
	assert(controller.engine("difftastic"))
	assert(
		workspace.mode_state.presentation == previous
			and workspace.markdown_view == "render"
			and workspace.engine == "patience"
	)
	assert(controller.engine("main"))
	assert(workspace.markdown_view == "source" and workspace.mode_state.presentation.origin_engine.id == "main")
	assert(controller.markdown("render"))
end)
test("render preference travels across Markdown entries and leaves source available elsewhere", function()
	select("sample.lua")
	assert(workspace.markdown_view == "render" and not workspace.mode_state.presentation.engine_result.markdown)
	local previous = workspace.mode_state.presentation
	assert(not controller.markdown("render") and workspace.mode_state.presentation == previous)
	select("other.md")
	assert(workspace.mode_state.presentation.engine_result.markdown)
	for _, path in ipairs({ "added.md", "deleted.md" }) do
		local entry = select(path)
		assert(controller.layout("split"))
		local p = workspace.mode_state.presentation
		assert(p.left and p.right and p.engine_result.markdown)
		assert(p.target.side == (entry.deleted and "old" or "new"))
		local filler = entry.deleted and p.right or p.left
		vim.api.nvim_set_current_win(filler.win)
		vim.api.nvim_win_set_cursor(filler.win, { 1, 0 })
		local before = composed
		controller.comment(1, 1)
		assert(composed == before, "filler row acquired an anchor")
	end
	select("sample.md")
end)
test("jumping to a hidden source comment reveals the source in either source layout", function()
	assert(controller.markdown("source") and controller.layout("inline"))
	local row = focus("new", 8)
	controller.comment(row, row)
	hidden_comment = workspace.session.items[#workspace.session.items]
	assert(hidden_comment.anchor.start_line == 8 and hidden_comment.origin_engine.id == "main")
	for _, engine in ipairs({ "main", "patience" }) do
		assert(controller.engine(engine))
		for _, layout in ipairs({ "inline", "split" }) do
			assert(controller.layout(layout) and controller.markdown("render"))
			assert(not presenter.locate_anchor(workspace.mode_state, hidden_comment.anchor))
			assert(controller.jump(hidden_comment.id), vim.inspect(notifications))
			assert(workspace.markdown_view == "source")
			local location = assert(presenter.capture_location(workspace.mode_state))
			assert(location.side == "new" and location.line == 8)
		end
	end
end)
test("composer blocks view switches and render survives refresh, mode and session suspension", function()
	assert(controller.markdown("render"))
	local previous = workspace.mode_state.presentation
	review.editor.has_active = function()
		return true
	end
	assert(not controller.markdown("source"))
	assert(not controller.engine("main"))
	assert(workspace.mode_state.presentation == previous and workspace.markdown_view == "render")
	review.editor.has_active = originals.has_active
	assert(controller.refresh(), vim.inspect(notifications))
	assert(workspace.mode_state.presentation.engine_result.markdown and workspace.engine == "patience")
	assert(controller.mode("off") and controller.mode("on"))
	assert(workspace.mode_state.presentation.engine_result.markdown)
	assert(controller.suspend_for_session() and controller.restore_after_session())
	assert(workspace.mode_state.presentation.engine_result.markdown)
	local loaded = assert(originals.load(fixture, workspace.session.scope.id, { state_home = state_home }))
	assert(loaded.version == 3 and loaded.items[1].origin_engine.id == "markdown-visual")
end)
test("table row comments preserve exact source anchors in both rendered layouts", function()
	select("table.md")
	assert(controller.markdown("render") and controller.context("full"))
	for _, layout in ipairs({ "inline", "split" }) do
		assert(controller.layout(layout))
		for _, side in ipairs({ "old", "new" }) do
			local row = focus(side, 4)
			controller.comment(row, row)
			local item = workspace.session.items[#workspace.session.items]
			assert(item.anchor.start_line == 4 and item.anchor.end_line == 4)
			assert(item.anchor.side == (side == "old" and "left" or "right"))
			assert(item.anchor.context:find("| delay |", 1, true))
			assert(item.origin_engine.version == renderer.version)
			local target = assert(host.source_document())
			assert(target.side == side and target.row == 4)
			assert(controller.markdown("source"))
			local location = assert(presenter.capture_location(workspace.mode_state))
			assert(location.side == side and location.line == 4)
			assert(controller.markdown("render"))
		end
	end
	local loaded = assert(originals.load(fixture, workspace.session.scope.id, { state_home = state_home }))
	local item = loaded.items[#loaded.items]
	assert(item.anchor.start_line == 4 and item.anchor.end_line == 4)
	assert(item.anchor.context:find("| delay |", 1, true))
	assert(review.export.render(loaded):find("table.md:4 [NEW]", 1, true))
end)
test("code line comments and navigation retain frozen row anchors and provenance", function()
	select("code.md")
	assert(controller.markdown("render") and controller.context("full"))
	for _, layout in ipairs({ "inline", "split" }) do
		assert(controller.layout(layout))
		for _, side in ipairs({ "old", "new" }) do
			local row = focus(side, 3)
			controller.comment(row, row)
			local item = workspace.session.items[#workspace.session.items]
			assert(item.anchor.start_line == 3 and item.anchor.end_line == 3, vim.inspect(item.anchor))
			assert(item.anchor.side == (side == "old" and "left" or "right"))
			assert(item.origin_engine.version == renderer.version)
			write("code.md", code_new:gsub("60", "999"))
			local target = assert(host.source_document({ start_row = row, end_row = row }))
			assert(
				target.side == side
					and target.row == 3
					and target.selection.start_row == 3
					and target.selection.end_row == 3
			)
			assert(target.lines[3]:find(side == "old" and "30" or "60", 1, true), "preview read current worktree code")
			write("code.md", code_new)
			assert(controller.markdown("source"))
			local location = assert(presenter.capture_location(workspace.mode_state))
			assert(location.side == side and location.line == 3)
			assert(controller.markdown("render"))
		end
	end
	local loaded = assert(originals.load(fixture, workspace.session.scope.id, { state_home = state_home }))
	local item = loaded.items[#loaded.items]
	assert(item.anchor.start_line == 3 and item.anchor.end_line == 3 and item.origin_engine.version == renderer.version)
	assert(review.export.render(loaded):find("code.md:3 [NEW]", 1, true))
	write("code.md", code_new)
end)
test("diagram keymaps preview the frozen OLD/NEW fence in both source and rendered layouts", function()
	local jobs = {}
	_G.Snacks = { image = {
		supports_terminal = function()
			return false
		end,
	} }
	assert(diagram.setup({
		cache_root = state_home .. "/diagrams",
		resolve_executable = function(executable)
			return "/verified/" .. executable
		end,
		spawn = function(argv, options, callback)
			jobs[#jobs + 1] = { argv = vim.deepcopy(argv), source = options.stdin }
			callback({ code = 0, stdout = options.stdin, stderr = "" })
			return { kill = function() end }
		end,
		schedule = function(callback)
			callback()
		end,
	}))
	select("diagram.md")
	write("diagram.md", diagram_new:gsub("NEW", "LIVE"):gsub("Bob: new", "Bob: live"))
	for _, view in ipairs({ "source", "render" }) do
		assert(controller.markdown(view))
		for _, layout in ipairs({ "inline", "split" }) do
			assert(controller.layout(layout))
			for _, context in ipairs({ "full", "hunks" }) do
				assert(controller.context(context))
				for _, side in ipairs({ "old", "new" }) do
					for _, source_line in ipairs({ 5, 10 }) do
						focus(side, source_line)
						local target = assert(host.source_document())
						assert(target.side == side and target.frozen and target.filetype == "markdown")
						assert(
							table.concat(target.lines, "\n")
								== (side == "old" and diagram_old or diagram_new):sub(1, -2)
						)
						assert(target.rendered == (view == "render"))
						if target.rendered then
							assert(target.col == nil)
						end
						local expected = source_line == 5 and ("flowchart LR\n  A --> " .. side:upper())
							or ("@startuml\nAlice -> Bob: " .. side .. "\n@enduml")
						local origin_win = vim.api.nvim_get_current_win()
						assert(vim.fn.maparg(" md", "n"):lower() == "<cmd>diagramshow<cr>")
						vim.api.nvim_feedkeys(" md", "xt", false)
						assert(vim.api.nvim_get_current_win() ~= origin_win, "diagram keymap did not open a float")
						assert(
							table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") == expected,
							vim.inspect(notifications)
						)
						vim.api.nvim_feedkeys("q", "xt", false)
						assert(vim.api.nvim_get_current_win() == origin_win, "closing the diagram lost the review pane")
					end
				end
			end
		end
	end
	assert(#jobs == 4, "identical frozen fences were not reused from the diagram cache")
	assert(vim.deep_equal(jobs[1].argv, { "/verified/mmdflux" }))
	assert(vim.deep_equal(jobs[2].argv, { "/verified/plantuml", "-ttxt", "-pipe" }))
	write("diagram.md", diagram_new)
	_G.Snacks = originals.snacks
end)
test("diagram selections resolve the selected side and complete rendered fences", function()
	select("diagram.md")
	assert(controller.layout("inline") and controller.context("full"))
	for _, view in ipairs({ "source", "render" }) do
		assert(controller.markdown(view))
		local old_row = focus("old", 5)
		focus("new", 5)
		local selection = { start_row = old_row, end_row = old_row }
		local target = assert(host.source_document(selection))
		assert(target.side == "old" and table.concat(target.lines, "\n"):find("A --> OLD", 1, true))
		local session = assert(diagram.show("ascii", selection), vim.inspect(notifications))
		assert(session.request.source == (view == "render" and "flowchart LR\n  A --> OLD" or "  A --> OLD"))
		assert(session:cancel("test"))
		focus("new", 5)
		local mixed = { start_row = old_row, end_row = focus("new", 5) }
		local document, err = host.source_document(mixed)
		assert(not document and err, "cross-side diagram selection acquired a source")
		assert(not diagram.show("ascii", mixed))
	end
	assert(controller.layout("split"))
	local row = focus("old", 10)
	local session = assert(diagram.show("ascii", { start_row = row, end_row = row }), vim.inspect(notifications))
	assert(session.request.kind == "plantuml" and session.request.source == "@startuml\nAlice -> Bob: old\n@enduml")
	assert(session:cancel("test"))
	assert(controller.layout("inline"))
	local first = focus("old", 5)
	local last = focus("old", 10)
	assert(
		not diagram.show("ascii", { start_row = first, end_row = last }),
		"multiple diagram blocks were rendered as one"
	)
end)
test("review diagram previews reject live images and unanchorable rows", function()
	diagram_image.load = function()
		error("review preview read a live image")
	end
	select("diagram.md")
	for _, view in ipairs({ "source", "render" }) do
		assert(controller.markdown(view))
		focus("new", 14)
		local session, err = diagram.show("ascii")
		assert(not session and err:find("frozen references", 1, true))
	end
	diagram_image.load = originals.image_load
	select("added.md")
	assert(controller.layout("split"))
	vim.api.nvim_set_current_win(pane("old").win)
	local target, err = host.source_document()
	assert(not target and err, "filler row acquired a diagram source")
	assert(not diagram.show("ascii"))
	select("sample.md")
end)
test("queued resize cannot recreate a presentation after Review closes", function()
	local state = workspace.mode_state
	vim.api.nvim_exec_autocmds("VimResized", {})
	assert(controller.close())
	vim.wait(30, function()
		return false
	end, 5)
	assert(not state.presentation and not controller.status().active)
end)
controller.teardown()
_G.Snacks = originals.snacks
diagram_image.load = originals.image_load
vim.notify = originals.notify
review.editor.compose, review.editor.has_active = originals.compose, originals.has_active
renderer.build_snapshot, structural.analyze = originals.build_snapshot, originals.analyze
for _, name in ipairs({ "load", "save", "list" }) do
	store[name] = originals[name]
end
vim.fn.delete(fixture, "rf")
vim.fn.delete(state_home, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("native_review_markdown_integration_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
