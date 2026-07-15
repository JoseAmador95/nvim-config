return {
	"MagicDuck/grug-far.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{
			"<leader>fg",
			function()
				-- toggle_instance keeps the search intact when returning to the panel
				require("grug-far").toggle_instance({
					instanceName = "far",
					staticTitle = "Search & Replace",
				})
			end,
			desc = "Search in files",
		},
	},
	opts = {
		startInInsertMode = true,
		-- open the search panel in its own full-window tab (not a split)
		windowCreationCommand = "tabnew",
		engines = {
			ripgrep = {
				-- hidden files ON; .git and node_modules always excluded; .gitignore respected
				extraArgs = "--hidden --glob=!**/.git/* --glob=!**/node_modules/*",
			},
		},
		keymaps = {
			-- keep spectre's muscle memory
			close = { n = "<leader>q" },
			qflist = { n = "<leader>qf" },
			-- <cr> (gotoLocation) is overridden below to open the hit in a tab
		},
	},
	config = function(_, opts)
		require("grug-far").setup(opts)

		vim.api.nvim_create_autocmd("FileType", {
			pattern = "grug-far",
			callback = function(ev)
				-- Deferred so these run after grug-far has finished building the
				-- buffer and its own window (winbar needs the window to exist).
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(ev.buf) then
						return
					end

					local gf = require("config.grug-far")

					-- Always-visible options bar at the top of the panel, with
					-- live [x]/[ ] state; click a box (or press <localleader>m)
					-- to toggle. No which-key / g? needed to discover options.
					gf.render_winbar(ev.buf)
					vim.keymap.set("n", "<localleader>m", function()
						gf.options_menu(ev.buf)
					end, { buffer = ev.buf, desc = "Search options" })

					-- Open the match under the cursor in a new tab
					vim.keymap.set("n", "<cr>", function()
						gf.open_entry_in_tab(ev.buf)
					end, { buffer = ev.buf, desc = "Open match in new tab" })
				end)
			end,
		})

		vim.api.nvim_create_autocmd("BufWipeout", {
			pattern = "*",
			callback = function(ev)
				if vim.bo[ev.buf].filetype == "grug-far" then
					require("config.grug-far").forget(ev.buf)
				end
			end,
		})
	end,
}
