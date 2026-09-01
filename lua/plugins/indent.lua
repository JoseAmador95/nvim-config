local redraw_profile = require("config.redraw_profile")
local deferred = require("config.deferred")
local palette = require("config.palette")

local opts = {
	debounce = redraw_profile.low_bandwidth() and 500 or 200,
	indent = {
		char = "│",
		tab_char = "│",
		highlight = { "IblIndent" },
	},
	scope = {
		enabled = not redraw_profile.low_bandwidth(),
		show_start = false,
		show_end = false,
		highlight = {
			"IblRainbow1",
			"IblRainbow2",
			"IblRainbow3",
			"IblRainbow4",
			"IblRainbow5",
			"IblRainbow6",
			"IblRainbow7",
		},
	},
	exclude = {
		filetypes = {
			"help",
			"dashboard",
			"oil",
			"Trouble",
			"lazy",
			"mason",
			"notify",
			"snacks_terminal",
		},
	},
}

return {
	"lukas-reineke/indent-blankline.nvim",
	main = "ibl",
	event = "BufReadPre",
	cond = function()
		return not vim.g.vscode
	end,
	opts = opts,
	config = function(_, config_opts)
		local ibl = deferred.load("ibl")
		local hooks = deferred.load("ibl.hooks")

		local function apply_hl()
			palette.apply()
		end

		hooks.register(hooks.type.HIGHLIGHT_SETUP, apply_hl)

		vim.api.nvim_create_autocmd("ColorScheme", {
			group = vim.api.nvim_create_augroup("IblRainbowColors", { clear = true }),
			callback = function()
				apply_hl()
				pcall(ibl.update, {})
			end,
		})

		-- Count how many ancestors the scope node has to get true nesting depth.
		-- This matches rainbow-delimiters' bracket nesting level, not indent column.
		hooks.register(hooks.type.SCOPE_HIGHLIGHT, function(_, _, scope, _)
			local depth = 0
			local node = scope:parent()
			while node do
				depth = depth + 1
				node = node:parent()
			end
			return ((depth - 2) % #palette.current().rainbow) + 1
		end)

		ibl.setup(config_opts)
	end,
}
