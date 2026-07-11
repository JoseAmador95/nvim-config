-- Highlight and navigate TODO/FIXME/HACK/NOTE comments.
return {
	"folke/todo-comments.nvim",
	event = "BufReadPost",
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-lua/plenary.nvim" },
	keys = {
		{
			"]t",
			function()
				require("todo-comments").jump_next()
			end,
			desc = "Next todo comment",
		},
		{
			"[t",
			function()
				require("todo-comments").jump_prev()
			end,
			desc = "Prev todo comment",
		},
		{
			"<leader>ft",
			function()
				Snacks.picker.todo_comments()
			end,
			desc = "Find todos",
		},
		{ "<leader>xt", "<cmd>Trouble todo toggle<cr>", desc = "Todos (Trouble)" },
	},
	opts = {},
}
