local M = {}

function M.open_entry_in_tab()
	local actions = require("spectre.actions")
	local entry = actions.get_current_entry()
	if not entry then
		return
	end

	require("config.editor").open_file_in_tab(entry.filename, { lnum = entry.lnum, col = entry.col })
end

return M
