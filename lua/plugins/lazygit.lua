-- lazygit in a floating terminal (via toggleterm), opened with <leader>gl.
-- Adds a lazy-loading key to the existing toggleterm spec.
--
-- When a file is edited from within lazygit (pressing `e`), it is opened as a
-- buffer in the *running* Neovim instance instead of lazygit's own float. This
-- works because Neovim sets `$NVIM` to its RPC socket inside terminal buffers,
-- so lazygit's `os.edit` command can talk back to Neovim via `--remote-send`.
local lazygit_term

-- Called by lazygit (through Neovim's RPC socket) to open a file in a new tab.
-- Invoked via `<Cmd>` from a terminal-mode buffer, so window/tab changes must
-- be deferred with vim.schedule (they are forbidden while <Cmd> runs).
function _G._lazygit_edit(filename, line)
	vim.schedule(function()
		if lazygit_term then
			lazygit_term:close()
		end
		-- `tab drop` reuses a tab already showing the file, otherwise opens a
		-- new tab -- so editing never overwrites the tab lazygit launched from.
		vim.cmd("tab drop " .. vim.fn.fnameescape(filename))
		if line then
			pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(line), 0 })
		end
	end)
end

-- Generate the lazygit config that wires `os.edit` to the RPC callback.
-- Rewritten on every launch so config changes always take effect.
--
-- `promptToReturnFromSubprocess: false` is essential: lazygit suspends its UI
-- to run the edit command, and the default "press ENTER to return" prompt would
-- otherwise leave the hidden float stuck on that screen. Since `--remote-send`
-- returns instantly, lazygit can resume silently.
local function ensure_config()
	local path = vim.fn.stdpath("cache") .. "/lazygit-nvim.yml"
	local lines = {
		"promptToReturnFromSubprocess: false",
		"os:",
		"  edit: 'nvim --server \"$NVIM\" --remote-send \"<Cmd>lua _lazygit_edit([==[{{filename}}]==])<CR>\"'",
		"  editAtLine: 'nvim --server \"$NVIM\" --remote-send \"<Cmd>lua _lazygit_edit([==[{{filename}}]==], {{line}})<CR>\"'",
	}
	vim.fn.writefile(lines, path)
	return path
end

-- Combine the user's own lazygit config (if present) with ours so both apply.
-- lazygit merges comma-separated config files, later ones taking precedence, so
-- our overrides win while every personal setting is preserved.
--
-- The config location is resolved by asking lazygit itself
-- (`lazygit --print-config-dir`) instead of guessing the XDG path, so custom
-- config dirs are honoured.
local function config_files()
	local ours = ensure_config()
	local dir = vim.fn.systemlist({ "lazygit", "--print-config-dir" })[1]
	if vim.v.shell_error == 0 and dir and dir ~= "" then
		local user = dir .. "/config.yml"
		if vim.fn.filereadable(user) == 1 then
			return user .. "," .. ours
		end
	end
	return ours
end

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
			env = { LG_CONFIG_FILE = config_files() },
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
