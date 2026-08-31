local navigation = setmetatable({}, {
	__index = function(_, name)
		return require("config.lsp_navigation")[name]
	end,
})

return require("native_review").setup({
	repo = require("config.repo"),
	fs = require("config.fs"),
	editor = require("config.editor"),
	local_config = require("config.local_config"),
	lsp_navigation = navigation,
})
