local pager = require("config.pager")
local deferred = require("config.deferred")
local jqx_commands = require("config.jqx_commands")
local markdown_view = require("config.markdown_view")

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

local function warn_if_no_lsp(bufnr)
	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local clients = vim.lsp.get_clients({ bufnr = bufnr })
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
	if pager.active then
		if not markdown_view.pager_show_source(vim.api.nvim_get_current_win()) then
			notify("Could not access the pager source buffer", vim.log.levels.ERROR)
			return nil, "pager source buffer unavailable"
		end
		local stripped, strip_err = pager.strip_ansi(0)
		if not stripped then
			notify("Could not set filetype: " .. tostring(strip_err), vim.log.levels.ERROR)
			return nil, strip_err
		end
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		local scratch = next_scratch_name(ft)
		vim.api.nvim_cmd({ cmd = "file", args = { scratch } }, {})
	end

	if pager.active then
		-- :setfiletype does nothing once Markdown has already been detected.
		-- The pager picker and :SetFileType must both be able to reclassify
		-- the original source after leaving its rendered view.
		vim.bo[bufnr].filetype = ft
		-- FileType handlers may make paged content editable again.
		vim.bo[bufnr].modifiable = false
		vim.bo[bufnr].modified = false
	else
		vim.api.nvim_cmd({ cmd = "setfiletype", args = { ft } }, {})
	end

	-- No LSP in pager mode. The new filetype also decides whether the hidden
	-- source should gain a read-only rendered view.
	if not pager.active then
		warn_if_no_lsp(bufnr)
	else
		markdown_view.pager_filetype_changed(bufnr)
	end
	return true
end

if not pager.active then
	jqx_commands.setup()
	vim.api.nvim_create_user_command("JsonTree", function()
		if not ensure_filetype({ "json" }) then
			return
		end
		deferred.load("config.jqx").list()
	end, { desc = "JSON tree view" })
end

-- The menu backend and its public entry points belong only to the full terminal
-- editor profile. The pager never loads the plugin.
if not pager.active then
	vim.api.nvim_create_user_command("MenuOpen", function()
		local ok, menu = deferred.try("config.menu")
		if not ok then
			notify("Menu config not available", vim.log.levels.WARN)
			return
		end
		menu.open_palette()
	end, { desc = "Open action palette" })

	vim.keymap.set({ "n", "x" }, "<leader><leader>", "<cmd>MenuOpen<cr>", { desc = "Open action palette" })
end

vim.api.nvim_create_user_command("LogHlAdd", function(opts)
	deferred.load("config.log_patterns").add("exact", opts)
end, {
	nargs = "+",
	range = true,
	complete = function(arglead, cmdline)
		return deferred.load("config.log_patterns").complete_colors(arglead, cmdline)
	end,
	desc = "Add log highlight (exact)",
})

vim.api.nvim_create_user_command("LogHlRegex", function(opts)
	deferred.load("config.log_patterns").add("regex", opts)
end, {
	nargs = "+",
	range = true,
	complete = function(arglead, cmdline)
		return deferred.load("config.log_patterns").complete_colors(arglead, cmdline)
	end,
	desc = "Add log highlight (regex)",
})

vim.api.nvim_create_user_command("LogHlClear", function(opts)
	deferred.load("config.log_patterns").clear(opts)
end, {
	nargs = "?",
	complete = function(arglead, cmdline)
		return deferred.load("config.log_patterns").complete_colors(arglead, cmdline)
	end,
	desc = "Clear log highlights",
})

vim.api.nvim_create_user_command("LogWatchCurrentFile", function(opts)
	deferred.load("config.log_watch").command(opts)
end, {
	nargs = "?",
	complete = function()
		return deferred.load("config.log_watch").complete()
	end,
	desc = "Follow current log file live (read-only, toggles without argument)",
})

-- The terminal editor maps this only on Markdown sources; nvimpager maps it
-- globally because its rendered buffer has its own non-Markdown filetype.
markdown_view.setup()

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
