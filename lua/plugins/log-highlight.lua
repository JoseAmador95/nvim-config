return {
	"fei6409/log-highlight.nvim",
	event = "FileType",
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		-- `*.dump` es el volcado de scrollback de Zellij: EditScrollback escribe en
		-- $TMPDIR/<uuid>.dump y abre este nvim ahí, sin extensión que dispare un filetype.
		pattern = { "*.log", "*.txt", "*.dump" },
		keyword = {
			error = { "ERROR", "FATAL", "CRITICAL" },
			warning = { "WARN", "WARNING" },
			info = { "INFO" },
			debug = { "DEBUG", "TRACE" },
			pass = { "OK", "SUCCESS" },
		},
	},
}
