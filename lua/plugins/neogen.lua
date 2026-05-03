return {
	"danymat/neogen",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = "Neogen",
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	config = function()
		require("neogen").setup({
			enabled = true,
			input_after_comment = true,
			languages = {
				lua = { template = { annotation_convention = "emmylua" } },
				python = { template = { annotation_convention = "google_docstrings" } },
				cpp = { template = { annotation_convention = "doxygen" } },
			},
		})
	end,
}
