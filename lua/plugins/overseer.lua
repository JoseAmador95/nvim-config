-- Task runner with a built-in .vscode/tasks.json provider, so projects that
-- assume VSCode keep their build/test tasks runnable from Neovim.
return {
	"stevearc/overseer.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = { "OverseerRun", "OverseerToggle", "OverseerInfo", "OverseerQuickAction", "OverseerRunCmd" },
	keys = {
		{ "<leader>rr", "<cmd>OverseerRun<cr>", desc = "Run task (incl. .vscode/tasks.json)" },
		{ "<leader>rt", "<cmd>OverseerToggle<cr>", desc = "Toggle task list" },
		{ "<leader>ra", "<cmd>OverseerQuickAction<cr>", desc = "Task quick action" },
		{
			"<leader>rl",
			function()
				local overseer = require("overseer")
				local tasks = overseer.list_tasks({ recent_first = true })
				if vim.tbl_isempty(tasks) then
					vim.notify("No tasks have run yet", vim.log.levels.WARN, { title = "Overseer" })
					return
				end
				overseer.run_action(tasks[1], "restart")
			end,
			desc = "Restart last task",
		},
	},
	opts = {
		-- "builtin" includes the vscode tasks.json template provider
		templates = { "builtin" },
	},
}
