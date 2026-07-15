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
				-- Deferred so these win over grug-far's own buffer-local maps,
				-- which are set while the buffer is being created.
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(ev.buf) then
						return
					end

					-- Toggle including gitignored files in the current search
					vim.keymap.set("n", "<leader>ti", function()
						require("grug-far").get_instance(ev.buf):toggle_flags({ "--no-ignore" })
					end, { buffer = ev.buf, desc = "Toggle search ignored files" })

					-- Open the match under the cursor in a new tab
					vim.keymap.set("n", "<cr>", function()
						require("config.grug-far").open_entry_in_tab(ev.buf)
					end, { buffer = ev.buf, desc = "Open match in new tab" })
				end)
			end,
		})
	end,
}
