-- Per-project settings from .vscode/settings.json (and .neoconf.json),
-- merged into LSP server settings. Loaded as a dependency of mason-lspconfig
-- (lsp.lua) so setup() runs before any vim.lsp.enable(); the actual merge is
-- wired there via a wildcard vim.lsp.config("*") before_init, because
-- neoconf's built-in integration only hooks the legacy lspconfig framework.
return {
	"folke/neoconf.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		import = {
			vscode = true,
			coc = false,
			nlsp = false,
		},
	},
}
