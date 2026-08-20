vim.o.shadafile = "NONE"
vim.o.swapfile = false

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
	equal(vim.bo.buftype, captured.buftype, "captured buffer type")
	equal(vim.bo.modifiable, captured.modifiable, "captured modifiable state")
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
	assert(not find_item(sections, "Git Branches"), "legacy Git Branches descriptor remains")
	local definition = assert(find_item(sections, "lsp.definition"), "definition descriptor missing")
	equal("gd", definition.hint, "definition hint")
	definition.run()
	equal("lsp.definition", dispatched, "descriptor dispatched the wrong action")
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
	for _, section in ipairs(catalog.definitions(function() end)) do
		for _, item in ipairs(section.items) do
			assert(actions.supports(item.id), "definition has no action: " .. item.id)
		end
	end
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

	local plantuml_sections = catalog.build(context.new({ filetype = "plantuml" }), dispatch)
	assert(find_item(plantuml_sections, "command.diagram_show"), "unified PlantUML viewer is missing")
	local markdown_sections = catalog.build(context.new({ filetype = "markdown" }), dispatch)
	assert(find_item(markdown_sections, "command.diagram_show"), "unified Markdown diagram viewer is missing")
	assert(not find_section(catalog.build(context.new({ filetype = "yaml" }), dispatch), "file.yaml"))
	assert(not find_section(catalog.build(context.new({ filetype = "xml" }), dispatch), "file.xml"))
end)

test("catalog filters palette-only descriptors by surface", function()
	local run = function() end
	local sections = {
		{
			id = "shared",
			label = "Shared",
			items = {
				{ id = "shared.item", label = "Shared item", run = run },
				{
					id = "palette.item",
					label = "Palette item",
					run = run,
					surfaces = { palette = true, context = false },
				},
			},
		},
	}

	local palette = catalog.filter(sections, context.new(), "palette")
	local menu = catalog.filter(sections, context.new(), "context")
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

		actions.run("log.highlight_regex")
		actions.run("json.jqx_query")

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
	local actions = require("config.menu.actions")
	local original_cmd = vim.api.nvim_cmd
	local original_select = vim.ui.select
	local calls = {}
	local choice = "Cancel"
	local target = context.capture().target
	target.surface = "palette"

	local ok, err = xpcall(function()
		vim.api.nvim_cmd = function(specification, options)
			calls[#calls + 1] = { specification = specification, options = options }
		end
		vim.ui.select = function(items, options, callback)
			equal({ "Cancel", "Continue" }, items, "confirmation choices")
			assert(options.prompt:find("Discard", 1, true), "confirmation prompt is ambiguous")
			callback(choice)
		end

		actions.run("file.revert", target)
		equal(0, #calls, "cancelled destructive action executed")
		choice = "Continue"
		actions.run("file.revert", target)
		equal({ cmd = "edit", args = {}, bang = true }, calls[1].specification, "confirmed revert command")
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
	vim.ui.select = original_select
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
		actions.run("command.trouble_buffer", target)
		equal({
			cmd = "Trouble",
			args = { "diagnostics", "toggle", "filter.buf=0" },
			bang = false,
		}, calls[1].specification, "Trouble wrapper arguments")
		equal({}, calls[1].options, "Trouble wrapper options")
	end, debug.traceback)

	vim.api.nvim_cmd = original_cmd
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

		actions.run("python.send_selection", target)
		assert(sent_selection == true, "Python action did not send a selection")
		equal({ 1, 1 }, vim.api.nvim_buf_get_mark(buf, "<"), "selection start mark")
		equal({ 3, 2 }, vim.api.nvim_buf_get_mark(buf, ">"), "selection end mark")
		vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
		vim.api.nvim_buf_set_mark(buf, ">", 2, 1, {})
		actions.run("search.selection", target)
		assert(searched_selection, "search action did not use the visual selection")

		actions.run("agent.context", target)
		equal({ cmd = "AgentContext", args = {}, bang = false, range = { 1, 3 } }, commands[1], "agent range")
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
	local original_actions = package.loaded["config.menu.actions"]
	local original_snacks = package.loaded.snacks
	local original_pager = package.loaded["config.pager"]
	local captured
	local dispatched = {}
	local origin = vim.api.nvim_get_current_buf()

	local ok, err = xpcall(function()
		package.loaded["config.menu.actions"] = {
			run = function(id, target)
				dispatched[#dispatched + 1] = { id = id, target = target }
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

		local menu = require("config.menu")
		menu.open_palette()
		assert(captured, "palette did not open")
		equal("menu_actions", captured.source, "palette source")
		assert(type(captured.format) == "function", "palette format is not custom")
		local session_item
		for _, item in ipairs(captured.items) do
			if item.id == "session.search" then
				session_item = item
				break
			end
		end
		assert(session_item, "session search is absent from the shared palette")
		equal("Sessions: Search and Restore", session_item.display, "palette item is not namespaced")
		assert(session_item.text:find(session_item.display, 1, true), "palette searchable text lost its display")
		local expected_labels = {
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
			{ { session_item.display }, { "  <leader>Sp", "Comment" } },
			captured.format(session_item),
			"palette format"
		)

		local closes = 0
		local picker = {
			close = function()
				closes = closes + 1
			end,
		}
		vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
		captured.confirm(picker, session_item)
		captured.confirm(picker, session_item)
		vim.wait(500, function()
			return #dispatched == 1
		end, 5)
		equal("session.search", dispatched[1].id, "palette dispatched the wrong action")
		equal(origin, dispatched[1].target.bufnr, "palette lost the origin buffer")
		equal(1, closes, "palette closed more than once")
	end, debug.traceback)

	package.loaded["config.menu"] = original_menu
	package.loaded["config.menu.actions"] = original_actions
	package.loaded.snacks = original_snacks
	package.loaded["config.pager"] = original_pager
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
