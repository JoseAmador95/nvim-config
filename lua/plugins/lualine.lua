local redraw_profile = require("config.redraw_profile")

return {
	"nvim-lualine/lualine.nvim",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = {
		"nvim-tree/nvim-web-devicons",
	},
	config = function()
		local palette = require("config.palette")
		local lualine = require("lualine")
		local statusline = require("config.statusline")

		local function theme()
			local colors = palette.current()
			local hex = palette.hex
			local base = { a = { bg = hex(colors.selected_bg), fg = hex(colors.selected_fg), gui = "bold" } }
			local function mode(color)
				return {
					a = { bg = hex(color), fg = hex(colors.background), gui = "bold" },
					b = { bg = hex(colors.selected_bg), fg = hex(colors.selected_fg) },
					c = { bg = hex(colors.background), fg = hex(colors.foreground) },
				}
			end
			base.b = { bg = hex(colors.selected_bg), fg = hex(colors.selected_fg) }
			base.c = { bg = hex(colors.background), fg = hex(colors.foreground) }
			return {
				normal = base,
				insert = mode(colors.rainbow[5]),
				visual = mode(colors.rainbow[4]),
				replace = mode(colors.rainbow[6]),
				command = mode(colors.warning),
				inactive = {
					a = { bg = hex(colors.background), fg = hex(colors.muted) },
					b = { bg = hex(colors.background), fg = hex(colors.muted) },
					c = { bg = hex(colors.background), fg = hex(colors.muted) },
				},
			}
		end

		local function setup()
			lualine.setup({
				options = {
					refresh = { refresh_time = redraw_profile.low_bandwidth() and 100 or 16 },
					theme = theme(),
					icons_enabled = true,
					component_separators = "",
					section_separators = { left = "", right = "" },
					disabled_filetypes = {
						statusline = { "snacks_dashboard" },
						winbar = {},
					},
					always_divide_middle = true,
				},

				sections = {
					lualine_a = {
						{
							"mode",
							fmt = function(value)
								return value:sub(1, 1)
							end,
						},
					},
					lualine_b = { "branch" },
					lualine_c = {
						{ "filename", path = 1 }, -- relative path
						statusline.navic,
					},
					lualine_x = {
						statusline.review,
						statusline.devcontainer,
						statusline.python,
						statusline.cmake,
						statusline.clangd,
						"diagnostics",
						"filetype",
					},
					lualine_y = {},
					lualine_z = { "location" },
				},

				inactive_sections = {
					lualine_a = {},
					lualine_b = {},
					lualine_c = {
						{ "filename", path = 1 },
					},
					lualine_x = { "location" },
					lualine_y = {},
					lualine_z = {},
				},

				extensions = {
					"quickfix",
				},
			})
		end

		setup()
		statusline.setup_refresh()
		vim.api.nvim_create_autocmd("ColorScheme", {
			group = vim.api.nvim_create_augroup("NvimConfigLualineTheme", { clear = true }),
			callback = function()
				vim.schedule(setup)
			end,
		})
	end,
}
