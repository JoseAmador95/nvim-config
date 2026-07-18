-- GitHub PR/issue review in-editor. Requires `gh auth login` once.
return {
	"pwntester/octo.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = "Octo",
	keys = {
		{ "<leader>gp", "<cmd>Octo pr list<cr>", desc = "GitHub PRs (octo)" },
		{ "<leader>gi", "<cmd>Octo issue list<cr>", desc = "GitHub issues (octo)" },
		{ "<leader>gr", "<cmd>Octo review<cr>", desc = "GitHub PR review (octo)" },
	},
	dependencies = {
		"nvim-lua/plenary.nvim",
		"nvim-telescope/telescope.nvim",
		"nvim-tree/nvim-web-devicons",
	},
	config = function()
		require("octo").setup({
			enable_builtin = true,
		})
	end,
}
