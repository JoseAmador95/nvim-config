local function full_terminal_editor()
	local pager = require("config.pager")
	return not vim.g.vscode and not pager.active
end

return {
	{
		"nvzone/volt",
		name = "volt",
		cond = full_terminal_editor,
		lazy = true,
	},
	{
		"nvzone/menu",
		name = "menu",
		cond = full_terminal_editor,
		lazy = true,
		dependencies = { "volt" },
		init = function()
			require("config.menu").setup()
		end,
	},
}
