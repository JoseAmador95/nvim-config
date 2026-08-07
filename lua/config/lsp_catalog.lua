-- Single catalog for Mason installation and native vim.lsp enablement. This
-- module is intentionally free of Neovim runtime calls; callers provide the
-- small set of host-tool probes that affect installation/enablement.

local M = {}

M.servers = {
	{ name = "asm_lsp", mason = true },
	{ name = "bashls", mason = true },
	{ name = "clangd", mason = true },
	{
		name = "cmake",
		mason = function(context)
			return not context.has_cmake_language_server
		end,
	},
	{ name = "docker_language_server", mason = true },
	{ name = "gopls", mason = true },
	{ name = "jsonls", mason = true },
	{ name = "lemminx", mason = true },
	{ name = "lua_ls", mason = true },
	{ name = "marksman", mason = true },
	{ name = "pyright", mason = true },
	{ name = "ruff", mason = true },
	{
		name = "rust_analyzer",
		mason = function(context)
			return not context.has_rust_analyzer
		end,
	},
	{ name = "taplo", mason = true },
	{ name = "vtsls", mason = true },
	{ name = "yamlls", mason = true },
	{
		name = "plantuml_lsp",
		mason = false,
		enabled = function(context)
			return context.has_plantuml_lsp
		end,
	},
}

M.mason_tools = {
	"codelldb",
	"clang-format",
	"debugpy",
	"delve",
	"gofumpt",
	"goimports",
	"hadolint",
	"jq",
	"markdownlint-cli2",
	"prettierd",
	"shellcheck",
	"shfmt",
	"stylua",
}

local function selected(value, context, default)
	if value == nil then
		return default
	end
	if type(value) == "function" then
		return value(context)
	end
	return value
end

function M.ensure_installed(context)
	context = context or {}
	local names = {}
	for _, server in ipairs(M.servers) do
		if selected(server.mason, context, false) then
			names[#names + 1] = server.name
		end
	end
	return names
end

function M.enabled_servers(context)
	context = context or {}
	local names = {}
	for _, server in ipairs(M.servers) do
		if selected(server.enabled, context, true) then
			names[#names + 1] = server.name
		end
	end
	return names
end

return M
