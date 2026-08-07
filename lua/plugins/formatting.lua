local function autoformat_enabled(bufnr)
	local override = vim.b[bufnr].conform_format_on_save
	if override ~= nil then
		return override == true
	end
	return vim.g.conform_format_on_save == true
end

return {
	{
		"stevearc/conform.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = { "BufWritePre" },
		cmd = { "ConformInfo", "FormatFile", "FormatToggle" },
		keys = {
			{ "<leader>cf", "<cmd>FormatFile<cr>", desc = "Format buffer" },
		},
		init = function()
			vim.g.conform_format_on_save = false
		end,
		opts = {
			format_on_save = function(bufnr)
				if vim.bo[bufnr].buftype ~= "" then
					return
				end

				if not autoformat_enabled(bufnr) then
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
				rust = { "rustfmt" }, -- ships with rustup, not Mason-managed
				-- goimports handles import add/remove/sort; gofumpt then applies
				-- strict formatting (matches the gofumpt=true gopls setting)
				go = { "goimports", "gofumpt" },
				javascript = { "prettierd", "prettier", stop_after_first = true },
				typescript = { "prettierd", "prettier", stop_after_first = true },
				javascriptreact = { "prettierd", "prettier", stop_after_first = true },
				typescriptreact = { "prettierd", "prettier", stop_after_first = true },
			},
		},
		config = function(_, opts)
			local conform = require("conform")
			conform.setup(opts)

			vim.api.nvim_create_user_command("FormatFile", function()
				conform.format({ async = true, lsp_format = "fallback" })
			end, { desc = "Format current buffer" })

			vim.api.nvim_create_user_command("FormatToggle", function(args)
				if args.bang then
					local override = not autoformat_enabled(0)
					vim.b.conform_format_on_save = override
					vim.notify(
						string.format(
							"Autoformat buffer override: %s (effective: %s; global: %s)",
							override and "ON" or "OFF",
							autoformat_enabled(0) and "ON" or "OFF",
							vim.g.conform_format_on_save and "ON" or "OFF"
						),
						vim.log.levels.INFO
					)
					return
				end

				vim.g.conform_format_on_save = not vim.g.conform_format_on_save
				vim.notify(
					string.format(
						"Autoformat global: %s (current buffer effective: %s)",
						vim.g.conform_format_on_save and "ON" or "OFF",
						autoformat_enabled(0) and "ON" or "OFF"
					),
					vim.log.levels.INFO
				)
			end, {
				desc = "Toggle autoformat on save (! for buffer)",
				bang = true,
			})
		end,
	},
}
