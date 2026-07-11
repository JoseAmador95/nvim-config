return {
	"windwp/nvim-autopairs",
	cond = function()
		return not vim.g.vscode
	end,
	event = "InsertEnter",
	config = function()
		-- blink.cmp handles bracket completion for accepted items; nvim-autopairs
		-- still auto-closes pairs while typing.
		require("nvim-autopairs").setup({})
	end,
}
