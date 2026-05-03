return {
	"lewis6991/gitsigns.nvim",
	event = "BufReadPre",
	cond = function()
		return not vim.g.vscode
	end,

	config = function()
		require("gitsigns").setup({
			signs = {
				add = { text = "│", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
				change = { text = "│", numhl = "GitSignsChangeNr", linehl = "GitSignsChangeLn" },
				delete = { text = "_", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
				topdelete = { text = "‾", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
				changedelete = { text = "~", numhl = "GitSignsChangeNr", linehl = "GitSignsChangeLn" },
				untracked = { text = "┆", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
			},
		})
	end,
}
