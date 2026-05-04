local M = {}

function M.open_entry_in_tab()
	local actions = require("spectre.actions") ---@diagnostic disable-line: missing-fields
	local entry = actions.get_current_entry() ---@diagnostic disable-line: undefined-field
	if not entry then
		return
	end

	---@diagnostic disable-next-line: undefined-field
	require("config.editor").open_file_in_tab(entry.filename, { lnum = entry.lnum, col = entry.col })
end

return M
