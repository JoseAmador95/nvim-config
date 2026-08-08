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
	equal({ filetype = "json", mode = "V", visual = true }, menu_context, "visual context")
	assert(values.visual == nil, "context constructor mutated its input")
	equal(false, context.new({ mode = "n" }).visual, "normal mode was treated as visual")
	equal(true, context.new({ mode = "n", visual = true }).visual, "explicit visual override was ignored")
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
			closes = closes + 1
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
	end, debug.traceback)

	backend_module.default = original_default
	package.loaded["config.menu"] = original_menu
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
