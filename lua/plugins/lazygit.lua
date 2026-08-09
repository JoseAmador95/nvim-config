-- lazygit in the shared Snacks terminal factory, opened with <leader>gl.
--
-- When a file is edited from within lazygit (pressing `e`), LazyGit's official
-- `nvim-remote` preset opens it in the parent Neovim instance. The LazyGit
-- terminal remains available in its original tab.
-- Generate the lazygit config that selects its parent-Neovim edit preset.
-- Rewritten on every launch so config changes always take effect.
--
-- `promptToReturnFromSubprocess: false` lets LazyGit resume without displaying
-- its default "press ENTER to return" prompt after the edit command.
local function ensure_config()
	local path = vim.fn.stdpath("cache") .. "/lazygit-nvim.yml"
	local lines = {
		"promptToReturnFromSubprocess: false",
		"os:",
		"  editPreset: nvim-remote",
	}
	local ok, err = require("config.fs").write_binary_atomic(path, table.concat(lines, "\n") .. "\n")
	if not ok then
		error("could not write lazygit config: " .. tostring(err))
	end
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
	local root = require("config.repo").current_root(0) or vim.uv.cwd()
	local record, err = require("config.terminal").toggle({
		runtime = "host",
		root = root,
		id = "lazygit",
		argv = { "lazygit" },
		cwd = root,
		env = { LG_CONFIG_FILE = config_files() },
		layout = "float",
		title = "LazyGit",
		passthrough = { "j", "<space>" },
	})
	if not record then
		vim.notify(err, vim.log.levels.ERROR, { title = "lazygit" })
	end
end

return {
	"folke/snacks.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>gl", toggle_lazygit, desc = "Open lazygit" },
	},
	init = function()
		vim.api.nvim_create_user_command("LazyGit", toggle_lazygit, { desc = "Open lazygit" })
	end,
}
