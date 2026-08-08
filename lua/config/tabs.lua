local M = {}

local HOME_VARIABLE = "nvim_config_home"
local pending = {}

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

local function nonfloating_windows(tabpage)
	local windows = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		local ok, config = pcall(vim.api.nvim_win_get_config, win)
		if ok and (not config.relative or config.relative == "") then
			windows[#windows + 1] = win
		end
	end
	return windows
end

local function has_home_marker(tabpage)
	if not valid_tab(tabpage) then
		return false
	end

	local ok, value = pcall(vim.api.nvim_tabpage_get_var, tabpage, HOME_VARIABLE)
	return ok and value == true
end

local function has_home_shape(tabpage)
	if not valid_tab(tabpage) then
		return false
	end

	local windows = nonfloating_windows(tabpage)
	if #windows ~= 1 then
		return false
	end

	local buf = vim.api.nvim_win_get_buf(windows[1])
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	return vim.bo[buf].buftype == ""
		and vim.api.nvim_buf_get_name(buf) == ""
		and not vim.bo[buf].modified
		and vim.api.nvim_buf_line_count(buf) == 1
		and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
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

local function open_menu_when_home_is_alone(home)
	vim.schedule(function()
		local tabs = vim.api.nvim_list_tabpages()
		if #tabs ~= 1 or tabs[1] ~= home or not M.is_home(home) then
			return
		end

		vim.api.nvim_set_current_tabpage(home)
		require("config.menu").ensure_open()
	end)
end

---Whether a tab is the explicitly marked, still-pristine home landing page.
---@param tabpage integer
---@return boolean
function M.is_home(tabpage)
	return has_home_marker(tabpage) and has_home_shape(tabpage)
end

---Mark a pristine scratch tab as the home landing page.
---@param tabpage integer
---@return boolean
function M.mark_home(tabpage)
	if not has_home_shape(tabpage) then
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

---@return integer?
function M.find_home()
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		if M.is_home(tabpage) then
			return tabpage
		end
	end
	return nil
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
		open_menu_when_home_is_alone(tabpage)
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
		open_menu_when_home_is_alone(home)
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

---@return table[]
function M.close_area()
	return {
		{
			text = "%@v:lua.NvimConfigCloseTab@ × %X",
			link = "BufferLineCloseButton",
		},
	}
end

function M.setup()
	if not enabled() then
		return
	end

	_G.NvimConfigCloseTab = function(_, clicks, button)
		if button ~= "l" or clicks ~= 1 then
			return
		end
		M.request_close(vim.api.nvim_get_current_tabpage())
	end

	vim.api.nvim_create_user_command("CloseTab", function()
		M.request_close(vim.api.nvim_get_current_tabpage())
	end, { force = true, desc = "Close tab and return home when it is the last work tab" })

	vim.keymap.set("n", "<leader>q", "<cmd>CloseTab<cr>", {
		noremap = true,
		silent = true,
		desc = "Close tab",
	})
end

return M
