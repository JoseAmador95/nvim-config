-- snacks.picker: the single fuzzy finder for editor workflows.
return {
	"folke/snacks.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	priority = 1000,
	lazy = false,
	keys = {
		{
			"<leader>t",
			function()
				require("config.terminal").toggle_shell()
			end,
			desc = "Toggle terminal",
		},
		{
			"<leader>ff",
			function()
				Snacks.picker.files()
			end,
			desc = "Find files",
		},
		{
			"<leader>fb",
			function()
				Snacks.picker.buffers()
			end,
			desc = "Buffers",
		},
		{
			"<leader>fh",
			function()
				Snacks.picker.help()
			end,
			desc = "Help tags",
		},
		{
			"<leader>u",
			function()
				Snacks.picker.undo()
			end,
			desc = "Undo tree",
		},
	},
	---@type snacks.Config
	opts = {
		terminal = { enabled = true },
		notifier = {
			enabled = not require("config.pager").active,
			timeout = 3000,
		},
		scratch = {
			enabled = true,
			root = vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "scratch"),
		},
		image = {
			-- Enable the image machinery (Kitty graphics protocol; Ghostty). The
			-- diagram viewer (config.diagram) drives image rendering itself via the
			-- placement API, so disable the auto doc scanner -- that keeps Snacks
			-- from ever trying to convert mermaid via mmdc (Chromium) or pulling
			-- ImageMagick for image links.
			enabled = true,
			doc = { enabled = false },
		},
		-- Sole home screen for `nvim` without argv and for the reusable landing
		-- tab created after the final work tab closes. Session restore is always
		-- explicit, so the dashboard never disappears behind an automatic restore.
		dashboard = {
			enabled = true,
			sections = {
				{ section = "header" },
				{ section = "keys", gap = 1, padding = 1 },
				{ icon = " ", title = "Projects", section = "projects", session = false, padding = 1 },
				{ icon = " ", title = "Recent", section = "recent_files", padding = 1 },
				{ section = "startup" },
			},
			preset = {
				keys = {
					{
						icon = " ",
						key = "n",
						desc = "New file",
						action = function()
							local tabpage = vim.api.nvim_get_current_tabpage()
							vim.api.nvim_cmd({ cmd = "enew" }, {})
							require("config.tabs").unmark_home(tabpage)
						end,
					},
					{
						icon = " ",
						key = "f",
						desc = "Find file",
						action = function()
							Snacks.picker.files()
						end,
					},
					{
						icon = " ",
						key = "g",
						desc = "Grep",
						action = function()
							Snacks.picker.grep()
						end,
					},
					{ icon = " ", key = "s", desc = "Restore session", action = ":AutoSession search" },
					{ icon = " ", key = "p", desc = "Action palette", action = ":MenuOpen" },
					{
						icon = " ",
						key = "c",
						desc = "Config",
						action = function()
							Snacks.picker.files({ cwd = vim.fn.stdpath("config") })
						end,
					},
					{
						icon = "󰊢",
						key = "l",
						desc = "Lazygit",
						-- Reuse the existing lazygit flow (<leader>gl -> toggle_lazygit
						-- in lua/plugins/lazygit.lua) instead of reimplementing it.
						action = function()
							vim.schedule(function()
								local keys = vim.api.nvim_replace_termcodes("<leader>gl", true, false, true)
								vim.api.nvim_feedkeys(keys, "m", false)
							end)
						end,
					},
					{ icon = " ", key = "q", desc = "Quit", action = ":qa" },
				},
			},
		},
		picker = {
			actions = {
				-- Open the selection in a tab, reusing an existing one if the file
				-- is already open.
				open_in_tab = function(picker, item)
					picker:close()
					if not item then
						return
					end
					local path = item.file
					if (not path or path == "") and item.buf then
						path = vim.api.nvim_buf_get_name(item.buf)
					end
					if not path or path == "" then
						return
					end
					local pos = item.pos or {}
					-- item.pos is { row (1-indexed), col (0-indexed) };
					-- open_file_in_tab expects a 1-indexed column.
					require("config.editor").open_file_in_tab(path, {
						lnum = pos[1] or 1,
						col = (pos[2] or 0) + 1,
					})
				end,
			},
			-- Global confirm for file-like sources (files, buffers, grep, recent,
			-- diagnostics). Sources with their own confirm (commands, help, keymaps,
			-- undo, git_log) keep their native behaviour.
			confirm = "open_in_tab",
			sources = {
				files = { hidden = true },
				grep = { hidden = true },
				-- `vim.ui.select` runs through the "select" source, which wires its
				-- own confirm action to resolve the on_choice callback. The
				-- global confirm = "open_in_tab" shortcut above would clobber that
				-- (config.get re-applies the shortcut over actions.confirm), leaving
				-- the choice dropped. Setting confirm = false disables the shortcut
				-- for this source so its native confirm survives.
				select = { confirm = false },
			},
			win = {
				input = {
					keys = {
						["<C-j>"] = { "list_down", mode = { "i", "n" } },
						["<C-l>"] = { "list_down", mode = { "i", "n" } },
						["<C-k>"] = { "list_up", mode = { "i", "n" } },
						["<C-h>"] = { "list_up", mode = { "i", "n" } },
						["<C-q>"] = { "close", mode = { "i", "n" } },
						["<C-p>"] = { "history_back", mode = { "i", "n" } },
						["<C-n>"] = { "history_forward", mode = { "i", "n" } },
						["<C-Up>"] = { "history_back", mode = { "i", "n" } },
						["<C-Down>"] = { "history_forward", mode = { "i", "n" } },
					},
				},
			},
		},
	},
}
