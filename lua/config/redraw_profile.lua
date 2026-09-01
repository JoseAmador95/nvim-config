local local_config = require("config.local_config")

local M = {}

local FULL = "full"
local LOW_BANDWIDTH = "low-bandwidth"

function M.configured()
	local ui = local_config.get("ui", {})
	return ui.redraw_profile or FULL
end

function M.current()
	if vim.g.vscode == true or vim.g.vscode == 1 or vim.env.NVIM_APPNAME == "nvimpager" then
		return FULL
	end
	return M.configured()
end

function M.low_bandwidth()
	return M.current() == LOW_BANDWIDTH
end

return M
