-- Using Lazy
return {
  "navarasu/onedark.nvim",
  priority = 1000, -- make sure to load this before all the other start plugins
  lazy = false,
  cond = function() return not vim.g.vscode end,
  config = function()
    require('onedark').setup {
      style = 'warmer'
    }
    require('onedark').load()
  end
}
