-- Single audited host boundary for LSP-owned first use. Server registration
-- stays cheap; project runtimes are resolved only while Neovim is preparing a
-- concrete client configuration.
local M = {}
local deferred = require("config.deferred")

function M.clangd_command()
	return deferred.load("config.clangd").command()
end

function M.clangd_on_new_config(config, root)
	return deferred.load("config.clangd").on_new_config(config, root)
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
