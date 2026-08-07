-- :checkhealth nvimconfig
local M = {}

local health = vim.health
local uv = vim.uv

local function version_string()
	local version = vim.version()
	return ("%d.%d.%d"):format(version.major, version.minor, version.patch)
end

local function check_tool(name, feature, install, required)
	local path = vim.fn.exepath(name)
	if path ~= "" then
		health.ok(("%s available for %s: %s"):format(name, feature, path))
		return true
	end

	local message = ("%s is missing (%s). Install: %s"):format(name, feature, install)
	if required then
		health.error(message)
	else
		health.warn(message)
	end
	return false
end

local function config_paths()
	local config_home = vim.env.XDG_CONFIG_HOME
	if not config_home or config_home == "" then
		config_home = vim.fn.expand("~/.config")
	else
		config_home = vim.fn.expand(config_home)
	end
	return vim.fs.joinpath(config_home, "nvim"), vim.fs.joinpath(config_home, "nvimpager")
end

local function check_pager_profile()
	local main_path, pager_path = config_paths()
	local pager_stat = uv.fs_lstat(pager_path)
	local command = ("ln -s %s %s"):format(main_path, pager_path)

	if not pager_stat then
		health.info(("Pager profile is not linked at %s. Enable it with: %s"):format(pager_path, command))
		return
	end
	if pager_stat.type ~= "link" then
		health.warn(
			("Pager profile path exists but is not a symlink: %s (expected target: %s)"):format(pager_path, main_path)
		)
		return
	end

	local actual = uv.fs_realpath(pager_path)
	local expected = uv.fs_realpath(main_path)
	if not actual then
		health.warn(("Pager profile symlink is broken: %s. Recreate it with: %s"):format(pager_path, command))
	elseif expected and actual == expected then
		health.ok(("Pager profile links to this config: %s -> %s"):format(pager_path, actual))
	else
		health.warn(("Pager profile points to %s, expected %s"):format(actual, expected or main_path))
	end
end

local function config_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.check()
	health.start("Neovim configuration")
	if vim.fn.has("nvim-0.12") == 1 then
		health.ok("Neovim " .. version_string() .. " satisfies the 0.12+ requirement")
	else
		health.error("Neovim " .. version_string() .. " is unsupported; install Neovim 0.12 or newer")
	end
	check_tool("git", "lazy.nvim bootstrap and Git workflows", "Git from https://git-scm.com", true)

	health.start("Optional feature dependencies")
	check_tool("mmdflux", "Mermaid ASCII/SVG rendering", "cargo install mmdflux", false)
	check_tool("plantuml", "PlantUML ASCII/SVG rendering", "brew install plantuml", false)
	check_tool("rsvg-convert", "SVG diagram rasterization", "brew install librsvg", false)
	check_tool("nvimpager", "pager profile", "brew install nvimpager", false)
	check_tool("devpod", "remote devcontainers", "brew install loft-sh/tap/devpod", false)
	check_pager_profile()

	health.start("Persistent undo")
	local legacy = vim.fs.joinpath(config_root(), ".undodir")
	if uv.fs_stat(legacy) then
		health.warn(
			("Legacy undo directory still exists at %s. It is no longer active; undo files now use %s. Review it and remove it manually when no longer needed."):format(
				legacy,
				vim.fs.joinpath(vim.fn.stdpath("state"), "undo")
			)
		)
	else
		health.ok("No legacy repo-local .undodir found")
	end
end

return M
