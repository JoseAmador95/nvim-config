return {
	{
		"gennaro-tedesco/nvim-jqx",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "JqxList", "JqxQuery" },
	},
}
