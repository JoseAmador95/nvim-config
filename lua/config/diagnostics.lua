local usage_map = require("config.usage").mapper("config.diagnostics")
local inline_diagnostics = require("config.inline_diagnostics")

vim.diagnostic.config({
	virtual_text = false,
	virtual_lines = false,
	severity_sort = true,
	float = {
		border = "rounded",
		source = "if_many",
	},
})
inline_diagnostics.setup()

if vim.g.vscode then
	return
end

-- Open diagnostics in a floating inline window
usage_map("n", "<leader>ld", function()
	vim.diagnostic.open_float({ border = "rounded", focusable = false })
end, { desc = "Show diagnostics in floating window" })

-- Jump to next diagnostic
usage_map("n", "]d", function()
	vim.diagnostic.jump({ count = 1 })
end, { desc = "Next diagnostic" })

-- Jump to previous diagnostic
usage_map("n", "[d", function()
	vim.diagnostic.jump({ count = -1 })
end, { desc = "Prev diagnostic" })

-- Populate location list with diagnostics
usage_map("n", "<leader>lq", vim.diagnostic.setloclist, {
	desc = "Send diagnostics to location list",
})
