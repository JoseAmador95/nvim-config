-- snacks.picker: modern fuzzy finder, primary picker for day-to-day flows.
-- Telescope stays installed only as a dependency of remote-nvim and bookmarks.
return {
	"folke/snacks.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	priority = 1000,
	lazy = false,
	keys = {
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
		image = {
			-- Enable the image machinery (Kitty graphics protocol; Ghostty). The
			-- diagram viewer (config.diagram) drives image rendering itself via the
			-- placement API, so disable the auto doc scanner -- that keeps Snacks
			-- from ever trying to convert mermaid via mmdc (Chromium) or pulling
			-- ImageMagick for image links.
			enabled = true,
			doc = { enabled = false },
		},
		picker = {
			actions = {
				-- Open the selection in a tab, reusing an existing one if the file
				-- is already open. Mirrors the old Telescope smart_open().
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
