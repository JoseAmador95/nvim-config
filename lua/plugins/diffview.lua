return {
	"dlyongemallo/diffview-plus.nvim",
	version = "v0.37",
	cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-lua/plenary.nvim" },
	config = function()
		require("diffview").setup({
			enhanced_diff_hl = true,
		})
	end,
}
