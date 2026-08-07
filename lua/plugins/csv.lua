return {
	{
		"cameron-wags/rainbow_csv.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = { "BufReadPre", "BufNewFile" },
		config = function()
			require("rainbow_csv").setup()
		end,
	},
}
