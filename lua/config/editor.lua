local M = {}

local SPECIAL_FILETYPES = {
	["neo-tree"] = true,
	["spectre_panel"] = true,
	["toggleterm"] = true,
	["terminal"] = true,
	["quickfix"] = true,
	["help"] = true,
	["qf"] = true,
	["NvimTree"] = true,
	["BookmarksTree"] = true,
	["aerial"] = true,
	["outline"] = true,
}

local function is_special_buffer(buf)
	local ft = vim.bo[buf].filetype
	local name = vim.api.nvim_buf_get_name(buf)
	return SPECIAL_FILETYPES[ft] or name == ""
end

local function set_cursor_position(buf, win, lnum, col)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(lnum, line_count))
	local line = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ""
	local target_col = math.max(0, math.min(col - 1, #line))
	vim.api.nvim_win_set_cursor(win, { target_line, target_col })
end

function M.open_file_in_tab(filepath, opts)
	opts = opts or {}
	local lnum = tonumber(opts.lnum) or 1
	local col = tonumber(opts.col) or 1

	filepath = vim.fn.fnamemodify(filepath, ":p")

	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		local win = vim.api.nvim_tabpage_get_win(tabpage)
		local buf = vim.api.nvim_win_get_buf(win)
		if not is_special_buffer(buf) then
			local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
			if name == filepath then
				vim.api.nvim_set_current_tabpage(tabpage)
				set_cursor_position(buf, win, lnum, col)
				return
			end
		end
	end

	vim.cmd("tabedit " .. vim.fn.fnameescape(filepath))
	set_cursor_position(0, 0, lnum, col)
end

return M
