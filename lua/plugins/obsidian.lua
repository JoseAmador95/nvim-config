return {
	{
		"obsidian-nvim/obsidian.nvim",
		version = "*",
		ft = "markdown",
		cond = function()
			return not vim.g.vscode
		end,
		dependencies = {
			"nvim-lua/plenary.nvim",
		},
		opts = function()
			local vaults = require("config.obsidian_vaults").read()
			if vim.tbl_isempty(vaults) then
				vim.notify(
					"No vaults found in ~/.nvim-local.lua; using the current directory",
					vim.log.levels.WARN,
					{ title = "obsidian.nvim" }
				)
				vaults = { { name = "cwd", path = vim.fn.getcwd() } }
			end
			return {
				workspaces = vaults,
				-- Use the new `Obsidian <subcmd>` commands; the keymaps below
				-- already use that syntax. Silences the legacy_commands warning.
				legacy_commands = false,
				-- Keep render-markdown.nvim as the single renderer; obsidian's
				-- own UI conflicts with it.
				ui = { enable = false },
				notes_subdir = "notes",
				new_notes_location = "notes_subdir",
			}
		end,
		keys = {
			{ "<leader>oo", "<cmd>Obsidian quick_switch<cr>", desc = "Obsidian quick switch" },
			{ "<leader>on", "<cmd>Obsidian new<cr>", desc = "Obsidian new note" },
			{ "<leader>os", "<cmd>Obsidian search<cr>", desc = "Obsidian search" },
			{ "<leader>ot", "<cmd>Obsidian today<cr>", desc = "Obsidian today" },
			{ "<leader>ob", "<cmd>Obsidian backlinks<cr>", desc = "Obsidian backlinks" },
			{ "<leader>ol", "<cmd>Obsidian links<cr>", desc = "Obsidian links" },
			{ "<leader>of", "<cmd>Obsidian follow_link<cr>", desc = "Obsidian follow link" },
		},
	},
}
