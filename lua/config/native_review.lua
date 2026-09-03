local navigation = setmetatable({}, {
	__index = function(_, name)
		return require("config.lsp_navigation")[name]
	end,
})

local local_config = require("config.local_config")
local configured = local_config.plugin("native_review", {
	hunk_context = 3,
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
	lsp_navigation = navigation,
	event = function(status)
		vim.api.nvim_exec_autocmds("User", {
			pattern = "NvimConfigReviewChanged",
			data = vim.deepcopy(status),
			modeline = false,
		})
	end,
}))
