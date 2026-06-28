-- lazygit in a floating terminal (via toggleterm), opened with <leader>gl.
-- Adds a lazy-loading key to the existing toggleterm spec.
local lazygit_term

local function toggle_lazygit()
	if vim.fn.executable("lazygit") ~= 1 then
		vim.notify("lazygit not found in PATH", vim.log.levels.ERROR, { title = "lazygit" })
		return
	end
	if not lazygit_term then
		local Terminal = require("toggleterm.terminal").Terminal
		lazygit_term = Terminal:new({
			cmd = "lazygit",
			direction = "float",
			hidden = true,
			close_on_exit = true,
		})
	end
	lazygit_term:toggle()
end

return {
	"akinsho/toggleterm.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>gl", toggle_lazygit, desc = "Open lazygit" },
	},
}
