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
	tabs = {
		"acquire_transient",
		"focus_transient",
		"rename_transient",
		"release_transient",
		"valid_transient",
	},
}

local function default_clipboard()
	return {
		available = function()
			return vim.fn.has("clipboard") == 1
		end,
		setreg = vim.fn.setreg,
	}
end

function M.setup(opts)
	assert(type(opts) == "table", "native-review setup options must be a table")
	for name in pairs(opts) do
		assert(
			REQUIRED[name]
				or name == "clipboard"
				or name == "lsp_navigation"
				or name == "structural_diff"
				or name == "markdown"
				or name == "config"
				or name == "event",
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
	if opts.clipboard ~= nil then
		assert(type(opts.clipboard) == "table", "native-review adapter clipboard must be a table")
		for _, method in ipairs({ "available", "setreg" }) do
			assert(
				type(opts.clipboard[method]) == "function",
				"native-review adapter clipboard." .. method .. " must be a function"
			)
		end
	end
	assert(type(opts.config) == "table", "native-review config must be a table")
	if opts.structural_diff ~= nil then
		assert(type(opts.structural_diff) == "table", "native-review adapter structural_diff must be a table")
		assert(
			type(opts.structural_diff.run) == "function",
			"native-review adapter structural_diff.run must be a function"
		)
		assert(
			opts.structural_diff.analyze == nil or type(opts.structural_diff.analyze) == "function",
			"native-review adapter structural_diff.analyze must be a function"
		)
	end
	assert(opts.event == nil or type(opts.event) == "function", "native-review event adapter must be a function")
	if opts.markdown ~= nil then
		assert(type(opts.markdown) == "table", "native-review adapter markdown must be a table")
		assert(type(opts.markdown.build_snapshot) == "function", "markdown.build_snapshot is required")
		assert(type(opts.markdown.version) == "string", "markdown.version is required")
		assert(
			opts.markdown.decorate == nil or type(opts.markdown.decorate) == "function",
			"markdown.decorate must be a function"
		)
	end
	values = {}
	for name, value in pairs(opts) do
		values[name] = value
	end
	values.clipboard = opts.clipboard or default_clipboard()
	values.markdown = opts.markdown
		or {
			version = "unavailable",
			build_snapshot = function()
				return nil, "No Markdown renderer adapter is configured"
			end,
		}
	values.structural_diff = opts.structural_diff
		or {
			run = function(_, callback)
				callback(nil, "No structural diff adapter is configured")
				return function() end
			end,
		}
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
