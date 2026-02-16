-- lua/plugins/treesitter.lua
return {
	{
		"nvim-treesitter/nvim-treesitter",
		version = false,
		lazy = false,
		build = ":TSUpdate",
		config = function()
			local max_filesize = 200 * 1024
			require("nvim-treesitter").setup({
				ensure_installed = {
					"bash",
					"c",
					"cmake",
					"cpp",
					"javascript",
					"json",
					"lua",
					"markdown",
					"python",
					"query",
					"toml",
					"vim",
					"vimdoc",
					"yaml",
				},
				auto_install = false,
				sync_install = false,
				highlight = {
					enable = true,
					disable = function(_, buf)
						local ok, stats = pcall(vim.loop.fs_stat, vim.api.nvim_buf_get_name(buf))
						return ok and stats and stats.size > max_filesize
					end,
				},
				indent = {
					enable = true,
					disable = { "c", "cpp" },
				},
			})
		end,
		-- If you want to skip inside VSCode:
		cond = function()
			return not vim.g.vscode
		end,
	},

	{
		"nvim-treesitter/nvim-treesitter-context",
		event = "VeryLazy",
		opts = {},
		cond = function()
			return not vim.g.vscode
		end,
	},

	{
		"HiPhish/rainbow-delimiters.nvim",
		event = "VeryLazy",
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
