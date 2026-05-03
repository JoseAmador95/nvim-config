return {
	"nvim-neotest/neotest",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = { "Neotest" },
	dependencies = {
		"nvim-neotest/neotest-python",
		"alfaix/neotest-gtest",
		"nvim-lua/plenary.nvim",
	},
	config = function()
		local adapters = {
			require("neotest-python"),
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
