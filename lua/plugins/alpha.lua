return {
  "goolord/alpha-nvim",
  cond = function() return not vim.g.vscode end,
  dependencies = { "nvim-tree/nvim-web-devicons" },
  lazy = false,
  config = function()
    local startify = require("alpha.themes.startify")
    startify.file_icons.provider = "devicons"
    require("alpha").setup(startify.config)
  end,
}
