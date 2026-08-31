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
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve lazygit config source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local devcontainer_editor = vim.fs.joinpath(config_root, "scripts", "devcontainer-editor")

local function gh_editor()
	return vim.fn.shellescape(devcontainer_editor) .. " editor-open --wait-editor"
end

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
	if require("config.devcontainer").in_workspace() then
		local ok, err = require("config.devcontainer").request_host("lazygit")
		if not ok then
			vim.notify(err, vim.log.levels.ERROR, { title = "lazygit" })
		end
		return
	end
	if vim.fn.executable("lazygit") ~= 1 then
		vim.notify("lazygit not found in PATH", vim.log.levels.ERROR, { title = "lazygit" })
		return
	end
	local root = require("config.repo").current_root(0) or vim.uv.cwd()
	local canonical_root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
	local key = vim.json.encode({ "host", canonical_root, "lazygit" })
	local record, err = require("config.terminal").toggle({
		key = key,
		launch = {
			argv = { "lazygit" },
			cwd = root,
			env = { LG_CONFIG_FILE = config_files(), GH_EDITOR = gh_editor() },
		},
		policy = { dispose_on_success = true, dispose_on_stop = false },
		view = { layout = "float", title = "LazyGit", passthrough = { "j", "<space>" } },
		metadata = { runtime = "host", root = canonical_root, id = "lazygit" },
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
