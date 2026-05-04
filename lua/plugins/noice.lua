return {
	"folke/noice.nvim",
	event = "VeryLazy",
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = {
		"MunifTanjim/nui.nvim",
		"rcarriga/nvim-notify",
	},
	opts = {
		cmdline = {
			enabled = true,
			view = "cmdline_popup",
			format = {
				cmdline = { pattern = "^:", icon = ":", lang = "vim" },
				search_down = { kind = "search", pattern = "^/", icon = " ", lang = "regex" },
				search_up = { kind = "search", pattern = "^%?", icon = " ", lang = "regex" },
				filter = { pattern = "^:%s*!", icon = "$", lang = "bash" },
				lua = { pattern = { "^:%s*lua%s+", "^:%s*lua%s*=%s*", "^:%s*=%s*" }, icon = "", lang = "lua" },
				help = { pattern = "^:%s*he?l?p?%s+", icon = "?" },
			},
		},
		messages = {
			enabled = true,
			view = "notify",
			view_error = "notify",
			view_warn = "notify",
			view_history = "messages",
			view_search = "virtualtext",
		},
		popupmenu = {
			enabled = true,
			backend = "nui",
		},
		notify = {
			enabled = true,
			view = "notify",
		},
		lsp = {
			progress = {
				enabled = true,
				format = "lsp_progress",
				format_done = "lsp_progress_done",
				throttle = 1000 / 30,
				view = "mini",
			},
			override = {
				["vim.lsp.util.convert_input_to_markdown_lines"] = true,
				["vim.lsp.util.stylize_markdown"] = true,
				["cmp.entry.get_documentation"] = true,
			},
			hover = { enabled = false }, -- keep our own hover handler
			signature = { enabled = false }, -- no auto signature popup
		},
		presets = {
			bottom_search = true, -- classic search bar at bottom
			command_palette = true, -- cmdline popup with completion
			long_message_to_split = true, -- long messages go to a split
			inc_rename = false,
			lsp_doc_border = true,
		},
		routes = {
			-- Silence common noise
			{ filter = { event = "msg_show", find = "written" }, opts = { skip = true } },
			{ filter = { event = "msg_show", find = "%d+ lines" }, opts = { skip = true } },
			{ filter = { event = "msg_show", find = "search hit" }, opts = { skip = true } },
			{ filter = { event = "msg_show", find = "Already at" }, opts = { skip = true } },
		},
	},
}
