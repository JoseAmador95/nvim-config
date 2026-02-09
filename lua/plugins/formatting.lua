return {
	{
		"stevearc/conform.nvim",
		event = { "BufWritePre" },
		cmd = { "ConformInfo", "Format", "FormatToggle" },
		keys = {
			{
				"<leader>f",
				function()
					require("conform").format({ async = true, lsp_format = "fallback" })
				end,
				desc = "Format buffer",
			},
		},
		init = function()
			vim.g.conform_format_on_save = false
		end,
		opts = {
			format_on_save = function(bufnr)
				if not vim.g.conform_format_on_save then
					return
				end

				if vim.bo[bufnr].buftype ~= "" then
					return
				end

				if vim.b[bufnr].disable_autoformat then
					return
				end

				return { timeout_ms = 2000, lsp_format = "fallback" }
			end,
			formatters_by_ft = {
				lua = { "stylua" },
				c = { "clang-format" },
				cpp = { "clang-format" },
				python = { "ruff_format" },
				sh = { "shfmt" },
				bash = { "shfmt" },
				zsh = { "shfmt" },
				toml = { "taplo" },
			},
		},
		config = function(_, opts)
			local conform = require("conform")
			conform.setup(opts)

			vim.api.nvim_create_user_command("Format", function()
				conform.format({ async = true, lsp_format = "fallback" })
			end, { desc = "Format current buffer" })

			vim.api.nvim_create_user_command("FormatToggle", function(args)
				if args.bang then
					vim.b.disable_autoformat = not vim.b.disable_autoformat
					vim.notify(
						string.format("Autoformat (buffer): %s", vim.b.disable_autoformat and "OFF" or "ON"),
						vim.log.levels.INFO
					)
					return
				end

				vim.g.conform_format_on_save = not vim.g.conform_format_on_save
				vim.notify(
					string.format("Autoformat on save (global): %s", vim.g.conform_format_on_save and "ON" or "OFF"),
					vim.log.levels.INFO
				)
			end, {
				desc = "Toggle autoformat on save (! for buffer)",
				bang = true,
			})
		end,
	},
}
