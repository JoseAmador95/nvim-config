return {
	"sindrets/diffview.nvim",
	cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-lua/plenary.nvim" },
	config = function()
		require("diffview").setup({
			enhanced_diff_hl = true,
			keymaps = {
				view = {
					["<tab>"] = require("diffview.actions").select_next_entry,
					["<s-tab>"] = require("diffview.actions").select_prev_entry,
					["q"] = require("diffview.actions").close,
				},
				file_panel = {
					["j"] = require("diffview.actions").next_entry,
					["k"] = require("diffview.actions").prev_entry,
					["q"] = require("diffview.actions").close,
				},
			},
		})
	end,
}
