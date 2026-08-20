local M = {}

local visual_modes = {
	v = true,
	V = true,
	["\22"] = true,
}

---Build the immutable context used to filter menu descriptors.
---@param values? { filetype?: string, mode?: string, visual?: boolean, buftype?: string, modifiable?: boolean, target?: table }
---@return { filetype: string, mode: string, visual: boolean, buftype: string, modifiable: boolean, target: table? }
function M.new(values)
	values = values or {}
	local mode = values.mode or "n"
	local visual = values.visual
	if visual == nil then
		visual = visual_modes[mode] == true
	end

	return {
		filetype = values.filetype or "",
		mode = mode,
		visual = visual,
		buftype = values.buftype or "",
		modifiable = values.modifiable ~= false,
		target = values.target and vim.deepcopy(values.target) or nil,
	}
end

---Capture the editor target before a picker or menu takes focus.
---@return table
function M.capture()
	local bufnr = vim.api.nvim_get_current_buf()
	local winid = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(winid)
	local mode = vim.fn.mode()
	local visual = visual_modes[mode] == true
	local target = {
		bufnr = bufnr,
		winid = winid,
		tabpage = vim.api.nvim_get_current_tabpage(),
		cursor = { line = cursor[1], col = cursor[2] },
		mode = mode,
		buftype = vim.bo[bufnr].buftype,
		modifiable = vim.bo[bufnr].modifiable,
	}

	if visual then
		local anchor = vim.fn.getpos("v")
		target.selection = {
			mode = mode,
			anchor = { line = anchor[2], col = math.max(anchor[3] - 1, 0) },
			cursor = vim.deepcopy(target.cursor),
		}
	end

	return M.new({
		filetype = vim.bo[bufnr].filetype,
		mode = mode,
		visual = visual,
		buftype = target.buftype,
		modifiable = target.modifiable,
		target = target,
	})
end

return M
