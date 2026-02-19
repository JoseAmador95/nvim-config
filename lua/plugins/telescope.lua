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
			"nvim-telescope/telescope-smart-history.nvim",
			"kkharji/sqlite.lua",
		},
		keys = {
			{ "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "Find files" },
			{ "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
			{ "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "Help tags" },
		},

		opts = function()
			local history_path = vim.fn.stdpath("data") .. "/databases/telescope_history.sqlite3"
			vim.fn.mkdir(vim.fn.fnamemodify(history_path, ":h"), "p")

			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")
			local editor = require("config.editor")

			local function append_history(prompt_bufnr)
				action_state
					.get_current_history()
					:append(action_state.get_current_line(), action_state.get_current_picker(prompt_bufnr))
			end

			local function smart_open(prompt_bufnr)
				local entry = action_state.get_selected_entry()
				local filepath = entry.path or entry.filename
				local lnum = tonumber(entry.lnum) or tonumber(entry.line) or 1
				local col = tonumber(entry.col) or 1

				append_history(prompt_bufnr)
				actions.close(prompt_bufnr)

				editor.open_file_in_tab(filepath, { lnum = lnum, col = col })
			end

			return {
				defaults = {
					cwd = vim.fn.getcwd(),
					file_ignore_patterns = { "node_modules", ".git" },
					history = {
						path = history_path,
						limit = 100,
						cycle_wrap = true,
					},

					mappings = {
						i = {
							["<C-j>"] = "move_selection_next",
							["<C-k>"] = "move_selection_previous",
							["<C-h>"] = "move_selection_previous",
							["<C-l>"] = "move_selection_next",
							["<C-q>"] = "close",
							["<C-p>"] = actions.cycle_history_prev,
							["<C-n>"] = actions.cycle_history_next,
							["<C-Up>"] = actions.cycle_history_prev,
							["<C-Down>"] = actions.cycle_history_next,

							["<CR>"] = smart_open,
						},
						n = {
							["j"] = "move_selection_next",
							["k"] = "move_selection_previous",
							["h"] = "move_selection_previous",
							["l"] = "move_selection_next",
							["q"] = "close",
							["<C-p>"] = actions.cycle_history_prev,
							["<C-n>"] = actions.cycle_history_next,
							["<C-Up>"] = actions.cycle_history_prev,
							["<C-Down>"] = actions.cycle_history_next,

							["<CR>"] = smart_open,
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
		config = function(_, opts)
			require("telescope").setup(opts)
			require("telescope").load_extension("smart_history")
		end,
	},
}
