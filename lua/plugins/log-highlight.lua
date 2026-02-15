return {
	"fei6409/log-highlight.nvim",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		keyword = {
			error = { "ERROR", "FATAL", "CRITICAL" },
			warning = { "WARN", "WARNING" },
			info = { "INFO" },
			debug = { "DEBUG", "TRACE" },
			pass = { "OK", "SUCCESS" },
		},
	},
}
