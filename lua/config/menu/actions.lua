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

local function command(name, args, bang, range)
	local specification = { cmd = name, args = args or {}, bang = bang or false }
	if range then
		specification.range = range
	end
	return vim.api.nvim_cmd(specification, {})
end

local picker_sources = {
	buffers = "buffers",
	commands = "commands",
	command_history = "command_history",
	diagnostics = "diagnostics",
	find_files = "files",
	git_bcommits = "git_log_file",
	git_branches = "git_branches",
	git_commits = "git_log",
	git_stash = "git_stash",
	git_status = "git_status",
	grep_string = "grep_word",
	help_tags = "help",
	jumps = "jumps",
	keymaps = "keymaps",
	live_grep = "grep",
	lsp_document_symbols = "lsp_symbols",
	lsp_implementations = "lsp_implementations",
	lsp_references = "lsp_references",
	lsp_type_definitions = "lsp_type_definitions",
	lsp_workspace_symbols = "lsp_workspace_symbols",
	marks = "marks",
	oldfiles = "recent",
	registers = "registers",
	todo = "todo_comments",
	undo = "undo",
}

local lsp_actions = {
	code_action = { "textDocument/codeAction", "code_action" },
	declaration = { "textDocument/declaration", "declaration" },
	definition = { "textDocument/definition", "definition" },
	hover = { "textDocument/hover", "hover", { border = "rounded" } },
	incoming_calls = { "callHierarchy/incomingCalls", "incoming_calls" },
	outgoing_calls = { "callHierarchy/outgoingCalls", "outgoing_calls" },
	rename = { "textDocument/rename", "rename" },
	signature_help = { "textDocument/signatureHelp", "signature_help" },
}

local gitsigns_actions = {
	blame_line = { "blame_line", { full = true } },
	diffthis = { "diffthis" },
	next_hunk = { "nav_hunk", "next" },
	prev_hunk = { "nav_hunk", "prev" },
	preview_hunk = { "preview_hunk" },
	reset_buffer = { "reset_buffer" },
	reset_hunk = { "reset_hunk" },
	reset_selection = { "reset_hunk" },
	stage_buffer = { "stage_buffer" },
	stage_hunk = { "stage_hunk" },
	stage_selection = { "stage_hunk" },
	toggle_current_line_blame = { "toggle_current_line_blame" },
	toggle_deleted = { "toggle_deleted" },
}

local flash_actions = {
	jump = "jump",
	treesitter = "treesitter",
}

