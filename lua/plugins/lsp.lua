-- Native Neovim 0.12 LSP setup. Mason decides what to install, while the
-- catalog and server modules decide what to configure and explicitly enable.

local function offline()
	return vim.env.NVIM_CONFIG_OFFLINE == "1"
end

local function host_context()
	local cmake_path = vim.fn.exepath("cmake-language-server")
	return {
		has_cmake_language_server = cmake_path ~= "",
		cmake_language_server_path = cmake_path,
		has_rust_analyzer = vim.fn.executable("rust-analyzer") == 1,
		has_plantuml_lsp = require("config.plantuml_lsp").available(),
	}
end

local function setup_mason_lsp(options)
	if not offline() then
		require("mason-lspconfig").setup(options)
		return
	end

	-- mason-lspconfig.setup() unconditionally refreshes the Mason registry. In
	-- offline validation, replace that one refresh with a successful no-op while
	-- still letting setup register its commands and other public APIs.
	options.ensure_installed = {}
	local registry = require("mason-registry")
	local original_refresh = registry.refresh
	registry.refresh = function(callback)
		vim.schedule(function()
			callback(true, {})
		end)
	end
	local ok, error_message = pcall(require("mason-lspconfig").setup, options)
	registry.refresh = original_refresh
	if not ok then
		error(error_message)
	end
end

return {
	{
		"mason-org/mason.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "Mason", "MasonInstall", "MasonUninstall", "MasonUninstallAll", "MasonUpdate", "MasonLog" },
		build = function()
			if not offline() then
				vim.cmd("MasonUpdate")
			end
		end,
		init = function()
			require("config.tool_installer").setup()
		end,
		config = function()
			require("mason").setup()
		end,
	},

	{
		"mason-org/mason-lspconfig.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = { "BufReadPre", "BufNewFile" },
		dependencies = {
			"saghen/blink.cmp",
			"b0o/SchemaStore.nvim",
			"folke/neoconf.nvim",
			"neovim/nvim-lspconfig",
		},
		init = function()
			require("config.plantuml_lsp").setup_install_command()
		end,
		config = function()
			local catalog = require("config.lsp_catalog")
			local context = host_context()
			local mason_lsp_options = {
				ensure_installed = catalog.ensure_installed(context),
				automatic_enable = false,
			}
			setup_mason_lsp(mason_lsp_options)

			require("config.lsp_navigation").setup()
			require("config.lsp_servers").setup(context)
			vim.lsp.enable(catalog.enabled_servers(context))
		end,
	},

	{
		"WhoIsSethDaniel/mason-tool-installer.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = "VeryLazy",
		dependencies = { "mason-org/mason.nvim" },
		config = function()
			local ensure_tools = offline() and {} or vim.deepcopy(require("config.lsp_catalog").mason_tools)
			require("mason-tool-installer").setup({
				ensure_installed = ensure_tools,
				run_on_start = not offline(),
			})
		end,
	},
}
