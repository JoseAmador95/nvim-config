local M = {}
local uv = vim.uv or vim.loop

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Menu" })
end

local function ensure_menu()
	local ok, menu = pcall(require, "menu")
	if ok then
		return menu
	end

	local ok_lazy, lazy = pcall(require, "lazy")
	if ok_lazy then
		lazy.load({ plugins = { "menu" } })
	end

	ok, menu = pcall(require, "menu")
	if ok then
		return menu
	end

	notify("menu.nvim not available", vim.log.levels.ERROR)
	return nil
end

local function lsp_action(method, action)
	return function()
		local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
		if not clients or #clients == 0 then
			notify("LSP action not available", vim.log.levels.WARN)
			return
		end
		action()
	end
end

local function format_buffer()
	local ok, conform = pcall(require, "conform")
	if ok then
		conform.format({ lsp_format = "fallback" })
		return
	end
	vim.lsp.buf.format()
end

local function telescope_action(action, opts)
	return function()
		local ok, builtin = pcall(require, "telescope.builtin")
		if not ok or not builtin[action] then
			notify("Telescope action not available", vim.log.levels.WARN)
			return
		end
		if opts then
			builtin[action](opts)
		else
			builtin[action]()
		end
	end
end

local function gitsigns_action(action)
	return function()
		local ok, gs = pcall(require, "gitsigns")
		if not ok or type(gs[action]) ~= "function" then
			notify("Gitsigns action not available", vim.log.levels.WARN)
			return
		end
		gs[action]()
	end
end

local function neotest_action(action, ...)
	local args = { ... }
	return function()
		local ok, nt = pcall(require, "neotest")
		if not ok then
			notify("Neotest not available", vim.log.levels.WARN)
			return
		end
		local parts = vim.split(action, "%.")
		local fn = nt
		for _, p in ipairs(parts) do
			fn = fn[p]
			if not fn then
				notify("Neotest action not available: " .. action, vim.log.levels.WARN)
				return
			end
		end
		fn(unpack(args))
	end
end

local function dap_action(action, ...)
	local args = { ... }
	return function()
		local ok, dap = pcall(require, "dap")
		if not ok then
			notify("DAP not available", vim.log.levels.WARN)
			return
		end
		if type(dap[action]) ~= "function" then
			notify("DAP action not available: " .. action, vim.log.levels.WARN)
			return
		end
		dap[action](unpack(args))
	end
end

local function dapui_action(action)
	return function()
		local ok, dapui = pcall(require, "dapui")
		if not ok then
			notify("DAP UI not available", vim.log.levels.WARN)
			return
		end
		dapui[action]()
	end
end

local function toggle_window_option(name, label)
	vim.wo[name] = not vim.wo[name]
	notify(label .. ": " .. (vim.wo[name] and "on" or "off"))
end

local function toggle_paste()
	vim.o.paste = not vim.o.paste
	notify("Paste: " .. (vim.o.paste and "on" or "off"))
end

local function spectre_open_all()
	local ok, spectre = pcall(require, "spectre")
	if not ok then
		notify("Spectre not available", vim.log.levels.WARN)
		return
	end

	local state = require("spectre.state")
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		if vim.bo[state.bufnr].filetype == "spectre_panel" then
			spectre.close()
		end
	end
	state.bufnr = nil
	state.is_open = false

	spectre.open({
		path = "!**/.git/** !**/node_modules/** !**/build/** !**/.cache/**",
		is_insert_mode = true,
	})
end

local function spectre_open_word()
	local ok, spectre = pcall(require, "spectre")
	if not ok then
		notify("Spectre not available", vim.log.levels.WARN)
		return
	end

	spectre.open_visual({
		select_word = true,
		path = "!**/.git/** !**/node_modules/** !**/build/** !**/.cache/**",
	})
end

local function spectre_open_selection()
	local ok, spectre = pcall(require, "spectre")
	if not ok then
		notify("Spectre not available", vim.log.levels.WARN)
		return
	end

	spectre.open_visual({
		path = "!**/.git/** !**/node_modules/** !**/build/** !**/.cache/**",
	})
end

