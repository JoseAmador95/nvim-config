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
		{
			"<leader>fw",
			function()
				require("grug-far").open({ prefills = { search = vim.fn.expand("<cword>") } })
			end,
			mode = "n",
			desc = "Search word in files",
		},
		{
			"<leader>fw",
			function()
				require("grug-far").with_visual_selection()
			end,
			mode = "x",
			desc = "Search selection in files",
		},
	},
	opts = {
		startInInsertMode = true,
		-- open the search panel in a centered floating window (see
		-- config.grug-far.open_float_window). grug-far runs this via vim.cmd on
		-- both the initial open and every toggle_instance re-show, so the panel
		-- is always a float.
		windowCreationCommand = "lua require('config.grug-far').open_float_window()",
		-- more compact inputs header before the results
		showCompactInputs = true,
		engines = {
			ripgrep = {
				-- .git and node_modules are always excluded (permanent).
				extraArgs = "--glob=!**/.git/* --glob=!**/node_modules/*",
				-- no "e.g. ..." example placeholders in the input fields
				placeholders = { enabled = false },
				-- --hidden and --smart-case are ON by default but live in the
				-- (toggleable) Flags input. smart-case = case-insensitive unless
				-- the query contains an uppercase letter.
				defaults = { flags = "--hidden --smart-case" },
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

					-- <CR>: toggle the fold on a file path line, or open the
					-- match under the cursor in a new tab
					vim.keymap.set("n", "<cr>", function()
						gf.on_enter(ev.buf)
					end, { buffer = ev.buf, desc = "Toggle fold / open match in tab" })

					-- Close the float from normal mode with `q` or `<Esc>` (in
					-- addition to <leader>q). These go through the window/buffer
					-- API, which dismisses the float reliably where :q sometimes
					-- doesn't.
					for _, lhs in ipairs({ "q", "<esc>" }) do
						vim.keymap.set("n", lhs, function()
							gf.dismiss(ev.buf)
						end, { buffer = ev.buf, desc = "Close search panel" })
					end

					-- :q / :quit sometimes fails to close this float; finish the
					-- job from the API afterwards (and wipe throwaway instances so
					-- hidden grug-far buffers don't accumulate).
					vim.api.nvim_create_autocmd("QuitPre", {
						buffer = ev.buf,
						callback = function()
							gf.on_quit(ev.buf)
						end,
					})
				end)
			end,
		})
	end,
}
