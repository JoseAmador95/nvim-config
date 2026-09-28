local M = {
	follow = require("log_workbench.follow"),
	matches = require("log_workbench.matches"),
}

local configured = false

local function validate_positive_integer(value, path)
	if
		value ~= nil
		and (type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value ~= value or value == math.huge)
	then
		return nil, path .. " must be a positive integer"
	end
	return true
end

local function validate_follow(opts)
	if opts == nil then
		opts = {}
	end
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "log_workbench.setup.follow must be an object"
	end
	local allowed = {
		uv = true,
		notify = true,
		event = true,
		schedule = true,
		new_fs_poll = true,
		new_fs_event = true,
		poll_interval_ms = true,
		max_lines = true,
		max_bytes = true,
		continuity_bytes = true,
	}
	for key in pairs(opts) do
		if not allowed[key] then
			return nil, "log_workbench.setup.follow contains an unknown option: " .. tostring(key)
		end
	end
	for _, key in ipairs({ "notify", "event", "schedule", "new_fs_poll", "new_fs_event" }) do
		if opts[key] ~= nil and type(opts[key]) ~= "function" then
			return nil, "log_workbench.setup.follow." .. key .. " must be a function"
		end
	end
	if opts.uv ~= nil and type(opts.uv) ~= "table" then
		return nil, "log_workbench.setup.follow.uv must be a table"
	end
	for _, key in ipairs({ "poll_interval_ms", "max_lines", "max_bytes", "continuity_bytes" }) do
		local valid, err = validate_positive_integer(opts[key], "log_workbench.setup.follow." .. key)
		if not valid then
			return nil, err
		end
	end
	return true
end

local function validate_matches(opts)
	if opts == nil then
		opts = {}
	end
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "log_workbench.setup.matches must be an object"
	end
	for key in pairs(opts) do
		if key ~= "schedule" and key ~= "event" and key ~= "max_matches" and key ~= "scan_lines_per_tick" then
			return nil, "log_workbench.setup.matches contains an unknown option: " .. tostring(key)
		end
	end
	for _, key in ipairs({ "schedule", "event" }) do
		if opts[key] ~= nil and type(opts[key]) ~= "function" then
			return nil, "log_workbench.setup.matches." .. key .. " must be a function"
		end
	end
	for _, key in ipairs({ "max_matches", "scan_lines_per_tick" }) do
		local valid, err = validate_positive_integer(opts[key], "log_workbench.setup.matches." .. key)
		if not valid then
			return nil, err
		end
	end
	return true
end

---Configure both independent workbench modules through one plugin boundary.
---@param opts? { follow?: table, matches?: table }
---@return boolean? ok
---@return string? error_message
function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "log_workbench.setup options must be an object"
	end
	for key in pairs(opts) do
		if key ~= "follow" and key ~= "matches" then
			return nil, "log_workbench.setup contains an unknown field: " .. tostring(key)
		end
	end
	if opts.follow ~= nil and type(opts.follow) ~= "table" then
		return nil, "log_workbench.setup.follow must be a table"
	end
	if opts.matches ~= nil and type(opts.matches) ~= "table" then
		return nil, "log_workbench.setup.matches must be a table"
	end
	local follow_valid, follow_validation_err = validate_follow(opts.follow)
	if not follow_valid then
		return nil, follow_validation_err
	end
	local matches_valid, matches_validation_err = validate_matches(opts.matches)
	if not matches_valid then
		return nil, matches_validation_err
	end
	local follow_ok, follow_err = M.follow.setup(opts.follow or {})
	if not follow_ok then
		return nil, follow_err
	end
	local matches_ok, matches_err = M.matches.setup(opts.matches or {})
	if not matches_ok then
		M.follow.teardown()
		return nil, matches_err
	end
	configured = true
	return true
end

function M.effective_config()
	local result = M.follow.effective_config()
	for key, value in pairs(M.matches.effective_config()) do
		result[key] = value
	end
	return vim.deepcopy(result)
end

function M.status()
	return vim.deepcopy({ configured = configured, sessions = M.follow.status(), config = M.effective_config() })
end

function M.teardown()
	M.follow.teardown()
	M.matches.teardown()
	configured = false
	return true
end

return M
