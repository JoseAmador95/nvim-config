local M = {}

local HOME_VARIABLE = "nvim_config_home"
local TRANSIENT_TITLE_VARIABLE = "nvim_config_transient_title"
local pending = {}
local focused_windows = {}
local home_recovery_pending = false

local function enabled()
	local ok, pager = pcall(require, "config.pager")
	return not vim.g.vscode and not (ok and pager.active)
end

local function valid_tab(tabpage)
	return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function tab_number(tabpage)
	if not valid_tab(tabpage) then
		return nil
	end

	local ok, number = pcall(vim.api.nvim_tabpage_get_number, tabpage)
	return ok and number or nil
end

local function is_nonfloating_window(win, tabpage)
	if type(win) ~= "number" or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	if tabpage and vim.api.nvim_win_get_tabpage(win) ~= tabpage then
		return false
	end

	local ok, config = pcall(vim.api.nvim_win_get_config, win)
	return ok and (not config.relative or config.relative == "")
end

local function nonfloating_windows(tabpage)
	local windows = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if is_nonfloating_window(win, tabpage) then
			windows[#windows + 1] = win
		end
	end
	return windows
end

local function remember_current_window()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	if valid_tab(tabpage) and is_nonfloating_window(win, tabpage) then
		focused_windows[tabpage] = win
	end
end

local function focused_window(tabpage)
	local win = focused_windows[tabpage]
	if is_nonfloating_window(win, tabpage) then
		return win
	end

	win = nonfloating_windows(tabpage)[1]
	focused_windows[tabpage] = win
	return win
end

local function has_home_marker(tabpage)
	if not valid_tab(tabpage) then
		return false
	end

	local ok, value = pcall(vim.api.nvim_tabpage_get_var, tabpage, HOME_VARIABLE)
	return ok and value == true
end

local function home_window(tabpage)
	if not valid_tab(tabpage) then
		return nil
	end

	local windows = nonfloating_windows(tabpage)
	if #windows ~= 1 then
		return nil
	end
	return windows[1]
end

local function has_home_shape(tabpage)
	local win = home_window(tabpage)
	if not win then
		return false
	end
	if vim.wo[win].diff then
		return false
	end

	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
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

local function buffer_is_blank(buf)
	return vim.api.nvim_buf_line_count(buf) == 1 and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
end

local function notify_close_failure(message)
	vim.notify("Could not close tab: " .. tostring(message), vim.log.levels.ERROR, { title = "Tabs" })
end

local function close_handle(tabpage)
	local number = tab_number(tabpage)
	if not number then
		return false, "the tab no longer exists"
	end

	local ok, error_message = pcall(vim.api.nvim_cmd, {
		cmd = "tabclose",
		args = { tostring(number) },
	}, {})
	return ok, error_message
end

local function delete_owned_buffer(buf, owned)
	if
		not owned
		or not vim.api.nvim_buf_is_valid(buf)
		or vim.api.nvim_buf_get_name(buf) ~= ""
		or vim.bo[buf].modified
	then
		return
	end
	if #vim.fn.win_findbuf(buf) > 0 then
		return
	end
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function rollback_landing(landing, landing_buf, landing_buf_owned, restore)
	if valid_tab(restore) then
		pcall(vim.api.nvim_set_current_tabpage, restore)
	end
	if valid_tab(landing) then
		close_handle(landing)
	end
	delete_owned_buffer(landing_buf, landing_buf_owned)
	if valid_tab(restore) then
		pcall(vim.api.nvim_set_current_tabpage, restore)
	end
end

local function notify_dashboard_failure(message)
	vim.notify("Could not open home dashboard: " .. tostring(message), vim.log.levels.ERROR, { title = "Tabs" })
end

local function recover_home()
	local tabpages = vim.api.nvim_list_tabpages()
	if #tabpages ~= 1 then
		return
	end

	local tabpage = tabpages[1]
	if M.is_transient(tabpage) then
		return
	end
	local win = home_window(tabpage)
	if not win or vim.wo[win].diff then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= "" or vim.bo[buf].modified then
		return
	end

	local dashboard = vim.bo[buf].buftype == "nofile" and vim.bo[buf].filetype == "snacks_dashboard"
	local marked = has_home_marker(tabpage)
	local marked_landing = marked and vim.bo[buf].buftype == "" and vim.bo[buf].filetype == ""
	if not dashboard and not marked_landing then
		return
	end
	if dashboard and not buffer_is_blank(buf) then
		if not marked then
			M.mark_home(tabpage)
		end
		return
	end
	if not buffer_is_blank(buf) then
		return
	end

	local ok, snacks = pcall(require, "snacks")
	if not ok or type(snacks.dashboard) ~= "table" or type(snacks.dashboard.open) ~= "function" then
		notify_dashboard_failure(ok and "Snacks dashboard is unavailable" or snacks)
		return
	end
	local opened, error_message = pcall(snacks.dashboard.open, { buf = buf, win = win })
	if not opened then
		notify_dashboard_failure(error_message)
		return
	end
	M.mark_home(tabpage)
end

---Schedule one safe attempt to restore the sole home dashboard.
---Repeated requests coalesce until the scheduled attempt has run.
---@return boolean queued
function M.ensure_home()
	if not enabled() or home_recovery_pending then
		return false
	end

	home_recovery_pending = true
	vim.schedule(function()
		home_recovery_pending = false
		if enabled() then
			recover_home()
		end
	end)
	return true
end

---Whether a tab is the explicitly marked, still-pristine home landing page.
---@param tabpage integer
---@return boolean
function M.is_home(tabpage)
	return not M.is_transient(tabpage) and has_home_marker(tabpage) and has_home_shape(tabpage)
end

---Mark a pristine scratch tab as the home landing page.
---@param tabpage integer
---@return boolean
function M.mark_home(tabpage)
	if M.is_transient(tabpage) or not has_home_shape(tabpage) then
		return false
	end
	vim.api.nvim_tabpage_set_var(tabpage, HOME_VARIABLE, true)
	return true
end

---@param tabpage integer
function M.unmark_home(tabpage)
	if valid_tab(tabpage) then
		pcall(vim.api.nvim_tabpage_del_var, tabpage, HOME_VARIABLE)
	end
end

---Mark a tab as transient and give it a stable display title.
---@param tabpage integer
---@param title string
---@return boolean
function M.mark_transient(tabpage, title)
	if not valid_tab(tabpage) or type(title) ~= "string" or title == "" then
		return false
	end

	local ok = pcall(vim.api.nvim_tabpage_set_var, tabpage, TRANSIENT_TITLE_VARIABLE, title)
	return ok
end

---Remove a tab's transient marker.
---@param tabpage integer
function M.unmark_transient(tabpage)
	if valid_tab(tabpage) then
		pcall(vim.api.nvim_tabpage_del_var, tabpage, TRANSIENT_TITLE_VARIABLE)
	end
end

---Return the stable title for a transient tab.
---@param tabpage integer
---@return string?
function M.transient_title(tabpage)
	if not valid_tab(tabpage) then
		return nil
	end

	local ok, title = pcall(vim.api.nvim_tabpage_get_var, tabpage, TRANSIENT_TITLE_VARIABLE)
	return ok and type(title) == "string" and title ~= "" and title or nil
end

---Whether a tab is explicitly marked as transient.
---@param tabpage integer
---@return boolean
function M.is_transient(tabpage)
	return M.transient_title(tabpage) ~= nil
end

---@return integer?
function M.find_home()
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		if M.is_home(tabpage) then
			return tabpage
		end
	end
	return nil
end

---Keep a tab label on its last focused normal window while a UI float is active.
---The saved value is a window handle so buffer changes in that window stay live.
---@param item { name: string, tabnr: integer }
---@return string
function M.name_formatter(item)
	local fallback = type(item) == "table" and type(item.name) == "string" and item.name or "[No Name]"
	if type(item) ~= "table" or not valid_tab(item.tabnr) then
		return fallback
	end

	local transient_title = M.transient_title(item.tabnr)
	if transient_title then
		return transient_title
	end
	if not enabled() then
		return fallback
	end

	local active = vim.api.nvim_tabpage_get_win(item.tabnr)
	if is_nonfloating_window(active, item.tabnr) then
		focused_windows[item.tabnr] = active
		return item.name
	end

	local win = focused_window(item.tabnr)
	if not win then
		return fallback
	end

	local buf = vim.api.nvim_win_get_buf(win)
	local path = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
	return path ~= "" and vim.fn.fnamemodify(path, ":t") or "[No Name]"
end

---Close one stable tab handle without deleting any user buffer.
---@param tabpage? integer
---@return boolean
function M.close(tabpage)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	if not valid_tab(tabpage) then
		return false
	end

	if M.is_home(tabpage) and #vim.api.nvim_list_tabpages() == 1 then
		M.ensure_home()
		return true
	end

	if tabpage == vim.api.nvim_get_current_tabpage() then
		require("config.menu").dismiss()
	end

	local original = vim.api.nvim_get_current_tabpage()
	local landing
	local landing_buf
	local landing_buf_owned
	if #vim.api.nvim_list_tabpages() == 1 then
		local existing_buffers = {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			existing_buffers[buf] = true
		end
		local ok, error_message = pcall(vim.api.nvim_cmd, { cmd = "tabnew" }, {})
		if not ok then
			notify_close_failure(error_message)
			return false
		end

		landing = vim.api.nvim_get_current_tabpage()
		landing_buf = vim.api.nvim_get_current_buf()
		landing_buf_owned = not existing_buffers[landing_buf]
		if not M.mark_home(landing) then
			rollback_landing(landing, landing_buf, landing_buf_owned, original)
			notify_close_failure("could not create a clean home tab")
			return false
		end
	end

	local ok, error_message = close_handle(tabpage)
	if not ok then
		if landing then
			rollback_landing(landing, landing_buf, landing_buf_owned, original)
		elseif valid_tab(original) then
			pcall(vim.api.nvim_set_current_tabpage, original)
		end
		notify_close_failure(error_message)
		return false
	end

	local home = landing or M.find_home()
	if home then
		M.ensure_home()
	end
	return true
end

---Queue one close per stable handle. Bufferline can emit two mouse events before
---its tabline redraws; coalescing them prevents the second event closing a new tab.
---@param tabpage? integer
---@return boolean
function M.request_close(tabpage)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	if not valid_tab(tabpage) or pending[tabpage] then
		return false
	end

	pending[tabpage] = true
	vim.schedule(function()
		pending[tabpage] = nil
		if valid_tab(tabpage) then
			M.close(tabpage)
		end
	end)
	return true
end

function M.setup()
	if not enabled() then
		return
	end

	local focus_group = vim.api.nvim_create_augroup("NvimConfigTabsFocus", { clear = true })
	vim.api.nvim_create_autocmd({ "TabEnter", "WinEnter" }, {
		group = focus_group,
		desc = "Remember the last focused non-floating window for each tab label",
		callback = remember_current_window,
	})
	remember_current_window()

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
			local tabpage = vim.api.nvim_get_current_tabpage()
			if has_home_shape(tabpage) then
				M.mark_home(tabpage)
			end
		end,
	})
	if vim.v.vim_did_enter == 1 then
		M.ensure_home()
	end
end

return M
