local M = {}

local values = {}
local proxies = {}

local REQUIRED = {
	repo = {
		"clean_git_command",
		"contains",
		"current_root",
		"git",
		"relative_existing",
		"resolve_relative",
		"root",
	},
	fs = { "read_binary", "write_binary_atomic" },
	editor = { "open_file_in_tab" },
}

function M.setup(opts)
	assert(type(opts) == "table", "native-review setup options must be a table")
	for name in pairs(opts) do
		assert(
			REQUIRED[name] or name == "lsp_navigation" or name == "config" or name == "event",
			"unknown native-review adapter: " .. name
		)
	end
	for name, methods in pairs(REQUIRED) do
		local adapter = opts[name]
		assert(type(adapter) == "table", "native-review adapter " .. name .. " must be a table")
		for _, method in ipairs(methods) do
			assert(
				type(adapter[method]) == "function",
				"native-review adapter " .. name .. "." .. method .. " must be a function"
			)
		end
	end
	assert(type(opts.lsp_navigation) == "table", "native-review adapter lsp_navigation must be a table")
	assert(type(opts.config) == "table", "native-review config must be a table")
	assert(opts.event == nil or type(opts.event) == "function", "native-review event adapter must be a function")
	values = opts
end

function M.get(name)
	local value = values[name]
	if value == nil then
		error("native-review dependency is not configured: " .. tostring(name), 2)
	end
	if type(value) ~= "table" then
		return value
	end
	if not proxies[name] then
		proxies[name] = setmetatable({}, {
			__index = function(_, key)
				local value = values[name]
				return value and value[key]
			end,
			__newindex = function()
				error("native-review adapters are immutable", 2)
			end,
		})
	end
	return proxies[name]
end

function M.clear()
	values = {}
end

return M
