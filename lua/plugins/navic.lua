local redraw_profile = require("config.redraw_profile")

return {
	"SmiteshP/nvim-navic",
	commit = "f5eba192f39b453675d115351808bd51276d9de5",
	cond = function()
		return not vim.g.vscode
	end,
	lazy = true,
	init = function()
		vim.api.nvim_create_autocmd("LspAttach", {
			group = vim.api.nvim_create_augroup("NvimConfigNavic", { clear = true }),
			callback = function(event)
				if require("config.native_review").lsp.blocked(event.buf) then
					return
				end
				local client = vim.lsp.get_client_by_id(event.data.client_id)
				if client and client:supports_method("textDocument/documentSymbol", event.buf) then
					require("lazy").load({ plugins = { "nvim-navic" } })
					require("nvim-navic").attach(client, event.buf)
				end
			end,
		})
	end,
	opts = {
		highlight = true,
		separator = " ",
		depth_limit = 0,
		lazy_update_context = redraw_profile.low_bandwidth(),
	},
}
