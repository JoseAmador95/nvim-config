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

		-- Friendly toggle UI for the common search options (case, word, literal,
		-- ignored) instead of hand-typing ripgrep flags. `go` opens a checkbox
		-- menu; the direct keys are shortcuts for the same toggles.
		local option_keys = {
			gi = "--ignore-case",
			gw = "--word-regexp",
			gl = "--fixed-strings",
			gu = "--no-ignore",
		}

		vim.api.nvim_create_autocmd("FileType", {
			pattern = "grug-far",
			callback = function(ev)
				-- Deferred so these win over grug-far's own buffer-local maps,
				-- which are set while the buffer is being created.
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(ev.buf) then
						return
					end

					local gf = require("config.grug-far")

					-- Options menu (checkbox-style popup)
					vim.keymap.set("n", "go", function()
						gf.options_menu(ev.buf)
					end, { buffer = ev.buf, desc = "Search options menu" })

					-- Direct toggles for each option
					for lhs, flag in pairs(option_keys) do
						vim.keymap.set("n", lhs, function()
							gf.toggle_option(ev.buf, flag)
						end, { buffer = ev.buf, desc = "Toggle " .. flag })
					end

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