local function spectre_open_file()
	local ok, spectre = pcall(require, "spectre")
	if not ok then
		notify("Spectre not available", vim.log.levels.WARN)
		return
	end

	local path = vim.fn.fnameescape(vim.fn.expand("%:p:."))
	if path == "" then
		notify("No file path for current buffer", vim.log.levels.WARN)
		return
	end

	if uv.os_uname().sysname == "Windows_NT" then
		path = vim.fn.substitute(path, "\\", "/", "g")
	end

	spectre.open({ path = path, is_insert_mode = true })
end

local function is_visual_mode()
	local mode = vim.fn.mode()
	return mode == "v" or mode == "V" or mode == "\22"
end

local function log_hl_prompt(kind)
	return function()
		local colors = { "red", "orange", "yellow", "green", "cyan", "blue", "purple", "gray" }
		vim.ui.select(colors, { prompt = "Pick color:" }, function(color)
			if not color then
				return
			end
			vim.ui.input({ prompt = "Pattern (" .. kind .. "): " }, function(pattern)
				if not pattern or pattern == "" then
					return
				end
				vim.cmd("LogHl" .. (kind == "regex" and "Regex" or "Add") .. " " .. color .. " " .. pattern)
			end)
		end)
	end
end

-- ── Sections ────────────────────────────────────────────────────────────────

local function search_items()
	local items = {
		{ name = "Spectre: Open", cmd = spectre_open_all },
		{ name = "Spectre: Search Word", cmd = spectre_open_word },
	}

	if is_visual_mode() then
		table.insert(items, { name = "Spectre: Search Selection", cmd = spectre_open_selection })
	end

	table.insert(items, { name = "Spectre: Search in File", cmd = spectre_open_file })
	table.insert(items, { name = "Live Grep", cmd = telescope_action("live_grep") })
	table.insert(items, { name = "Grep String (cursor)", cmd = telescope_action("grep_string") })
	return items
end

local function navigation_items()
	return {
		{ name = "Find Files", cmd = telescope_action("find_files") },
		{ name = "Recent Files", cmd = telescope_action("oldfiles") },
		{ name = "Buffers", cmd = telescope_action("buffers") },
		{ name = "Help Tags", cmd = telescope_action("help_tags") },
		{ name = "Command History", cmd = telescope_action("command_history") },
		{ name = "Git Commits", cmd = telescope_action("git_commits") },
		{ name = "Git Branches", cmd = telescope_action("git_bcommits") },
	}
end

local function lsp_items()
	return {
		{ name = "Go to Definition", cmd = lsp_action("textDocument/definition", vim.lsp.buf.definition), rtxt = "gd" },
		{
			name = "Go to Declaration",
			cmd = lsp_action("textDocument/declaration", vim.lsp.buf.declaration),
			rtxt = "gD",
		},
		{ name = "References", cmd = telescope_action("lsp_references", { jump_type = "never" }) },
		{ name = "Implementation", cmd = telescope_action("lsp_implementations", { jump_type = "never" }) },
		{ name = "Type Definition", cmd = telescope_action("lsp_type_definitions", { jump_type = "never" }) },
		{ name = "Document Symbols", cmd = telescope_action("lsp_document_symbols") },
		{ name = "Workspace Symbols", cmd = telescope_action("lsp_workspace_symbols") },
		{ name = "Incoming Calls", cmd = lsp_action("callHierarchy/incomingCalls", vim.lsp.buf.incoming_calls) },
		{ name = "Outgoing Calls", cmd = lsp_action("callHierarchy/outgoingCalls", vim.lsp.buf.outgoing_calls) },
		{ name = "Rename", cmd = lsp_action("textDocument/rename", vim.lsp.buf.rename) },
		{ name = "Code Actions", cmd = lsp_action("textDocument/codeAction", vim.lsp.buf.code_action) },
		{ name = "Generate Docs", cmd = function() vim.cmd("Neogen") end },
		{
			name = "Toggle Inlay Hints",
			cmd = function()
				vim.cmd("ToggleInlayHints")
			end,
		},
		{
			name = "Toggle Inline Diagnostics",
			cmd = function()
				vim.cmd("ToggleInlineDiagnostics")
			end,
		},
		{ name = "Format", cmd = format_buffer },
	}
end

