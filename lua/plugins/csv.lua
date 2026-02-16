return {
	{
		"cameron-wags/rainbow_csv.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		ft = { "csv", "tsv" },
		config = function()
			require("rainbow_csv").setup()
		end,
	},
}
