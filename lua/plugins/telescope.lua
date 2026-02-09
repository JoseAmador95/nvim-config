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
			local action_state = require("telescope.actions.state")

			-- ⭐ Custom smart-tab opener
			local function smart_open(prompt_bufnr)
				local entry = action_state.get_selected_entry()
				local filepath = entry.path or entry.filename
				local lnum = tonumber(entry.lnum) or tonumber(entry.line) or 1
				local col = tonumber(entry.col) or 1

				actions.close(prompt_bufnr)

				-- Normalize path to avoid mismatches
				filepath = vim.fn.fnamemodify(filepath, ":p")

				-- 1. Loop through tabs and check ONLY the main window of each tab
				for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
					local win = vim.api.nvim_tabpage_get_win(tabpage)
					local buf = vim.api.nvim_win_get_buf(win)
					local name = vim.api.nvim_buf_get_name(buf)

					-- Normalize tab buffer filepath
					name = vim.fn.fnamemodify(name, ":p")

					if name == filepath then
						-- File is open as the MAIN buffer of this tab → reuse tab
						vim.api.nvim_set_current_tabpage(tabpage)
						local line_count = vim.api.nvim_buf_line_count(buf)
						local target_line = math.max(1, math.min(lnum, line_count))
						local line = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ""
						local target_col = math.max(0, math.min(col - 1, #line))
						vim.api.nvim_win_set_cursor(win, { target_line, target_col })
						return
					end
				end

				-- 2. File may be open in a split or not open at all → create new tab
				vim.cmd("tabedit " .. vim.fn.fnameescape(filepath))
				local current_buf = vim.api.nvim_get_current_buf()
				local line_count = vim.api.nvim_buf_line_count(current_buf)
				local target_line = math.max(1, math.min(lnum, line_count))
				local line = vim.api.nvim_buf_get_lines(current_buf, target_line - 1, target_line, false)[1] or ""
				local target_col = math.max(0, math.min(col - 1, #line))
				vim.api.nvim_win_set_cursor(0, { target_line, target_col })
			end

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

							-- ⭐ Replace default Enter action with smart tab reuse
							["<CR>"] = smart_open,
						},
						n = {
							["j"] = "move_selection_next",
							["k"] = "move_selection_previous",
							["h"] = "move_selection_previous",
							["l"] = "move_selection_next",
							["q"] = "close",

							-- ⭐ Same in normal mode
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
	},
}
