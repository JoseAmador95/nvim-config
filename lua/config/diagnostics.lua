vim.diagnostic.config({
	virtual_text = {
		prefix = "●",
		spacing = 2,
	},
	severity_sort = true,
	float = {
		border = "rounded",
		source = "if_many",
	},
})

-- Open diagnostics in a floating inline window
vim.keymap.set("n", "<leader>ld", function()
	vim.diagnostic.open_float(nil, { border = "rounded", focusable = false })
end, { desc = "Show diagnostics in floating window" })

-- Jump to next diagnostic
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })

-- Jump to previous diagnostic
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Prev diagnostic" })

-- Show diagnostics for the current line
vim.keymap.set("n", "<leader>ll", function()
	vim.diagnostic.open_float({ scope = "line" })
end, { desc = "Line diagnostics" })

-- Show diagnostics for the current cursor position
vim.keymap.set("n", "<leader>lc", function()
	vim.diagnostic.open_float({ scope = "cursor" })
end, { desc = "Cursor diagnostics" })

-- Populate location list with diagnostics
vim.keymap.set("n", "<leader>lq", vim.diagnostic.setloclist, {
	desc = "Send diagnostics to location list",
})
