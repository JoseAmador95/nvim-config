return {
	{
		"Mofiqul/vscode.nvim",
		lazy = false,
		priority = 1000,
		cond = function()
			return not vim.g.vscode
		end,
		config = function()
			local last_style = nil

			local function apply(bg)
				local style = bg == "light" and "light" or "dark"
				if style == last_style then
					return
				end
				last_style = style

				local ok, vscode = pcall(require, "vscode")
				if not ok then
					vim.notify("vscode.nvim not available", vim.log.levels.ERROR)
					return
				end

				vscode.setup({
					style = style,
					transparent = false,
					italic_comments = true,
				})
				vim.cmd("colorscheme vscode")
			end

			-- Paint once with whatever background is known right now.
			apply(vim.o.background)

			-- The terminal answers Neovim's OSC 11 background query
			-- asynchronously, so vim.o.background may flip after this plugin has
			-- already loaded. Re-apply the matching style whenever it changes
			-- (also covers a manual `:set background=...`).
			vim.api.nvim_create_autocmd("OptionSet", {
				pattern = "background",
				group = vim.api.nvim_create_augroup("VscodeBgFollow", { clear = true }),
				callback = function()
					if vim.g.vscode then
						return
					end
					apply(vim.v.option_new)
				end,
			})
		end,
	},
}
