local local_config = require("config.local_config")
local navigation = require("config.lsp_navigation")
local configured = local_config.plugin("native_review", {
	hunk_context = 3,
	max_files = 2000,
	max_file_bytes = 4 * 1024 * 1024,
	max_model_bytes = 64 * 1024 * 1024,
	layout = "inline",
	context = "hunks",
	inline_comments = true,
	composer = { style = "card" },
	panel = { max_width = 200, max_height = 48 },
})

return require("native_review").setup(vim.tbl_extend("force", configured, {
	repo = require("config.repo"),
	fs = require("config.fs"),
	editor = require("config.editor"),
	tabs = require("config.tabs"),
	clipboard = require("config.clipboard"),
	lsp_navigation = navigation,
	event = function(status)
		vim.api.nvim_exec_autocmds("User", {
			pattern = "NvimConfigReviewChanged",
			data = vim.deepcopy(status),
			modeline = false,
		})
	end,
}))
