return {
	"fei6409/log-highlight.nvim",
	event = "FileType",
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		pattern = { "*.log", "*.txt" },
	},
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
