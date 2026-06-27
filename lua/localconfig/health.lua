-- :checkhealth localconfig -- reports which local config files loaded and any
-- schema validation issues. See lua/config/local_config.lua.

local M = {}

local health = vim.health

function M.check()
	health.start("Local config (.nvim-local.lua)")

	local ok, lc = pcall(require, "config.local_config")
	if not ok then
		health.error("config.local_config module failed to load: " .. tostring(lc))
		return
	end

	for _, s in ipairs(lc.sources()) do
		if s.status == "loaded" then
			health.ok(s.path .. " loaded")
		elseif s.status == "absent" then
			health.info(s.path .. " (absent)")
		elseif s.status == "untrusted" then
			health.warn(s.path .. " present but not trusted (declined)")
		else
			health.error(s.path .. " failed to load (" .. s.status .. ")")
		end
	end

	local errors = lc.errors()
	if #errors == 0 then
		health.ok("no validation errors")
	else
		for _, e in ipairs(errors) do
			health.error(e)
		end
	end
end

return M
