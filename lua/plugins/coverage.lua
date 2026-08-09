return {
	"andythigpen/nvim-coverage",
	commit = "a939e425e363319d952a6c35fb3f38b34041ded2",
	cmd = { "CoverageLoad", "CoverageSummary", "CoverageClear" },
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-lua/plenary.nvim" },
	config = function()
		require("coverage").setup({
			commands = false,
			auto_reload = false,
		})
		require("config.coverage").setup()
	end,
}
