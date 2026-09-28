-- Pure mapping between native Neovim server names and their executable source.
-- Exact Mason package versions and prerequisites live only in config.toolchain.

local M = {}

M.servers = {
	{ name = "bashls", package = "bash-language-server", command = "bash-language-server", args = { "start" } },
	{ name = "clangd", package = "clangd", command = "clangd" },
	{ name = "cmake", package = "cmake-language-server", command = "cmake-language-server" },
	{
		name = "docker_language_server",
		package = "docker-language-server",
		command = "docker-language-server",
		args = { "start", "--stdio" },
	},
	{ name = "jsonls", package = "json-lsp", command = "vscode-json-language-server", args = { "--stdio" } },
	{ name = "lemminx", package = "lemminx", command = "lemminx" },
	{ name = "lua_ls", package = "lua-language-server", command = "lua-language-server" },
	{ name = "marksman", package = "marksman", command = "marksman", args = { "server" } },
	{ name = "ruff", package = "ruff", command = "ruff", args = { "server" } },
	-- Rust intentionally remains a host/user tool. It is never resolved from
	-- Mason, and its lookup is deferred until the first Rust client starts.
	{ name = "rust_analyzer", external = "rust-analyzer", args = {} },
	{ name = "tombi", package = "tombi", command = "tombi", args = { "lsp" } },
	{ name = "ty", package = "ty", command = "ty", args = { "server" } },
	{ name = "vtsls", package = "vtsls", command = "vtsls", args = { "--stdio" } },
	{
		name = "yamlls",
		package = "yaml-language-server",
		command = "yaml-language-server",
		args = { "--stdio" },
	},
}

function M.server_names()
	local names = {}
	for _, server in ipairs(M.servers) do
		names[#names + 1] = server.name
	end
	return names
end

function M.enabled_servers()
	local names = {}
	for _, server in ipairs(M.servers) do
		names[#names + 1] = server.name
	end
	return names
end

function M.server(name)
	for _, server in ipairs(M.servers) do
		if server.name == name then
			return server
		end
	end
	return nil
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
