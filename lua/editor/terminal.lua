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

local function toggle_log_wrap()
	vim.wo.wrap = not vim.wo.wrap
	vim.wo.linebreak = vim.wo.wrap
end

vim.api.nvim_create_user_command("CloseAll", function()
	vim.cmd("confirm qall")
end, { desc = "Close all with confirmation" })

vim.api.nvim_create_user_command("ToggleLogHighlight", toggle_log_highlight, {
	desc = "Toggle log highlighting",
})

vim.api.nvim_create_user_command("ToggleLogWrap", toggle_log_wrap, {
	desc = "Toggle log wrap",
})

vim.keymap.set("i", "jj", "<Esc>", {
	noremap = true,
	silent = true,
	desc = "Exit insert mode",
})

vim.keymap.set("n", "<leader>w", ":w!<CR>", {
	noremap = true,
	silent = true,
	desc = "Save",
})

vim.keymap.set("n", "<leader>q", ":q<CR>", {
	noremap = true,
	silent = true,
	desc = "Quit",
})

vim.keymap.set("n", "<leader>Q", "<cmd>CloseAll<cr>", {
	noremap = true,
	silent = true,
	desc = "Close all (confirm)",
})

vim.keymap.set("n", "<leader>lh", "<cmd>ToggleLogHighlight<cr>", {
	noremap = true,
	silent = true,
	desc = "Toggle log highlight",
})

vim.keymap.set("n", "<leader>lw", "<cmd>ToggleLogWrap<cr>", {
	noremap = true,
	silent = true,
	desc = "Toggle log wrap",
})

vim.keymap.set("n", "<leader>x", ":x<CR>", {
	noremap = true,
	silent = true,
	desc = "Save & quit",
})

vim.keymap.set("n", "J", "<Cmd>tabprevious<CR>", {
	noremap = true,
	silent = true,
	desc = "Previous tab",
})

vim.keymap.set("n", "K", "<Cmd>tabnext<CR>", {
	noremap = true,
	silent = true,
	desc = "Next tab",
})
