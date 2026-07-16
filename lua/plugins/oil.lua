-- oil.nvim: edit the filesystem like a normal buffer. Replaces neo-tree as the
-- file explorer. Opened as a floating window (not a lateral panel) via
-- `<leader>e`, which toggles it.
--
-- File opening is routed through `config.editor.open_file_in_tab` so selecting a
-- file keeps the repo's tab-based navigation (reuse a tab if the file is already
-- open) instead of replacing the buffer under the float. Directories are
-- navigated inside the float as usual.

-- Open the entry under the cursor:
--   * directory / ".."  -> navigate into it inside the float
--   * file              -> close the float and open it in a tab (reusing one)
-- Falls back to oil's native select for adapters without a local path (ssh, ...).
local function open_selection()
	local oil = require("oil")
	local entry = oil.get_cursor_entry()
	if not entry then
		return
	end

	if entry.type == "directory" then
		oil.select()
		return
	end

	local dir = oil.get_current_dir()
	if not dir then
		oil.select()
		return
	end

	oil.close()
	require("config.editor").open_file_in_tab(dir .. entry.name)
end

return {
	{
		"stevearc/oil.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		-- Not lazy: oil must be loaded before a directory buffer is entered so
		-- `default_file_explorer` can hijack `nvim .` and `:e some/dir/`.
		lazy = false,
		dependencies = {
			"nvim-tree/nvim-web-devicons",
		},
		keys = {
			{
				"<leader>e",
				function()
					require("oil").toggle_float()
				end,
				desc = "Open file explorer (float)",
			},
		},
		---@type oil.SetupOpts
		opts = {
			-- Take over directory buffers (replaces neo-tree's BufEnter hack that
			-- deleted directory buffers by hand).
			default_file_explorer = true,
			-- Deletes (dd + :w) go to the system trash instead of an unrecoverable
			-- rm. Needs a trash backend on the host (gio / trash-cli / ...).
			delete_to_trash = true,
			-- Skip the confirmation prompt for trivial renames/creates/moves; real
			-- deletes still confirm.
			skip_confirm_for_simple_edits = true,
			-- Two sign columns for oil-git-status (index + working tree).
			win_options = {
				signcolumn = "yes:2",
			},
			view_options = {
				-- Match the old neo-tree behaviour: show dotfiles and gitignored.
				show_hidden = true,
			},
			float = {
				padding = 2,
				max_width = 0.7,
				max_height = 0.8,
				border = "rounded",
				win_options = {
					winblend = 0,
				},
				preview_split = "auto",
			},
			keymaps = {
				-- Route file opening through the repo's tab helper; keep oil's
				-- editable-buffer model intact (no h/l hijacking).
				["<CR>"] = {
					desc = "Open (files reuse a tab, dirs navigate in)",
					callback = open_selection,
				},
				["<C-t>"] = "actions.parent",
				["?"] = "actions.show_help",
				["q"] = "actions.close",
			},
		},
	},
	{
		-- Git status signs in oil's two sign columns (index + working tree).
		-- This is the one thing oil doesn't do out of the box that neo-tree did.
		"refractalize/oil-git-status.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		-- Not lazy: nothing require()s this plugin, so with the repo's
		-- `defaults = { lazy = true }` it would install but never load, and its
		-- `User OilEnter` autocmd would never register (no signs). Load it at
		-- startup so the autocmd is in place before the first oil buffer opens.
		lazy = false,
		dependencies = { "stevearc/oil.nvim" },
		config = true,
	},
}
