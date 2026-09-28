local M = {}

local visual_modes = {
	v = true,
	V = true,
	["\22"] = true,
}

---Build the immutable context used to filter menu descriptors.
---@param values? { filetype?: string, mode?: string, visual?: boolean, buftype?: string, modifiable?: boolean, target?: table, selection?: table, path?: string, cwd?: string, git_root?: string }
---@return { filetype: string, mode: string, visual: boolean, buftype: string, modifiable: boolean, target: table?, selection: table?, path: string?, cwd: string?, git_root: string? }
function M.new(values)
	values = values or {}
	local mode = values.mode or "n"
	local visual = values.visual
	if visual == nil then
		visual = visual_modes[mode] == true
	end

	local context = {
		filetype = values.filetype or "",
		mode = mode,
		visual = visual,
		buftype = values.buftype or "",
		modifiable = values.modifiable ~= false,
		target = values.target and vim.deepcopy(values.target) or nil,
		selection = values.selection and vim.deepcopy(values.selection) or nil,
	}
	for _, name in ipairs({ "path", "cwd", "git_root" }) do
		if type(values[name]) == "string" and values[name] ~= "" then
			context[name] = values[name]
		end
	end
	return context
end

local function file_metadata(bufnr)
	local buftype = vim.bo[bufnr].buftype
	if buftype ~= "" then
		return buftype
	end
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return buftype
	end
	return buftype, path, vim.fs.root(path, ".git")
end

local function window_cwd(winid)
	local ok, cwd = pcall(vim.fn.getcwd, winid)
	return ok and cwd or nil
end

---Capture the editor target before a picker or menu takes focus.
---@return table
function M.capture()
	local target = require("config.action_palette").capture_target()
	local bufnr = target.bufnr
	local mode = vim.fn.mode()
	local visual = visual_modes[mode] == true
	local selection
	local buftype, path, git_root = file_metadata(bufnr)

	if visual then
		local anchor = vim.fn.getpos("v")
		selection = {
			mode = mode,
			anchor = { line = anchor[2], col = math.max(anchor[3] - 1, 0) },
			cursor = vim.deepcopy(target.cursor),
		}
	end

	return M.new({
		filetype = vim.bo[bufnr].filetype,
		mode = mode,
		visual = visual,
		buftype = buftype,
		modifiable = vim.bo[bufnr].modifiable,
		target = target,
		selection = selection,
		path = path,
		cwd = window_cwd(target.winid),
		git_root = git_root,
	})
end

---Refresh availability fields from the revalidated origin without recapturing
---picker-owned mode or selection state.
---@param context table
---@param target table
---@return table
function M.refresh(context, target)
	local buftype, path, git_root = file_metadata(target.bufnr)
	return M.new({
		filetype = vim.bo[target.bufnr].filetype,
		mode = context.mode,
		visual = context.visual,
		buftype = buftype,
		modifiable = vim.bo[target.bufnr].modifiable,
		target = target,
		selection = context.selection,
		path = path,
		cwd = context.cwd or window_cwd(target.winid),
		git_root = git_root,
	})
end

return M
