return {
	"folke/which-key.nvim",
	event = "VeryLazy",
	cond = function()
		return not vim.g.vscode
	end,
	init = function()
		vim.o.timeout = true
		vim.o.timeoutlen = 300
	end,
	opts = {
		preset = "helix",
		delay = 500,
		-- Inside the grug-far panel, only show grug-far's own (buffer-local)
		-- mappings, not the global leader cloud.
		filter = function(mapping)
			if vim.bo.filetype == "grug-far" then
				return type(mapping.buffer) == "number" and mapping.buffer > 0
			end
			return true
		end,
		spec = {
			{ "<leader>a", group = "ai" },
			{ "<leader>b", group = "bookmarks/buffer" },
			{ "<leader>c", group = "code" },
			{ "<leader>d", group = "debug" },
			{ "<leader>f", group = "find" },
			{ "<leader>g", group = "git" },
			{ "<leader>h", group = "git hunks" },
			{ "<leader>l", group = "lsp/diagnostics" },
			{ "<leader>m", group = "markdown" },
			{ "<leader>n", group = "note" },
			{ "<leader>o", group = "obsidian" },
			{ "<leader>R", group = "remote" },
			{ "<leader>s", group = "swap/split/spell" },
			{ "<leader>x", group = "trouble" },
		},
	},
}
