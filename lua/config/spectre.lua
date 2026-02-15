local M = {}

function M.open_entry_in_tab()
	local actions = require("spectre.actions")
	local entry = actions.get_current_entry()
	if not entry then
		return
	end

	vim.cmd("tabnew " .. vim.fn.fnameescape(entry.filename))
	pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, entry.col })
end

return M
