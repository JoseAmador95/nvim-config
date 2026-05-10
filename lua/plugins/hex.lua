return {
	{
		"RaafatTurki/hex.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "HexDump", "HexAssemble", "HexToggle" },
		config = function()
			require("hex").setup()
		end,
	},
}
