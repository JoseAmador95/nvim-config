-- :checkhealth nvimconfig
local M = {}

local health = vim.health
local uv = vim.uv
local toolchain = require("config.toolchain")
local tool_paths = require("config.tool_paths")

local LOCAL_PRODUCTS = {
	{ name = "native-review.nvim", module = "native_review" },
	{ name = "exact-editor.nvim", module = "exact_editor" },
	{ name = "devcontainer-editor.nvim", module = "devcontainer_editor" },
	{ name = "tab-first.nvim", module = "tab_first" },
	{ name = "terminal-lifecycle.nvim", module = "terminal_lifecycle" },
	{ name = "project-python.nvim", module = "project_python" },
	{ name = "action-palette.nvim", module = "action_palette" },
	{ name = "diagram-view.nvim", module = "diagram_view" },
	{ name = "log-workbench.nvim", module = "log_workbench" },
	{ name = "repo-scratch.nvim", module = "repo_scratch" },
	{ name = "coverage-workbench.nvim", module = "coverage_workbench" },
	{ name = "just-workbench.nvim", module = "just_workbench" },
	{ name = "clangd-compile-db.nvim", module = "clangd_compile_db" },
	{ name = "trusted-workspace.nvim", module = "trusted_workspace" },
	{ name = "treesitter-runtime.nvim", module = "treesitter_runtime" },
	{ name = "theme-router.nvim", module = "theme_router" },
}

local function version_string()
	local version = vim.version()
	return ("%d.%d.%d"):format(version.major, version.minor, version.patch)
end

local function normalized(path)
	return vim.fs.normalize(vim.fn.expand(path))
end

local function split_path(value)
	return vim.split(value or "", ":", { plain = true, trimempty = true })
end

local function local_path_set()
	local local_config = package.loaded["config.local_config"]
	local observed
	if type(local_config) == "table" and type(local_config.observation) == "function" then
		local ok, value = pcall(local_config.observation)
		observed = ok and type(value) == "table" and value or nil
	end
	local configured = observed and observed.evaluated and observed.config and observed.config.path or {}
	configured = type(configured) == "table" and configured or {}
	local result = {}
	for _, path in ipairs(configured) do
		result[normalized(path)] = true
	end
	return result
end

