return {
	{
		"Mofiqul/vscode.nvim",
		lazy = false,
		priority = 1000,
		cond = function()
			return not vim.g.vscode
		end,
		main = "config.theme",
		opts = {},
	},
}
