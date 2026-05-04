-- lua/plugins/treesitter.lua
return {
	{
		"nvim-treesitter/nvim-treesitter",
		version = false,
		lazy = false,
		build = ":TSUpdate",
		config = function()
			local max_filesize = 200 * 1024
			local uv = vim.uv
			local ensure_installed = {
				"bash",
				"c",
				"cmake",
				"cpp",
				"go",
				"javascript",
				"json",
				"lua",
				"markdown",
				"markdown_inline",
				"python",
				"query",
				"rust",
				"toml",
				"typescript",
				"vim",
				"vimdoc",
				"xml",
				"yaml",
			}

			require("nvim-treesitter").setup()
			require("nvim-treesitter").install(ensure_installed, { summary = false })

			local installable = {}
			for _, lang in ipairs(ensure_installed) do
				installable[lang] = true
			end

			local indent_disabled = {}
			vim.api.nvim_create_autocmd("FileType", {
				group = vim.api.nvim_create_augroup("TreesitterStart", { clear = true }),
				callback = function(args)
					local name = vim.api.nvim_buf_get_name(args.buf)
					local ok, stats = pcall(uv.fs_stat, name)
					if ok and stats and stats.size > max_filesize then
						return
					end

					local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
						or vim.bo[args.buf].filetype
					if not installable[lang] then
						return
					end

					if pcall(vim.treesitter.start, args.buf, lang) and not indent_disabled[lang] then
						vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
					end
				end,
			})
		end,
		-- If you want to skip inside VSCode:
		cond = function()
			return not vim.g.vscode
		end,
	},

	{
		"nvim-treesitter/nvim-treesitter-textobjects",
		dependencies = { "nvim-treesitter/nvim-treesitter" },
		event = "VeryLazy",
		cond = function()
			return not vim.g.vscode
		end,
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
		event = "FileType",
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
					"RainbowDelimiterYellow",
					"RainbowDelimiterBlue",
					"RainbowDelimiterOrange",
					"RainbowDelimiterViolet",
					"RainbowDelimiterCyan",
					"RainbowDelimiterRed",
					"RainbowDelimiterGreen",
				},
			})

			-- Patch rainbow-delimiters lib to safely handle missing parsers
			local lib = require("rainbow-delimiters.lib")
			local original_attach = lib.attach
			lib.attach = function(bufnr, lang)
				-- Safely attempt to attach, notify on errors
				local ok, err = pcall(original_attach, bufnr, lang)
				if not ok then
					vim.notify(
						"rainbow-delimiters error for buffer " .. bufnr .. ": " .. tostring(err),
						vim.log.levels.WARN
					)
				end
				return ok
			end
		end,
		cond = function()
			return not vim.g.vscode
		end,
	},
}
