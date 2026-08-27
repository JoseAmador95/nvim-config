return {
	"nvim-neotest/neotest",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = { "Neotest" },
	keys = {
		{
			"<leader>Tn",
			function()
				require("neotest").run.run()
			end,
			desc = "Run nearest test",
		},
		{
			"<leader>Td",
			function()
				require("neotest").run.run({ strategy = "dap" })
			end,
			desc = "Debug nearest test",
		},
	},
	dependencies = {
		"linux-cultist/venv-selector.nvim",
		"nvim-neotest/neotest-python",
		"alfaix/neotest-gtest",
		"nvim-lua/plenary.nvim",
	},
	config = function()
		local python = require("config.python")
		local adapters = {
			require("neotest-python")({
				python = python.neotest_python,
				runner = python.neotest_runner,
			}),
		}
		local ok_gtest, gtest = pcall(require, "neotest-gtest")
		if ok_gtest then
			adapters[#adapters + 1] = gtest.setup({})
		else
			vim.notify("neotest-gtest disabled: " .. tostring(gtest), vim.log.levels.WARN)
		end

		require("neotest").setup({
			adapters = adapters,
		})
	end,
}
