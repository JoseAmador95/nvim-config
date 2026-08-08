return {
	"akinsho/bufferline.nvim",
	version = "*",
	event = "UIEnter",
	cond = function()
		return not vim.g.vscode and not require("config.pager").active
	end,
	dependencies = { "nvim-tree/nvim-web-devicons" },
	config = function()
		local tabs = require("config.tabs")
		local palette = require("config.palette")
		local function request_close(tabpage)
			return tabs.request_close(tabpage)
		end
		local function open_context_menu()
			return require("config.menu").open_context({ move_cursor = false })
		end

		require("bufferline").setup({
			options = {
				mode = "tabs",
				diagnostics = "nvim_lsp",
				show_buffer_icons = true,
				show_buffer_close_icons = true,
				show_close_icon = false,
				close_command = request_close,
				right_mouse_command = open_context_menu,
				middle_mouse_command = request_close,
				separator_style = "thin",
				hover = { enabled = true },
				numbers = "none",
			},
			highlights = function(defaults)
				local colors = palette.current()
				local highlights = {}
				for name in pairs(defaults.highlights) do
					if name:match("_selected$") then
						highlights[name] = { bg = colors.selected_bg, fg = colors.selected_fg }
					end
				end
				for _, name in ipairs({ "tab_selected", "buffer_selected" }) do
					highlights[name].bold = true
					highlights[name].italic = false
				end
				highlights.separator_selected.fg = colors.accent
				highlights.indicator_selected.fg = colors.accent
				highlights.close_button_selected.fg = colors.accent
				if highlights.modified_selected then
					highlights.modified_selected.fg = colors.warning
				end
				return highlights
			end,
		})
	end,
}
