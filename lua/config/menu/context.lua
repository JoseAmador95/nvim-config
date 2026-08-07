local M = {}

local visual_modes = {
	v = true,
	V = true,
	["\22"] = true,
}

---Build the immutable context used to filter menu descriptors.
---@param values? { filetype?: string, mode?: string, visual?: boolean }
---@return { filetype: string, mode: string, visual: boolean }
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
	}
end

return M
