return {
  "nvim-neotest/neotest",
  cond = function() return not vim.g.vscode end,
  cmd = { "NeotestRun", "NeotestSummary" },
  dependencies = {
    "nvim-neotest/neotest-python",
    "alfaix/neotest-gtest",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("neotest").setup({
      adapters = {
        require("neotest-python"),
        require("neotest-gtest").setup({}),
      },
    })
  end,
}
