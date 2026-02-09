-- lua/plugins/treesitter.lua
return {
  {
    "nvim-treesitter/nvim-treesitter",
    version = false,
    lazy = false,       -- Treesitter itself should not be lazy-loaded
    build = ":TSUpdate",
    config = function()
      -- Modern nvim-treesitter API (rewrite):
      -- Prefer this; if you still need the legacy branch, we can switch later.
      require("nvim-treesitter").setup({
        highlight = { enable = true },
        indent = { enable = true },
      })
    end,
    -- If you want to skip inside VSCode:
    cond = function() return not vim.g.vscode end,
  },

  -- Always-on context (loads at startup)
  {
    "nvim-treesitter/nvim-treesitter-context",
    lazy = false,
    opts = {},
    cond = function() return not vim.g.vscode end,
  },

  -- Always-on rainbow delimiters (loads at startup)
  {
    "HiPhish/rainbow-delimiters.nvim",
    lazy = false,
    config = function()
      local rd = require("rainbow-delimiters")

      require("rainbow-delimiters.setup").setup({
        strategy = {
          [""] = rd.strategy.global,
          -- `local` is a Lua keyword; use bracket syntax:
          commonlisp = rd.strategy["local"],
        },
        query = {
          [""] = "rainbow-delimiters",
          lua = "rainbow-blocks",
        },
        highlight = {
          "RainbowDelimiterRed",
          "RainbowDelimiterYellow",
          "RainbowDelimiterBlue",
          "RainbowDelimiterOrange",
          "RainbowDelimiterGreen",
          "RainbowDelimiterViolet",
          "RainbowDelimiterCyan",
        },
      })
    end,
    cond = function() return not vim.g.vscode end,
  },
}
