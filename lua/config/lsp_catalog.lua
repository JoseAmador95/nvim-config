-- Pure mapping between native Neovim server names and their executable source.
-- Exact Mason package versions and prerequisites live only in config.toolchain.

local M = {}

M.servers = {
	{ name = "bashls", package = "bash-language-server" },
	{ name = "clangd", package = "clangd" },
	{ name = "cmake", package = "cmake-language-server" },
	{ name = "docker_language_server", package = "docker-language-server" },
	{ name = "jsonls", package = "json-lsp" },
	{ name = "lemminx", package = "lemminx" },
	{ name = "lua_ls", package = "lua-language-server" },
	{ name = "marksman", package = "marksman" },
	{ name = "ruff", package = "ruff" },
	{ name = "rust_analyzer", external = "rust-analyzer" },
	{ name = "tombi", package = "tombi" },
	{ name = "ty", package = "ty" },
	{ name = "vtsls", package = "vtsls" },
	{ name = "yamlls", package = "yaml-language-server" },
}

function M.server_names()
	local names = {}
	for _, server in ipairs(M.servers) do
		names[#names + 1] = server.name
	end
	return names
end

-- External servers are enabled only when the caller proves that the executable
-- comes from a host/user path. This keeps Rust editing available without ever
-- falling through to the managed or Mason roots.
function M.enabled_servers(resolve_external)
	local names = {}
	for _, server in ipairs(M.servers) do
		if not server.external or (resolve_external and resolve_external(server.external)) then
			names[#names + 1] = server.name
		end
	end
	return names
end

function M.mason_packages()
	local names = {}
	for _, server in ipairs(M.servers) do
		if server.package then
			names[#names + 1] = server.package
		end
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
