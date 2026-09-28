-- Lightweight command facade. The execution/UI module and upstream JQX
-- runtime stay absent until a user invokes a JSON action.
local M = {}

local deferred = require("config.deferred")
local configured = false

local function delete_upstream_entries()
	pcall(vim.keymap.del, "n", "<Plug>JqxList")
	pcall(vim.api.nvim_del_augroup_by_name, "JqxAutoClose")
	for _, name in ipairs({ "FileKeys", "TypeKeys" }) do
		pcall(vim.api.nvim_exec2, "delfunction! " .. name, { output = false })
	end
end

function M.setup(force)
	if configured and not force then
		return
	end
	delete_upstream_entries()
	vim.api.nvim_create_user_command("JqxList", function(options)
		deferred.load("config.jqx").list(options.args)
	end, {
		nargs = "?",
		complete = function(prefix)
			return deferred.load("config.jqx").complete_types(prefix)
		end,
		desc = "List top-level JSON keys with verified jq",
		force = true,
	})
	vim.api.nvim_create_user_command("JqxQuery", function(options)
		deferred.load("config.jqx").query(options.args)
	end, {
		nargs = "?",
		complete = function(prefix)
			return deferred.load("config.jqx").complete_keys(prefix)
		end,
		desc = "Query JSON with verified jq",
		force = true,
	})
	configured = true
end

return M
