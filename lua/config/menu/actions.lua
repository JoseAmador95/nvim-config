local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Menu" })
end

local function require_or_notify(module, label)
	local ok, value = pcall(require, module)
	if ok then
		return value
	end
	notify(label .. " not available", vim.log.levels.WARN)
	return nil
end

local function command(name, args, bang)
	return vim.api.nvim_cmd({ cmd = name, args = args or {}, bang = bang or false }, {})
end

local picker_sources = {
	buffers = "buffers",
	command_history = "command_history",
	diagnostics = "diagnostics",
	find_files = "files",
	git_bcommits = "git_log_file",
	git_commits = "git_log",
	grep_string = "grep_word",
	help_tags = "help",
	live_grep = "grep",
	lsp_document_symbols = "lsp_symbols",
	lsp_implementations = "lsp_implementations",
	lsp_references = "lsp_references",
	lsp_type_definitions = "lsp_type_definitions",
	lsp_workspace_symbols = "lsp_workspace_symbols",
	oldfiles = "recent",
}

local lsp_actions = {
	code_action = { "textDocument/codeAction", "code_action" },
	declaration = { "textDocument/declaration", "declaration" },
	definition = { "textDocument/definition", "definition" },
	incoming_calls = { "callHierarchy/incomingCalls", "incoming_calls" },
	outgoing_calls = { "callHierarchy/outgoingCalls", "outgoing_calls" },
	rename = { "textDocument/rename", "rename" },
}

local gitsigns_actions = {
	diffthis = { "diffthis" },
	next_hunk = { "nav_hunk", "next" },
	prev_hunk = { "nav_hunk", "prev" },
	preview_hunk = { "preview_hunk" },
	reset_buffer = { "reset_buffer" },
	reset_hunk = { "reset_hunk" },
	stage_buffer = { "stage_buffer" },
	stage_hunk = { "stage_hunk" },
	toggle_current_line_blame = { "toggle_current_line_blame" },
	toggle_deleted = { "toggle_deleted" },
}

local neotest_actions = {
	last = { "run.run_last" },
	nearest = { "run.run" },
	next_failed = { "jump.next", { status = "failed" } },
	output_panel = { "output_panel.toggle" },
	prev_failed = { "jump.prev", { status = "failed" } },
	stop = { "run.stop" },
	summary = { "summary.toggle" },
}

local dap_actions = {
	clear_breakpoints = "clear_breakpoints",
	continue = "continue",
	run_last = "run_last",
	run_to_cursor = "run_to_cursor",
	step_into = "step_into",
	step_out = "step_out",
	step_over = "step_over",
	terminate = "terminate",
	toggle_breakpoint = "toggle_breakpoint",
}

local commands = {
	bookmark_add = { "BookmarksMark" },
	bookmark_tree = { "BookmarksTree" },
	cmake_build = { "CMakeBuild" },
	cmake_build_target = { "CMakeSelectBuildTarget" },
	cmake_build_type = { "CMakeSelectBuildType" },
	cmake_configure_preset = { "CMakeSelectConfigurePreset" },
	cmake_debug = { "CMakeDebug" },
	cmake_generate = { "CMakeGenerate" },
	cmake_launch_target = { "CMakeSelectLaunchTarget" },
	cmake_run = { "CMakeRun" },
	cmake_test = { "CMakeRunTest" },
	conform_info = { "ConformInfo" },
	devcontainer_shell = { "DevcontainerShell" },
	devcontainer_workspace = { "DevcontainerWorkspace" },
	diffview_file_history = { "DiffviewFileHistory" },
	diffview_open = { "DiffviewOpen" },
	fold_close = { "FoldCloseAll" },
	fold_open = { "FoldOpenAll" },
	format_toggle = { "FormatToggle" },
	format_toggle_buffer = { "FormatToggle", true },
	json_tree = { "JsonTree" },
	log_highlight_clear = { "LogHlClear" },
	markdown_preview = { "MarkdownPreviewToggle" },
	mason = { "Mason" },
	neogen = { "Neogen" },
	plantuml_ascii = { "PlantumlAscii" },
	plantuml_preview = { "PlantumlPreview" },
	reload_config = { "ReloadConfig" },
	remote_start = { "RemoteStart" },
	toggle_inlay_hints = { "ToggleInlayHints" },
	toggle_inline_diagnostics = { "ToggleInlineDiagnostics" },
	xml_outline = { "XmlOutline" },
	yaml_outline = { "YamlOutline" },
}

