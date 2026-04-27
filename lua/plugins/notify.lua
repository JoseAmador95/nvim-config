return {
  "rcarriga/nvim-notify",
  cond = function() return not vim.g.vscode end,
  config = function()
    vim.notify = require("notify")
    require("notify").setup({
      timeout = 3000,
      background_colour = "NotifyBackground",
      render = "default",
      stages = "fade_in_slide_out",
    })
  end,
}
