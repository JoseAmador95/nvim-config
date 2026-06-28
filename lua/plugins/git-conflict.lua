-- Merge-conflict highlighting and resolution. Buffer keymaps (co/ct/cb/c0 to
-- pick ours/theirs/both/none, ]x/[x to move between conflicts) only attach when
-- a buffer actually contains conflict markers.
return {
	"akinsho/git-conflict.nvim",
	version = "*",
	event = "BufReadPre",
	cond = function()
		return not vim.g.vscode
	end,
	opts = {},
}