local function run_picker(name)
	local source = picker_sources[name]
	local snacks = require_or_notify("snacks", "Picker action")
	if not snacks or not snacks.picker or type(snacks.picker[source]) ~= "function" then
		if snacks then
			notify("Picker action not available", vim.log.levels.WARN)
		end
		return
	end

	local options = {}
	if source:match("^lsp_") then
		options.confirm = "open_in_tab"
	end
	snacks.picker[source](options)
end

local function run_lsp(name)
	local action = lsp_actions[name]
	local clients = vim.lsp.get_clients({ bufnr = 0, method = action[1] })
	if not clients or #clients == 0 then
		notify("LSP action not available", vim.log.levels.WARN)
		return
	end
	vim.lsp.buf[action[2]]()
end

local function run_gitsigns(name)
	local action = gitsigns_actions[name]
	local gitsigns = require_or_notify("gitsigns", "Gitsigns action")
	if not gitsigns or type(gitsigns[action[1]]) ~= "function" then
		if gitsigns then
			notify("Gitsigns action not available", vim.log.levels.WARN)
		end
		return
	end
	gitsigns[action[1]](unpack(action, 2))
end

local function nested_function(root, path)
	local value = root
	for part in path:gmatch("[^.]+") do
		value = value[part]
		if value == nil then
			return nil
		end
	end
	return value
end

local function run_neotest(name)
	local neotest = require_or_notify("neotest", "Neotest")
	if not neotest then
		return
	end

	if name == "file" then
		neotest.run.run(vim.fn.expand("%"))
		return
	end

	local action = neotest_actions[name]
	local fn = action and nested_function(neotest, action[1])
	if type(fn) ~= "function" then
		notify("Neotest action not available: " .. name, vim.log.levels.WARN)
		return
	end
	fn(unpack(action, 2))
end

local function run_dap(name)
	local dap = require_or_notify("dap", "DAP")
	if not dap then
		return
	end
	local action = dap_actions[name]
	if type(dap[action]) ~= "function" then
		notify("DAP action not available: " .. name, vim.log.levels.WARN)
		return
	end
	---@diagnostic disable-next-line: redundant-parameter
	dap[action]()
end

local function format_buffer()
	local ok, conform = pcall(require, "conform")
	if ok then
		conform.format({ lsp_format = "fallback" })
		return
	end
	vim.lsp.buf.format()
end

local function grug_far()
	return require_or_notify("grug-far", "grug-far")
end

local function prompt_log_highlight(kind)
	local colors = { "red", "orange", "yellow", "green", "cyan", "blue", "purple", "gray" }
	vim.ui.select(colors, { prompt = "Pick color:" }, function(color)
		if not color then
			return
		end
		vim.ui.input({ prompt = "Pattern (" .. kind .. "): " }, function(pattern)
			if not pattern or pattern == "" then
				return
			end
			local name = kind == "regex" and "LogHlRegex" or "LogHlAdd"
			command(name, { color, pattern })
		end)
	end)
end

