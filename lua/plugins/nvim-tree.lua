return {
	{
		"nvim-tree/nvim-tree.lua",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "NvimTreeToggle", "NvimTreeFindFile" },
		dependencies = { "nvim-tree/nvim-web-devicons" },
		keys = {
			{ "<leader>e", "<cmd>NvimTreeToggle<CR>", desc = "Toggle file explorer" },
		},
		init = function()
			-- Auto-open nvim-tree when opening a directory like `nvim .`
			vim.api.nvim_create_autocmd("VimEnter", {
				callback = function(data)
					-- `data.file` is the file or directory passed on the CLI
					local dir = data.file
					if dir == "" then
						-- If no argument was passed, but `nvim` started in a directory,
						-- check if argc() is 0 and current dir has files; optional behavior:
						return
					end
					if vim.fn.isdirectory(dir) == 1 then
						-- Change to the directory
						vim.cmd.cd(dir)
						-- Open the tree
						require("nvim-tree.api").tree.open()
					end
				end,
			})
		end,
		opts = function()
			local api = require("nvim-tree.api")

			local function edit_or_open()
				local node = api.tree.get_node_under_cursor()
				if node.nodes ~= nil then
					api.node.open.edit()
				else
					api.node.open.edit()
					api.tree.close()
				end
			end

			local function vsplit_preview()
				local node = api.tree.get_node_under_cursor()
				if node.nodes ~= nil then
					api.node.open.edit()
				else
					api.node.open.vertical()
				end
				api.tree.focus()
			end

			local function my_on_attach(bufnr)
				api.config.mappings.default_on_attach(bufnr)
				local function opts(desc)
					return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
				end
				vim.keymap.set("n", "<C-t>", api.tree.change_root_to_parent, opts("Up"))
				vim.keymap.set("n", "?", api.tree.toggle_help, opts("Help"))
				vim.keymap.set("n", "l", edit_or_open, opts("Edit Or Open"))
				vim.keymap.set("n", "L", vsplit_preview, opts("Vsplit Preview"))
				vim.keymap.set("n", "h", api.tree.close, opts("Close"))
				vim.keymap.set("n", "H", api.tree.collapse_all, opts("Collapse All"))
			end

			return {
				sync_root_with_cwd = true,
				respect_buf_cwd = true,
				update_focused_file = { enable = true, update_cwd = true },
				sort = { sorter = "case_sensitive" },
				view = { width = 30 },
				renderer = { group_empty = true },
				filters = { dotfiles = false, git_ignored = false },
				on_attach = my_on_attach,
			}
		end,
	},
}
