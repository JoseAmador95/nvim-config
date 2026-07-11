local log_patterns = require("config.log_patterns")
local log_watch = require("config.log_watch")
local plantuml_ascii = require("config.plantuml_ascii")
local plantuml_preview = require("config.plantuml_preview")

log_patterns.setup()

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Viewer" })
end

local function ensure_filetype(allowed)
	local ft = vim.bo.filetype
	for _, value in ipairs(allowed) do
		if value == ft then
			return true
		end
	end

	notify("Command available only for: " .. table.concat(allowed, ", "), vim.log.levels.WARN)
	return false
end

local function lsp_has_method(method)
	local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
	return clients and #clients > 0
end

local function open_outline()
	if not lsp_has_method("textDocument/documentSymbol") then
		notify("LSP document symbols not available", vim.log.levels.WARN)
		return
	end

	local ok, snacks = pcall(require, "snacks")
	if ok then
		snacks.picker.lsp_symbols()
		return
	end

	vim.lsp.buf.document_symbol()
end

local function sanitize_suffix(ft)
	local safe = ft:gsub("[^%w%-_]", "-")
	if safe == "" then
		safe = "txt"
	end
	return safe
end

local function escape_pattern(text)
	return text:gsub("([^%w])", "%%%1")
end

local function next_scratch_name(ft)
	local suffix = sanitize_suffix(ft)
	local pat = "^scratch%-(%d+)%." .. escape_pattern(suffix) .. "$"
	local max_num = 0

	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" then
			local tail = vim.fn.fnamemodify(name, ":t")
			local num = tail:match(pat)
			if num then
				max_num = math.max(max_num, tonumber(num) or 0)
			end
		end
	end

	return string.format("scratch-%d.%s", max_num + 1, suffix)
end

local function try_lsp_start()
	-- Trigger FileType so Neovim 0.11+ native LSP handlers re-evaluate the buffer.
	vim.api.nvim_exec_autocmds("FileType", { buffer = 0 })
	vim.defer_fn(function()
		local clients = vim.lsp.get_clients({ bufnr = 0 })
		if not clients or #clients == 0 then
			notify("No LSP client started for this buffer", vim.log.levels.WARN)
		end
	end, 200)
end

local function set_filetype_with_scratch(ft)
	-- In pager mode the buffer often holds colored CLI output (gh, git, ...);
	-- strip the ANSI escapes first so the new filetype renders cleanly instead
	-- of showing the raw sequences as garbage. Guarded to pager mode so we never
	-- rewrite a real file buffer in normal nvim.
	local pager = require("config.pager")
	if pager.active then
		pager.strip_ansi(0)
	end

	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		local scratch = next_scratch_name(ft)
		vim.api.nvim_cmd({ cmd = "file", args = { scratch } }, {})
	end

	vim.api.nvim_cmd({ cmd = "setfiletype", args = { ft } }, {})

	-- No LSP in pager mode; setfiletype already fired FileType so render-markdown
	-- attaches. Skip the LSP-start probe (and its "no client" warning) there.
	if not pager.active then
		try_lsp_start()
	end
end

vim.api.nvim_create_user_command("JsonTree", function()
	if not ensure_filetype({ "json" }) then
		return
	end

	if vim.fn.executable("jq") ~= 1 then
		notify("jq not found in PATH", vim.log.levels.ERROR)
		return
	end

	vim.cmd("JqxList")
end, { desc = "JSON tree view" })

vim.api.nvim_create_user_command("MenuOpen", function()
	local ok, menu = pcall(require, "config.menu")
	if not ok then
		notify("Menu config not available", vim.log.levels.WARN)
		return
	end
	menu.open()
end, { desc = "Open menu" })

-- The menu plugin is not loaded in pager mode, so don't offer its keymap there.
if not require("config.pager").active then
	vim.keymap.set("n", "<leader><leader>", "<cmd>MenuOpen<cr>", { desc = "Open menu" })
end

vim.api.nvim_create_user_command("LogHlAdd", function(opts)
	log_patterns.add("exact", opts)
end, { nargs = "+", complete = log_patterns.complete_colors, desc = "Add log highlight (exact)" })

vim.api.nvim_create_user_command("LogHlRegex", function(opts)
	log_patterns.add("regex", opts)
end, { nargs = "+", complete = log_patterns.complete_colors, desc = "Add log highlight (regex)" })

vim.api.nvim_create_user_command("LogHlClear", function(opts)
	log_patterns.clear(opts)
end, { nargs = "?", complete = log_patterns.complete_colors, desc = "Clear log highlights" })

vim.api.nvim_create_user_command("LogWatchCurrentFile", function(opts)
	log_watch.command(opts)
end, {
	nargs = "?",
	complete = log_watch.complete,
	desc = "Follow current log file live (read-only, toggles without argument)",
})

vim.api.nvim_create_user_command("PlantumlAscii", function()
	plantuml_ascii.render()
end, { desc = "Render PlantUML ASCII preview" })

vim.api.nvim_create_user_command("PlantumlPreview", function()
	plantuml_preview.preview()
end, { desc = "Preview PlantUML diagram in browser" })

vim.api.nvim_create_user_command("YamlOutline", function()
	if not ensure_filetype({ "yaml" }) then
		return
	end
	open_outline()
end, { desc = "YAML document outline" })

vim.api.nvim_create_user_command("XmlOutline", function()
	if not ensure_filetype({ "xml" }) then
		return
	end
	open_outline()
end, { desc = "XML document outline" })

vim.api.nvim_create_user_command("FoldOpenAll", function()
	local ok, ufo = pcall(require, "ufo")
	if ok then
		ufo.openAllFolds()
		return
	end
	vim.cmd("normal! zR")
end, { desc = "Open all folds" })

vim.api.nvim_create_user_command("FoldCloseAll", function()
	local ok, ufo = pcall(require, "ufo")
	if ok then
		ufo.closeAllFolds()
		return
	end
	vim.cmd("normal! zM")
end, { desc = "Close all folds" })

vim.api.nvim_create_user_command("SetFileType", function(opts)
	local ft = vim.trim(opts.args or "")
	if ft == "" then
		notify("Filetype is required", vim.log.levels.WARN)
		return
	end

	set_filetype_with_scratch(ft)
end, { nargs = 1, complete = "filetype", desc = "Set filetype for buffer (with scratch name)" })

vim.api.nvim_create_user_command("SetFt", function(opts)
	local ft = vim.trim(opts.args or "")
	if ft == "" then
		notify("Filetype is required", vim.log.levels.WARN)
		return
	end

	set_filetype_with_scratch(ft)
end, { nargs = 1, complete = "filetype", desc = "Set filetype (alias)" })
