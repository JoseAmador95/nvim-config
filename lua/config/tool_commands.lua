-- Lightweight host surface for verified-tools.nvim. The lifecycle engine is
-- loaded only after an explicit install/repair command is invoked.
local M = {}
local deferred = require("config.deferred")
local manifest = require("config.toolchain")

local registered = false

local function names()
	local result = vim.deepcopy(manifest.managed_order or {})
	vim.list_extend(result, manifest.mason_order or {})
	return result
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
		desc = "Install or repair exact verified tools",
	})
	registered = true
	return true
end

return M