local function git_items()
	return {
		{ name = "Preview Hunk", cmd = gitsigns_action("preview_hunk") },
		{ name = "Stage Hunk", cmd = gitsigns_action("stage_hunk") },
		{ name = "Undo Stage Hunk", cmd = gitsigns_action("undo_stage_hunk") },
		{ name = "Reset Hunk", cmd = gitsigns_action("reset_hunk") },
		{ name = "Stage Buffer", cmd = gitsigns_action("stage_buffer") },
		{ name = "Reset Buffer", cmd = gitsigns_action("reset_buffer") },
		{ name = "Diff This", cmd = gitsigns_action("diffthis") },
		{ name = "Toggle Deleted", cmd = gitsigns_action("toggle_deleted") },
		{ name = "Toggle Line Blame", cmd = gitsigns_action("toggle_current_line_blame") },
		{ name = "Next Hunk", cmd = gitsigns_action("next_hunk"), rtxt = "]c" },
		{ name = "Prev Hunk", cmd = gitsigns_action("prev_hunk"), rtxt = "[c" },
		{
			name = "Neogit Status",
			cmd = function()
				local ok, ng = pcall(require, "neogit")
				if ok then
					ng.open()
				else
					notify("Neogit not available", vim.log.levels.WARN)
				end
			end,
			rtxt = "<leader>gg",
		},
		{
			name = "Diffview Open",
			cmd = function()
				vim.cmd("DiffviewOpen")
			end,
		},
		{
			name = "Diffview File History",
			cmd = function()
				vim.cmd("DiffviewFileHistory")
			end,
		},
	}
end

local function format_items()
	return {
		{ name = "Format Buffer", cmd = format_buffer },
		{
			name = "Toggle Autoformat (global)",
			cmd = function()
				vim.cmd("FormatToggle")
			end,
		},
		{
			name = "Toggle Autoformat (buffer)",
			cmd = function()
				vim.cmd("FormatToggle!")
			end,
		},
		{
			name = "Conform Info",
			cmd = function()
				vim.cmd("ConformInfo")
			end,
		},
	}
end

local function test_items()
	return {
		{ name = "Run Nearest", cmd = neotest_action("run.run") },
		{ name = "Run File", cmd = neotest_action("run.run", vim.fn.expand("%")) },
		{ name = "Run Last", cmd = neotest_action("run.run_last") },
		{ name = "Stop", cmd = neotest_action("run.stop") },
		{ name = "Toggle Output Panel", cmd = neotest_action("output_panel.toggle") },
		{ name = "Toggle Summary", cmd = neotest_action("summary.toggle") },
		{ name = "Next Failed", cmd = neotest_action("jump.next", { status = "failed" }) },
		{ name = "Prev Failed", cmd = neotest_action("jump.prev", { status = "failed" }) },
	}
end

local function cmake_items()
	return {
		{
			name = "Generate",
			cmd = function()
				vim.cmd("CMakeGenerate")
			end,
		},
		{
			name = "Build",
			cmd = function()
				vim.cmd("CMakeBuild")
			end,
		},
		{
			name = "Run",
			cmd = function()
				vim.cmd("CMakeRun")
			end,
		},
		{
			name = "Debug",
			cmd = function()
				vim.cmd("CMakeDebug")
			end,
		},
		{
			name = "Run Tests (CTest)",
			cmd = function()
				vim.cmd("CMakeRunTest")
			end,
		},
		{
			name = "Select Build Target",
			cmd = function()
				vim.cmd("CMakeSelectBuildTarget")
			end,
		},
		{
			name = "Select Launch Target",
			cmd = function()
				vim.cmd("CMakeSelectLaunchTarget")
			end,
		},
		{
			name = "Select Build Type",
			cmd = function()
				vim.cmd("CMakeSelectBuildType")
			end,
		},
		{
			name = "Select Configure Preset",
			cmd = function()
				vim.cmd("CMakeSelectConfigurePreset")
			end,
		},
	}
end

