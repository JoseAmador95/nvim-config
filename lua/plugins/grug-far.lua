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
				-- buffer (its actions registry and its own buffer-local maps).
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(ev.buf) then
						return
					end

					local gf = require("config.grug-far")

					-- Register the "Search Options" toggle menu as a native
					-- grug-far action so it shows up in the g? help window
					-- (bound to <localleader>m), instead of leaking into which-key.
					gf.register_actions(ev.buf)

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
