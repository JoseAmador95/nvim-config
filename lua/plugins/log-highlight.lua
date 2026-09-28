return {
	"fei6409/log-highlight.nvim",
	-- Put the syntax backend on runtimepath before filetype detection, but do
	-- not call its setup(): upstream setup generates after/syntax/log.vim under
	-- stdpath(data) on every process. The host owns detection and fixed keyword
	-- additions without runtime state writes.
	event = { "BufReadPre", "BufNewFile" },
	cond = function()
		return not vim.g.vscode
	end,
	init = function()
		vim.filetype.add({ extension = { log = "log" } })
	end,
}
