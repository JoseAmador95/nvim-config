return {
	{
		"m4xshen/hardtime.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		lazy = false,
		dependencies = { "MunifTanjim/nui.nvim" },
		opts = {
			restriction_mode = "hint",
			disable_mouse = false,
			disabled_filetypes = {
				"spectre_panel",
				"toggleterm",
			},
		},
	},
}
