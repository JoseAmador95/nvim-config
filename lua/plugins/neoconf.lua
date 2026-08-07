-- Per-project settings from .vscode/settings.json (and .neoconf.json),
-- merged into LSP server settings. Loaded as a dependency of mason-lspconfig
-- so setup() runs before any vim.lsp.enable(). config.lsp_neoconf uses the
-- public neoconf.get() API to gate startup in root_dir, merge settings before
-- initialization, and reapply them when neoconf live-reloads a project file.
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