local handlers = {
	["dap.conditional_breakpoint"] = function()
		local dap = require_or_notify("dap", "DAP")
		if not dap then
			return
		end
		vim.ui.input({ prompt = "Condition: " }, function(condition)
			if condition then
				dap.set_breakpoint(condition)
			end
		end)
	end,
	["dapui.eval"] = function()
		local dapui = require_or_notify("dapui", "DAP UI")
		if dapui then
			dapui.eval()
		end
	end,
	["dapui.toggle"] = function()
		local dapui = require_or_notify("dapui", "DAP UI")
		if dapui then
			dapui.toggle()
		end
	end,
	["format.buffer"] = format_buffer,
	["lsp.format"] = format_buffer,
	["git.neogit"] = function()
		local neogit = require_or_notify("neogit", "Neogit")
		if neogit then
			neogit.open()
		end
	end,
	["json.jqx_query"] = function()
		vim.ui.input({ prompt = "jq query: " }, function(query)
			if query and query ~= "" then
				command("JqxQuery", { query })
			end
		end)
	end,
	["log.highlight_exact"] = function()
		prompt_log_highlight("exact")
	end,
	["log.highlight_regex"] = function()
		prompt_log_highlight("regex")
	end,
	["markdown.render_toggle"] = function()
		local render_markdown = require_or_notify("render-markdown", "render-markdown")
		if render_markdown then
			render_markdown.toggle()
		end
	end,
	["search.file"] = function()
		local path = vim.fn.expand("%:p:.")
		if path == "" then
			notify("No file path for current buffer", vim.log.levels.WARN)
			return
		end
		local grug = grug_far()
		if grug then
			grug.open({ prefills = { paths = path } })
		end
	end,
	["search.open"] = function()
		local grug = grug_far()
		if grug then
			-- toggle_instance keeps the search intact when returning to the panel.
			grug.toggle_instance({ instanceName = "far", staticTitle = "Search & Replace" })
		end
	end,
	["search.selection"] = function()
		local grug = grug_far()
		if grug then
			grug.with_visual_selection()
		end
	end,
	["search.word"] = function()
		local grug = grug_far()
		if grug then
			grug.open({ prefills = { search = vim.fn.expand("<cword>") } })
		end
	end,
	["view.oil"] = function()
		local oil = require_or_notify("oil", "oil.nvim")
		if oil then
			oil.toggle_float()
		end
	end,
	["view.peek_fold"] = function()
		local ufo = require_or_notify("ufo", "nvim-ufo")
		if ufo then
			ufo.peekFoldedLinesUnderCursor()
		end
	end,
	["view.toggle_paste"] = function()
		vim.o.paste = not vim.o.paste
		notify("Paste: " .. (vim.o.paste and "on" or "off"))
	end,
	["view.toggle_relative_number"] = function()
		vim.wo.relativenumber = not vim.wo.relativenumber
		notify("Relative number: " .. (vim.wo.relativenumber and "on" or "off"))
	end,
	["view.toggle_spell"] = function()
		vim.wo.spell = not vim.wo.spell
		notify("Spell: " .. (vim.wo.spell and "on" or "off"))
	end,
	["view.toggle_wrap"] = function()
		vim.wo.wrap = not vim.wo.wrap
		notify("Wrap: " .. (vim.wo.wrap and "on" or "off"))
	end,
	["view.toggleterm"] = function()
		local ok = pcall(command, "ToggleTerm")
		if not ok then
			notify("ToggleTerm not available", vim.log.levels.WARN)
		end
	end,
}

---Run a menu action by its stable descriptor id.
---@param id string
---@return boolean
function M.supports(id)
	if handlers[id] then
		return true
	end
	local namespace, name = id:match("^([^.]+)%.(.+)$")
	return (namespace == "command" and commands[name] ~= nil)
		or (namespace == "dap" and dap_actions[name] ~= nil)
		or (namespace == "gitsigns" and gitsigns_actions[name] ~= nil)
		or (namespace == "lsp" and lsp_actions[name] ~= nil)
		or (namespace == "picker" and picker_sources[name] ~= nil)
		or (namespace == "test" and (name == "file" or neotest_actions[name] ~= nil))
end

---Run a menu action by its stable descriptor id.
---@param id string
function M.run(id)
	local handler = handlers[id]
	if handler then
		return handler()
	end

	local namespace, name = id:match("^([^.]+)%.(.+)$")
	if namespace == "command" and commands[name] then
		local definition = commands[name]
		return command(definition[1], nil, definition[2])
	elseif namespace == "dap" and dap_actions[name] then
		return run_dap(name)
	elseif namespace == "gitsigns" and gitsigns_actions[name] then
		return run_gitsigns(name)
	elseif namespace == "lsp" and lsp_actions[name] then
		return run_lsp(name)
	elseif namespace == "picker" and picker_sources[name] then
		return run_picker(name)
	elseif namespace == "test" and (name == "file" or neotest_actions[name]) then
		return run_neotest(name)
	end

	notify("Unknown menu action: " .. id, vim.log.levels.ERROR)
end

return M
