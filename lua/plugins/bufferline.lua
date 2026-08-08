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
		local function request_close(tabpage)
			return tabs.request_close(tabpage)
		end

		require("bufferline").setup({
			options = {
				mode = "tabs",
				diagnostics = "nvim_lsp",
				show_buffer_icons = true,
				show_buffer_close_icons = true,
				show_close_icon = false,
				close_command = request_close,
				right_mouse_command = request_close,
				middle_mouse_command = request_close,
				separator_style = "thin",
				hover = { enabled = true },
				numbers = "none",
			},
			highlights = function(defaults)
				local visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
				local selected = visual.bg and visual or vim.api.nvim_get_hl(0, { name = "PmenuSel", link = false })
				local highlights = {}
				for name in pairs(defaults.highlights) do
					if name:match("_selected$") then
						highlights[name] = { bg = selected.bg }
					end
				end
				for _, name in ipairs({ "tab_selected", "buffer_selected" }) do
					highlights[name].bold = true
					highlights[name].italic = false
				end
				highlights.indicator_selected.fg = {
					highlight = "DiagnosticInfo",
					attribute = "fg",
				}
				return highlights
			end,
		})
	end,
}
