-- Pure mapping between native Neovim server names and Mason package names.
-- Exact package versions and prerequisites live only in config.toolchain.

local M = {}

M.servers = {
	{ name = "bashls", package = "bash-language-server" },
	{ name = "clangd", package = "clangd" },
	{ name = "cmake", package = "cmake-language-server" },
	{ name = "docker_language_server", package = "docker-language-server" },
	{ name = "gopls", package = "gopls" },
	{ name = "jsonls", package = "json-lsp" },
	{ name = "lemminx", package = "lemminx" },
	{ name = "lua_ls", package = "lua-language-server" },
	{ name = "marksman", package = "marksman" },
	{ name = "pyright", package = "pyright" },
	{ name = "ruff", package = "ruff" },
	{ name = "rust_analyzer", package = "rust-analyzer" },
	{ name = "taplo", package = "taplo" },
	{ name = "vtsls", package = "vtsls" },
	{ name = "yamlls", package = "yaml-language-server" },
}

function M.enabled_servers()
	local names = {}
	for _, server in ipairs(M.servers) do
		names[#names + 1] = server.name
	end
	return names
end

function M.mason_package(server_name)
	for _, server in ipairs(M.servers) do
		if server.name == server_name then
			return server.package
		end
	end
	return nil
end

return M
