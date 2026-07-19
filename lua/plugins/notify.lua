return {
	"rcarriga/nvim-notify",
	event = "UIEnter",
	cond = function()
		return not vim.g.vscode
	end,
	config = function()
		-- vim.notify is owned by the noice.lua wrapper, which delegates here.
		require("notify").setup({
			timeout = 3000,
			-- The colorscheme runs with a transparent background (always in
			-- light mode), so NotifyBackground/Normal carry no bg and the
			-- fade animation can't derive one. Give it an explicit colour
			-- matching the current background instead.
			background_colour = function()
				return vim.o.background == "light" and "#FFFFFF" or "#000000"
			end,
			render = "default",
			stages = "fade_in_slide_out",
		})
	end,
}
