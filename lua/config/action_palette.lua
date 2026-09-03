local actions = require("config.menu.actions")
local catalog = require("config.menu.catalog")
local local_config = require("config.local_config")
local deferred = require("config.deferred")
local menu_context = require("config.menu.context")

local M = {}

local core
local configured = false

local function host_options()
	return local_config.plugin("action_palette", {
		target_default = "exact",
		unavailable = "hide",
	})
end

local function load_core()
	if core then
		return core
	end
	local ok, result = deferred.try("action_palette")
	if not ok then
		return nil, result
	end
	core = result
	return core
end

local function ensure_configured()
	if configured then
		return core
	end
	local palette, load_err = load_core()
	if not palette then
		return nil, load_err
	end
	local options = host_options()
	local ok, setup_err = pcall(function()
		palette.setup({
			target_default = options.target_default,
			unavailable = options.unavailable,
			confirm = function(prompt, callback)
				vim.ui.select({ "Cancel", "Continue" }, { prompt = prompt }, function(choice)
					callback(choice == "Continue")
				end)
			end,
			notify = function(message, level)
				vim.notify(message, level or vim.log.levels.WARN, { title = "Menu" })
			end,
			refresh_context = function(context, target)
				return menu_context.refresh(context, target)
			end,
		})
		palette.register_catalog(catalog.definitions(), {
			supports = actions.supports,
			confirmation = actions.confirmation,
			execute = function(id, invocation)
				local target = vim.deepcopy(invocation.target)
				target.selection = invocation.context.selection and vim.deepcopy(invocation.context.selection) or nil
				return actions.execute(id, target)
			end,
		})
	end)
	if not ok then
		pcall(palette.teardown)
		return nil, setup_err
	end
	configured = true
	return palette
end

local function configured_core()
	local palette, err = ensure_configured()
	if not palette then
		error("could not initialize action palette: " .. tostring(err), 3)
	end
	return palette
end

for _, method in ipairs({
	"register_catalog",
	"supports",
	"is_available",
	"bind",
	"sections",
	"definitions",
	"capture_target",
	"revalidate_target",
	"effective_config",
}) do
	local method_name = method
	M[method_name] = function(...)
		return configured_core()[method_name](...)
	end
end

function M.new(...)
	local palette, err = load_core()
	if not palette then
		error("could not load action palette: " .. tostring(err), 2)
	end
	return palette.new(...)
end

function M.setup(...)
	local palette, err = load_core()
	if not palette then
		error("could not load action palette: " .. tostring(err), 2)
	end
	local result = palette.setup(...)
	configured = true
	return result
end

function M.status()
	if not configured then
		local options = host_options()
		return {
			configured = false,
			actions = 0,
			sections = 0,
			config = {
				target_default = options.target_default,
				unavailable = options.unavailable,
			},
		}
	end
	return core.status()
end

function M.teardown()
	if core then
		core.teardown()
	end
	configured = false
	return true
end

M.schema = require("action_palette.schema")

return M
