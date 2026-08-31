local M = {}

local values = {}

function M.setup(opts)
	assert(type(opts) == "table", "native-review setup options must be a table")
	for name, value in pairs(opts) do
		values[name] = value
	end
end

function M.get(name)
	local value = values[name]
	if value == nil then
		error("native-review dependency is not configured: " .. tostring(name), 2)
	end
	return value
end

return M
