local M = {
	follow = require("log_workbench.follow"),
	matches = require("log_workbench.matches"),
}

---Configure both independent workbench modules through one plugin boundary.
---@param opts? { follow?: table, matches?: table }
---@return boolean? ok
---@return string? error_message
function M.setup(opts)
	opts = opts or {}
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
	local matches_ok, matches_err = M.matches.setup(opts.matches or {})
	if not matches_ok then
		return nil, matches_err
	end
	local follow_ok, follow_err = M.follow.setup(opts.follow or {})
	if not follow_ok then
		M.matches.teardown()
		return nil, follow_err
	end
	return true
end

return M
