local markdown_view = require("config.markdown_view")

return {
	"delphinus/md-render.nvim",
	commit = markdown_view.PIN,
	lazy = false,
	cond = function()
		local locked = markdown_view.lock_ok()
		return not vim.g.vscode and locked == true
	end,
	config = function()
		markdown_view.configure_renderer()
	end,
}
