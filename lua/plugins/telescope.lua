return {
	{
		"nvim-telescope/telescope.nvim",
		cmd = "Telescope",
		cond = function()
			return not vim.g.vscode
		end,
		dependencies = {
			"nvim-lua/plenary.nvim",
			"nvim-tree/nvim-web-devicons",
		},
		keys = {
			{ "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "Find files" },
			{ "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "Live grep" },
			{ "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
			{ "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "Help tags" },
		},

		opts = function()
			local actions = require("telescope.actions")

			return {
				defaults = {
					cwd = vim.fn.getcwd(),
					file_ignore_patterns = { "node_modules", ".git" },

					mappings = {
						i = {
							["<C-j>"] = "move_selection_next",
							["<C-k>"] = "move_selection_previous",
							["<C-h>"] = "move_selection_previous",
							["<C-l>"] = "move_selection_next",
							["<C-q>"] = "close",

							-- ⭐ Open in NEW TAB by default (Insert mode)
							["<CR>"] = actions.select_tab,
						},
						n = {
							["j"] = "move_selection_next",
							["k"] = "move_selection_previous",
							["h"] = "move_selection_previous",
							["l"] = "move_selection_next",
							["q"] = "close",

							-- ⭐ Open in NEW TAB by default (Normal mode)
							["<CR>"] = actions.select_tab,
						},
					},
				},

				pickers = {
					find_files = {
						hidden = true,
						no_ignore = false,
					},
					live_grep = {
						additional_args = function()
							return { "--hidden" }
						end,
					},
				},
			}
		end,
	},
}
