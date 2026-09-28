return {
	{
		"RaafatTurki/hex.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		event = "BufReadPre",
		cmd = { "HexDump", "HexAssemble", "HexToggle" },
		main = "config.hex",
		opts = {},
	},
}
