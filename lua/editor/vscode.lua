-- Map <leader>q to close the current VSCode editor
vim.keymap.set("n", "<leader>q", function()
	vim.fn.VSCodeCall("workbench.action.closeActiveEditor")
end, { noremap = true, silent = true })
