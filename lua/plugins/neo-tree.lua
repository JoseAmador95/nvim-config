return {
	{
		"nvim-neo-tree/neo-tree.nvim",
		branch = "v3.x",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "Neotree" },
		dependencies = {
			"nvim-lua/plenary.nvim",
			"MunifTanjim/nui.nvim",
			"nvim-tree/nvim-web-devicons",
		},
		keys = {
			{ "<leader>e", "<cmd>Neotree toggle filesystem left<CR>", desc = "Toggle file explorer" },
		},
		opts = {
			close_if_last_window = false,
			enable_git_status = true,
			enable_diagnostics = true,
			default_component_configs = {
				indent = {
					with_expanders = true,
				},
			},
			window = {
				position = "left",
				width = 30,
			},
			filesystem = {
				follow_current_file = {
					enabled = true,
				},
				filtered_items = {
					hide_dotfiles = false,
					hide_gitignored = false,
				},
				window = {
					mappings = {
						["<C-t>"] = "navigate_up",
						["?"] = "show_help",
						["l"] = "open",
						["L"] = "open_vsplit",
						["h"] = "close_node",
						["H"] = "close_all_nodes",
					},
				},
			},
		},
	},
}
