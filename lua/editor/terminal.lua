-- Fast saving and quitting
vim.api.nvim_set_keymap("n", "<leader>w", ":w!<CR>", {
	noremap = true,
	silent = true,
})
