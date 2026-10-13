-- Native Neovim LSP registration; Mise supplies the executable tools.
return {
	{
		"neovim/nvim-lspconfig",
		cond = function()
			return not vim.g.vscode
		end,
		event = { "BufReadPre", "BufNewFile" },
		dependencies = {
			"saghen/blink.cmp",
			"b0o/SchemaStore.nvim",
			"folke/neoconf.nvim",
		},
		config = function()
			local catalog = require("config.lsp_catalog")
			require("config.lsp_navigation").setup()
			require("config.lsp_servers").setup()
			vim.lsp.enable(catalog.enabled_servers())
		end,
	},
}
