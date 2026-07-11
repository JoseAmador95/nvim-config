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
			-- We own `vim.notify` in `config` below (to also record into the
			-- native `:messages`), so noice must not manage it — otherwise it
			-- warns that `vim.notify` was overwritten. nvim-notify still renders
			-- the toast (called directly from our wrapper).
			enabled = false,
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
			-- `vim.notify` is mirrored into the native `:messages` history by the
			-- wrapper in `config` below, tagged with a leading `[notify]`. Skip
			-- that tagged echo here so noice does not show a duplicate toast.
			{ filter = { event = "msg_show", find = "^%[notify%]" }, opts = { skip = true } },
		},
	},
	-- `<leader>fn` opens the native `:messages` (the single source now: echo +
	-- notifications, via the wrapper below). `<leader>fN` dismisses toasts,
	-- which has no native equivalent.
	keys = {
		{ "<leader>fn", "<cmd>messages<cr>", desc = "Messages" },
		{ "<leader>fN", function() require("noice").cmd("dismiss") end, desc = "Dismiss notifications" },
	},
	config = function(_, opts)
		require("noice").setup(opts)

		-- Own `vim.notify` so notifications are ALSO recorded in the native
		-- `:messages` history (noice by itself routes them only to transient
		-- toasts). noice's own notify handling is disabled above
		-- (`notify.enabled = false`), so this override is expected and does not
		-- trigger noice's "vim.notify overwritten" warning. The toast is still
		-- rendered directly via nvim-notify; the `[notify]` tag is filtered by
		-- the route above so noice doesn't echo a duplicate.
		vim.notify = function(msg, level, notify_opts)
			local text = type(msg) == "table" and table.concat(msg, "\n") or tostring(msg)
			local hl = "Normal"
			if level == vim.log.levels.ERROR then
				hl = "ErrorMsg"
			elseif level == vim.log.levels.WARN then
				hl = "WarningMsg"
			end
			pcall(vim.api.nvim_echo, { { "[notify] " .. text, hl } }, true, {})
			local ok, nvim_notify = pcall(require, "notify")
			if ok then
				return nvim_notify(msg, level, notify_opts)
			end
		end
	end,
}
