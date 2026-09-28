-- :checkhealth localconfig -- reports which local config files loaded and any
-- schema validation issues. See lua/config/local_config.lua.

local M = {}

local health = vim.health

function M.check()
	health.start("Local config (.nvim-local.lua)")

	local lc = package.loaded["config.local_config"]
	if type(lc) ~= "table" or type(lc.observation) ~= "function" then
		health.info("local config runtime state is not loaded; health did not activate it")
		return
	end
	local ok, observed = pcall(lc.observation)
	if not ok or type(observed) ~= "table" then
		health.error("could not observe local config runtime state: " .. tostring(observed))
		return
	end
	if not observed.evaluated then
		health.info("local config has not been evaluated; health did not read or trust project configuration")
		return
	end

	local sources = type(observed.sources) == "table" and observed.sources or {}
	for index, s in ipairs(sources) do
		if s.status == "loaded" then
			health.ok(s.path .. " loaded")
			if index == 1 then
				local stat = vim.uv.fs_lstat(s.path)
				local mode = stat and bit.band(stat.mode or 0, tonumber("777", 8)) or nil
				if not stat or stat.type ~= "file" or stat.nlink ~= 1 then
					health.error(s.path .. " must be one owner-controlled regular file")
				elseif mode == tonumber("600", 8) then
					health.ok(s.path .. " is owner-only (0600)")
				else
					health.error(("%s mode is %03o, expected 600"):format(s.path, mode or 0))
				end
			end
		elseif s.status == "absent" then
			health.info(s.path .. " (absent)")
		elseif s.status == "untrusted" then
			health.warn(s.path .. " present but not trusted (declined)")
		else
			health.error(s.path .. " failed to load (" .. s.status .. ")")
		end
	end

	local errors = type(observed.errors) == "table" and observed.errors or {}
	if #errors == 0 then
		health.ok("no validation errors")
	else
		for _, e in ipairs(errors) do
			health.error(e)
		end
	end
end

return M
