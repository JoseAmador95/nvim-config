return {
	"akinsho/toggleterm.nvim",
	cmd = { "ToggleTerm", "TermExec" },
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>t", "<cmd>ToggleTerm<cr>", desc = "Toggle terminal" },
		{ "<leader>t", "<C-\\><C-n><cmd>ToggleTerm<cr>", mode = "t", desc = "Toggle terminal" },
	},
	config = function()
		require("toggleterm").setup({
			direction = "horizontal",
			start_in_insert = true,
			insert_mappings = true,
			terminal_mappings = true,
		})
	end,
}
