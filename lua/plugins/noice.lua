return {
	"folke/noice.nvim",
	event = "VeryLazy",
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = {
		"MunifTanjim/nui.nvim",
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
			-- The config owns `vim.notify` so it can also record an exact native
			-- `:messages` entry before sending one toast to Snacks Notifier.
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
			-- `vim.notify` is mirrored into native `:messages` with this dedicated
			-- echo kind. The toast is sent directly to Snacks, so Noice must never
			-- turn the echo into a second notification.
			{ filter = { event = "msg_show", kind = "nvim_config_notify" }, opts = { skip = true } },
		},
	},
	-- `<leader>fn` opens the native `:messages` (the single source now: echo +
	-- notifications, via the wrapper below). `<leader>fN` dismisses toasts,
	-- which has no native equivalent.
	keys = {
		{ "<leader>fn", "<cmd>messages<cr>", desc = "Messages" },
		{
			"<leader>fN",
			function()
				require("snacks").notifier.hide()
			end,
			desc = "Dismiss notifications",
		},
	},
	config = function(_, opts)
		require("noice").setup(opts)

		-- Own `vim.notify`: mirror the text into native history once, then create
		-- exactly one Snacks toast. Noice's notify source is disabled above, so it
		-- cannot wrap this function or feed the toast back into itself.
		vim.notify = function(msg, level, notify_opts)
			local function dispatch()
				local text
				if msg ~= nil then
					if type(msg) == "table" then
						local lines = {}
						for _, value in ipairs(msg) do
							lines[#lines + 1] = tostring(value)
						end
						text = table.concat(lines, "\n")
					else
						text = type(msg) == "string" and msg or tostring(msg)
					end
					local hl = "Normal"
					if level == vim.log.levels.ERROR then
						hl = "ErrorMsg"
					elseif level == vim.log.levels.WARN then
						hl = "WarningMsg"
					end
					pcall(vim.api.nvim_echo, { { text, hl } }, true, {
						kind = "nvim_config_notify",
						err = level == vim.log.levels.ERROR,
					})
				end
				return require("snacks").notifier.notify(text or "", level, notify_opts)
			end

			if vim.in_fast_event() then
				vim.schedule(dispatch)
				return
			end
			return dispatch()
		end
	end,
}
