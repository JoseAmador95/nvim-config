return {
  {
    "vscode-neovim/vscode-multi-cursor.nvim",
    cond = function() return vim.g.vscode == 1 or vim.g.vscode == true end,
    event = "VeryLazy",
    config = function()
      -- Your multi-cursor keymaps:
      require("cfg-vscode-multi-cursor") -- same bindings you wrote
    end,
  },
}
