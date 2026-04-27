return {
  "NeogitOrg/neogit",
  cond = function() return not vim.g.vscode end,
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  cmd = "Neogit",
  keys = {
    { "<leader>gg", "<cmd>Neogit<cr>", desc = "Open Neogit" }
  },
  config = function()
    require("neogit").setup({})
  end,
}
