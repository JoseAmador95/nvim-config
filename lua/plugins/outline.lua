-- Symbol tree (LSP) in a side panel, toggled with <leader>cs.
return {
	"hedyhli/outline.nvim",
	cmd = { "Outline", "OutlineOpen" },
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>cs", "<cmd>Outline<cr>", desc = "Symbols outline" },
	},
	opts = {},
}
