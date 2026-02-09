local tabnames = require("config.tabnames")

local M = {}

function M.tabline()
  local s = ""
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local nr = vim.api.nvim_tabpage_get_number(tab)
    local name = tabnames.tab_title(tab)

    local hl = (tab == vim.api.nvim_get_current_tabpage()) and "%#TabLineSel#" or "%#TabLine#"

    s = s .. hl .. " " .. nr .. ":" .. name .. " "
  end
  s = s .. "%#TabLineFill#"
  return s
end

return M
