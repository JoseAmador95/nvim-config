-- Single audited host boundary for LSP-owned first use. Server registration
-- stays cheap; project runtimes are resolved only while Neovim is preparing a
-- concrete client configuration.
local M = {}
local deferred = require("config.deferred")
local catalog = require("config.lsp_catalog")
local runtime = require("config.lsp_runtime")

local function binding(name)
	return assert(catalog.server(name), "unknown LSP server: " .. tostring(name))
end

function M.managed_command(name)
	local server = binding(name)
	assert(server.package and server.command, "LSP server is not manifest-backed: " .. name)
	return function(dispatchers, config)
		return runtime.managed_start(server, dispatchers, config)
	end
end

function M.rust_analyzer_command()
	local server = binding("rust_analyzer")
	return function(dispatchers, config)
		return runtime.external_rust_start(server, dispatchers, config)
	end
end

function M.clangd_rpc_start(dispatchers, config)
	return deferred.load("config.clangd").rpc_start(dispatchers, config)
end

function M.clangd_command()
	return M.clangd_rpc_start
end

function M.ty_root_dir(buf, on_dir)
	return deferred.load("config.python").lsp_root_dir(buf, on_dir)
end

function M.ty_before_init(params, config)
	return deferred.load("config.python").before_init(params, config)
end

function M.ty_on_new_config(config, root)
	return deferred.load("config.python").on_new_config(config, root)
end

return M
