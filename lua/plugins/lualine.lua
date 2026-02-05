return {
  "nvim-lualine/lualine.nvim",
  lazy = false,
  cond = function() return not vim.g.vscode end,
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  config = function()
    require("lualine").setup({
      options = {
        theme = "tomorrow_night",
        icons_enabled = true,
        component_separators = { left = "│", right = "│" },
        section_separators = { left = "", right = "" },
        disabled_filetypes = {
          statusline = {},
          winbar = {},
        },
        always_divide_middle = true,
      },

      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch" },
        lualine_c = {
          { "filename", path = 1 }, -- relative path
        },
        lualine_x = {
          "filetype",
        },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },

      inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = {
          { "filename", path = 1 },
        },
        lualine_x = { "location" },
        lualine_y = {},
        lualine_z = {},
      },

      extensions = {
        "quickfix",
        "toggleterm",
      },
    })
  end,
}
