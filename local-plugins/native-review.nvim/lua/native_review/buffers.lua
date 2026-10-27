-- Buffer bytes and window-scoped decorations shared by review surfaces.
local M = {}

function M.text(buf)
	local separator = ({ dos = "\r\n", mac = "\r" })[vim.bo[buf].fileformat] or "\n"
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), separator)
	return vim.bo[buf].endofline and text .. separator or text
end

function M.scope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		return pcall(vim.api.nvim_win_add_ns, win, namespace)
	end
	if type(vim.api.nvim__ns_set) == "function" then
		return pcall(vim.api.nvim__ns_set, namespace, { wins = { win } })
	end
	return false, "window-scoped namespaces are unavailable"
end

function M.unscope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		if type(win) == "number" and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_remove_ns, win, namespace)
		end
	elseif type(vim.api.nvim__ns_set) == "function" then
		pcall(vim.api.nvim__ns_set, namespace, { wins = {} })
	end
end

return M
