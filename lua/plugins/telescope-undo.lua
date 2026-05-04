return {
	"debugloop/telescope-undo.nvim",
	dependencies = { "nvim-telescope/telescope.nvim" },
	keys = {
		{ "<leader>u", "<cmd>Telescope undo<cr>", desc = "Undo tree" },
	},
	cond = function()
		return not vim.g.vscode
	end,
	config = function()
		require("telescope").load_extension("undo")
	end,
}
