-- lua/plugins/treesitter.lua
local parsers = {
	"bash",
	"c",
	"cmake",
	"cpp",
	"javascript",
	"json",
	"lua",
	"markdown",
	"markdown_inline",
	"python",
	"query",
	"rust",
	"toml",
	"tsx",
	"typescript",
	"vim",
	"vimdoc",
	"xml",
	"yaml",
}

return {
	{
		"nvim-treesitter/nvim-treesitter",
		version = false,
		lazy = false,
		build = ":TSUpdate",
		config = function()
			require("nvim-treesitter").setup()
			require("config.treesitter_runtime").setup({
				parsers = parsers,
				highlight = not vim.g.vscode,
				indent = not vim.g.vscode,
			})
		end,
		-- Loads in VSCode too (installed parsers only, no highlight/indent) so
		-- text objects can query trees on demand.
	},

	{
		"nvim-treesitter/nvim-treesitter-textobjects",
		dependencies = { "nvim-treesitter/nvim-treesitter" },
		event = "VeryLazy",
		config = function()
			local select = require("nvim-treesitter-textobjects.select")
			local move = require("nvim-treesitter-textobjects.move")
			local swap = require("nvim-treesitter-textobjects.swap")

			-- Global config: lookahead for select, set_jumps for move
			require("nvim-treesitter-textobjects").setup({
				select = { lookahead = true },
				move = { set_jumps = true },
			})

			-- Text object selections (visual + operator-pending)
			local sel_maps = {
				["af"] = "@function.outer",
				["if"] = "@function.inner",
				["ac"] = "@class.outer",
				["ic"] = "@class.inner",
				["aa"] = "@parameter.outer",
				["ia"] = "@parameter.inner",
				["ab"] = "@block.outer",
				["ib"] = "@block.inner",
			}
			for key, query in pairs(sel_maps) do
				vim.keymap.set({ "x", "o" }, key, function()
					select.select_textobject(query, "textobjects")
				end, { desc = "TS select " .. query })
			end

			-- Navigation keymaps
			vim.keymap.set({ "n", "x", "o" }, "]f", function()
				move.goto_next_start("@function.outer")
			end, { desc = "Next function start" })
			vim.keymap.set({ "n", "x", "o" }, "[f", function()
				move.goto_previous_start("@function.outer")
			end, { desc = "Prev function start" })
			vim.keymap.set({ "n", "x", "o" }, "]F", function()
				move.goto_next_end("@function.outer")
			end, { desc = "Next function end" })
			vim.keymap.set({ "n", "x", "o" }, "[F", function()
				move.goto_previous_end("@function.outer")
			end, { desc = "Prev function end" })
			vim.keymap.set({ "n", "x", "o" }, "]c", function()
				move.goto_next_start("@class.outer")
			end, { desc = "Next class start" })
			vim.keymap.set({ "n", "x", "o" }, "[c", function()
				move.goto_previous_start("@class.outer")
			end, { desc = "Prev class start" })

			-- Swap arguments
			vim.keymap.set("n", "<leader>sa", function()
				swap.swap_next("@parameter.inner")
			end, { desc = "Swap next argument" })
			vim.keymap.set("n", "<leader>sA", function()
				swap.swap_previous("@parameter.inner")
			end, { desc = "Swap prev argument" })
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
		-- Its plugin file installs the FileType attachment autocmd, so load on
		-- the preceding buffer lifecycle event without replaying FileType.
		event = { "BufReadPre", "BufNewFile" },
		config = function()
			local rd = require("rainbow-delimiters")
			require("config.palette").apply()

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
					"RainbowDelimiterYellow",
					"RainbowDelimiterBlue",
					"RainbowDelimiterOrange",
					"RainbowDelimiterViolet",
					"RainbowDelimiterCyan",
					"RainbowDelimiterRed",
					"RainbowDelimiterGreen",
				},
			})
		end,
		cond = function()
			return not vim.g.vscode
		end,
	},
}
