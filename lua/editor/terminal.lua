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

vim.keymap.set("n", "<leader>Q", ":q!<CR>", {
	noremap = true,
	silent = true,
	desc = "Force quit",
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
