return {
	{
		"nvzone/volt",
		name = "volt",
		cond = function()
			return not vim.g.vscode
		end,
		lazy = true,
	},
	{
		"nvzone/menu",
		name = "menu",
		cond = function()
			return not vim.g.vscode
		end,
		lazy = true,
		dependencies = { "volt" },
		init = function()
			require("config.menu").setup()
		end,
	},
}
