return {
	{
		"LintaoAmons/bookmarks.nvim",
		tag = "v4.0.0",
		dependencies = {
			{ "kkharji/sqlite.lua" },
			{ "nvim-telescope/telescope.nvim" },
			{ "stevearc/dressing.nvim" },
		},
		keys = {
			{ "<leader>bm", "<cmd>BookmarksTree<cr>", desc = "Bookmarks tree" },
			{ "<leader>ba", "<cmd>BookmarksMark<cr>", desc = "Add bookmark" },
		},
		config = function()
			require("bookmarks").setup({})

			local Repo = require("bookmarks.domain.repo")
			local Operate = require("bookmarks.tree.operate")

			vim.api.nvim_create_autocmd("FileType", {
				pattern = "BookmarksTree",
				callback = function()
					vim.keymap.set("n", "o", function()
						local line_no = vim.api.nvim_win_get_cursor(0)[1]
						local ctx = vim.g.bookmark_tree_view_ctx
						if not ctx then
							return
						end
						local line_ctx = ctx.lines_ctx.lines_ctx[line_no]
						if not line_ctx then
							return
						end
						local node = Repo.find_node(line_ctx.id)
						if not node then
							return
						end

						if node.type == "bookmark" and node.location then
							require("config.editor").open_file_in_tab(node.location.path, {
								lnum = node.location.line,
								col = node.location.col or 0,
							})
						elseif node.type == "list" then
							Operate.toggle()
						end
					end, { buffer = 0, silent = true, nowait = true })
				end,
			})
		end,
	},
}
