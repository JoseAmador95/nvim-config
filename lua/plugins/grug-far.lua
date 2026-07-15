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
				-- .git and node_modules are always excluded (permanent).
				extraArgs = "--glob=!**/.git/* --glob=!**/node_modules/*",
				-- no "e.g. ..." example placeholders in the input fields
				placeholders = { enabled = false },
				-- --hidden is ON by default but lives in the (toggleable) Flags
				-- input, so it can be turned off like the other options.
				defaults = { flags = "--hidden" },
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

		-- Search option toggles, grouped under <localleader>g. They flip a
		-- ripgrep flag in the Flags input (whose current value is visible in
		-- the panel), so which-key shows them as a discoverable menu.
		local option_toggles = {
			{ key = "h", flag = "--hidden", desc = "Hidden files" },
			{ key = "w", flag = "--word-regexp", desc = "Whole word" },
			{ key = "c", flag = "--ignore-case", desc = "Ignore case" },
			{ key = "l", flag = "--fixed-strings", desc = "Literal (no regex)" },
			{ key = "i", flag = "--no-ignore", desc = "Include ignored" },
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

					local wk_ok, wk = pcall(require, "which-key")
					if wk_ok then
						wk.add({ { "<localleader>g", group = "search options", buffer = ev.buf } })
					end

					for _, opt in ipairs(option_toggles) do
						vim.keymap.set("n", "<localleader>g" .. opt.key, function()
							gf.toggle_option(ev.buf, opt.flag)
						end, { buffer = ev.buf, desc = opt.desc })
					end

					-- Open the match under the cursor in a new tab
					vim.keymap.set("n", "<cr>", function()
						gf.open_entry_in_tab(ev.buf)
					end, { buffer = ev.buf, desc = "Open match in new tab" })
				end)
			end,
		})
	end,
}
