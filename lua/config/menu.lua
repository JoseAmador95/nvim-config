local M = {}

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
		conform.format({ lsp_fallback = true })
		return
	end
	vim.lsp.buf.format()
end

local function telescope_action(action)
	return function()
		local ok, builtin = pcall(require, "telescope.builtin")
		if not ok or not builtin[action] then
			notify("Telescope action not available", vim.log.levels.WARN)
			return
		end
		builtin[action]()
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

	if vim.loop.os_uname().sysname == "Windows_NT" then
		path = vim.fn.substitute(path, "\\", "/", "g")
	end

	spectre.open({ path = path, is_insert_mode = true })
end

local function is_visual_mode()
	local mode = vim.fn.mode()
	return mode == "v" or mode == "V" or mode == "\22"
end

local function menu_items()
	local search_items = {
		{ name = "Spectre: Open", cmd = spectre_open_all },
		{ name = "Spectre: Search word", cmd = spectre_open_word },
	}

	if is_visual_mode() then
		table.insert(search_items, { name = "Spectre: Search selection", cmd = spectre_open_selection })
	end

	table.insert(search_items, { name = "Spectre: Search in file", cmd = spectre_open_file })
	table.insert(search_items, { name = "Live Grep", cmd = telescope_action("live_grep") })

	local navigation_items = {
		{ name = "Find Files", cmd = telescope_action("find_files") },
		{ name = "Buffers", cmd = telescope_action("buffers") },
		{ name = "Recent Files", cmd = telescope_action("oldfiles") },
		{ name = "Help Tags", cmd = telescope_action("help_tags") },
	}

	local lsp_items = {
		{ name = "Go to Definition", cmd = lsp_action("textDocument/definition", vim.lsp.buf.definition), rtxt = "gd" },
		{ name = "Go to Declaration", cmd = lsp_action("textDocument/declaration", vim.lsp.buf.declaration), rtxt = "gD" },
		{ name = "References", cmd = lsp_action("textDocument/references", vim.lsp.buf.references) },
		{ name = "Implementation", cmd = lsp_action("textDocument/implementation", vim.lsp.buf.implementation) },
		{ name = "Type Definition", cmd = lsp_action("textDocument/typeDefinition", vim.lsp.buf.type_definition) },
		{ name = "Rename", cmd = lsp_action("textDocument/rename", vim.lsp.buf.rename) },
		{ name = "Code Actions", cmd = lsp_action("textDocument/codeAction", vim.lsp.buf.code_action) },
		{ name = "Format", cmd = format_buffer },
	}

	local git_items = {
		{ name = "Preview Hunk", cmd = gitsigns_action("preview_hunk") },
		{ name = "Stage Hunk", cmd = gitsigns_action("stage_hunk") },
		{ name = "Undo Stage Hunk", cmd = gitsigns_action("undo_stage_hunk") },
		{ name = "Toggle Line Blame", cmd = gitsigns_action("toggle_current_line_blame") },
	}

	local view_items = {
		{ name = "Neo-tree Toggle", cmd = function()
			local ok = pcall(vim.cmd, "Neotree toggle")
			if not ok then
				pcall(vim.cmd, "Neotree")
			end
		end },
		{ name = "ToggleTerm", cmd = function()
			local ok = pcall(vim.cmd, "ToggleTerm")
			if not ok then
				notify("ToggleTerm not available", vim.log.levels.WARN)
			end
		end },
		{ name = "Diagnostics", cmd = telescope_action("diagnostics") },
		{ name = "JSON Tree", cmd = function() vim.cmd("JsonTree") end },
		{ name = "YAML Outline", cmd = function() vim.cmd("YamlOutline") end },
		{ name = "XML Outline", cmd = function() vim.cmd("XmlOutline") end },
		{ name = "Fold Open All", cmd = function() vim.cmd("FoldOpenAll") end },
		{ name = "Fold Close All", cmd = function() vim.cmd("FoldCloseAll") end },
		{ name = "Toggle Wrap", cmd = function() toggle_window_option("wrap", "Wrap") end },
		{ name = "Toggle Spell", cmd = function() toggle_window_option("spell", "Spell") end },
		{ name = "Toggle Relative Number", cmd = function() toggle_window_option("relativenumber", "Relative number") end },
		{ name = "Toggle Paste", cmd = toggle_paste },
	}

	return {
		{ name = "Search / Replace", items = search_items },
		{ name = "Navigation", items = navigation_items },
		{ name = "LSP", items = lsp_items },
		{ name = "Git", items = git_items },
		{ name = "View / Utils", items = view_items },
	}
end

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


function M.open()
	local menu = ensure_menu()
	if not menu then
		return
	end

	reset_menu_config()
	local items = menu_items()
	menu.open(items, { border = true })
end

function M.open_context()
	local menu = ensure_menu()
	if not menu then
		return
	end

	delete_old_menus()
	if not is_visual_mode() then
		pcall(vim.cmd, "normal! \\<RightMouse>")
	end

	reset_menu_config()
	local items = menu_items()
	menu.open(items, { mouse = true, border = true })
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
