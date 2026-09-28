local formatting = require("config.formatting")
local tombi = require("config.tombi")

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
				if vim.bo[bufnr].buftype ~= "" or not autoformat_enabled(bufnr) then
					return
				end
				return formatting.on_save(bufnr)
			end,
			formatters_by_ft = {
				lua = { "stylua" },
				c = { "clang-format" },
				cpp = { "clang-format" },
				python = { "ruff_format" },
				sh = { "shfmt" },
				bash = { "shfmt" },
				zsh = { "shfmt" },
				toml = { "tombi" },
				javascript = { "prettierd" },
				typescript = { "prettierd" },
				javascriptreact = { "prettierd" },
				typescriptreact = { "prettierd" },
				json = { "prettierd" },
				jsonc = { "prettierd" },
				yaml = { "prettierd" },
				markdown = { "prettierd" },
			},
			default_format_opts = { lsp_format = "never" },
			formatters = {
				["clang-format"] = { command = formatting.command("clang-format") },
				prettierd = { command = formatting.command("prettierd") },
				ruff_format = { command = formatting.command("ruff_format") },
				shfmt = { command = formatting.command("shfmt") },
				stylua = { command = formatting.command("stylua") },
				tombi = {
					command = formatting.command("tombi"),
					env = tombi.env(),
				},
			},
		},
		config = function(_, opts)
			-- Lazy adds the plugin to runtimepath immediately before this callback;
			-- loading the optional upstream module earlier would defeat lazy-loading.
			local conform = require("conform")
			local setup_opts = vim.deepcopy(opts)
			conform.setup(setup_opts)
			local guarded, guard_err = formatting.setup(conform)
			assert(guarded, guard_err)

			vim.api.nvim_create_user_command("FormatFile", function()
				formatting.format({ async = true })
			end, { desc = "Format current buffer", force = true })

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
				force = true,
			})
		end,
	},
}
