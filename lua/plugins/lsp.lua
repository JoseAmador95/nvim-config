-- Native Neovim 0.12 LSP setup. Installation is deliberately separate:
-- mason-lspconfig only supplies mappings/commands, mason-tool-installer owns
-- explicit manual sync, and config.tool_bootstrap owns the one-shot lifecycle.

local function offline()
	return vim.env.NVIM_CONFIG_OFFLINE == "1"
end

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

local function manual_mason_tools()
	if offline() then
		return {}
	end
	local toolchain = require("config.toolchain")
	local tools = {}
	for _, name in ipairs(toolchain.mason_order) do
		local entry = assert(toolchain.mason_entry(name), "missing Mason manifest entry: " .. name)
		tools[#tools + 1] = {
			name,
			version = entry.version,
			condition = require("config.tool_bootstrap").mason_condition(entry),
		}
	end
	return tools
end

return {
	{
		"mason-org/mason.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = "VeryLazy",
		cmd = { "Mason", "MasonInstall", "MasonUninstall", "MasonUninstallAll", "MasonUpdate", "MasonLog" },
		init = function()
			require("config.tool_bootstrap").setup()
		end,
		config = function()
			require("mason").setup({
				install_root_dir = require("config.tool_paths").mason_root(),
				PATH = "append",
			})
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

	{
		"WhoIsSethDaniel/mason-tool-installer.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "MasonToolsInstall", "MasonToolsInstallSync" },
		dependencies = { "mason-org/mason.nvim" },
		config = function()
			require("mason-tool-installer").setup({
				ensure_installed = manual_mason_tools(),
				auto_update = false,
				run_on_start = false,
				integrations = {
					["mason-lspconfig"] = false,
					["mason-null-ls"] = false,
					["mason-nvim-dap"] = false,
				},
			})
		end,
	},
}
