local M = {}
local runtime = require("tab_first")
local local_config = require("config.local_config")
local code_review = require("config.code_review")

local SPECIAL_FILETYPES = {
	oil = true,
	["grug-far"] = true,
	snacks_terminal = true,
	terminal = true,
	quickfix = true,
	help = true,
	qf = true,
	NvimTree = true,
	aerial = true,
}

local NEW_FILE_WINDOW_OPTIONS = {
	"colorcolumn",
	"cursorcolumn",
	"cursorline",
	"foldmethod",
	"list",
	"number",
	"relativenumber",
	"sidescrolloff",
	"signcolumn",
	"spell",
	"statuscolumn",
	"statusline",
	"winbar",
	"winhighlight",
	"wrap",
}

local function enabled()
	local ok, pager = pcall(require, "config.pager")
	return not vim.g.vscode and not (ok and pager.active)
end

local function present_home(context)
	local snacks = require("snacks")
	if type(snacks.dashboard) ~= "table" or type(snacks.dashboard.open) ~= "function" then
		error("Snacks dashboard is unavailable")
	end
	snacks.dashboard.open({ buf = context.buf, win = context.win })
end

local function dismiss_ui()
	return require("config.menu").dismiss()
end

local function is_special_buffer(buf)
	return SPECIAL_FILETYPES[vim.bo[buf].filetype] or vim.api.nvim_buf_get_name(buf) == ""
end

local function is_home_buffer(buf)
	if vim.bo[buf].filetype == "snacks_dashboard" then
		return vim.bo[buf].buftype == "nofile" and vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
	end
	return vim.bo[buf].buftype == ""
		and vim.bo[buf].filetype == ""
		and vim.api.nvim_buf_get_name(buf) == ""
		and not vim.bo[buf].modified
		and vim.api.nvim_buf_line_count(buf) == 1
		and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
end

local function native_history_fallback(direction, count)
	local key = direction < 0 and "<C-o>" or "<C-i>"
	vim.api.nvim_feedkeys(tostring(count or 1) .. vim.keycode(key), "nx", false)
end

local configured = local_config.plugin("tab_first", {
	history = { enabled = true, max_entries = 200, scope = "workspace" },
})

runtime.setup({
	enabled = enabled,
	present_home = present_home,
	dismiss_ui = dismiss_ui,
	is_special_buffer = is_special_buffer,
	is_home_buffer = is_home_buffer,
	notify = function(message, level, opts)
		vim.notify(message, level, opts)
	end,
	history = {
		enabled = configured.history.enabled,
		max_entries = configured.history.max_entries,
		scope = configured.history.scope,
		native_fallback = native_history_fallback,
		capture_location = code_review.capture_location,
		restore_location = code_review.restore_location,
		open_location = function(entry)
			require("config.editor").open_file_in_tab(entry.path, {
				lnum = entry.lnum,
				col = entry.col,
				record_history = false,
			})
			return true
		end,
	},
})

for _, name in ipairs({
	"ensure_home",
	"recover_home",
	"is_home",
	"mark_home",
	"unmark_home",
	"mark_transient",
	"unmark_transient",
	"transient_title",
	"is_transient",
	"find_home",
	"name_formatter",
	"close",
	"request_close",
	"acquire_transient",
	"focus_transient",
	"rename_transient",
	"release_transient",
	"valid_transient",
}) do
	M[name] = function(...)
		return runtime[name](...)
	end
end

---Create one unnamed normal buffer without inheriting transient window styling.
---@return table
function M.new_file()
	local tabpage = vim.api.nvim_get_current_tabpage()
	vim.api.nvim_cmd({ cmd = "enew" }, {})
	local winid = vim.api.nvim_get_current_win()
	for _, name in ipairs(NEW_FILE_WINDOW_OPTIONS) do
		vim.api.nvim_set_option_value(name, nil, { scope = "local", win = winid })
	end
	M.unmark_home(tabpage)
	return { tabpage = tabpage, winid = winid, bufnr = vim.api.nvim_get_current_buf() }
end

function M.setup()
	if not enabled() then
		return
	end

	local focus_group = vim.api.nvim_create_augroup("NvimConfigTabsFocus", { clear = true })
	vim.api.nvim_create_autocmd({ "TabEnter", "WinEnter" }, {
		group = focus_group,
		desc = "Remember the last focused non-floating window for each tab label",
		callback = runtime.remember_current_window,
	})
	runtime.remember_current_window()

	vim.api.nvim_create_user_command("CloseTab", function()
		M.request_close(vim.api.nvim_get_current_tabpage())
	end, { force = true, desc = "Close tab and return home when it is the last work tab" })

	vim.keymap.set("n", "<leader>q", "<cmd>CloseTab<cr>", {
		noremap = true,
		silent = true,
		desc = "Close tab",
	})

	local home_group = vim.api.nvim_create_augroup("NvimConfigTabsHome", { clear = true })
	vim.api.nvim_create_autocmd("UIEnter", {
		group = home_group,
		once = true,
		desc = "Recover a dashboard restored without its Snacks instance",
		callback = M.ensure_home,
	})
	vim.api.nvim_create_autocmd("User", {
		pattern = "SnacksDashboardOpened",
		group = home_group,
		desc = "Mark an in-place Snacks dashboard as the reusable home tab",
		callback = function()
			M.mark_home(vim.api.nvim_get_current_tabpage())
		end,
	})
	if vim.v.vim_did_enter == 1 then
		M.ensure_home()
	end
end

return M
