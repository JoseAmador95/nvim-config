return {
	"nvim-pack/nvim-spectre",
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-lua/plenary.nvim" },
	keys = {
		{
			"<leader>fg",
			function()
				local state = require("spectre.state")
				if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
					if vim.bo[state.bufnr].filetype == "spectre_panel" then
						require("spectre").close()
					end
				end
				state.bufnr = nil
				state.is_open = false

				require("spectre").open({
					path = "!**/.git/** !**/node_modules/** !**/build/** !**/.cache/**",
					is_insert_mode = true,
				})
			end,
			desc = "Search in files",
		},
	},
	opts = {
		is_insert_mode = true,
		is_open_target_win = false,
		mapping = {
			enter_file = {
				map = "<cr>",
				cmd = "<cmd>lua require('config.spectre').open_entry_in_tab()<CR>",
				desc = "Open in new tab",
			},
			send_to_qf = {
				map = "<leader>qf",
				cmd = "<cmd>lua require('spectre.actions').send_to_qf()<CR>",
				desc = "Send all items to quickfix",
			},
			close_panel = {
				map = "<leader>q",
				cmd = "<cmd>lua require('spectre').close()<CR>",
				desc = "Close search panel",
			},
		},
		open_cmd = function()
			vim.cmd("tabnew")
		end,
		find_engine = {
			rg = {
				options = {
					["ignore-case"] = {
						value = "--ignore-case",
						icon = "[I]",
						desc = "ignore case",
					},
					["word-regexp"] = {
						value = "--word-regexp",
						icon = "[W]",
						desc = "whole word",
					},
					["fixed-strings"] = {
						value = "--fixed-strings",
						icon = "[L]",
						desc = "literal (no regex)",
					},
					["hidden"] = {
						value = "--hidden",
						icon = "[H]",
						desc = "hidden files",
					},
					["no-ignore-vcs"] = {
						value = "--no-ignore-vcs",
						icon = "[G]",
						desc = "search ignored files",
					},
				},
			},
		},
		default = {
			find = {
				cmd = "rg",
				options = { "ignore-case" },
			},
		},
	},
}
