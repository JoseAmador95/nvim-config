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
			-- Enter terminal (insert) mode so keystrokes reach lazygit instead of
			-- moving the Neovim cursor. The global terminal-mode mappings `jj`
			-- (exit terminal) and `<leader>t` (= <space>t, toggle terminal) would
			-- otherwise steal lazygit's `j` (navigate) and `<space>` (stage); send
			-- those through immediately with nowait buffer-local maps.
			on_open = function(term)
				vim.cmd("startinsert!")
				local opts = { buffer = term.bufnr, nowait = true }
				vim.keymap.set("t", "j", "j", opts)
				vim.keymap.set("t", "<space>", "<space>", opts)
			end,
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