local function path_origin(path, configured)
	path = normalized(path)
	local function within(root)
		root = root:gsub("/+$", "")
		return path == root or path:sub(1, #root + 1) == root .. "/"
	end
	if within(tool_paths.managed_bin()) then
		return "mise-launcher", 1
	end
	for root in pairs(configured) do
		if within(root) then
			return "local_config", 2
		end
	end
	if within(normalized("~/.local/bin")) then
		return "user-local", 3
	end
	if tool_paths.is_managed_path(path) then
		return "managed", 5
	end
	if tool_paths.is_mason_path(path) then
		return "mason", 6
	end
	return "host", 4
end

local function check_path_order()
	local configured = local_path_set()
	local previous_rank = 0
	local ordered = true
	health.info("PATH precedence contract: Mise launchers > local_config.path > ~/.local/bin > host PATH")
	for index, path in ipairs(split_path(vim.env.PATH)) do
		local origin, rank = path_origin(path, configured)
		health.info(("PATH[%02d] %-12s %s"):format(index, origin, normalized(path)))
		if rank < previous_rank then
			ordered = false
		end
		previous_rank = math.max(previous_rank, rank)
	end
	if ordered then
		health.ok("PATH segments follow the configured precedence")
	else
		health.warn(
			"PATH contains an origin after a lower-precedence segment; restart after reviewing local_config.path"
		)
	end
	return configured
end

local function check_tool(name, feature, install, required, configured)
	local path = vim.fn.exepath(name)
	if path ~= "" then
		local origin = path_origin(path, configured or local_path_set())
		health.ok(("%s available for %s (%s): %s"):format(name, feature, origin, path))
		return true
	end

	local message = ("%s is missing (%s). %s"):format(name, feature, install)
	if required then
		health.error(message)
	else
		health.warn(message)
	end
	return false
end

local function check_external_tool(name, feature, install, configured)
	local path = tool_paths.external_executable(name)
	if path then
		local origin = path_origin(path, configured or local_path_set())
		health.ok(("%s available for %s (%s): %s"):format(name, feature, origin, path))
		return true
	end
	health.warn(("%s is missing (%s). %s"):format(name, feature, install))
	return false
end

local function check_validation_tool(name, expected_line, configured)
	local path = vim.fn.exepath(name)
	local install = "Run: scripts/install-ci-tools /absolute/path/to/bin"
	if path == "" then
		health.warn(("%s is missing; reproducible validation will fail. %s"):format(name, install))
		return
	end

	local origin = path_origin(path, configured)
	health.info(
		("%s is present for validation (%s): %s; expected %q, version execution is reserved for scripts/check-config"):format(
			name,
			origin,
			path,
			expected_line
		)
	)
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
	elseif vim.env.NVIM_APPNAME == "nvimpager" then
		health.ok("nvimpager profile active; only the pager plugin allowlist is available")
	else
		health.ok("full terminal editor profile active")
	end
end

local function local_product_status()
	local rows = {}
	for _, product in ipairs(LOCAL_PRODUCTS) do
		local plugin = package.loaded[product.module]
		local row = { name = product.name, module = product.module, loaded = type(plugin) == "table" }
		if plugin == nil or plugin == false then
			row.observational = true
		elseif type(plugin) ~= "table" then
			row.error = "loaded module is not a table"
		else
			if type(plugin.status) ~= "function" then
				row.error = "missing status()"
			elseif type(plugin.effective_config) ~= "function" then
				row.error = "missing effective_config()"
			else
				local status_ok, status = pcall(plugin.status)
				local config_ok, config = pcall(plugin.effective_config)
				if not status_ok then
					row.error = "status() failed: " .. tostring(status)
				elseif not config_ok then
					row.error = "effective_config() failed: " .. tostring(config)
				elseif type(status) ~= "table" or type(config) ~= "table" then
					row.error = "status() and effective_config() must return tables"
				else
					row.status = vim.deepcopy(status)
					row.effective_config = vim.deepcopy(config)
				end
			end
		end
		rows[#rows + 1] = row
	end
	return rows
end

local function check_local_products()
	health.start("Local plugin products")
	for _, row in ipairs(local_product_status()) do
		if row.error then
			health.error(row.name .. ": " .. row.error)
		elseif not row.loaded then
			health.info(row.name .. ": not loaded; health did not activate it")
		else
			local configured = row.status.configured
			local suffix = configured == nil and "" or ("; configured=" .. tostring(configured))
			health.ok(row.name .. ": status and effective configuration available" .. suffix)
		end
	end
end

local function tool_contract()
	local result = {}
	for _, name in ipairs(toolchain.tool_order) do
		local entry = toolchain.tools[name]
		result[#result + 1] = { name = name, version = entry.version, backend = entry.backend }
	end
	return result
end

local function check_validation_contract(configured)
	local root = config_root()
	local lockfile = vim.fs.joinpath(root, "lazy-lock.json")
	if vim.fn.filereadable(lockfile) == 1 then
		health.ok("plugin lockfile available: " .. lockfile)
	else
		health.error("plugin lockfile is missing: " .. lockfile)
	end

	for _, name in ipairs({ "bootstrap-config", "check-config", "install-ci-tools", "provision-runtime" }) do
		local path = vim.fs.joinpath(root, "scripts", name)
		if vim.fn.executable(path) == 1 then
			health.ok("validation entrypoint is executable: scripts/" .. name)
		else
			health.error("validation entrypoint is missing or not executable: " .. path)
		end
	end
	local provision = vim.fs.joinpath(root, "scripts", "provision-runtime")
	if vim.fn.executable(provision) == 1 then
		health.info(
			"provision-runtime is present; contract version 2 is executed only by scripts/check-config (offline unless --allow-network is explicit)"
		)
	end
	check_validation_tool("stylua", "stylua " .. toolchain.versions.stylua, configured)
	check_validation_tool("shellcheck", "version: " .. toolchain.versions.shellcheck, configured)
	check_validation_tool("actionlint", toolchain.versions.actionlint, configured)
	check_validation_tool("tree-sitter", "tree-sitter " .. toolchain.versions.tree_sitter, configured)
	check_tool("cc", "Tree-sitter parser compilation", "Install a host C compiler.", true, configured)
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
			("Legacy undo directory still exists at %s. It is no longer active; review and remove it manually when no longer needed."):format(
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
	local configured = check_path_order()
	check_tool(
		"git",
		"lazy.nvim bootstrap and Git workflows",
		"Install Git from https://git-scm.com.",
		true,
		configured
	)
	check_profile()
	check_local_products()

	health.start("Mise tools")
	check_tool("mise", "locked editor tools", "Install Mise or run :NvimConfigMiseInstall.", true, configured)
	health.info(
		"Mise minimum version: " .. toolchain.versions.mise .. "; version execution is reserved for provisioning"
	)
	health.info("Tools: ~/.local/share/mise/installs; state: ~/.local/state/mise")
	for _, entry in ipairs(tool_contract()) do
		health.info(entry.name .. "@" .. entry.version .. " (" .. entry.backend .. ")")
	end
	health.info(
		"mise exec installs missing locked tools on first use; :NvimConfigToolsInstall[!] [all|name] preinstalls or reinstalls them"
	)
	health.info(
		"Health observes the catalog and executable paths; provision-runtime inventories installed versions offline"
	)

	health.start("Optional feature dependencies")
	check_tool("mmdflux", "Mermaid ASCII/SVG rendering", "Run :NvimConfigToolsInstall mmdflux.", false, configured)
	check_tool("plantuml", "PlantUML ASCII/SVG rendering", "Run :NvimConfigToolsInstall plantuml.", false, configured)
	check_external_tool(
		"rust-analyzer",
		"Rust language intelligence (host/user only)",
		"Install it with rustup or the host package manager; managed and Mason copies are intentionally ignored.",
		configured
	)
	health.info("Rust formatting is disabled until rustfmt has an exact manifest contract")
	check_tool(
		"cmake-language-server",
		"CMake language intelligence",
		"Run :NvimConfigToolsInstall cmake-language-server.",
		false,
		configured
	)
	check_tool(
		"rsvg-convert",
		"SVG diagram rasterization",
		"Install librsvg with the host package manager.",
		false,
		configured
	)
	check_tool("nvimpager", "pager profile", "Install nvimpager with the host package manager.", false, configured)
	check_tool("lazygit", "Git terminal UI", "Install lazygit with the host package manager.", false, configured)
	check_pager_profile()

	health.start("Reproducible validation")
	check_validation_contract(configured)

	health.start("Persistent undo")
	check_undo()
end

-- Small test seam for origin classification; no filesystem or state mutation.
M._path_origin = path_origin
M._local_product_status = local_product_status
M._tool_contract = tool_contract

return M