local function debug_items()
	return {
		{ name = "Continue", cmd = dap_action("continue"), rtxt = "F5" },
		{ name = "Toggle Breakpoint", cmd = dap_action("toggle_breakpoint"), rtxt = "<leader>db" },
		{
			name = "Conditional Breakpoint",
			cmd = function()
				local ok, dap = pcall(require, "dap")
				if not ok then
					notify("DAP not available", vim.log.levels.WARN)
					return
				end
				vim.ui.input({ prompt = "Condition: " }, function(cond)
					if cond then
						dap.set_breakpoint(cond)
					end
				end)
			end,
		},
		{ name = "Run to Cursor", cmd = dap_action("run_to_cursor") },
		{ name = "Run Last", cmd = dap_action("run_last") },
		{ name = "Step Over", cmd = dap_action("step_over"), rtxt = "F10" },
		{ name = "Step Into", cmd = dap_action("step_into"), rtxt = "F11" },
		{ name = "Step Out", cmd = dap_action("step_out"), rtxt = "F12" },
		{ name = "Terminate", cmd = dap_action("terminate") },
		{ name = "Clear Breakpoints", cmd = dap_action("clear_breakpoints") },
		{ name = "Toggle DAP UI", cmd = dapui_action("toggle"), rtxt = "<leader>du" },
		{
			name = "Eval Expression",
			cmd = function()
				local ok, dapui = pcall(require, "dapui")
				if not ok then
					notify("DAP UI not available", vim.log.levels.WARN)
					return
				end
				dapui.eval()
			end,
		},
	}
end

local function devcontainer_items()
	return {
		{
			name = "Shell",
			cmd = function()
				vim.cmd("DevcontainerShell")
			end,
		},
		{
			name = "Toggle Mode",
			cmd = function()
				vim.cmd("DevcontainerMode")
			end,
		},
		{
			name = "Mode Status",
			cmd = function()
				vim.cmd("DevcontainerModeStatus")
			end,
		},
		{
			name = "Set Workspace",
			cmd = function()
				vim.cmd("DevcontainerWorkspace")
			end,
		},
	}
end

local function bookmark_items()
	return {
		{ name = "Add Bookmark", cmd = function() vim.cmd("BookmarksMark") end, rtxt = "<leader>ba" },
		{ name = "Bookmarks Tree", cmd = function() vim.cmd("BookmarksTree") end, rtxt = "<leader>bm" },
	}
end

local function log_highlight_items()
	return {
		{ name = "Add Highlight (exact)", cmd = log_hl_prompt("exact") },
		{ name = "Add Highlight (regex)", cmd = log_hl_prompt("regex") },
		{
			name = "Clear All Highlights",
			cmd = function()
				vim.cmd("LogHlClear")
			end,
		},
	}
end

local function view_items()
	return {
		{
			name = "Neo-tree Toggle",
			cmd = function()
				local ok = pcall(vim.cmd, "Neotree toggle")
				if not ok then
					pcall(vim.cmd, "Neotree")
				end
			end,
		},
		{
			name = "ToggleTerm",
			cmd = function()
				local ok = pcall(vim.cmd, "ToggleTerm")
				if not ok then
					notify("ToggleTerm not available", vim.log.levels.WARN)
				end
			end,
		},
		{ name = "Diagnostics", cmd = telescope_action("diagnostics") },
		{ name = "Fold Open All", cmd = function() vim.cmd("FoldOpenAll") end },
		{ name = "Fold Close All", cmd = function() vim.cmd("FoldCloseAll") end },
		{
			name = "Peek Fold",
			cmd = function()
				local ok, ufo = pcall(require, "ufo")
				if ok then
					ufo.peekFoldedLinesUnderCursor()
				else
					notify("nvim-ufo not available", vim.log.levels.WARN)
				end
			end,
		},
		{ name = "Toggle Wrap", cmd = function() toggle_window_option("wrap", "Wrap") end },
		{ name = "Toggle Spell", cmd = function() toggle_window_option("spell", "Spell") end },
		{ name = "Toggle Relative Number", cmd = function() toggle_window_option("relativenumber", "Relative number") end },
		{ name = "Toggle Paste", cmd = toggle_paste },
		{ name = "Reload Config", cmd = function() vim.cmd("ReloadConfig") end },
		{ name = "Mason", cmd = function() vim.cmd("Mason") end },
	}
end

-- ── Filetype-conditional items ───────────────────────────────────────────────

