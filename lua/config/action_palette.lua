local actions = require("config.menu.actions")
local catalog = require("config.menu.catalog")
local local_config = require("config.local_config")

local configured = local_config.plugin("action_palette", {
	target_default = "exact",
	unavailable = "hide",
})

local palette = require("action_palette").setup({
	target_default = configured.target_default,
	unavailable = configured.unavailable,
	confirm = function(prompt, callback)
		vim.ui.select({ "Cancel", "Continue" }, { prompt = prompt }, function(choice)
			callback(choice == "Continue")
		end)
	end,
	notify = function(message, level)
		vim.notify(message, level or vim.log.levels.WARN, { title = "Menu" })
	end,
	refresh_context = function(context, target)
		return require("config.menu.context").refresh(context, target)
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

return palette
