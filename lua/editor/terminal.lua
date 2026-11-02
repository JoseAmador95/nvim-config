local usage_map = require("config.usage").mapper("editor.terminal")
local function toggle_log_highlight()
	local bufnr = vim.api.nvim_get_current_buf()
	local ft = vim.bo[bufnr].filetype

	if ft == "log" then
		local prev = vim.b[bufnr].log_highlight_prev_ft or "text"
		vim.bo[bufnr].filetype = prev
		vim.b[bufnr].log_highlight_enabled = false
		return
	end

	vim.b[bufnr].log_highlight_prev_ft = ft
	vim.bo[bufnr].filetype = "log"
	vim.b[bufnr].log_highlight_enabled = true
end

vim.api.nvim_create_user_command("CloseAll", function()
	vim.cmd("confirm qall")
end, { desc = "Close all with confirmation" })

vim.api.nvim_create_user_command("ToggleLogHighlight", toggle_log_highlight, {
	desc = "Toggle log highlighting",
})

vim.api.nvim_create_user_command("ToggleWrap", function()
	local _, err = require("config.editor_actions").toggle_wrap()
	if err then
		vim.notify(err, vim.log.levels.ERROR, { title = "Editor" })
	end
end, {
	desc = "Toggle line wrap",
})

usage_map("i", "jj", "<Esc>", {
	noremap = true,
	silent = true,
	desc = "Exit insert mode",
})

usage_map("t", "jj", "<C-\\><C-n>", {
	noremap = true,
	silent = true,
	desc = "Exit terminal mode",
})

local pager = require("config.pager")

-- Saving and tab ownership make no sense over a read-only pager buffer.
if not pager.active then
	usage_map("n", "<leader>w", "<cmd>write<CR>", {
		noremap = true,
		silent = true,
		desc = "Save",
	})
	usage_map("n", "<leader>q", "<cmd>lua Snacks.bufdelete()<cr>", {
		noremap = true,
		silent = true,
		desc = "Close buffer",
	})
	require("config.tabs").setup()
	require("config.menu").setup()
else
	usage_map("n", "<leader>q", ":q<CR>", {
		noremap = true,
		silent = true,
		desc = "Quit",
	})
end

usage_map("n", "<leader>Q", "<cmd>CloseAll<cr>", {
	noremap = true,
	silent = true,
	desc = "Close all (confirm)",
})

usage_map("n", "<leader>lh", "<cmd>ToggleLogHighlight<cr>", {
	noremap = true,
	silent = true,
	desc = "Toggle log highlight",
})

usage_map("n", "<leader>lw", "<cmd>ToggleWrap<cr>", {
	noremap = true,
	silent = true,
	desc = "Toggle line wrap",
})

usage_map("n", "<leader>j", "<Cmd>tabprevious<CR>", {
	noremap = true,
	silent = true,
	desc = "Previous tab",
})

usage_map("n", "<leader>k", "<Cmd>tabnext<CR>", {
	noremap = true,
	silent = true,
	desc = "Next tab",
})
