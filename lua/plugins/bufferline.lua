return {
  "akinsho/bufferline.nvim",
  version = "*",
  event = "UIEnter",
  cond = function() return not vim.g.vscode end,
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    require("bufferline").setup({
      options = {
        mode = "buffers",
        diagnostics = "nvim_lsp",
        show_buffer_icons = true,
        show_buffer_close_icons = true,
        show_close_icon = false,
        separator_style = "thin",
        hover = { enabled = true },
        numbers = "none",
      },
    })
  end,
}
