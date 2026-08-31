-- Native Neovim 0.12 LSP setup. verified-tools owns all installation;
-- mason-lspconfig only supplies package mappings and native LSP integration.

local function host_context()
	local rust_tools = require("config.rust_tools")
	return {
		cmake_language_server_path = vim.fn.exepath("cmake-language-server"),
		rust_analyzer_path = rust_tools.rust_analyzer(),
	}
end

local function setup_mason_lsp()
	local registry = require("mason-registry")
	local original_refresh = registry.refresh
	registry.refresh = function(callback)
		vim.schedule(function()
			callback(true, {})
		end)
	end
	local ok, error_message = pcall(require("mason-lspconfig").setup, {
		ensure_installed = {},
		automatic_enable = false,
	})
	registry.refresh = original_refresh
	if not ok then
		error(error_message)
	end
end

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
		event = "VeryLazy",
		cmd = { "Mason", "MasonLog" },
		init = function()
			require("config.tool_bootstrap").setup()
		end,
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
			require("config.tool_bootstrap").mason_ready()
		end,
	},

	{
		"mason-org/mason-lspconfig.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = { "BufReadPre", "BufNewFile" },
		dependencies = {
			"mason-org/mason.nvim",
			"saghen/blink.cmp",
			"b0o/SchemaStore.nvim",
			"folke/neoconf.nvim",
			"neovim/nvim-lspconfig",
		},
		config = function()
			setup_mason_lsp()

			local context = host_context()
			local catalog = require("config.lsp_catalog")
			require("config.lsp_navigation").setup()
			require("config.lsp_servers").setup(context)
			vim.lsp.enable(catalog.enabled_servers(function(executable)
				if executable == "rust-analyzer" then
					return context.rust_analyzer_path
				end
			end))
		end,
	},
}
