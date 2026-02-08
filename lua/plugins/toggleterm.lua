return {
	"akinsho/toggleterm.nvim",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	config = function()
		require("toggleterm").setup({
			open_mapping = [[<leader>t]],
			direction = "horizontal",
			start_in_insert = true,
			insert_mappings = true,
			terminal_mappings = true,
		})
	end,
}
