return {
	{
		"gennaro-tedesco/nvim-jqx",
		cond = function()
			return not vim.g.vscode
		end,
		ft = { "json" },
		cmd = { "JqxList", "JqxQuery" },
	},
}