local filetype_items = {
	plantuml = function()
		return {
			{ name = "PlantUML ASCII", cmd = function() vim.cmd("PlantumlAscii") end },
			{ name = "PlantUML Preview", cmd = function() vim.cmd("PlantumlPreview") end },
		}
	end,
	json = function()
		return {
			{ name = "JSON Tree", cmd = function() vim.cmd("JsonTree") end },
			{
				name = "JQX Query",
				cmd = function()
					vim.ui.input({ prompt = "jq query: " }, function(q)
						if q and q ~= "" then
							vim.cmd("JqxQuery " .. q)
						end
					end)
				end,
			},
		}
	end,
	yaml = function()
		return {
			{ name = "YAML Outline", cmd = function() vim.cmd("YamlOutline") end },
		}
	end,
	xml = function()
		return {
			{ name = "XML Outline", cmd = function() vim.cmd("XmlOutline") end },
		}
	end,
	markdown = function()
		return {
			{ name = "Markdown Preview Toggle", cmd = function() vim.cmd("MarkdownPreviewToggle") end },
			{
				name = "Render Markdown Toggle",
				cmd = function()
					local ok, rm = pcall(require, "render-markdown")
					if ok then
						rm.toggle()
					else
						notify("render-markdown not available", vim.log.levels.WARN)
					end
				end,
			},
		}
	end,
}

local cmake_filetypes = { cmake = true, cpp = true, c = true }

-- ── Build full item list ─────────────────────────────────────────────────────

local function build_items()
	local ft = vim.bo.filetype
	local sections = {}

	-- Search / Replace
	table.insert(sections, { name = "Search / Replace", items = search_items() })

	-- Navigation
	table.insert(sections, { name = "Navigation", items = navigation_items() })

	-- LSP
	table.insert(sections, { name = "LSP", items = lsp_items() })

	-- Git
	table.insert(sections, { name = "Git", items = git_items() })

	-- Tests
	table.insert(sections, { name = "Tests", items = test_items() })

	-- CMake (only for relevant filetypes)
	if cmake_filetypes[ft] then
		table.insert(sections, { name = "CMake", items = cmake_items() })
	end

	-- Debug
	table.insert(sections, { name = "Debug", items = debug_items() })

	-- Format
	table.insert(sections, { name = "Format", items = format_items() })

	-- Bookmarks
	table.insert(sections, { name = "Bookmarks", items = bookmark_items() })

	-- Log Highlights
	table.insert(sections, { name = "Log Highlights", items = log_highlight_items() })

	-- Devcontainer
	table.insert(sections, { name = "Devcontainer", items = devcontainer_items() })

	-- Filetype-specific section
	if filetype_items[ft] then
		local ft_list = filetype_items[ft]()
		if #ft_list > 0 then
			table.insert(sections, { name = "File (" .. ft .. ")", items = ft_list })
		end
	end

	-- View / Utils
	table.insert(sections, { name = "View / Utils", items = view_items() })

	return sections
end

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function delete_old_menus()
	local ok, utils = pcall(require, "menu.utils")
	if ok and utils and utils.delete_old_menus then
		utils.delete_old_menus()
	end
end

local function reset_menu_config()
	local ok, state = pcall(require, "menu.state")
	if ok and state then
		state.config = nil
	end
end

-- ── Public API ───────────────────────────────────────────────────────────────

local function is_menu_open()
	local ok, mstate = pcall(require, "menu.state")
	return ok and mstate and #mstate.bufids > 0
end

function M.open()
	if is_menu_open() then
		delete_old_menus()
		return
	end

	local menu = ensure_menu()
	if not menu then
		return
	end

	reset_menu_config()
	menu.open(build_items(), { border = true })
end

function M.open_context()
	if is_menu_open() then
		delete_old_menus()
		return
	end

	local menu = ensure_menu()
	if not menu then
		return
	end

	if not is_visual_mode() then
		pcall(vim.cmd, "normal! \\<RightMouse>")
	end

	reset_menu_config()
	menu.open(build_items(), { mouse = true, border = true })
end

function M.setup()
	if vim.g.vscode then
		return
	end

	vim.keymap.set({ "n", "v" }, "<RightMouse>", function()
		M.open_context()
	end, { desc = "Open menu" })
end

return M
