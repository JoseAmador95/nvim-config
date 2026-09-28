local jqx_commands = require("config.jqx_commands")

return {
	{
		"gennaro-tedesco/nvim-jqx",
		cond = function()
			return not vim.g.vscode
		end,
		event = "User NvimConfigJqxUi",
		config = function()
			-- The pinned upstream runtime briefly publishes shell-string commands
			-- while Lazy sources plugin/. Reclaim every public entry synchronously
			-- before control returns to the caller; only its visual config is used.
			jqx_commands.setup(true)
		end,
	},
}
