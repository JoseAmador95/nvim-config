return {
  "nvim-neotest/neotest",
  cond = function() return not vim.g.vscode end,
  dependencies = {
    "nvim-neotest/neotest-python",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("neotest").setup({
      adapters = {
        require("neotest-python"),
      },
    })
  end,
}