local neotest_actions = {
	debug_nearest = { "run.run", { strategy = "dap" } },
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
	cmake_build = { "CMakeBuild" },
	cmake_build_preset = { "CMakeSelectBuildPreset" },
	cmake_build_target = { "CMakeSelectBuildTarget" },
	cmake_build_type = { "CMakeSelectBuildType" },
	cmake_configure_preset = { "CMakeSelectConfigurePreset" },
	cmake_debug = { "CMakeDebug" },
	cmake_generate = { "CMakeGenerate" },
	cmake_launch_target = { "CMakeSelectLaunchTarget" },
	cmake_run = { "CMakeRun" },
	cmake_test = { "CMakeRunTest" },
	conform_info = { "ConformInfo" },
	coverage_clear = { "CoverageClear" },
	coverage_load = { "CoverageLoad" },
	coverage_summary = { "CoverageSummary" },
	devpod_host = { "HostEditor" },
	devpod_log = { "DevPodLog" },
	devpod_recreate = { "DevPodRecreate" },
	devpod_status = { "DevPodStatus" },
	devpod_up = { "DevPodUp" },
	diffview_file_history = { "DiffviewFileHistory" },
	diffview_close = { "DiffviewClose" },
	diffview_open = { "DiffviewOpen" },
	diagram_show_ascii = { name = "DiagramShow", args = { "ascii" } },
	diagram_show_svg = { name = "DiagramShow", args = { "svg" } },
	fold_close = { "FoldCloseAll" },
	fold_open = { "FoldOpenAll" },
	format_toggle = { "FormatToggle" },
	format_toggle_buffer = { "FormatToggle", true },
	hex_assemble = { "HexAssemble" },
	hex_dump = { "HexDump" },
	hex_toggle = { "HexToggle" },
	diagram_show = { "DiagramShow" },
	json_tree = { "JsonTree" },
	just_import_last = { "JustImportLast" },
	just_run = { "JustRun" },
	lazygit = { "LazyGit" },
	log_watch = { "LogWatchCurrentFile" },
	log_watch_disable = { name = "LogWatchCurrentFile", args = { "off" } },
	log_watch_enable = { name = "LogWatchCurrentFile", args = { "on" } },
	log_highlight_clear = { "LogHlClear" },
	markdown_preview = { "MarkdownPreviewToggle" },
	markdown_preview_open = { "MarkdownPreview" },
	markdown_preview_stop = { "MarkdownPreviewStop" },
	markdown_render_buffer_disable = { name = "MarkdownRender", args = { "buf_disable" } },
	markdown_render_buffer_enable = { name = "MarkdownRender", args = { "buf_enable" } },
	markdown_render_buffer_toggle = { name = "MarkdownRender", args = { "buf_toggle" } },
	markdown_render_contract = { name = "MarkdownRender", args = { "contract" } },
	markdown_render_disable = { name = "MarkdownRender", args = { "disable" } },
	markdown_render_enable = { name = "MarkdownRender", args = { "enable" } },
	markdown_render_expand = { name = "MarkdownRender", args = { "expand" } },
	markdown_render_preview = { name = "MarkdownRender", args = { "preview" } },
	mason = { "Mason" },
	messages = { "messages" },
	nvim_config_dump = { "NvimConfigDump" },
	nvim_config_edit = { "NvimConfigEdit" },
	nvim_config_init = { "NvimConfigInit" },
	nvim_config_reload = { "NvimConfigReload" },
	parsers_install = { "NvimConfigParsersInstall" },
	reload_config = { "ReloadConfig" },
	review_close = { "ReviewClose" },
	review_code = { "ReviewCode" },
	review_comment = { "ReviewComment" },
	review_commits = { "ReviewCommits" },
	review_export = { "ReviewExport" },
	review_files = { "ReviewFiles" },
	review_link_tuicr = { "ReviewLinkTuicr" },
	review_next = { "ReviewNext" },
	review_open = { "ReviewOpen" },
	review_prev = { "ReviewPrev" },
	review_refresh = { "ReviewRefresh" },
	review_scope = { "ReviewScope" },
	review_sessions = { "ReviewSessions" },
	review_start = { "ReviewRoundStart" },
	review_threads = { "ReviewThreads" },
	scratch = { "Scratch" },
	theme = { "Theme" },
	theme_reset = { "ThemeReset" },
	toggle_inlay_hints = { "ToggleInlayHints" },
	toggle_inline_diagnostics = { "ToggleInlineDiagnostics" },
	toggle_log_highlight = { "ToggleLogHighlight" },
	tools_install = { "NvimConfigToolsInstall" },
	trouble_buffer = { name = "Trouble", args = { "diagnostics", "toggle", "filter.buf=0" } },
	trouble_diagnostics = { name = "Trouble", args = { "diagnostics", "toggle" } },
	trouble_loclist = { name = "Trouble", args = { "loclist", "toggle" } },
	trouble_quickfix = { name = "Trouble", args = { "qflist", "toggle" } },
	trouble_references = {
		name = "Trouble",
		args = { "lsp_references", "toggle", "focus=false", "win.position=right" },
	},
	trouble_todos = { name = "Trouble", args = { "todo", "toggle" } },
	venv_cached = { "VenvSelectCached" },
	venv_select = { "VenvSelect" },
	clangd_switch = { "ClangdSwitchSourceHeader" },
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
	if name == "definition" or name == "declaration" then
		require("config.lsp_navigation")[name]()
		return
	end
	local action = lsp_actions[name]
	local clients = vim.lsp.get_clients({ bufnr = 0, method = action[1] })
	if not clients or #clients == 0 then
		notify("LSP action not available", vim.log.levels.WARN)
		return
	end
	local callback = vim.lsp.buf[action[2]]
	if type(callback) ~= "function" then
		notify("LSP action not available: " .. name, vim.log.levels.WARN)
		return
	end
	if action[3] then
		callback(action[3])
	else
		callback()
	end
end

local function ordered_selection(target)
	local selection = target and target.selection
	if not selection then
		return nil
	end
	local anchor = selection.anchor
	local cursor = selection.cursor
	if anchor.line < cursor.line or (anchor.line == cursor.line and anchor.col <= cursor.col) then
		return anchor, cursor
	end
	return cursor, anchor
end

local function run_gitsigns(name, target)
	local action = gitsigns_actions[name]
	local gitsigns = require_or_notify("gitsigns", "Gitsigns action")
	if not gitsigns or type(gitsigns[action[1]]) ~= "function" then
		if gitsigns then
			notify("Gitsigns action not available: " .. name, vim.log.levels.WARN)
		end
		return
	end
	if name == "stage_selection" or name == "reset_selection" then
		local first, last = ordered_selection(target)
		if not first then
			notify("Git selection is no longer available", vim.log.levels.WARN)
			return
		end
		gitsigns[action[1]]({ first.line, last.line })
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

local function on_target(target, options, callback)
	local ok, err = require("config.editor_actions").with_target(target, options, callback)
	if not ok then
		notify(tostring(err), vim.log.levels.WARN)
	end
	return ok
end

local function target_command(target, name, args, bang, range)
	return on_target(target, { window = true }, function()
		command(name, args, bang, range)
	end)
end

local function run_flash(name, target)
	return on_target(target, { window = true }, function()
		local flash = require_or_notify("flash", "flash.nvim")
		local action = flash_actions[name]
		if not flash then
			return
		end
		if type(flash[action]) ~= "function" then
			notify("Flash action not available: " .. name, vim.log.levels.WARN)
			return
		end
		flash[action]()
	end)
end

local function format_buffer(target)
	return on_target(target, { window = true }, function()
		require("config.formatting").format({ async = true })
	end)
end

local function restore_selection_marks(target)
	local first, last = ordered_selection(target)
	if not first then
		return
	end
	vim.api.nvim_buf_set_mark(target.bufnr, "<", first.line, first.col, {})
	vim.api.nvim_buf_set_mark(target.bufnr, ">", last.line, last.col, {})
end

local function set_window_option(target, name, enabled, label)
	local value, err = require("config.editor_actions").set_window_option(name, enabled, target)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	notify(label .. ": " .. (value and "on" or "off"))
end

local function toggle_window_option(target, name, label)
	local value, err = require("config.editor_actions").toggle_window_option(name, target)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	notify(label .. ": " .. (value and "on" or "off"))
end

local function set_wrap(target, enabled)
	local value, err = require("config.editor_actions").set_wrap(enabled, target)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	notify("Wrap: " .. (value and "on" or "off"))
end

local function toggle_wrap(target)
	local value, err = require("config.editor_actions").toggle_wrap(target)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	notify("Wrap: " .. (value and "on" or "off"))
end

local file_actions = {
	new = function(target)
		on_target(target, { window = true }, function(origin)
			command("enew")
			local ok, tabs = pcall(require, "config.tabs")
			if ok then
				tabs.unmark_home(origin.tabpage)
			end
		end)
	end,
	save = function(target)
		target_command(target, "write")
	end,
	save_as = function(target)
		vim.ui.input({ prompt = "Save as: ", completion = "file" }, function(path)
			if path and path ~= "" then
				target_command(target, "saveas", { path })
			end
		end)
	end,
	save_all = function()
		command("wall")
	end,
	revert = function(target)
		target_command(target, "edit", nil, true)
	end,
	close_tab = function(target)
		target_command(target, "CloseTab")
	end,
	close_all = function()
		command("CloseAll")
	end,
	open_under_cursor = function(target)
		local ok, err = require("config.editor_actions").open_file_under_cursor(target)
		if not ok then
			notify(err, vim.log.levels.WARN)
		end
	end,
	set_filetype = function(target)
		local filetypes = vim.fn.getcompletion("", "filetype")
		vim.ui.select(filetypes, { prompt = "File type" }, function(filetype)
			if filetype then
				target_command(target, "SetFileType", { filetype })
			end
		end)
	end,
}

local edit_actions = {
	undo = function(target)
		target_command(target, "undo")
	end,
	redo = function(target)
		target_command(target, "redo")
	end,
	clear_search = function()
		vim.v.hlsearch = 0
	end,
	join_line = function(target)
		target_command(target, "normal", { "J" }, true)
	end,
	duplicate_line = function(target)
		on_target(target, { modifiable = true }, function(origin)
			local row = origin.cursor.line
			local line = vim.api.nvim_buf_get_lines(origin.bufnr, row - 1, row, false)
			vim.api.nvim_buf_set_lines(origin.bufnr, row, row, false, line)
		end)
	end,
	trim_whitespace = function(target)
		on_target(target, { modifiable = true }, function(origin)
			local lines = vim.api.nvim_buf_get_lines(origin.bufnr, 0, -1, false)
			local changed = false
			for index, line in ipairs(lines) do
				local trimmed = line:gsub("%s+$", "")
				changed = changed or trimmed ~= line
				lines[index] = trimmed
			end
			if changed then
				vim.api.nvim_buf_set_lines(origin.bufnr, 0, -1, false, lines)
			end
		end)
	end,
}

local go_actions = {
	line = function(target)
		vim.ui.input({ prompt = "Go to line: " }, function(value)
			local line = tonumber(value)
			if not line then
				return
			end
			on_target(target, { window = true }, function(origin)
				local last = vim.api.nvim_buf_line_count(origin.bufnr)
				vim.api.nvim_win_set_cursor(origin.winid, { math.max(1, math.min(line, last)), 0 })
			end)
		end)
	end,
	matching_bracket = function(target)
		target_command(target, "normal", { "%" }, true)
	end,
	todo_next = function(target)
		on_target(target, { window = true }, function()
			local todo = require_or_notify("todo-comments", "todo-comments")
			if todo then
				todo.jump_next()
			end
		end)
	end,
	todo_prev = function(target)
		on_target(target, { window = true }, function()
			local todo = require_or_notify("todo-comments", "todo-comments")
			if todo then
				todo.jump_prev()
			end
		end)
	end,
	reference_next = function(target)
		on_target(target, { window = true }, function()
			local illuminate = require_or_notify("illuminate", "illuminate")
			if illuminate then
				illuminate.goto_next_reference(true)
			end
		end)
	end,
	reference_prev = function(target)
		on_target(target, { window = true }, function()
			local illuminate = require_or_notify("illuminate", "illuminate")
			if illuminate then
				illuminate.goto_prev_reference(true)
			end
		end)
	end,
	reference_freeze = function(target)
		on_target(target, { window = true }, function()
			local illuminate = require_or_notify("illuminate", "illuminate")
			if illuminate then
				illuminate.toggle_freeze_buf()
			end
		end)
	end,
}

local treesitter_moves = {
	function_next = { "goto_next_start", "@function.outer" },
	function_prev = { "goto_previous_start", "@function.outer" },
	class_next = { "goto_next_start", "@class.outer" },
	class_prev = { "goto_previous_start", "@class.outer" },
}

local function run_treesitter_move(name, target)
	local action = treesitter_moves[name]
	on_target(target, { window = true }, function()
		local move = require_or_notify("nvim-treesitter-textobjects.move", "Tree-sitter textobjects")
		if move and type(move[action[1]]) == "function" then
			move[action[1]](action[2])
		end
	end)
end

local window_commands = {
	split_horizontal = { "split" },
	split_vertical = { "vsplit" },
	close = { "close" },
	only = { "only" },
}

local smart_split_actions = {
	focus_left = "move_cursor_left",
	focus_down = "move_cursor_down",
	focus_up = "move_cursor_up",
	focus_right = "move_cursor_right",
	resize_left = "resize_left",
	resize_down = "resize_down",
	resize_up = "resize_up",
	resize_right = "resize_right",
}

local function run_window(name, target)
	if window_commands[name] then
		return target_command(target, window_commands[name][1])
	elseif name == "equalize" then
		return target_command(target, "wincmd", { "=" })
	end
	local action = smart_split_actions[name]
	on_target(target, { window = true }, function()
		local splits = require_or_notify("smart-splits", "smart-splits")
		if not splits then
			return
		end
		if type(splits[action]) ~= "function" then
			notify("smart-splits action not available: " .. name, vim.log.levels.WARN)
			return
		end
		splits[action]()
	end)
end

local tab_commands = {
	new = { "tabnew" },
	previous = { "tabprevious" },
	next = { "tabnext" },
	first = { "tabfirst" },
	last = { "tablast" },
	move_left = { "tabmove", { "-1" } },
	move_right = { "tabmove", { "+1" } },
}

local diagnostic_actions = {
	float = function()
		vim.diagnostic.open_float({ border = "rounded", focusable = false })
	end,
	next = function()
		vim.diagnostic.jump({ count = 1 })
	end,
	prev = function()
		vim.diagnostic.jump({ count = -1 })
	end,
	loclist = vim.diagnostic.setloclist,
}

local python_actions = {
	repl = function()
		require("config.python").open_repl()
	end,
	send_line = function()
		require("config.python").send(false)
	end,
	send_selection = function(target)
		restore_selection_marks(target)
		require("config.python").send(true)
	end,
}

local multicursor_actions = {
	match_all = "matchAllAddCursors",
	clear = "clearCursors",
	next = "nextCursor",
	prev = "prevCursor",
}

local multicursor_flash_actions = {
	flash_cursor = "flash_cursor",
	flash_word_selection = "flash_word_selection",
}

local function run_multicursor(name, target)
	on_target(target, { window = true }, function()
		local multicursor = require_or_notify("multicursor-nvim", "multicursor")
		local action = multicursor_actions[name]
		if not multicursor then
			return
		end
		if type(multicursor[action]) ~= "function" then
			notify("Multicursor action not available: " .. name, vim.log.levels.WARN)
			return
		end
		multicursor[action]()
	end)
end

local function run_multicursor_flash(name, target)
	on_target(target, { window = true }, function()
		local helpers = require_or_notify("config.multicursor", "Multicursor Flash actions")
		local action = multicursor_flash_actions[name]
		if not helpers then
			return
		end
		if type(helpers[action]) ~= "function" then
			notify("Multicursor Flash action not available: " .. name, vim.log.levels.WARN)
			return
		end
		helpers[action]()
	end)
end

local transform_kinds = {
	upper = true,
	lower = true,
	toggle = true,
	title = true,
	camel = true,
	pascal = true,
	snake = true,
	kebab = true,
}

local transform_scopes = { word = true, line = true, selection = true }

local function transform_parts(name)
	local kind, scope = name:match("^([a-z]+)_([a-z]+)$")
	if transform_kinds[kind] and transform_scopes[scope] then
		return kind, scope
	end
end

local function run_transform(name, target)
	local kind, scope = transform_parts(name)
	local ok, err = require("config.menu.transforms").apply(kind, scope, target)
	if not ok and err then
		notify(err, vim.log.levels.WARN)
	end
end

local confirmation_prompts = {
	["file.revert"] = "Discard unsaved changes and reload this file?",
	["gitsigns.reset_hunk"] = "Discard the current Git hunk?",
	["gitsigns.reset_selection"] = "Discard Git changes in the selected lines?",
	["gitsigns.reset_buffer"] = "Discard all Git hunks in this buffer?",
	["command.devpod_recreate"] = "Recreate the DevPod workspace editor?",
	["command.hex_assemble"] = "Assemble the current hex buffer?",
	["command.nvim_config_init"] = "Create the local Neovim config template?",
	["command.tools_install"] = "Install the configured managed tools?",
	["command.parsers_install"] = "Install the configured Tree-sitter parsers?",
	["tmux.refresh_dev_session"] = "Refresh the tmux dev session? This restarts agent/editor/git, Neovim exits, and term keeps running.",
}

local function confirm(prompt, callback)
	vim.ui.select({ "Cancel", "Continue" }, { prompt = prompt }, function(choice)
		if choice == "Continue" then
			callback()
		end
	end)
end

local handlers = {
	["navigation.back"] = function()
		require("config.navigation_history").back()
	end,
	["navigation.forward"] = function()
		require("config.navigation_history").forward()
	end,
	["navigation.history"] = function()
		require("config.navigation_history").select()
	end,
	["tmux.refresh_dev_session"] = function()
		local refresh = require_or_notify("config.dev_session_refresh", "Dev session refresh")
		if refresh then
			refresh.refresh()
		end
	end,
	["coverage.load_report"] = function(target)
		vim.ui.input({ prompt = "Coverage report: ", completion = "file" }, function(path)
			if path and path ~= "" then
				target_command(target, "CoverageLoad", { path })
			end
		end)
	end,
	["dap.conditional_breakpoint"] = function(target)
		vim.ui.input({ prompt = "Condition: " }, function(condition)
			if not condition then
				return
			end
			on_target(target, { window = true }, function()
				local dap = require_or_notify("dap", "DAP")
				if dap then
					dap.set_breakpoint(condition)
				end
			end)
		end)
	end,
	["dapui.eval"] = function(target)
		on_target(target, { window = true }, function()
			local dap_ui = require_or_notify("config.dap_ui", "DAP UI")
			if dap_ui then
				dap_ui.eval()
			end
		end)
	end,
	["dapui.toggle"] = function()
		local dap_ui = require_or_notify("config.dap_ui", "DAP UI")
		if dap_ui then
			dap_ui.toggle()
		end
	end,
	["format.buffer"] = format_buffer,
	["lsp.format"] = format_buffer,
	["json.jqx_query"] = function(target)
		vim.ui.input({ prompt = "jq query: " }, function(query)
			if query and query ~= "" then
				target_command(target, "JqxQuery", { query })
			end
		end)
	end,
	["log.highlight_exact"] = function()
		prompt_log_highlight("exact")
	end,
	["log.highlight_regex"] = function()
		prompt_log_highlight("regex")
	end,
	["markdown.render_toggle"] = function(target)
		on_target(target, { window = true }, function()
			local render_markdown = require_or_notify("render-markdown", "render-markdown")
			if render_markdown then
				render_markdown.toggle()
			end
		end)
	end,
	["session.delete"] = function()
		command("AutoSession", { "deletePicker" })
	end,
	["session.restore"] = function()
		command("AutoSession", { "restore" })
	end,
	["session.save"] = function()
		command("AutoSession", { "save" })
	end,
	["session.search"] = function()
		command("AutoSession", { "search" })
	end,
	["search.file"] = function(target)
		on_target(target, { window = true }, function()
			local path = vim.fn.expand("%:p:.")
			if path == "" then
				notify("No file path for current buffer", vim.log.levels.WARN)
				return
			end
			local grug = grug_far()
			if grug then
				grug.open({ prefills = { paths = path } })
			end
		end)
	end,
	["search.open"] = function()
		local grug = grug_far()
		if grug then
			-- toggle_instance keeps the search intact when returning to the panel.
			grug.toggle_instance({ instanceName = "far", staticTitle = "Search & Replace" })
		end
	end,
	["search.selection"] = function(target)
		on_target(target, { window = true }, function(origin)
			restore_selection_marks(origin)
			local grug = grug_far()
			if grug then
				grug.with_visual_selection()
			end
		end)
	end,
	["search.word"] = function(target)
		on_target(target, { window = true }, function()
			local grug = grug_far()
			if grug then
				grug.open({ prefills = { search = vim.fn.expand("<cword>") } })
			end
		end)
	end,
	["view.oil"] = function(target)
		on_target(target, { window = true }, function()
			local oil = require_or_notify("oil", "oil.nvim")
			if oil then
				oil.toggle_float()
			end
		end)
	end,
	["view.peek_fold"] = function(target)
		on_target(target, { window = true }, function()
			local ufo = require_or_notify("ufo", "nvim-ufo")
			if ufo then
				ufo.peekFoldedLinesUnderCursor()
			end
		end)
	end,
	["view.toggle_paste"] = function()
		vim.o.paste = not vim.o.paste
		notify("Paste: " .. (vim.o.paste and "on" or "off"))
	end,
	["view.toggle_relative_number"] = function(target)
		toggle_window_option(target, "relativenumber", "Relative number")
	end,
	["view.toggle_spell"] = function(target)
		toggle_window_option(target, "spell", "Spell")
	end,
	["view.toggle_wrap"] = function(target)
		toggle_wrap(target)
	end,
	["view.enable_wrap"] = function(target)
		set_wrap(target, true)
	end,
	["view.disable_wrap"] = function(target)
		set_wrap(target, false)
	end,
	["view.enable_spell"] = function(target)
		set_window_option(target, "spell", true, "Spell")
	end,
	["view.disable_spell"] = function(target)
		set_window_option(target, "spell", false, "Spell")
	end,
	["view.toggle_number"] = function(target)
		toggle_window_option(target, "number", "Line numbers")
	end,
	["view.enable_relative_number"] = function(target)
		set_window_option(target, "relativenumber", true, "Relative number")
	end,
	["view.disable_relative_number"] = function(target)
		set_window_option(target, "relativenumber", false, "Relative number")
	end,
	["view.toggle_cursorline"] = function(target)
		toggle_window_option(target, "cursorline", "Cursor line")
	end,
	["view.toggle_list"] = function(target)
		toggle_window_option(target, "list", "Invisible characters")
	end,
	["notification.dismiss"] = function()
		local snacks = require_or_notify("snacks", "Snacks notifier")
		if snacks and snacks.notifier then
			snacks.notifier.hide()
		end
	end,
	["notification.history"] = function()
		local snacks = require_or_notify("snacks", "Snacks notifier")
		if snacks and snacks.notifier then
			snacks.notifier.show_history()
		end
	end,
	["review.open"] = function(target)
		target_command(target, "TuicrReview")
	end,
	["agent.context"] = function(target)
		local first, last = ordered_selection(target)
		target_command(target, "AgentContext", nil, false, first and { first.line, last.line } or nil)
	end,
	["agent.results"] = function(target)
		vim.ui.input({ prompt = "Agent results JSON: ", completion = "file" }, function(path)
			if path and path ~= "" then
				target_command(target, "AgentResultsImport", { path })
			end
		end)
	end,
	["clangd.compile_commands"] = function(target)
		vim.ui.input({ prompt = "compile_commands.json directory: ", completion = "dir" }, function(path)
			if path and path ~= "" then
				target_command(target, "ClangdSetCompileCommands", { path })
			end
		end)
	end,
	["view.terminal"] = function(target)
		on_target(target, { window = true }, function()
			require("config.terminal").toggle_shell()
		end)
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
		or (namespace == "diagnostic" and diagnostic_actions[name] ~= nil)
		or (namespace == "edit" and edit_actions[name] ~= nil)
		or (namespace == "file" and file_actions[name] ~= nil)
		or (namespace == "flash" and flash_actions[name] ~= nil)
		or (namespace == "gitsigns" and gitsigns_actions[name] ~= nil)
		or (namespace == "go" and (go_actions[name] ~= nil or treesitter_moves[name] ~= nil))
		or (namespace == "lsp" and lsp_actions[name] ~= nil)
		or (namespace == "multicursor" and (multicursor_actions[name] ~= nil or multicursor_flash_actions[name] ~= nil))
		or (namespace == "picker" and picker_sources[name] ~= nil)
		or (namespace == "python" and python_actions[name] ~= nil)
		or (namespace == "tab" and tab_commands[name] ~= nil)
		or (namespace == "test" and (name == "file" or neotest_actions[name] ~= nil))
		or (namespace == "transform" and transform_parts(name) ~= nil)
		or (
			namespace == "window"
			and (window_commands[name] ~= nil or name == "equalize" or smart_split_actions[name] ~= nil)
		)
end

local function execute(id, target)
	local handler = handlers[id]
	if handler then
		return handler(target)
	end

	local namespace, name = id:match("^([^.]+)%.(.+)$")
	if namespace == "command" and commands[name] then
		local definition = commands[name]
		if definition.name then
			return target_command(target, definition.name, definition.args, definition.bang)
		end
		return target_command(target, definition[1], nil, definition[2])
	elseif namespace == "dap" and dap_actions[name] then
		return on_target(target, { window = true }, function()
			run_dap(name)
		end)
	elseif namespace == "diagnostic" and diagnostic_actions[name] then
		return on_target(target, { window = true }, diagnostic_actions[name])
	elseif namespace == "edit" and edit_actions[name] then
		return edit_actions[name](target)
	elseif namespace == "file" and file_actions[name] then
		return file_actions[name](target)
	elseif namespace == "flash" and flash_actions[name] then
		return run_flash(name, target)
	elseif namespace == "gitsigns" and gitsigns_actions[name] then
		return on_target(target, { window = true }, function()
			run_gitsigns(name, target)
		end)
	elseif namespace == "go" and go_actions[name] then
		return go_actions[name](target)
	elseif namespace == "go" and treesitter_moves[name] then
		return run_treesitter_move(name, target)
	elseif namespace == "lsp" and lsp_actions[name] then
		return on_target(target, { window = true }, function()
			run_lsp(name)
		end)
	elseif namespace == "multicursor" and multicursor_actions[name] then
		return run_multicursor(name, target)
	elseif namespace == "multicursor" and multicursor_flash_actions[name] then
		return run_multicursor_flash(name, target)
	elseif namespace == "picker" and picker_sources[name] then
		return on_target(target, { window = true }, function()
			run_picker(name)
		end)
	elseif namespace == "python" and python_actions[name] then
		return on_target(target, { window = true }, python_actions[name])
	elseif namespace == "tab" and tab_commands[name] then
		local definition = tab_commands[name]
		return target_command(target, definition[1], definition[2])
	elseif namespace == "test" and (name == "file" or neotest_actions[name]) then
		return on_target(target, { window = true }, function()
			run_neotest(name)
		end)
	elseif namespace == "transform" and transform_parts(name) then
		return run_transform(name, target)
	elseif namespace == "window" and (window_commands[name] or name == "equalize" or smart_split_actions[name]) then
		return run_window(name, target)
	end

	notify("Unknown menu action: " .. id, vim.log.levels.ERROR)
end

---Run a menu action by its stable descriptor id.
---@param id string
---@param target? table
function M.run(id, target)
	local prompt = target and target.surface == "palette" and confirmation_prompts[id] or nil
	if prompt then
		confirm(prompt, function()
			execute(id, target)
		end)
		return
	end
	return execute(id, target)
end

return M
