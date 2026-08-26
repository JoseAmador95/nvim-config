return {
	"dlyongemallo/diffview-plus.nvim",
	version = "v0.37",
	cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-lua/plenary.nvim" },
	config = function()
		local actions = require("diffview.actions")
		local review = require("config.review_diffview")
		local review_commands = require("config.code_review")
		local help_groups = review_commands.help_groups()
		require("diffview").setup({
			enhanced_diff_hl = true,
			hooks = review.hooks(),
			keymaps = {
				view = {
					["<tab>"] = actions.select_next_entry,
					["<s-tab>"] = actions.select_prev_entry,
					["g<C-x>"] = review.layout_or(actions.cycle_layout),
					["q"] = review.close_or(actions.close),
					["gf"] = review.code_or(actions.goto_file_edit),
					["<C-w><C-f>"] = review.code_or(actions.goto_file_split),
					["<C-w>gf"] = review.code_or(actions.goto_file_tab),
					["<leader>co"] = review.guard(actions.conflict_choose("ours")),
					["<leader>ct"] = review.guard(actions.conflict_choose("theirs")),
					["<leader>cb"] = review.guard(actions.conflict_choose("base")),
					["<leader>ca"] = review.guard(actions.conflict_choose("all")),
					["dx"] = review.guard(actions.conflict_choose("none")),
					["<leader>cO"] = review.guard(actions.conflict_choose_all("ours")),
					["<leader>cT"] = review.guard(actions.conflict_choose_all("theirs")),
					["<leader>cB"] = review.guard(actions.conflict_choose_all("base")),
					["<leader>cA"] = review.guard(actions.conflict_choose_all("all")),
					["dX"] = review.guard(actions.conflict_choose_all("none")),
				},
				diff1 = {
					{
						"n",
						"g?",
						review.help_or(
							actions.help({ "view", "diff1" }),
							actions.help({
								"view",
								"diff1",
								help_groups.common,
								help_groups.diff_line,
								help_groups.file,
							})
						),
						{ desc = "Open the help panel" },
					},
				},
				file_panel = {
					{
						"n",
						"g?",
						review.help_or(
							actions.help("file_panel"),
							actions.help({ "file_panel", help_groups.common, help_groups.file })
						),
						{ desc = "Open the help panel" },
					},
					["<cr>"] = review.focus_entry_or(actions.select_entry, actions.focus_entry),
					["j"] = actions.next_entry,
					["k"] = actions.prev_entry,
					["q"] = review.close_or(actions.close),
					["gf"] = review.code_or(actions.goto_file_edit),
					["<C-w><C-f>"] = review.code_or(actions.goto_file_split),
					["<C-w>gf"] = review.code_or(actions.goto_file_tab),
					["R"] = review.refresh_or(actions.refresh_files),
					["-"] = review.guard(actions.toggle_stage_entry),
					["s"] = review.guard(actions.toggle_stage_entry),
					["S"] = review.guard(actions.stage_all),
					["U"] = review.guard(actions.unstage_all),
					["X"] = review.guard(actions.restore_entry),
					["<leader>cO"] = review.guard(actions.conflict_choose_all("ours")),
					["<leader>cT"] = review.guard(actions.conflict_choose_all("theirs")),
					["<leader>cB"] = review.guard(actions.conflict_choose_all("base")),
					["<leader>cA"] = review.guard(actions.conflict_choose_all("all")),
					["dX"] = review.guard(actions.conflict_choose_all("none")),
				},
				file_history_panel = {
					{
						"n",
						"g?",
						review.help_or(
							actions.help("file_history_panel"),
							actions.help({ "file_history_panel", help_groups.common })
						),
						{ desc = "Open the help panel" },
					},
					["<cr>"] = review.focus_entry_or(actions.select_entry, actions.focus_entry),
					["q"] = review.close_or(actions.close),
					["g!"] = review.guard(actions.options),
					["<C-A-d>"] = review.guard(actions.open_in_diffview),
					["gf"] = review.code_or(actions.goto_file_edit),
					["<C-w><C-f>"] = review.code_or(actions.goto_file_split),
					["<C-w>gf"] = review.code_or(actions.goto_file_tab),
					["X"] = review.guard(actions.restore_entry),
				},
				diff1_inline = {
					{
						{ "n", "x" },
						"do",
						review.guard(actions.diffget_inline),
						{ desc = "Obtain the old-side hunk unless the view is read-only" },
					},
					{
						"n",
						"g?",
						review.help_or(
							actions.help({ "view", "diff1", "diff1_inline" }),
							actions.help({
								"view",
								"diff1",
								"diff1_inline",
								help_groups.common,
								help_groups.diff_line,
								help_groups.file,
							})
						),
						{ desc = "Open the help panel" },
					},
				},
				diff2 = {
					{
						"n",
						"g?",
						review.help_or(
							actions.help({ "view", "diff2" }),
							actions.help({
								"view",
								"diff2",
								help_groups.common,
								help_groups.diff_line,
								help_groups.file,
							})
						),
						{ desc = "Open the help panel" },
					},
				},
				diff3 = {
					{
						"n",
						"g?",
						review.help_or(
							actions.help({ "view", "diff3" }),
							actions.help({ "view", "diff3", help_groups.common, help_groups.diff_line })
						),
						{ desc = "Open the help panel" },
					},
					{
						{ "n", "x" },
						"2do",
						review.guard(actions.diffget("ours")),
						{ desc = "Obtain the diff hunk from OURS unless the view is read-only" },
					},
					{
						{ "n", "x" },
						"3do",
						review.guard(actions.diffget("theirs")),
						{ desc = "Obtain the diff hunk from THEIRS unless the view is read-only" },
					},
				},
				diff4 = {
					{
						"n",
						"g?",
						review.help_or(
							actions.help({ "view", "diff4" }),
							actions.help({ "view", "diff4", help_groups.common, help_groups.diff_line })
						),
						{ desc = "Open the help panel" },
					},
					{
						{ "n", "x" },
						"1do",
						review.guard(actions.diffget("base")),
						{ desc = "Obtain the diff hunk from BASE unless the view is read-only" },
					},
					{
						{ "n", "x" },
						"2do",
						review.guard(actions.diffget("ours")),
						{ desc = "Obtain the diff hunk from OURS unless the view is read-only" },
					},
					{
						{ "n", "x" },
						"3do",
						review.guard(actions.diffget("theirs")),
						{ desc = "Obtain the diff hunk from THEIRS unless the view is read-only" },
					},
				},
			},
		})
		-- Diffview normalizes only its built-in groups during setup. Keep these
		-- effective-config additions help-only so they never become buffer maps.
		local effective_keymaps = require("diffview.config").get_config().keymaps
		effective_keymaps[help_groups.common] = review_commands.help_mappings("common")
		effective_keymaps[help_groups.diff_line] = review_commands.help_mappings("diff_line")
		effective_keymaps[help_groups.file] = review_commands.help_mappings("file")
		vim.api.nvim_del_user_command("DiffviewClose")
		vim.api.nvim_create_user_command("DiffviewClose", review.close_or(require("diffview").close), {
			nargs = 0,
			bang = true,
		})
	end,
}
