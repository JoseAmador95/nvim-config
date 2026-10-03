vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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

local function find_section(sections, id)
	for _, section in ipairs(sections) do
		if section.id == id then
			return section
		end
	end
end

local function find_item(sections, id)
	for _, section in ipairs(sections) do
		for _, item in ipairs(section.items) do
			if item.id == id then
				return item
			end
		end
	end
end

local catalog = require("config.menu.catalog")
local context = require("config.menu.context")
local action_palette = require("config.action_palette")

-- Catalog definitions remain pure host data; filtering, availability and bound
-- execution belong to action-palette.nvim.
catalog.build = function(menu_context, dispatch, surface)
	menu_context = vim.deepcopy(menu_context)
	menu_context.target = menu_context.target or action_palette.capture_target()
	if dispatch == nil then
		return action_palette.sections(menu_context, surface)
	end
	local registry = action_palette.new({
		target = {
			revalidate = function(target)
				return target
			end,
		},
		notify = function() end,
	})
	registry:register_catalog(catalog.definitions(), {
		supports = function()
			return true
		end,
		execute = function(id)
			return dispatch(id)
		end,
	})
	return registry:sections(menu_context, surface)
end

test("context is pure and derives visual modes", function()
	local values = { filetype = "json", mode = "V" }
	local menu_context = context.new(values)
	equal({
		filetype = "json",
		mode = "V",
		visual = true,
		buftype = "",
		modifiable = true,
	}, menu_context, "visual context")
	assert(values.visual == nil, "context constructor mutated its input")
	equal(false, context.new({ mode = "n" }).visual, "normal mode was treated as visual")
	equal(true, context.new({ mode = "n", visual = true }).visual, "explicit visual override was ignored")

	local target = { bufnr = 7, cursor = { line = 3, col = 2 } }
	local targeted = context.new({ target = target })
	target.cursor.line = 99
	equal(3, targeted.target.cursor.line, "context retained a mutable target reference")
end)

test("context capture records the origin editor target", function()
	local captured = context.capture()
	equal(vim.api.nvim_get_current_buf(), captured.target.bufnr, "captured buffer")
	equal(vim.api.nvim_get_current_win(), captured.target.winid, "captured window")
	equal(vim.api.nvim_get_current_tabpage(), captured.target.tabpage, "captured tab")
	equal(vim.api.nvim_win_get_cursor(0)[1], captured.target.cursor.line, "captured cursor line")
	equal(vim.api.nvim_buf_get_changedtick(0), captured.target.changedtick, "captured changedtick")
	assert(captured.target.mode == nil, "mode leaked into ActionTarget")
	assert(captured.target.selection == nil, "selection leaked into ActionTarget")
	assert(captured.target.buftype == nil, "buffer metadata leaked into ActionTarget")
	equal(vim.bo.buftype, captured.buftype, "captured buffer type")
	equal(vim.bo.modifiable, captured.modifiable, "captured modifiable state")
end)

