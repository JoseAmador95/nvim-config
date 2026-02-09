-- Common core deps used by many plugins
return {
	{ "nvim-lua/plenary.nvim", lazy = true },
	{
		"nvim-tree/nvim-web-devicons",
		cond = function()
			return not vim.g.vscode
		end,
		opts = {},
	},
	{
		"stevearc/resession.nvim",
		lazy = true,
		cond = function()
			return not vim.g.vscode
		end,
		opts = {},
	}, -- you referenced it via cokeline requires
}
