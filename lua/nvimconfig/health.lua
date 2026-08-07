-- :checkhealth nvimconfig
local M = {}

local health = vim.health
local uv = vim.uv
local toolchain = require("config.toolchain")

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

local function has_exact_line(output, expected)
	for line in output:gmatch("[^\r\n]+") do
		if line == expected then
			return true
		end
	end
	return false
end

local function check_validation_tool(name, args, expected_line)
	local path = vim.fn.exepath(name)
	local install = "scripts/install-ci-tools /absolute/path/to/bin"
	if path == "" then
		health.warn(("%s is missing; reproducible validation will fail. Install: %s"):format(name, install))
		return
	end

	local command = { path }
	vim.list_extend(command, args)
	local result = vim.system(command, { text = true }):wait(5000)
	local output = (result.stdout or "") .. (result.stderr or "")
	if result.code == 0 and has_exact_line(output, expected_line) then
		health.ok(("%s matches the validation pin at %s: %s"):format(name, path, expected_line))
	else
		health.warn(
			("%s does not match the required validation version %q. Reinstall with: %s"):format(
				path,
				expected_line,
				install
			)
		)
	end
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

local function check_profile()
	if vim.g.vscode == 1 or vim.g.vscode == true then
		health.ok("VSCode profile active; terminal IDE services are isolated")
	elseif require("config.pager").active then
		health.ok("nvimpager profile active; only the pager plugin allowlist is available")
	else
		health.ok("full terminal editor profile active")
	end
end

local function check_validation_contract()
	local root = config_root()
	local lockfile = vim.fs.joinpath(root, "lazy-lock.json")
	if vim.fn.filereadable(lockfile) == 1 then
		health.ok("plugin lockfile available: " .. lockfile)
	else
		health.error("plugin lockfile is missing: " .. lockfile)
	end

	for _, name in ipairs({ "bootstrap-config", "check-config", "install-ci-tools" }) do
		local path = vim.fs.joinpath(root, "scripts", name)
		if vim.fn.executable(path) == 1 then
			health.ok("validation entrypoint is executable: scripts/" .. name)
		else
			health.error("validation entrypoint is missing or not executable: " .. path)
		end
	end
	check_validation_tool("stylua", { "--version" }, "stylua " .. toolchain.versions.stylua)
	check_validation_tool("shellcheck", { "--version" }, "version: " .. toolchain.versions.shellcheck)
	check_validation_tool("actionlint", { "-version" }, "v" .. toolchain.versions.actionlint)
	health.info(
		("Feature installer pins: Claude ACP %s, mmdflux %s, plantuml-lsp %s"):format(
			toolchain.versions.claude_acp,
			toolchain.versions.mmdflux,
			toolchain.versions.plantuml_lsp
		)
	)
end

local function check_undo()
	local active = vim.fs.joinpath(vim.fn.stdpath("state"), "undo")
	local stat = uv.fs_stat(active)
	if not stat or stat.type ~= "directory" then
		health.error("persistent undo directory is missing: " .. active)
	else
		local permissions = bit.band(stat.mode or 0, tonumber("777", 8))
		if permissions == tonumber("700", 8) then
			health.ok("persistent undo directory is owner-only: " .. active)
		else
			health.error(("persistent undo directory mode is %03o, expected 700: %s"):format(permissions, active))
		end
	end
	if vim.o.undodir:find(active, 1, true) then
		health.ok("'undodir' uses the state directory")
	else
		health.error("'undodir' does not use " .. active)
	end

	local legacy = vim.fs.joinpath(config_root(), ".undodir")
	if uv.fs_stat(legacy) then
		health.warn(
			("Legacy undo directory still exists at %s. It is no longer active; review it and remove it manually when no longer needed."):format(
				legacy
			)
		)
	else
		health.ok("No legacy repo-local .undodir found")
	end
end

function M.check()
	health.start("Neovim configuration")
	if vim.fn.has("nvim-0.12") == 1 then
		if version_string() == toolchain.versions.neovim then
			health.ok("Neovim " .. version_string() .. " matches the reproducible validation pin")
		else
			health.warn(
				("Neovim %s is supported; reproducible validation pins %s"):format(
					version_string(),
					toolchain.versions.neovim
				)
			)
		end
	else
		health.error("Neovim " .. version_string() .. " is unsupported; install Neovim 0.12 or newer")
	end
	check_tool("git", "lazy.nvim bootstrap and Git workflows", "Git from https://git-scm.com", true)
	check_profile()

	health.start("Optional feature dependencies")
	check_tool(
		"mmdflux",
		"Mermaid ASCII/SVG rendering",
		"cargo install mmdflux --version " .. toolchain.versions.mmdflux .. " --locked",
		false
	)
	check_tool("plantuml", "PlantUML ASCII/SVG rendering", "brew install plantuml", false)
	check_tool("rsvg-convert", "SVG diagram rasterization", "brew install librsvg", false)
	check_tool(
		"plantuml-lsp",
		"PlantUML language support",
		"go install github.com/ptdewey/plantuml-lsp@" .. toolchain.versions.plantuml_lsp,
		false
	)
	check_tool("hadolint", "Dockerfile linting", ":MasonInstall hadolint", false)
	check_tool("markdownlint-cli2", "Markdown linting", ":MasonInstall markdownlint-cli2", false)
	check_tool("debugpy-adapter", "Python debugging", ":MasonInstall debugpy", false)
	check_tool("codelldb", "C/C++ debugging", ":MasonInstall codelldb", false)
	check_tool("npx", "CodeCompanion Claude ACP", "install Node.js/npm", false)
	check_tool("jq", "JSON tree view", ":MasonInstall jq", false)
	check_tool("nvimpager", "pager profile", "brew install nvimpager", false)
	check_tool("devpod", "remote devcontainers", "brew install loft-sh/tap/devpod", false)
	check_pager_profile()

	health.start("Reproducible validation")
	check_validation_contract()

	health.start("Persistent undo")
	check_undo()
end

return M
