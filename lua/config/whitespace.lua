-- Trailing-whitespace policy and view-preserving cleanup.
local M = {}

local semantic_filetypes = {
	markdown = true,
	["markdown.mdx"] = true,
	mdx = true,
	gitcommit = true,
	gitrebase = true,
	diff = true,
	patch = true,
	mail = true,
	email = true,
}

local function save_views(buf)
	local views = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local ok, view = pcall(vim.api.nvim_win_call, win, function()
			return vim.fn.winsaveview()
		end)
		if ok then
			views[win] = view
		end
	end
	return views
end

local function restore_views(buf, views)
	for win, view in pairs(views) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			pcall(vim.api.nvim_win_call, win, function()
				vim.fn.winrestview(view)
			end)
		end
	end
end

---Remove incidental trailing whitespace without disturbing any window view.
---@param buf integer
---@return boolean changed_or_attempted
function M.trim(buf)
	if
		not vim.api.nvim_buf_is_valid(buf)
		or vim.bo[buf].buftype ~= ""
		or not vim.bo[buf].modifiable
		or vim.b[buf].trim_trailing_whitespace == false
		or semantic_filetypes[vim.bo[buf].filetype]
	then
		return false
	end

	local views = save_views(buf)
	vim.api.nvim_buf_call(buf, function()
		vim.cmd([[silent keepjumps keeppatterns %s/\s\+$//e]])
	end)
	restore_views(buf, views)
	return true
end

function M.setup()
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = vim.api.nvim_create_augroup("trim_whitespace", { clear = true }),
		callback = function(event)
			M.trim(event.buf)
		end,
	})
end

return M
