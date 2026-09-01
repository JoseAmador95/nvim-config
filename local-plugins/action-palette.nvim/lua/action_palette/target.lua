local schema = require("action_palette.schema")

local M = {}

---@return table ActionTarget
function M.capture()
	local winid = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_win_get_buf(winid)
	local cursor = vim.api.nvim_win_get_cursor(winid)
	return {
		bufnr = bufnr,
		winid = winid,
		tabpage = vim.api.nvim_win_get_tabpage(winid),
		cursor = { line = cursor[1], col = cursor[2] },
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
	}
end

---@param value table
---@return table? target
---@return string? error_message
function M.revalidate(value, mode)
	mode = mode or "exact"
	if mode == "none" then
		return nil
	end
	if mode ~= "exact" and mode ~= "buffer" and mode ~= "window" then
		return nil, "Unknown action target mode: " .. tostring(mode)
	end
	local target, target_err = schema.action_target(value)
	if not target then
		return nil, target_err
	end
	if not vim.api.nvim_buf_is_valid(target.bufnr) then
		return nil, "Origin buffer is no longer available"
	end
	if mode == "buffer" then
		return target
	end
	if not vim.api.nvim_win_is_valid(target.winid) then
		return nil, "Origin window is no longer available"
	end
	if not vim.api.nvim_tabpage_is_valid(target.tabpage) then
		return nil, "Origin tab is no longer available"
	end
	if vim.api.nvim_win_get_tabpage(target.winid) ~= target.tabpage then
		return nil, "Origin window moved to another tab"
	end
	if vim.api.nvim_win_get_buf(target.winid) ~= target.bufnr then
		return nil, "Origin window no longer displays the captured buffer"
	end
	if mode == "window" then
		return target
	end
	if vim.api.nvim_buf_get_changedtick(target.bufnr) ~= target.changedtick then
		return nil, "Origin buffer changed after the action was captured"
	end
	local cursor = vim.api.nvim_win_get_cursor(target.winid)
	if cursor[1] ~= target.cursor.line or cursor[2] ~= target.cursor.col then
		return nil, "Origin cursor changed after the action was captured"
	end
	return target
end

return M
