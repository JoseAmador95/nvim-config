local M = {}

local registry_module = require("action_palette.registry")
local target = require("action_palette.target")

local default_registry

---@param opts? table
---@return table
function M.setup(opts)
	local replacement = registry_module.new(opts)
	local previous = default_registry
	default_registry = replacement
	if previous then
		previous:teardown()
	end
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
	return target.revalidate(value, "exact")
end

function M.effective_config()
	return default_registry and default_registry:effective_config()
		or { target_default = "exact", unavailable = "hide" }
end

function M.status()
	return default_registry and vim.deepcopy(default_registry:status())
		or {
			configured = false,
			actions = 0,
			sections = 0,
			config = M.effective_config(),
		}
end

function M.teardown()
	if default_registry then
		default_registry:teardown()
	end
	default_registry = nil
	return true
end

M.new = registry_module.new
M.schema = require("action_palette.schema")

return M
