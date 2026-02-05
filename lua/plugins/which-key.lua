return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  cond = function() return not vim.g.vscode end,
  init = function()
    vim.o.timeout = true
    vim.o.timeoutlen = 300
  end,
  opts = {
    preset = "helix",
    delay = 500,
  }
}
