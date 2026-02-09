-- lua/plugins/treesitter.lua
return {
	{
		"nvim-treesitter/nvim-treesitter",
		version = false,
		event = { "BufReadPost", "BufNewFile" },
		build = ":TSUpdate",
		config = function()
			-- Modern nvim-treesitter API (rewrite):
			-- Prefer this; if you still need the legacy branch, we can switch later.
			require("nvim-treesitter").setup({
				highlight = { enable = true },
				indent = { enable = true },
			})
		end,
		-- If you want to skip inside VSCode:
		cond = function()
			return not vim.g.vscode
		end,
	},

	{
		"nvim-treesitter/nvim-treesitter-context",
		event = { "BufReadPost", "BufNewFile" },
		opts = {},
		cond = function()
			return not vim.g.vscode
		end,
	},

	{
		"HiPhish/rainbow-delimiters.nvim",
		event = { "BufReadPost", "BufNewFile" },
		config = function()
			local rd = require("rainbow-delimiters")

			require("rainbow-delimiters.setup").setup({
				strategy = {
					[""] = rd.strategy.global,
					-- `local` is a Lua keyword; use bracket syntax:
					commonlisp = rd.strategy["local"],
				},
				query = {
					[""] = "rainbow-delimiters",
					lua = "rainbow-blocks",
				},
				highlight = {
					"RainbowDelimiterRed",
					"RainbowDelimiterYellow",
					"RainbowDelimiterBlue",
					"RainbowDelimiterOrange",
					"RainbowDelimiterGreen",
					"RainbowDelimiterViolet",
					"RainbowDelimiterCyan",
				},
			})
		end,
		cond = function()
			return not vim.g.vscode
		end,
	},
}
