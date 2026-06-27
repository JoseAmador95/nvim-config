-- lua/config/obsidian_vaults.lua
-- Thin wrapper over config.local_config: returns the Obsidian vault list with
-- paths expanded. The file format lives in lua/config/local_config.lua.

local M = {}

function M.read()
	local entries = require("config.local_config").get("obsidian", {})
	local vaults = {}
	for _, e in ipairs(entries) do
		if e.name and e.path and e.name ~= "" and e.path ~= "" then
			vaults[#vaults + 1] = {
				name = e.name,
				path = vim.fn.expand(e.path),
			}
		end
	end
	return vaults
end

return M
