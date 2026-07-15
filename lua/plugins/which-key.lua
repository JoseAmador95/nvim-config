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
		-- grug-far has its own context help (g?); don't pop the full
		-- which-key cloud (global + buffer maps) inside its buffer.
		disable = {
			ft = { "grug-far" },
		},
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
			{ "<leader>s", group = "swap/split/spell" },
			{ "<leader>t", group = "terminal" },
			{ "<leader>x", group = "trouble" },
		},
	},
}
