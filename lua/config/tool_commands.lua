-- Startup-light command registration. Installations are delegated to Mise.
local M = {}
local deferred = require("config.deferred")
local manifest = require("config.toolchain")

local registered = false

local function names()
	return vim.deepcopy(manifest.tool_order)
end

function M.setup()
	if registered or vim.fn.exists(":NvimConfigToolsInstall") == 2 then
		registered = true
		return true
	end
	vim.api.nvim_create_user_command("NvimConfigToolsInstall", function(options)
		deferred.load("config.tool_bootstrap").install(options.args == "" and "all" or options.args, options.bang)
	end, {
		nargs = "?",
		bang = true,
		complete = names,
		desc = "Install or reinstall locked Mise tools",
	})
	vim.api.nvim_create_user_command("NvimConfigMiseInstall", function()
		deferred.load("config.tool_bootstrap").install_mise()
	end, { desc = "Install pinned Mise into ~/.local/bin" })
	registered = true
	return true
end

return M
