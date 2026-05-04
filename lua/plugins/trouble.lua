return {
	"folke/trouble.nvim",
	cmd = "Trouble",
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", desc = "Diagnostics (Trouble)" },
		{
			"<leader>xd",
			"<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
			desc = "Buffer Diagnostics (Trouble)",
		},
		{
			"<leader>xq",
			"<cmd>Trouble qflist toggle<cr>",
			desc = "Quickfix List (Trouble)",
		},
		{
			"<leader>xl",
			"<cmd>Trouble loclist toggle<cr>",
			desc = "Location List (Trouble)",
		},
		{
			"<leader>xr",
			"<cmd>Trouble lsp_references toggle focus=false win.position=right<cr>",
			desc = "LSP References (Trouble)",
		},
	},
	opts = {
		modes = {
			diagnostics = {
				auto_close = false,
				auto_preview = true,
			},
		},
	},
}
