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
		init = function()
			-- Auto-open tree when opening a directory like `nvim .`
			vim.api.nvim_create_autocmd("VimEnter", {
				callback = function(data)
					local dir = data.file
					local show_tree = function()
						require("neo-tree.command").execute({
							action = "show",
							source = "filesystem",
							position = "left",
							dir = vim.loop.cwd(),
						})
					end

					-- Case: `nvim <directory>`
					if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
						vim.cmd.cd(dir)
						show_tree()
						return
					end

					-- Case: `nvim` inside a directory (optional behavior)
					if dir == "" and vim.fn.argc() == 0 then
						show_tree()
					end
				end,
			})
		end,
		opts = {
			close_if_last_window = true,
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