test("file path actions are palette-only and reflect the origin window", function()
	local actions = require("config.menu.actions")
	local original_clipboard = package.loaded["config.clipboard"]
	local original_cwd = vim.fn.getcwd()
	local origin_buf = vim.api.nvim_get_current_buf()
	local root = vim.fn.tempname()
	local source = vim.fs.joinpath(root, "real.lua")
	local link = vim.fs.joinpath(root, "alias.lua")
	local nested = vim.fs.joinpath(root, "nested")
	local copied = {}

	local ok, err = xpcall(function()
		assert(vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p", 448) == 1)
		assert(vim.fn.mkdir(nested, "p", 448) == 1)
		assert(vim.fn.writefile({ "return true" }, source) == 0)
		assert(vim.uv.fs_symlink(source, link))
		vim.cmd("enew")
		local bufnr = vim.api.nvim_get_current_buf()
		local target_win = vim.api.nvim_get_current_win()
		vim.api.nvim_buf_set_name(bufnr, link)
		vim.cmd("new")
		local unrelated_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(target_win)
		vim.api.nvim_cmd({ cmd = "lcd", args = { nested } }, {})

		local captured = context.capture()
		equal("alias.lua", vim.fs.basename(captured.path), "capture resolved the lexical symlink path")
		equal(vim.fn.getcwd(), captured.cwd, "capture ignored the origin window-local cwd")
		equal(vim.fs.dirname(captured.path), captured.git_root, "capture did not find the lexical Git root")

		local palette = catalog.build(captured, function() end, "palette")
		local compact = catalog.build(captured, function() end, "context")
		for _, id in ipairs({
			"file.copy_absolute_path",
			"file.copy_cwd_relative_path",
			"file.copy_git_relative_path",
		}) do
			local item = assert(find_item(palette, id), id .. " is unavailable for a named file")
			equal("window", item.target, id .. " does not retain origin-window semantics")
			assert(not find_item(compact, id), id .. " leaked into the context menu")
		end

		package.loaded["config.clipboard"] = {
			copy_text = function(value)
				copied[#copied + 1] = value
				return true
			end,
		}
		local target = captured.target
		vim.api.nvim_set_current_win(unrelated_win)
		vim.api.nvim_cmd({ cmd = "lcd", args = { original_cwd } }, {})
		assert(actions.execute("file.copy_absolute_path", target))
		assert(actions.execute("file.copy_cwd_relative_path", target))
		assert(actions.execute("file.copy_git_relative_path", target))
		equal(unrelated_win, vim.api.nvim_get_current_win(), "path action stole focus from the caller window")
		equal({ captured.path, "../alias.lua", "alias.lua" }, copied, "path copies changed lexical origin semantics")
		for _, value in ipairs(copied) do
			assert(not value:find("\n", 1, true), "copied path gained a newline")
		end

		local unnamed = catalog.build(context.new({ buftype = "", path = nil }), function() end, "palette")
		local special = catalog.build(context.new({ buftype = "nofile", path = link }), function() end, "palette")
		local outside = catalog.build(context.new({ buftype = "", path = link }), function() end, "palette")
		for _, id in ipairs({
			"file.copy_absolute_path",
			"file.copy_cwd_relative_path",
			"file.copy_git_relative_path",
		}) do
			assert(not find_item(unnamed, id), id .. " is available for an unnamed buffer")
			assert(not find_item(special, id), id .. " is available for a special buffer")
		end
		assert(find_item(outside, "file.copy_absolute_path"), "absolute path requires a Git repository")
		assert(find_item(outside, "file.copy_cwd_relative_path"), "cwd-relative path requires a Git repository")
		assert(not find_item(outside, "file.copy_git_relative_path"), "Git-relative path is available outside Git")
		vim.api.nvim_win_close(unrelated_win, true)
	end, debug.traceback)

	package.loaded["config.clipboard"] = original_clipboard
	pcall(vim.api.nvim_cmd, { cmd = "lcd", args = { original_cwd } }, {})
	if vim.api.nvim_get_current_buf() ~= origin_buf then
		pcall(vim.api.nvim_buf_delete, vim.api.nvim_get_current_buf(), { force = true })
	end
	vim.fn.delete(root, "rf")
	assert(ok, err)
end)

test("session recents are unique, bounded, and accept only palette executions", function()
	local recent = require("config.menu.recent")
	recent.teardown()
	recent.configure(2)
	assert(not recent.observe({ kind = "executed", id = "ignored.context", surface = "context" }))
	assert(not recent.observe({ kind = "rejected", id = "ignored.rejected", surface = "palette" }))
	assert(not recent.observe({ kind = "error", id = "ignored.error", surface = "palette" }))
	assert(recent.observe({ kind = "executed", id = "first", surface = "palette" }))
	assert(recent.observe({ kind = "executed", id = "second", surface = "palette" }))
	assert(recent.observe({ kind = "executed", id = "first", surface = "palette" }))
	equal({ "first", "second" }, recent.ids(), "MRU order or deduplication drifted")

	local ordered = recent.order({
		{ id = "second", text = "second search" },
		{ id = "third", text = "third search" },
		{ id = "first", text = "first search" },
	})
	equal(
		{ "first", "second", "third" },
		vim.tbl_map(function(item)
			return item.id
		end, ordered),
		"visible recents were not pinned newest-first"
	)
	assert(ordered[1].recent and ordered[2].recent and not ordered[3].recent, "recent decoration is incorrect")
	equal("first search", ordered[1].text, "recent decoration changed fuzzy-search text")

	recent.configure(0)
	equal({}, recent.ids(), "zero recent limit retained session history")
	assert(not recent.observe({ kind = "executed", id = "disabled", surface = "palette" }))
	recent.teardown()
end)

test("catalog exposes stable descriptor ids, labels, hints, and dispatch", function()
	local actions = require("config.menu.actions")
	local dispatched
	local sections = catalog.build(context.new({ filetype = "lua" }), function(id)
		dispatched = id
	end)
	local seen = {}
	for _, section in ipairs(sections) do
		assert(type(section.id) == "string" and section.id ~= "", "section id is missing")
		assert(type(section.label) == "string" and section.label ~= "", "section label is missing")
		for _, item in ipairs(section.items) do
			assert(type(item.id) == "string" and item.id ~= "", "descriptor id is missing")
			assert(not seen[item.id], "duplicate descriptor id: " .. item.id)
			seen[item.id] = true
			assert(type(item.label) == "string" and item.label ~= "", "descriptor label is missing")
			assert(type(item.run) == "function", "descriptor run callback is missing")
			assert(actions.supports(item.id), "descriptor has no action: " .. item.id)
			assert(item.name == nil and item.cmd == nil and item.rtxt == nil, "backend fields leaked into descriptor")
		end
	end

	local history = assert(find_item(sections, "picker.git_bcommits"), "file-history descriptor missing")
	equal("File History", history.label, "git file history has a misleading label")
	local navigation_history =
		assert(find_item(sections, "navigation.history"), "navigation-history descriptor missing")
	equal("<leader>nh", navigation_history.hint, "navigation-history hint")
	assert(not find_item(sections, "Git Branches"), "legacy Git Branches descriptor remains")
	local definition = assert(find_item(sections, "lsp.definition"), "definition descriptor missing")
	equal("gd", definition.hint, "definition hint")
	definition.run()
	equal("lsp.definition", dispatched, "descriptor dispatched the wrong action")
	local devcontainer_recovery =
		assert(find_item(sections, "command.devcontainer_host"), "Dev Container recovery descriptor missing")
	equal("Recover / Return to Host Editor", devcontainer_recovery.label, "Dev Container recovery label")
	equal(
		{ "recover", "recovery", "lifecycle", "error", "stopped", "dead", "host" },
		devcontainer_recovery.keywords,
		"Dev Container recovery keywords"
	)
	assert(find_item(sections, "command.lazygit"), "retained LazyGit action is missing")
	for _, id in ipairs({
		"command.bookmark_add",
		"command.neogen",
		"command.plantuml_ascii",
		"command.plantuml_preview",
		"command.remote_start",
		"command.xml_outline",
		"command.yaml_outline",
		"git.neogit",
	}) do
		assert(not find_item(sections, id), "removed menu action remains: " .. id)
	end
	assert(not find_section(sections, "bookmarks"), "removed bookmarks section remains")
end)

test("every curated definition has an executable action", function()
	local actions = require("config.menu.actions")
	local definitions = catalog.definitions()
	local descriptor_count = 0
	local inventory = {}
	local function record(value)
		inventory[#inventory + 1] = value or ""
	end
	for _, section in ipairs(definitions) do
		record("S")
		record(section.id)
		record(section.label)
		record(section.palette_label)
		record(section.when and "1" or "0")
		record(section.surfaces and tostring(section.surfaces.palette) or "")
		record(section.surfaces and tostring(section.surfaces.context) or "")
		for _, item in ipairs(section.items) do
			descriptor_count = descriptor_count + 1
			assert(actions.supports(item.id), "definition has no action: " .. item.id)
			record("I")
			record(item.id)
			record(item.label)
			record(item.hint)
			record(item.palette_label)
			record(item.when and "1" or "0")
			record(item.surfaces and tostring(item.surfaces.palette) or "")
			record(item.surfaces and tostring(item.surfaces.context) or "")
			for _, keyword in ipairs(item.keywords or {}) do
				record("K")
				record(keyword)
			end
		end
	end
	assert(descriptor_count == 289, "catalog must retain exactly 289 explicit descriptors")
	equal(
		"219066e4f8af84bd5c069018cb29df127ec716f62500acfc9c98ae6270be6d41",
		vim.fn.sha256(table.concat(inventory, "\0")),
		"descriptor labels, order, availability or search metadata drifted"
	)

	local contextual = catalog.build(context.new({ filetype = "lua", mode = "n" }), function() end, "context")
	local contextual_count = 0
	for _, section in ipairs(contextual) do
		contextual_count = contextual_count + #section.items
	end
	assert(contextual_count == 89, "context menu must retain exactly 89 exposures")
	for _, id in ipairs({
		"command.review_publish",
		"command.review_link_tuicr",
		"command.review_start",
		"review.open",
		"agent.context",
		"agent.results",
	}) do
		assert(not actions.supports(id), "retired callback survived: " .. id)
		assert(not action_palette.supports(id), "retired registry entry survived: " .. id)
	end
end)

test("tmux refresh is a namespaced palette-only descriptor", function()
	local dispatch = function() end
	local menu_context = context.new({ filetype = "lua", mode = "n" })
	local palette = catalog.build(menu_context, dispatch, "palette")
	local compact = catalog.build(menu_context, dispatch, "context")
	local section = assert(find_section(palette, "tmux"), "Tmux palette section is missing")
	equal("Tmux", section.label, "Tmux namespace label")
	local item = assert(find_item(palette, "tmux.refresh_dev_session"), "refresh descriptor is missing")
	equal("Refresh Dev Session...", item.label, "refresh label")
	equal({ "tp", "layout dev", "reload tmux", "restart windows", "save session" }, item.keywords, "refresh keywords")
	assert(not find_item(compact, "tmux.refresh_dev_session"), "tmux refresh leaked into the context menu")
end)

test("review presentation and comment actions are palette-only namespaced commands", function()
	local menu_context = context.new({ filetype = "lua", mode = "n" })
	local palette = catalog.build(menu_context, function() end, "palette")
	local compact = catalog.build(menu_context, function() end, "context")
	local item = assert(find_item(palette, "command.review_layout"), "review layout descriptor is missing")
	equal("Toggle Side-by-side / Unified Inline Diff", item.label, "review layout label")
	equal("<leader>rv", item.hint, "review layout mapping hint")
	equal({ "layout", "interleaved", "inline", "unified" }, item.keywords, "review layout search terms")
	assert(not find_item(compact, "command.review_layout"), "review layout leaked into the context menu")
	local context_item = assert(find_item(palette, "command.review_context"), "review context descriptor is missing")
	equal("Toggle Hunks / Full File Context", context_item.label, "review context label")
	equal("<leader>rw", context_item.hint, "review context mapping hint")
	equal({ "context", "hunks", "full", "whole file", "folds" }, context_item.keywords, "review context search terms")
	assert(not find_item(compact, "command.review_context"), "review context leaked into the context menu")
	for id, expected in pairs({
		["command.review_structural_diff"] = { "Open Structural Diff" },
		["command.review_panel"] = { "Toggle Review Panel", "<leader>rr" },
		["command.review_mode"] = { "Toggle Read-only Review Mode", "<leader>rm" },
		["command.review_scope_back"] = { "Return to Parent Review Scope", "<leader>rb" },
		["command.review_code"] = { "Focus Reviewed Code", "<leader>rg" },
		["command.review_comments"] = { "Focus Review Comments", "<leader>rl" },
		["command.review_inline_comments"] = { "Toggle Inline Comment Previews", "<leader>ri" },
		["command.review_file_comment"] = { "Add File-level Review Comment", "<leader>rA" },
		["command.review_general_comment"] = { "Add Review-level Comment", "<leader>rR" },
		["command.review_edit"] = { "Edit Review Comment", "<leader>re" },
		["command.review_change_type"] = { "Change Comment Type at Current Line", "<leader>rc" },
		["command.review_delete"] = { "Delete Comment at Current Line", "<leader>rd" },
		["command.review_reply"] = { "Reply to Review Comment", "<leader>rp" },
		["command.review_toggle_resolve"] = { "Resolve or Reopen Review Comment", "<leader>rt" },
		["command.review_export"] = { "Export Complete Review", "<leader>rE" },
	}) do
		local descriptor = assert(find_item(palette, id), id .. " descriptor is missing")
		equal(expected[1], descriptor.label, id .. " label")
		equal(expected[2], descriptor.hint, id .. " mapping hint")
		assert(not find_item(compact, id), id .. " leaked into the context menu")
	end
	for _, id in ipairs({ "command.review_reanchor" }) do
		assert(find_item(palette, id), id .. " descriptor is missing")
		assert(not find_item(compact, id), id .. " leaked into the context menu")
	end
	for _, id in ipairs({
		"command.review_publish",
		"command.review_link_tuicr",
		"command.review_start",
		"review.open",
		"agent.context",
		"agent.results",
	}) do
		assert(not find_item(palette, id), id .. " survived retirement")
	end
	assert(not find_item(palette, "command.review_threads"), "duplicate ReviewThreads action survived")
end)

test("catalog filters visual, filetype, and CMake descriptors from context", function()
	local dispatch = function() end
	local lua_sections = catalog.build(context.new({ filetype = "lua", mode = "n" }), dispatch)
	assert(not find_item(lua_sections, "search.selection"), "visual action leaked into normal mode")
	assert(not find_section(lua_sections, "cmake"), "CMake section leaked into Lua")
	assert(not find_section(lua_sections, "file.json"), "JSON section leaked into Lua")

	local json_sections = catalog.build(context.new({ filetype = "json", mode = "v" }), dispatch)
	assert(find_item(json_sections, "search.selection"), "visual action was filtered out")
	assert(find_section(json_sections, "file.json"), "JSON section was filtered out")
	assert(not find_section(json_sections, "file.markdown"), "Markdown section leaked into JSON")

	local cpp_sections = catalog.build(context.new({ filetype = "cpp" }), dispatch)
	assert(find_section(cpp_sections, "cmake"), "CMake section missing for C++")
	local ctest = assert(find_item(cpp_sections, "command.cmake_test"), "CTest project action missing for C++")
	assert(ctest.label == "Run Tests (CTest)", "CTest is not the primary project-wide C/C++ action")
	assert(find_item(cpp_sections, "test.nearest"), "focused Neotest-GTest action missing for C++")
	assert(not find_item(cpp_sections, "test.file"), "project-wide Neotest-GTest action displaced CTest")

	local plantuml_context = context.new({ filetype = "plantuml" })
	local plantuml_palette = catalog.build(plantuml_context, dispatch, "palette")
	local plantuml_menu = catalog.build(plantuml_context, dispatch, "context")
	assert(find_section(plantuml_palette, "render"), "PlantUML render section is missing")
	for _, id in ipairs({ "command.diagram_show", "command.diagram_show_svg", "command.diagram_show_ascii" }) do
		assert(find_item(plantuml_palette, id), "PlantUML render action is missing: " .. id)
	end
	assert(find_item(plantuml_menu, "command.diagram_show"), "context menu lost its PlantUML viewer")
	assert(not find_item(plantuml_menu, "command.diagram_show_svg"), "palette-only SVG action leaked into context")

	local markdown_context = context.new({ filetype = "markdown" })
	local markdown_palette = catalog.build(markdown_context, dispatch, "palette")
	local markdown_menu = catalog.build(markdown_context, dispatch, "context")
	for _, id in ipairs({
		"command.diagram_show",
		"command.diagram_show_svg",
		"command.diagram_show_ascii",
		"command.markdown_view",
		"command.markdown_preview",
		"command.markdown_preview_open",
		"command.markdown_preview_stop",
	}) do
		assert(find_item(markdown_palette, id), "Markdown render action is missing: " .. id)
	end
	for _, id in ipairs({ "command.diagram_show", "command.markdown_view", "command.markdown_preview" }) do
		assert(find_item(markdown_menu, id), "context menu lost a Markdown render action: " .. id)
	end
	assert(not find_section(lua_sections, "render"), "render section leaked into Lua")
	assert(not find_section(catalog.build(context.new({ filetype = "yaml" }), dispatch), "file.yaml"))
	assert(not find_section(catalog.build(context.new({ filetype = "xml" }), dispatch), "file.xml"))
end)

test("catalog filters palette-only descriptors by surface", function()
	local sections = {
		{
			id = "shared",
			label = "Shared",
			items = {
				{ id = "shared.item", label = "Shared item" },
				{
					id = "palette.item",
					label = "Palette item",
					surfaces = { palette = true, context = false },
				},
			},
		},
	}
	local registry = action_palette.new({ notify = function() end })
	registry:register_catalog(sections, {
		supports = function()
			return true
		end,
		execute = function() end,
	})

	local palette = registry:sections(context.new(), "palette")
	local menu = registry:sections(context.new(), "context")
	assert(find_item(palette, "shared.item") and find_item(palette, "palette.item"), "palette surface lost items")
	assert(find_item(menu, "shared.item"), "context surface lost a shared item")
	assert(not find_item(menu, "palette.item"), "palette-only item leaked into context menu")
end)

test("expanded curated catalog stays palette-only and context-aware", function()
	local dispatch = function() end
	local normal = context.new({ filetype = "lua", mode = "n", modifiable = true })
	local palette = catalog.build(normal, dispatch, "palette")
	local menu = catalog.build(normal, dispatch, "context")
	local count = 0
	for _, section in ipairs(palette) do
		count = count + #section.items
	end
	assert(count >= 200, "expanded palette has fewer than 200 actions")
	for _, id in ipairs({
		"file.save",
		"edit.undo",
		"transform.upper_word",
		"go.function_next",
		"navigation.back",
		"navigation.forward",
		"navigation.history",
		"window.focus_left",
		"tab.next",
		"diagnostic.float",
		"picker.keymaps",
		"command.tools_install",
	}) do
		assert(find_item(palette, id), "expanded palette action missing: " .. id)
		assert(not find_item(menu, id), "palette-only action leaked into context menu: " .. id)
	end
	assert(not find_item(palette, "transform.upper_selection"), "visual transform leaked into normal mode")
	local visual = catalog.build(context.new({ filetype = "lua", mode = "v" }), dispatch, "palette")
	assert(find_item(visual, "transform.upper_selection"), "visual transform was filtered out")
end)

test("selected mapping actions are palette-only and respect visual selection state", function()
	local dispatch = function() end
	local normal = context.new({ filetype = "lua", mode = "n", modifiable = true })
	local visual = context.new({ filetype = "lua", mode = "v", modifiable = true })
	local readonly_visual = context.new({ filetype = "lua", mode = "v", modifiable = false })
	local palette = catalog.build(normal, dispatch, "palette")
	local menu = catalog.build(normal, dispatch, "context")
	local selected = {
		"lsp.hover",
		"lsp.signature_help",
		"flash.jump",
		"flash.treesitter",
		"window.resize_left",
		"window.resize_down",
		"window.resize_up",
		"window.resize_right",
		"multicursor.flash_cursor",
		"multicursor.flash_word_selection",
		"coverage.load_report",
		"command.log_watch_enable",
		"command.log_watch_disable",
	}
	for _, id in ipairs(selected) do
		assert(find_item(palette, id), "selected palette action missing: " .. id)
		assert(not find_item(menu, id), "selected palette action leaked into context menu: " .. id)
	end

	local visual_palette = catalog.build(visual, dispatch, "palette")
	local visual_menu = catalog.build(visual, dispatch, "context")
	for _, id in ipairs({ "gitsigns.stage_selection", "gitsigns.reset_selection" }) do
		assert(find_item(visual_palette, id), "visual Git action missing: " .. id)
		assert(not find_item(palette, id), "visual Git action leaked into normal mode: " .. id)
		assert(not find_item(visual_menu, id), "visual Git action leaked into context menu: " .. id)
		assert(
			not find_item(catalog.build(readonly_visual, dispatch, "palette"), id),
			"visual Git action leaked into a readonly buffer: " .. id
		)
	end

	for _, id in ipairs({
		"flash.treesitter_search",
		"go.function_end_next",
		"go.function_end_prev",
		"go.swap_argument_next",
		"go.swap_argument_prev",
	}) do
		assert(not find_item(palette, id), "excluded Tree-sitter manipulation action was added: " .. id)
	end
end)

test("shared wrap action keeps wrap and linebreak in sync", function()
	local editor_actions = require("config.editor_actions")
	local original_wrap = vim.wo.wrap
	local original_linebreak = vim.wo.linebreak
	local target = context.capture().target

	local enabled, err = editor_actions.set_wrap(false, target)
	assert(enabled == false and err == nil, "could not disable wrap")
	equal(false, vim.wo.wrap, "wrap remained enabled")
	equal(false, vim.wo.linebreak, "linebreak remained enabled")
	enabled, err = editor_actions.toggle_wrap(target)
	assert(enabled == true and err == nil, "could not toggle wrap")
	equal(true, vim.wo.wrap, "wrap was not enabled")
	equal(true, vim.wo.linebreak, "linebreak was not synchronized")

	vim.wo.wrap = original_wrap
	vim.wo.linebreak = original_linebreak
end)

test("new-file action delegates window normalization to the tabs adapter", function()
	local actions = require("config.menu.actions")
	local tabs = require("config.tabs")
	local original_new_file = tabs.new_file
	local calls = 0
	tabs.new_file = function()
		calls = calls + 1
		return true
	end

	local ok, err = xpcall(function()
		assert(actions.execute("file.new", context.capture().target), "new-file target was rejected")
		equal(1, calls, "menu bypassed the tabs new-file adapter")
	end, debug.traceback)
	tabs.new_file = original_new_file
	assert(ok, err)
end)

test("case transforms target words, lines, and exact visual ranges", function()
	local transforms = require("config.menu.transforms")
	local original = vim.api.nvim_get_current_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "hello World-value", "ab cd", "ef gh", "ábc" })
	local winid = vim.api.nvim_get_current_win()
	local base = { bufnr = buf, winid = winid, tabpage = vim.api.nvim_get_current_tabpage() }

	local ok, err = transforms.apply(
		"upper",
		"word",
		vim.tbl_extend("force", base, {
			cursor = { line = 1, col = 1 },
		})
	)
	assert(ok, err)
	equal("HELLO world", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "word uppercase")

	ok, err = transforms.apply(
		"snake",
		"line",
		vim.tbl_extend("force", base, {
			cursor = { line = 2, col = 0 },
		})
	)
	assert(ok, err)
	equal("hello_world_value", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "line snake case")

	ok, err = transforms.apply(
		"upper",
		"selection",
		vim.tbl_extend("force", base, {
			cursor = { line = 3, col = 0 },
			selection = {
				mode = "\22",
				anchor = { line = 3, col = 0 },
				cursor = { line = 4, col = 1 },
			},
		})
	)
	assert(ok, err)
	equal({ "AB cd", "EF gh" }, vim.api.nvim_buf_get_lines(buf, 2, 4, false), "blockwise uppercase")

	ok, err = transforms.apply(
		"upper",
		"word",
		vim.tbl_extend("force", base, {
			cursor = { line = 5, col = 0 },
		})
	)
	assert(ok, err)
	equal("ÁBC", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1], "multibyte uppercase")

	vim.bo[buf].modifiable = false
	ok, err = transforms.apply(
		"lower",
		"line",
		vim.tbl_extend("force", base, {
			cursor = { line = 1, col = 0 },
		})
	)
	assert(not ok and err:find("not modifiable", 1, true), "readonly transform did not fail closed")
	vim.bo[buf].modifiable = true

	vim.api.nvim_set_current_buf(original)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("user text reaches Ex commands as structured argv without concatenation", function()
	local actions = require("config.menu.actions")
	local original_cmd = vim.api.nvim_cmd
	local original_input = vim.ui.input
	local original_select = vim.ui.select
	local calls = {}
	local inputs = {
		[[failure | call writefile(['owned'], '/tmp/menu-owned')]],
		[[.items[] | select(.name == "a b")]],
	}

	local ok, err = xpcall(function()
		vim.api.nvim_cmd = function(specification, options)
			calls[#calls + 1] = { specification = specification, options = options }
		end
		vim.ui.select = function(_, _, callback)
			callback("purple")
		end
		vim.ui.input = function(_, callback)
			callback(table.remove(inputs, 1))
		end

		actions.execute("log.highlight_regex")
		actions.execute("json.jqx_query")

		equal({
			cmd = "LogHlRegex",
			args = { "purple", [[failure | call writefile(['owned'], '/tmp/menu-owned')]] },
			bang = false,
		}, calls[1].specification, "LogHl command was not structured")
		equal({}, calls[1].options, "LogHl command options")
		equal({
			cmd = "JqxQuery",
			args = { [[.items[] | select(.name == "a b")]] },
			bang = false,
		}, calls[2].specification, "JQX command was not structured")
		equal(2, #calls, "prompt text executed an extra Ex command")
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
	vim.ui.input = original_input
	vim.ui.select = original_select
	assert(ok, err)
end)

test("high-impact palette actions require confirmation", function()
	local original_cmd = vim.api.nvim_cmd
	local original_select = vim.ui.select
	local calls = {}
	local choice = "Cancel"
	local menu_context = context.capture()

	local ok, err = xpcall(function()
		vim.api.nvim_cmd = function(specification, options)
			calls[#calls + 1] = { specification = specification, options = options }
		end
		vim.ui.select = function(items, options, callback)
			equal({ "Cancel", "Continue" }, items, "confirmation choices")
			assert(options.prompt:find("Discard", 1, true), "confirmation prompt is ambiguous")
			callback(choice)
		end

		find_item(action_palette.sections(menu_context, "palette"), "file.revert").run()
		equal(0, #calls, "cancelled destructive action executed")
		choice = "Continue"
		find_item(action_palette.sections(menu_context, "palette"), "file.revert").run()
		equal({ cmd = "edit", args = {}, bang = true }, calls[1].specification, "confirmed revert command")
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
	vim.ui.select = original_select
	assert(ok, err)
end)

test("tmux refresh confirmation is explicit and honors Cancel and Continue", function()
	local original_refresh = package.loaded["config.dev_session_refresh"]
	local original_select = vim.ui.select
	local calls = 0
	local choice = "Cancel"
	local menu_context = context.capture()

	local ok, err = xpcall(function()
		package.loaded["config.dev_session_refresh"] = {
			refresh = function()
				calls = calls + 1
			end,
		}
		vim.ui.select = function(items, options, callback)
			equal({ "Cancel", "Continue" }, items, "refresh confirmation choices")
			equal(
				"Refresh the tmux dev session? This restarts agent/editor/git, Neovim exits, and term keeps running.",
				options.prompt,
				"refresh confirmation prompt"
			)
			callback(choice)
		end

		find_item(action_palette.sections(menu_context, "palette"), "tmux.refresh_dev_session").run()
		equal(0, calls, "cancelled refresh executed")
		choice = "Continue"
		find_item(action_palette.sections(menu_context, "palette"), "tmux.refresh_dev_session").run()
		equal(1, calls, "confirmed refresh did not execute exactly once")
	end, debug.traceback)

	package.loaded["config.dev_session_refresh"] = original_refresh
	vim.ui.select = original_select
	assert(ok, err)
end)

test("host dev-session refresh checks, saves, schedules, then exits without bang", function()
	local refresh = require("config.dev_session_refresh")
	local original_devcontainer = package.loaded["config.devcontainer"]
	local original_auto_session = package.loaded["auto-session"]
	local original_executable = vim.fn.executable
	local original_system = vim.system
	local original_schedule = vim.schedule
	local original_cmd = vim.api.nvim_cmd
	local original_notify = vim.notify
	local original_pane = vim.env.TMUX_PANE
	local calls = {}
	local saved
	local quit

	local ok, err = xpcall(function()
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
			end
		end
		package.loaded["config.devcontainer"] = {
			in_workspace = function()
				return false
			end,
		}
		package.loaded["auto-session"] = {
			save_session = function(name, options)
				saved = { name = name, options = vim.deepcopy(options) }
				return true
			end,
		}
		vim.env.TMUX_PANE = "%42"
		vim.fn.executable = function(path)
			equal(refresh._helper, path, "helper executable check path")
			return 1
		end
		vim.schedule = function(callback)
			callback()
		end
		vim.system = function(argv, options, callback)
			calls[#calls + 1] = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
			callback({ code = 0, stdout = "", stderr = "" })
			return {}
		end
		vim.api.nvim_cmd = function(specification, options)
			quit = { specification = specification, options = options }
		end
		vim.notify = function() end

		assert(refresh.refresh())
		equal({ refresh._helper, "check", "%42" }, calls[1].argv, "preflight argv")
		equal({ text = true }, calls[1].options, "preflight process options")
		equal({
			name = nil,
			options = { show_message = false, is_autosave = true },
		}, saved, "auto-session save call")
		equal({ refresh._helper, "schedule", "%42" }, calls[2].argv, "schedule argv")
		equal({ specification = { cmd = "quitall" }, options = {} }, quit, "safe Neovim exit")
	end, debug.traceback)

	package.loaded["config.devcontainer"] = original_devcontainer
	package.loaded["auto-session"] = original_auto_session
	vim.fn.executable = original_executable
	vim.system = original_system
	vim.schedule = original_schedule
	vim.api.nvim_cmd = original_cmd
	vim.notify = original_notify
	vim.env.TMUX_PANE = original_pane
	assert(ok, err)
end)

test("dev-session refresh aborts for modified buffers and save failures", function()
	local refresh = require("config.dev_session_refresh")
	local original_devcontainer = package.loaded["config.devcontainer"]
	local original_auto_session = package.loaded["auto-session"]
	local original_executable = vim.fn.executable
	local original_system = vim.system
	local original_schedule = vim.schedule
	local original_cmd = vim.api.nvim_cmd
	local original_notify = vim.notify
	local original_pane = vim.env.TMUX_PANE
	local original_buffer = vim.api.nvim_get_current_buf()
	local buffer
	local helper_calls = {}
	local saves = 0
	local quits = 0
	local notifications = {}
	local helper_result = { code = 0, stdout = "", stderr = "" }

	local ok, err = xpcall(function()
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
			end
		end
		package.loaded["config.devcontainer"] = {
			in_workspace = function()
				return false
			end,
		}
		package.loaded["auto-session"] = {
			save_session = function()
				saves = saves + 1
				return false
			end,
		}
		vim.fn.executable = function()
			return 1
		end
		vim.schedule = function(callback)
			callback()
		end
		vim.system = function(argv, _, callback)
			helper_calls[#helper_calls + 1] = vim.deepcopy(argv)
			callback(helper_result)
			return {}
		end
		vim.api.nvim_cmd = function()
			quits = quits + 1
		end
		vim.notify = function(message)
			notifications[#notifications + 1] = message
		end
		vim.env.TMUX_PANE = "editor;quit"
		assert(not refresh.refresh())
		equal(0, #helper_calls, "invalid TMUX_PANE reached the helper")
		assert(notifications[#notifications]:find("valid TMUX_PANE", 1, true), "invalid pane error was hidden")
		vim.env.TMUX_PANE = "%9"

		buffer = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(buffer)
		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved" })
		vim.api.nvim_set_current_buf(original_buffer)
		assert(vim.api.nvim_get_option_value("modified", { buf = buffer }))
		assert(refresh.refresh())
		equal(1, #helper_calls, "modified buffer ran schedule helper")
		equal(0, saves, "modified buffer was saved")
		equal(0, quits, "modified buffer exited Neovim")
		assert(notifications[#notifications]:find("modified buffer", 1, true), "modified buffer error was hidden")

		vim.api.nvim_set_option_value("modified", false, { buf = buffer })
		helper_calls = {}
		assert(refresh.refresh())
		equal(1, saves, "save failure was not observed")
		equal(1, #helper_calls, "save failure ran schedule helper")
		equal(0, quits, "save failure exited Neovim")
		assert(notifications[#notifications]:find("declined", 1, true), "save failure was hidden")

		package.loaded["auto-session"].save_session = function()
			saves = saves + 1
			error("disk full")
		end
		helper_calls = {}
		assert(refresh.refresh())
		equal(2, saves, "save exception was not observed")
		equal(1, #helper_calls, "save exception ran schedule helper")
		equal(0, quits, "save exception exited Neovim")
		assert(notifications[#notifications]:find("disk full", 1, true), "save exception was hidden")

		helper_result = { code = 3, stdout = "", stderr = "not a dev layout" }
		helper_calls = {}
		assert(refresh.refresh())
		equal(1, #helper_calls, "failed preflight invoked another helper action")
		equal(2, saves, "failed preflight saved the session")
		equal(0, quits, "failed preflight exited Neovim")
		assert(notifications[#notifications]:find("not a dev layout", 1, true), "helper failure was hidden")
	end, debug.traceback)

	if buffer and vim.api.nvim_buf_is_valid(buffer) then
		vim.api.nvim_buf_delete(buffer, { force = true })
	end
	package.loaded["config.devcontainer"] = original_devcontainer
	package.loaded["auto-session"] = original_auto_session
	vim.fn.executable = original_executable
	vim.system = original_system
	vim.schedule = original_schedule
	vim.api.nvim_cmd = original_cmd
	vim.notify = original_notify
	vim.env.TMUX_PANE = original_pane
	assert(ok, err)
end)

test("Dev Container dev-session refresh waits for both authenticated acknowledgements", function()
	local refresh = require("config.dev_session_refresh")
	local original_devcontainer = package.loaded["config.devcontainer"]
	local original_auto_session = package.loaded["auto-session"]
	local original_cmd = vim.api.nvim_cmd
	local original_pane = vim.env.TMUX_PANE
	local requests = {}
	local callbacks = {}
	local saves = 0
	local quits = 0

	local ok, err = xpcall(function()
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
			end
		end
		package.loaded["config.devcontainer"] = {
			in_workspace = function()
				return true
			end,
			request_host = function(action, callback)
				requests[#requests + 1] = action
				callbacks[action] = callback
				return true
			end,
		}
		package.loaded["auto-session"] = {
			save_session = function(_, options)
				saves = saves + 1
				equal({ show_message = false, is_autosave = true }, options, "Dev Container session save options")
				return true
			end,
		}
		-- Existing Dev Container editors do not necessarily receive
		-- TMUX_PANE. The authenticated host controller owns the exact pane.
		vim.env.TMUX_PANE = nil
		vim.api.nvim_cmd = function(specification)
			equal({ cmd = "quitall" }, specification, "Dev Container exit command")
			quits = quits + 1
		end

		assert(refresh.refresh())
		equal({ "tmux_dev_refresh_check" }, requests, "Dev Container preflight request")
		equal(0, saves, "Dev Container saved before preflight acknowledgement")
		callbacks.tmux_dev_refresh_check({ ok = true })
		equal(1, saves, "Dev Container did not save after preflight acknowledgement")
		equal({ "tmux_dev_refresh_check", "tmux_dev_refresh" }, requests, "Dev Container schedule request")
		equal(0, quits, "Dev Container exited before schedule acknowledgement")
		callbacks.tmux_dev_refresh({ ok = true })
		equal(1, quits, "Dev Container did not exit after schedule acknowledgement")
	end, debug.traceback)

	package.loaded["config.devcontainer"] = original_devcontainer
	package.loaded["auto-session"] = original_auto_session
	vim.api.nvim_cmd = original_cmd
	vim.env.TMUX_PANE = original_pane
	assert(ok, err)
end)

test("command wrappers preserve structured plugin arguments", function()
	local actions = require("config.menu.actions")
	local original_cmd = vim.api.nvim_cmd
	local calls = {}
	local target = context.capture().target

	local ok, err = xpcall(function()
		vim.api.nvim_cmd = function(specification, options)
			calls[#calls + 1] = { specification = specification, options = options }
		end
		actions.execute("command.trouble_buffer", target)
		equal({
			cmd = "Trouble",
			args = { "diagnostics", "toggle", "filter.buf=0" },
			bang = false,
		}, calls[1].specification, "Trouble wrapper arguments")
		equal({}, calls[1].options, "Trouble wrapper options")
		actions.execute("command.diagram_show_svg", target)
		equal({ cmd = "DiagramShow", args = { "svg" }, bang = false }, calls[2].specification, "SVG wrapper")
		actions.execute("command.markdown_view", target)
		equal(
			{ cmd = "MarkdownView", args = {}, bang = false },
			calls[3].specification,
			"Markdown reading view wrapper"
		)
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
	assert(ok, err)
end)

test("command wrapper errors remove only Vim transport stacks", function()
	local actions = require("config.menu.actions")
	local original_notify = vim.notify
	local original_formatting = package.loaded["config.formatting"]
	local notifications = {}
	local command_name = "DevContainerStatus"
	assert(vim.fn.exists(":" .. command_name) == 0, "test command already exists")

	local ok, err = xpcall(function()
		vim.notify = function(message, level)
			notifications[#notifications + 1] = { message = message, level = level }
		end
		vim.api.nvim_create_user_command(command_name, function()
			vim.api.nvim_err_writeln("concise lifecycle failure")
		end, {})
		assert(actions.execute("command.devcontainer_status", context.capture().target) == false)
		equal(1, #notifications, "Vim wrapper error notification count")
		equal("concise lifecycle failure", notifications[1].message, "Vim wrapper error was not sanitized")
		equal(vim.log.levels.WARN, notifications[1].level, "Vim wrapper error level")
		assert(not notifications[1].message:find("stack traceback", 1, true), "Vim wrapper stack leaked")

		vim.api.nvim_del_user_command(command_name)
		notifications = {}
		vim.api.nvim_create_user_command(command_name, function()
			error("real Lua command failure")
		end, {})
		assert(actions.execute("command.devcontainer_status", context.capture().target) == false)
		equal(1, #notifications, "Lua command error notification count")
		assert(notifications[1].message:find("real Lua command failure", 1, true), "Lua failure detail was lost")
		assert(notifications[1].message:find("stack traceback", 1, true), "real Lua stack was sanitized")

		notifications = {}
		package.loaded["config.formatting"] = {
			format = function()
				error("Vim: embedded detail")
			end,
		}
		assert(actions.execute("format.buffer", context.capture().target) == false)
		equal(1, #notifications, "embedded Vim text notification count")
		assert(
			notifications[1].message:find("Vim: embedded detail", 1, true),
			"embedded Vim text truncated a genuine Lua failure"
		)
		assert(notifications[1].message:find("stack traceback", 1, true), "embedded Vim text lost its Lua stack")
	end, debug.traceback)

	pcall(vim.api.nvim_del_user_command, command_name)
	package.loaded["config.formatting"] = original_formatting
	vim.notify = original_notify
	assert(ok, err)
end)

test("selected LSP, Flash, window, and multicursor actions dispatch exact APIs", function()
	local actions = require("config.menu.actions")
	local original_get_clients = vim.lsp.get_clients
	local original_hover = vim.lsp.buf.hover
	local original_signature_help = vim.lsp.buf.signature_help
	local original_flash = package.loaded.flash
	local original_splits = package.loaded["smart-splits"]
	local original_multicursor = package.loaded["config.multicursor"]
	local original_notify = vim.notify
	local calls = {}
	local warnings = {}
	local target = context.capture().target

	local ok, err = xpcall(function()
		vim.lsp.get_clients = function(options)
			calls[#calls + 1] = { "clients", options.bufnr, options.method }
			return { {} }
		end
		vim.lsp.buf.hover = function(options)
			calls[#calls + 1] = { "hover", options }
		end
		vim.lsp.buf.signature_help = function()
			calls[#calls + 1] = { "signature_help" }
		end
		package.loaded.flash = {
			jump = function()
				calls[#calls + 1] = { "flash.jump" }
			end,
			treesitter = function()
				calls[#calls + 1] = { "flash.treesitter" }
			end,
		}
		package.loaded["smart-splits"] = {}
		for _, name in ipairs({ "resize_left", "resize_down", "resize_up", "resize_right" }) do
			package.loaded["smart-splits"][name] = function()
				calls[#calls + 1] = { "smart-splits." .. name }
			end
		end
		package.loaded["config.multicursor"] = {
			flash_cursor = function()
				calls[#calls + 1] = { "multicursor.flash_cursor" }
			end,
			flash_word_selection = function()
				calls[#calls + 1] = { "multicursor.flash_word_selection" }
			end,
		}
		vim.notify = function(message)
			warnings[#warnings + 1] = message
		end

		actions.execute("lsp.hover", target)
		actions.execute("lsp.signature_help", target)
		actions.execute("flash.jump", target)
		actions.execute("flash.treesitter", target)
		for _, name in ipairs({ "resize_left", "resize_down", "resize_up", "resize_right" }) do
			actions.execute("window." .. name, target)
		end
		actions.execute("multicursor.flash_cursor", target)
		actions.execute("multicursor.flash_word_selection", target)

		equal({ "clients", 0, "textDocument/hover" }, calls[1], "hover client method")
		equal({ "hover", { border = "rounded" } }, calls[2], "hover API and border")
		equal({ "clients", 0, "textDocument/signatureHelp" }, calls[3], "signature client method")
		equal({ "signature_help" }, calls[4], "signature API")
		equal({ "flash.jump" }, calls[5], "Flash jump API")
		equal({ "flash.treesitter" }, calls[6], "Flash Treesitter API")
		equal({ "smart-splits.resize_left" }, calls[7], "resize left API")
		equal({ "smart-splits.resize_down" }, calls[8], "resize down API")
		equal({ "smart-splits.resize_up" }, calls[9], "resize up API")
		equal({ "smart-splits.resize_right" }, calls[10], "resize right API")
		equal({ "multicursor.flash_cursor" }, calls[11], "multicursor cursor helper")
		equal({ "multicursor.flash_word_selection" }, calls[12], "multicursor selection helper")

		package.loaded["smart-splits"].resize_left = nil
		actions.execute("window.resize_left", target)
		assert(
			warnings[#warnings]:find("smart-splits action not available", 1, true),
			"missing smart-splits method did not notify"
		)
	end, debug.traceback)

	vim.lsp.get_clients = original_get_clients
	vim.lsp.buf.hover = original_hover
	vim.lsp.buf.signature_help = original_signature_help
	package.loaded.flash = original_flash
	package.loaded["smart-splits"] = original_splits
	package.loaded["config.multicursor"] = original_multicursor
	vim.notify = original_notify
	assert(ok, err)
end)

test("Git selection actions use the captured normalized range and confirm reset", function()
	local actions = require("config.menu.actions")
	local original_buf = vim.api.nvim_get_current_buf()
	local original_gitsigns = package.loaded.gitsigns
	local original_select = vim.ui.select
	local origin = vim.api.nvim_create_buf(false, true)
	local calls = {}
	local choice = "Cancel"

	local ok, err = xpcall(function()
		vim.api.nvim_set_current_buf(origin)
		vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "one", "two", "three", "four" })
		local menu_context = context.capture()
		menu_context.mode = "v"
		menu_context.visual = true
		menu_context.selection = {
			mode = "v",
			anchor = { line = 4, col = 2 },
			cursor = { line = 2, col = 0 },
		}
		local target = vim.deepcopy(menu_context.target)
		target.selection = vim.deepcopy(menu_context.selection)
		vim.cmd("new")
		local picker_buf = vim.api.nvim_get_current_buf()
		package.loaded.gitsigns = {
			stage_hunk = function(range)
				calls[#calls + 1] = { action = "stage", range = range, bufnr = vim.api.nvim_get_current_buf() }
			end,
			reset_hunk = function(range)
				calls[#calls + 1] = { action = "reset", range = range, bufnr = vim.api.nvim_get_current_buf() }
			end,
		}
		vim.ui.select = function(items, options, callback)
			equal({ "Cancel", "Continue" }, items, "Git reset confirmation choices")
			assert(options.prompt:find("selected lines", 1, true), "Git reset prompt does not name the selection")
			callback(choice)
		end

		actions.execute("gitsigns.stage_selection", target)
		equal({ action = "stage", range = { 2, 4 }, bufnr = origin }, calls[1], "captured Git stage range")
		local reset = assert(find_item(action_palette.sections(menu_context, "palette"), "gitsigns.reset_selection"))
		reset.run()
		equal(1, #calls, "cancelled Git reset executed")
		choice = "Continue"
		reset = assert(find_item(action_palette.sections(menu_context, "palette"), "gitsigns.reset_selection"))
		reset.run()
		equal({ action = "reset", range = { 2, 4 }, bufnr = origin }, calls[2], "confirmed Git reset range")

		vim.cmd("close")
		vim.api.nvim_buf_delete(picker_buf, { force = true })
	end, debug.traceback)

	package.loaded.gitsigns = original_gitsigns
	vim.ui.select = original_select
	if vim.api.nvim_buf_is_valid(origin) then
		vim.api.nvim_set_current_buf(original_buf)
		vim.api.nvim_buf_delete(origin, { force = true })
	end
	assert(ok, err)
end)

test("coverage and log actions preserve structured arguments", function()
	local actions = require("config.menu.actions")
	local original_cmd = vim.api.nvim_cmd
	local original_input = vim.ui.input
	local calls = {}
	local input_options
	local path = [[reports/run a;$(echo nope)|coverage.info]]
	local target = context.capture().target

	local ok, err = xpcall(function()
		vim.api.nvim_cmd = function(specification, options)
			calls[#calls + 1] = { specification = specification, options = options }
		end
		vim.ui.input = function(options, callback)
			input_options = options
			callback(path)
		end

		actions.execute("coverage.load_report", target)
		actions.execute("command.log_watch_enable", target)
		actions.execute("command.log_watch_disable", target)
		equal({ prompt = "Coverage report: ", completion = "file" }, input_options, "coverage file prompt")
		equal(
			{ cmd = "CoverageLoad", args = { path }, bang = false },
			calls[1].specification,
			"coverage path was not structured"
		)
		equal(
			{ cmd = "LogWatchCurrentFile", args = { "on" }, bang = false },
			calls[2].specification,
			"log start arguments"
		)
		equal(
			{ cmd = "LogWatchCurrentFile", args = { "off" }, bang = false },
			calls[3].specification,
			"log stop arguments"
		)
		equal(3, #calls, "structured inputs executed an extra command")
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
	vim.ui.input = original_input
	assert(ok, err)
end)

test("shared multicursor Flash helper preserves cursor and word-selection semantics", function()
	local original_helper = package.loaded["config.multicursor"]
	local original_flash = package.loaded.flash
	local original_multicursor = package.loaded["multicursor-nvim"]
	local jumps = {}
	local cursor_position
	local visual_range
	local main_selected = 0
	local restored = 0

	local ok, err = xpcall(function()
		package.loaded.flash = {
			jump = function(options)
				jumps[#jumps + 1] = options
			end,
		}
		package.loaded["multicursor-nvim"] = {
			action = function(callback)
				callback({
					mainCursor = function()
						return {
							select = function()
								main_selected = main_selected + 1
							end,
						}
					end,
					addCursor = function()
						return {
							setPos = function(_, position)
								cursor_position = position
							end,
							setVisual = function(_, first, last)
								visual_range = { first, last }
							end,
						}
					end,
				})
			end,
		}
		package.loaded["config.multicursor"] = nil
		local helper = require("config.multicursor")

		helper.flash_cursor()
		equal({ multi_window = false }, jumps[1].search, "cursor Flash search scope")
		assert(jumps[1].pattern == nil and jumps[1].jump == nil, "cursor Flash gained word-selection options")
		jumps[1].action({ pos = { 3, 4 } }, {
			restore = function()
				restored = restored + 1
			end,
		})
		equal({ 3, 5 }, cursor_position, "Flash cursor column conversion")
		assert(visual_range == nil, "Flash cursor created a visual selection")

		helper.flash_word_selection()
		equal([[\<\k\+\>]], jumps[2].pattern, "word-selection pattern")
		equal({ mode = "search", multi_window = false }, jumps[2].search, "word-selection search")
		equal({ pos = "range" }, jumps[2].jump, "word-selection jump range")
		jumps[2].action({ pos = { 6, 1 }, end_pos = { 6, 5 } }, {
			restore = function()
				restored = restored + 1
			end,
		})
		equal({ 6, 2 }, cursor_position, "word-selection start conversion")
		equal({ { 6, 2 }, { 6, 6 } }, visual_range, "word-selection visual range")
		equal(2, main_selected, "main cursor selection count")
		equal(2, restored, "Flash state restore count")
	end, debug.traceback)

	package.loaded["config.multicursor"] = original_helper
	package.loaded.flash = original_flash
	package.loaded["multicursor-nvim"] = original_multicursor
	assert(ok, err)
end)

test("selection actions restore the captured range in the origin buffer", function()
	local actions = require("config.menu.actions")
	local original_buf = vim.api.nvim_get_current_buf()
	local original_python = package.loaded["config.python"]
	local original_grug = package.loaded["grug-far"]
	local original_cmd = vim.api.nvim_cmd
	local buf = vim.api.nvim_create_buf(false, true)
	local commands = {}
	local sent_selection = false
	local searched_selection = false

	local ok, err = xpcall(function()
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
		local target = context.capture().target
		target.selection = {
			mode = "v",
			anchor = { line = 3, col = 2 },
			cursor = { line = 1, col = 1 },
		}
		package.loaded["config.python"] = {
			send = function(selection)
				sent_selection = selection
			end,
		}
		package.loaded["grug-far"] = {
			with_visual_selection = function()
				searched_selection = true
				equal({ 1, 1 }, vim.api.nvim_buf_get_mark(buf, "<"), "search selection start mark")
				equal({ 3, 2 }, vim.api.nvim_buf_get_mark(buf, ">"), "search selection end mark")
			end,
		}
		vim.api.nvim_cmd = function(specification)
			commands[#commands + 1] = specification
		end

		actions.execute("python.send_selection", target)
		assert(sent_selection == true, "Python action did not send a selection")
		equal({ 1, 1 }, vim.api.nvim_buf_get_mark(buf, "<"), "selection start mark")
		equal({ 3, 2 }, vim.api.nvim_buf_get_mark(buf, ">"), "selection end mark")
		vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
		vim.api.nvim_buf_set_mark(buf, ">", 2, 1, {})
		actions.execute("search.selection", target)
		assert(searched_selection, "search action did not use the visual selection")

		assert(not actions.supports("agent.context"), "retired agent context action remains registered")
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
	package.loaded["config.python"] = original_python
	package.loaded["grug-far"] = original_grug
	vim.api.nvim_set_current_buf(original_buf)
	vim.api.nvim_buf_delete(buf, { force = true })
	assert(ok, err)
end)

test("backend adapter contains private menu.nvim state behind one seam", function()
	local backend = require("config.menu.backend")
	local state = { bufids = {}, bufs = {}, config = { stale = true }, nested_menu = "stale" }
	local closed = 0
	local opened
	local menu_available = false
	local lazy_loads = 0
	local modules = {
		lazy = {
			load = function(options)
				lazy_loads = lazy_loads + 1
				equal({ plugins = { "menu" } }, options, "lazy load request")
				menu_available = true
			end,
		},
		["menu.state"] = state,
		["menu.utils"] = {
			delete_old_menus = function()
				closed = closed + 1
			end,
		},
	}
	local menu = {
		open = function(items, options)
			opened = { items = items, options = options }
		end,
	}
	local adapter = backend.new({
		require = function(module)
			if module == "menu" then
				if menu_available then
					return menu
				end
				error("menu unavailable")
			end
			if modules[module] then
				return modules[module]
			end
			error("unexpected module: " .. module)
		end,
		loaded = function(module)
			return modules[module]
		end,
		notify = function() end,
	})

	assert(not adapter:is_open(), "empty backend state is open")
	local run = function() end
	assert(
		adapter:show({
			{
				id = "section",
				label = "Section",
				items = { { id = "item", label = "Item", run = run, hint = "key" } },
			},
		}, { border = true }),
		"adapter did not open"
	)
	equal(1, lazy_loads, "menu plugin was not loaded exactly once")
	assert(state.config == nil, "cached private menu config was not reset")
	equal("Section", opened.items[1].name, "section rendering")
	equal("Item", opened.items[1].items[1].name, "item rendering")
	equal(run, opened.items[1].items[1].cmd, "callback rendering")
	equal("key", opened.items[1].items[1].rtxt, "hint rendering")
	equal({ border = true }, opened.options, "menu options")

	local menu_buf = vim.api.nvim_create_buf(false, true)
	local menu_win = vim.api.nvim_open_win(menu_buf, false, {
		relative = "editor",
		width = 1,
		height = 1,
		row = 0,
		col = 0,
		style = "minimal",
	})
	state.bufids = { menu_buf }
	state.bufs[menu_buf] = { stale = true }
	assert(adapter:is_open(), "populated backend state is closed")
	assert(adapter:close(), "backend did not close")
	equal(1, closed, "private close seam was not invoked")

	vim.api.nvim_win_close(menu_win, true)
	assert(not adapter:is_open(), "hidden stale menu buffer was treated as displayed")
	assert(adapter:show({}, { border = true }), "adapter did not recover from stale menu state")
	assert(not vim.api.nvim_buf_is_valid(menu_buf), "stale hidden menu buffer was leaked")
	equal({}, state.bufids, "stale buffer ids were retained")
	equal({}, state.bufs, "stale buffer metadata was retained")
	equal("", state.nested_menu, "stale nested-menu state was retained")

	for _, path in ipairs({
		repo .. "/lua/config/menu.lua",
		repo .. "/lua/config/menu/actions.lua",
		repo .. "/lua/config/menu/catalog.lua",
		repo .. "/lua/config/menu/context.lua",
	}) do
		local source = table.concat(vim.fn.readfile(path), "\n")
		assert(not source:find('"menu.state"', 1, true), "private state escaped backend: " .. path)
		assert(not source:find('"menu.utils"', 1, true), "private utils escaped backend: " .. path)
	end
end)

test("backend close recovers hidden mouse menus without deleting unrelated mappings", function()
	local backend = require("config.menu.backend")
	local state = { bufids = {}, bufs = {}, config = nil, nested_menu = "" }
	local unsafe_closes = 0
	local plugin_callback
	local menu = {
		open = function(_, options)
			state.config = options
			plugin_callback = function() end
			vim.keymap.set("n", "<LeftMouse>", plugin_callback)
		end,
	}
	local modules = {
		menu = menu,
		["menu.state"] = state,
		["menu.utils"] = {
			delete_old_menus = function()
				unsafe_closes = unsafe_closes + 1
			end,
		},
	}
	local adapter = backend.new({
		require = function(module)
			if modules[module] then
				return modules[module]
			end
			error("unexpected module: " .. module)
		end,
		loaded = function(module)
			return modules[module]
		end,
		notify = function() end,
	})

	assert(adapter:show({}, { mouse = true }), "mouse menu fixture did not open")
	equal(plugin_callback, vim.fn.maparg("<LeftMouse>", "n", false, true).callback, "mouse mapping ownership")
	local stale_buf = vim.api.nvim_create_buf(false, true)
	local displayed_buf = vim.api.nvim_create_buf(false, true)
	local displayed_win = vim.api.nvim_open_win(displayed_buf, false, {
		relative = "editor",
		width = 1,
		height = 1,
		row = 0,
		col = 0,
		style = "minimal",
	})
	state.bufids = { displayed_buf }
	state.bufs[displayed_buf] = { stale = true }
	assert(not adapter:recover_stale(), "recovery closed a fully displayed mouse menu")
	assert(vim.api.nvim_buf_is_valid(displayed_buf), "displayed menu buffer was deleted")
	equal(plugin_callback, vim.fn.maparg("<LeftMouse>", "n", false, true).callback, "displayed mouse mapping")

	state.bufids = { stale_buf, displayed_buf }
	state.bufs[stale_buf] = { stale = true }
	state.nested_menu = "stale"

	assert(adapter:recover_stale(), "hidden mouse menu did not recover")
	equal(0, unsafe_closes, "hidden menu invoked menu.nvim's unsafe close helper")
	assert(not vim.api.nvim_buf_is_valid(stale_buf), "hidden stale menu buffer remains valid")
	assert(not vim.api.nvim_buf_is_valid(displayed_buf), "mixed stale menu buffer remains valid")
	assert(not vim.api.nvim_win_is_valid(displayed_win), "mixed stale menu window remains valid")
	equal({}, state.bufids, "hidden close retained buffer ids")
	equal({}, state.bufs, "hidden close retained buffer metadata")
	assert(state.config == nil, "hidden close retained menu config")
	equal("", state.nested_menu, "hidden close retained nested-menu state")
	assert(vim.fn.maparg("<LeftMouse>", "n", false, true).lhs == nil, "owned mouse mapping was not removed")
	assert(adapter:close(), "repeated hidden close was not idempotent")
	equal(0, unsafe_closes, "idempotent close invoked the unsafe helper")

	assert(adapter:show({}, { mouse = true }), "second mouse menu fixture did not open")
	local unrelated_callback = function() end
	vim.keymap.set("n", "<LeftMouse>", unrelated_callback)
	local second_stale_buf = vim.api.nvim_create_buf(false, true)
	state.bufids = { second_stale_buf }
	state.bufs[second_stale_buf] = { stale = true }
	assert(adapter:close(), "second hidden menu did not close")
	equal(
		unrelated_callback,
		vim.fn.maparg("<LeftMouse>", "n", false, true).callback,
		"hidden recovery deleted an unrelated replacement mapping"
	)
	vim.keymap.del("n", "<LeftMouse>")
end)

test("stale recovery and dismiss do not load menu.nvim", function()
	local requires = 0
	local adapter = require("config.menu.backend").new({
		require = function()
			requires = requires + 1
			error("menu.nvim must not load")
		end,
		loaded = function()
			return nil
		end,
		notify = function() end,
	})

	assert(not adapter:recover_stale(), "absent menu state was reported as recovered")
	assert(not adapter:close(), "absent menu state was reported as closed")
	equal(0, requires, "stale recovery or dismiss attempted to require menu.nvim")
end)

test("ensure_open is idempotent while open remains a toggle", function()
	local backend_module = require("config.menu.backend")
	local original_default = backend_module.default
	local original_menu = package.loaded["config.menu"]
	local original_pager = package.loaded["config.pager"]
	local open = false
	local shows = 0
	local closes = 0
	local adapter = {
		is_open = function()
			return open
		end,
		show = function()
			shows = shows + 1
			open = true
			return true
		end,
		close = function()
			if open then
				closes = closes + 1
			end
			open = false
			return true
		end,
	}

	local ok, err = xpcall(function()
		backend_module.default = function()
			return adapter
		end
		package.loaded["config.menu"] = nil
		package.loaded["config.pager"] = { active = false }
		local menu = require("config.menu")

		menu.ensure_open()
		menu.ensure_open()
		equal(1, shows, "ensure_open toggled or reopened an existing menu")
		equal(0, closes, "ensure_open closed an existing menu")
		menu.open()
		equal(1, closes, "open stopped behaving as a toggle")
		menu.dismiss()
		menu.dismiss()
		equal(1, closes, "dismiss was not idempotent")
	end, debug.traceback)

	backend_module.default = original_default
	package.loaded["config.menu"] = original_menu
	package.loaded["config.pager"] = original_pager
	assert(ok, err)
end)

test("Snacks palette flattens the shared catalog and confirms once", function()
	local original_menu = package.loaded["config.menu"]
	local original_palette = package.loaded["config.action_palette"]
	local original_snacks = package.loaded.snacks
	local original_pager = package.loaded["config.pager"]
	local captured
	local dispatched = {}
	local origin = vim.api.nvim_get_current_buf()
	local original_filetype = vim.bo.filetype
	local recent = require("config.menu.recent")

	local ok, err = xpcall(function()
		local registry = action_palette.new({ notify = function() end })
		registry:register_catalog(catalog.definitions(), {
			supports = function()
				return true
			end,
			execute = function(id, invocation)
				dispatched[#dispatched + 1] = { id = id, target = invocation.target }
			end,
		})
		package.loaded["config.action_palette"] = {
			capture_target = action_palette.capture_target,
			sections = function(menu_context, surface)
				return registry:sections(menu_context, surface)
			end,
		}
		package.loaded.snacks = {
			picker = {
				pick = function(opts)
					captured = opts
				end,
			},
		}
		package.loaded["config.pager"] = { active = false }
		package.loaded["config.menu"] = nil
		vim.bo.filetype = "markdown"
		recent.teardown()
		recent.configure(5)
		recent.observe({ kind = "executed", id = "session.search", surface = "palette" })

		local menu = require("config.menu")
		menu.open_palette()
		assert(captured, "palette did not open")
		equal("menu_actions", captured.source, "palette source")
		equal(false, captured.matcher.sort_empty, "empty-query order was left to fuzzy sorting")
		assert(type(captured.format) == "function", "palette format is not custom")
		local session_item
		for _, item in ipairs(captured.items) do
			if item.id == "session.search" then
				session_item = item
				break
			end
		end
		assert(session_item, "session search is absent from the shared palette")
		equal("session.search", captured.items[1].id, "visible recent action was not pinned first")
		assert(session_item.recent, "recent action lacks its visual marker")
		equal("Sessions: Search and Restore", session_item.display, "palette item is not namespaced")
		equal("Sessions: Search and Restore <leader>Sp", session_item.text, "recent marker changed fuzzy-search text")
		local expected_labels = {
			["command.diagram_show_svg"] = "Render: Diagram as SVG",
			["command.markdown_preview_open"] = "Render: Open Markdown Browser Preview",
			["command.markdown_view"] = "Render: Toggle Markdown Reading View",
			["search.open"] = "Search / Replace: Open",
			["view.toggle_wrap"] = "View: Toggle Wrap",
		}
		for _, item in ipairs(captured.items) do
			if expected_labels[item.id] then
				equal(expected_labels[item.id], item.display, "palette label repeats its namespace")
				expected_labels[item.id] = nil
			end
		end
		assert(next(expected_labels) == nil, "palette label fixtures are missing")
		equal(
			{ { "󰋚 " .. session_item.display }, { "  <leader>Sp", "Comment" } },
			captured.format(session_item),
			"palette format"
		)

		local closes = 0
		local picker = {
			close = function()
				closes = closes + 1
			end,
		}
		vim.cmd("new")
		local picker_win = vim.api.nvim_get_current_win()
		local picker_buf = vim.api.nvim_get_current_buf()
		captured.confirm(picker, session_item)
		captured.confirm(picker, session_item)
		vim.wait(500, function()
			return #dispatched == 1
		end, 5)
		equal("session.search", dispatched[1].id, "palette dispatched the wrong action")
		equal(origin, dispatched[1].target.bufnr, "palette lost the origin buffer")
		equal(1, closes, "palette closed more than once")
		vim.api.nvim_win_close(picker_win, true)
		if vim.api.nvim_buf_is_valid(picker_buf) then
			vim.api.nvim_buf_delete(picker_buf, { force = true })
		end
	end, debug.traceback)

	package.loaded["config.menu"] = original_menu
	package.loaded["config.action_palette"] = original_palette
	package.loaded.snacks = original_snacks
	package.loaded["config.pager"] = original_pager
	vim.bo.filetype = original_filetype
	recent.teardown()
	assert(ok, err)
end)

test("menu plugin is limited to the full terminal editor", function()
	local original_vscode = vim.g.vscode
	local original_pager = package.loaded["config.pager"]
	local original_keymap_set = vim.keymap.set
	local specs = require("plugins.menu")
	local mapping

	local ok, err = xpcall(function()
		package.loaded["config.pager"] = { active = false }
		vim.g.vscode = true
		assert(not specs[1].cond() and not specs[2].cond(), "menu enabled in VS Code")

		vim.g.vscode = false
		package.loaded["config.pager"] = { active = true }
		assert(not specs[1].cond() and not specs[2].cond(), "menu enabled in nvimpager")

		package.loaded["config.pager"] = { active = false }
		assert(specs[1].cond() and specs[2].cond(), "menu disabled in full terminal Neovim")
		assert(specs[2].init == nil, "menu Lazy spec eagerly initializes the host palette")

		vim.keymap.set = function(modes, lhs, rhs, options)
			mapping = { modes = modes, lhs = lhs, rhs = rhs, options = options }
		end
		require("config.menu").setup()
		equal({ "n", "v" }, mapping.modes, "RightMouse mapping modes")
		equal("<RightMouse>", mapping.lhs, "RightMouse mapping key")
		equal(require("config.menu").open_context, mapping.rhs, "RightMouse mapping callback")
		equal("Open menu", mapping.options.desc, "RightMouse mapping description")
	end, debug.traceback)

	vim.g.vscode = original_vscode
	package.loaded["config.pager"] = original_pager
	vim.keymap.set = original_keymap_set
	assert(ok, err)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("menu_spec: %d tests passed", count))
vim.cmd("quitall!")
