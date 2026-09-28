-- Native Neovim 0.12 LSP setup. verified-tools owns all installation. Mason's
-- UI and its compatibility bridge are deliberately outside the file-open
-- path: native lspconfig does not need either one to register these servers.

local function retire_mason_mutations()
	for _, name in ipairs({ "MasonInstall", "MasonUninstall", "MasonUninstallAll", "MasonUpdate" }) do
		pcall(vim.api.nvim_del_user_command, name)
	end
end

return {
	{
		"mason-org/mason.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "Mason", "MasonLog" },
		config = function()
			require("mason").setup({
				install_root_dir = require("config.tool_paths").mason_root(),
				PATH = "append",
				ui = {
					check_outdated_packages_on_open = false,
					keymaps = {
						install_package = "<Nop>",
						update_package = "<Nop>",
						check_package_version = "<Nop>",
						update_all_packages = "<Nop>",
						check_outdated_packages = "<Nop>",
						uninstall_package = "<Nop>",
						cancel_installation = "<Nop>",
					},
				},
			})
			retire_mason_mutations()
		end,
	},

	{
		"mason-org/mason-lspconfig.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		-- Retain the pinned upstream API for dependency contract checks, but do
		-- not put Mason or its registry into the normal LSP lifecycle.
		lazy = true,
		dependencies = {
			"mason-org/mason.nvim",
			"neovim/nvim-lspconfig",
		},
	},

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
