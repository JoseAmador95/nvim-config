-- Centers the content window between two empty padding buffers. Not enabled on
-- its own: config.markdown_reading drives enable/disable in lockstep with
-- render-markdown so markdown reads Obsidian-style (centered, ~80 columns),
-- while other filetypes are untouched.
return {
	"shortcuts/no-neck-pain.nvim",
	cmd = "NoNeckPain",
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		width = 80,
		-- Below this content width the sides would be too thin to bother with;
		-- skip centering on narrow windows/splits.
		minSideBufferWidth = 20,
		autocmds = {
			-- The reading view is driven by render-markdown, not by these.
			enableOnVimEnter = false,
			enableOnTabEnter = false,
			-- Repaint the side buffers when the theme (and background) changes,
			-- so they keep matching the editor background.
			reloadOnColorSchemeChange = true,
		},
		buffers = {
			setNames = false,
			-- Side padding buffers inherit the editor background (Normal). In
			-- light mode Normal is transparent, so they fall through to the
			-- terminal's white -- matching the content window.
			wo = {
				number = false,
				relativenumber = false,
				cursorline = false,
			},
		},
	},
}
