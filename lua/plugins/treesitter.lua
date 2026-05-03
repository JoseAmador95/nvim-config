-- lua/plugins/treesitter.lua
return {
	{
		"nvim-treesitter/nvim-treesitter",
		version = false,
		lazy = false,
		build = ":TSUpdate",
		config = function()
			local max_filesize = 200 * 1024
			local uv = vim.uv or vim.loop
			local ensure_installed = {
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
				"toml",
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

			local indent_disabled = { c = true, cpp = true }
			vim.api.nvim_create_autocmd("FileType", {
				group = vim.api.nvim_create_augroup("TreesitterStart", { clear = true }),
				callback = function(args)
					local name = vim.api.nvim_buf_get_name(args.buf)
					local ok, stats = pcall(uv.fs_stat, name)
					if ok and stats and stats.size > max_filesize then
						return
					end

					local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype) or vim.bo[args.buf].filetype
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
					"RainbowDelimiterGreen",
					"RainbowDelimiterYellow",
					"RainbowDelimiterBlue",
					"RainbowDelimiterOrange",
					"RainbowDelimiterViolet",
					"RainbowDelimiterCyan",
					"RainbowDelimiterRed",
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
