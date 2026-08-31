local M = {}

local registry_module = require("action_palette.registry")
local target = require("action_palette.target")

local default_registry

---@param opts? table
---@return table
function M.setup(opts)
	default_registry = registry_module.new(opts)
	return M
end

local function registry()
	if not default_registry then
		default_registry = registry_module.new()
	end
	return default_registry
end

function M.register_catalog(sections, resolver)
	return registry():register_catalog(sections, resolver)
end

function M.supports(id)
	return registry():supports(id)
end

function M.is_available(id, context)
	return registry():is_available(id, context)
end

function M.bind(id, context, surface)
	return registry():bind(id, context, surface)
end

function M.sections(context, surface)
	return registry():sections(context, surface)
end

function M.definitions()
	return registry():definitions()
end

function M.capture_target()
	return target.capture()
end

function M.revalidate_target(value)
	return target.revalidate(value)
end

M.new = registry_module.new
M.schema = require("action_palette.schema")

return M
