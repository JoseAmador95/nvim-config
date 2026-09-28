-- oil.nvim: edit the filesystem like a normal buffer. Replaces neo-tree as the
-- file explorer. Opened as a floating window (not a lateral panel) via
-- `<leader>e`, which toggles it.
--
-- File opening is routed through `config.editor.open_file_in_tab` so selecting a
-- file keeps the repo's tab-based navigation (reuse a tab if the file is already
-- open) instead of replacing the buffer under the float. Directories are
-- navigated inside the float as usual.

local deferred = require("config.deferred")
local lazy = require("lazy")

local function activate_git_status(args)
	local buf = args.data and args.data.buf
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	lazy.load({ plugins = { "oil-git-status.nvim" } })
	deferred.load("oil-git-status").refresh_buffer(buf)
end

return {
	{
		"stevearc/oil.nvim",
		main = "config.oil",
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
		-- Lazy's generic User-event replay skips ungrouped autocmds, including the
		-- upstream OilEnter listener. Keep the plugin dormant and let this tiny host
		-- listener load it with the original buffer still available, then refresh
		-- that first buffer explicitly. Future events use the upstream listener.
		lazy = true,
		init = function()
			vim.api.nvim_create_autocmd("User", {
				group = vim.api.nvim_create_augroup("NvimConfigOilGitStatus", { clear = true }),
				pattern = "OilEnter",
				once = true,
				callback = activate_git_status,
				desc = "Load Git status for the first Oil buffer",
			})
		end,
		dependencies = { "stevearc/oil.nvim" },
		config = true,
	},
}
