-- :checkhealth nvimconfig
local M = {}

local health = vim.health
local uv = vim.uv
local toolchain = require("config.toolchain")
local tool_paths = require("config.tool_paths")

local local_plugins = require("config.local_plugins")
local plugin_state = require("config.plugin_state")

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

-- A catalog tool without a launcher yet is still usable: the first use runs it
-- through `mise exec`, which installs the locked version.
local function check_managed_tool(tool, feature, configured)
	local command = toolchain.tools[tool].commands[1]
	local path = vim.fn.exepath(command)
	if path ~= "" then
		health.ok(("%s available for %s (%s): %s"):format(command, feature, path_origin(path, configured), path))
		return true
	end
	local uname = uv.os_uname()
	if not toolchain.supported(tool, toolchain.target_key(uname.sysname, uname.machine)) then
		health.info(("%s is not available on this platform (%s)"):format(command, feature))
		return false
	end
	if vim.fn.executable("mise") == 1 then
		health.ok(
			("%s for %s installs through Mise on first use; :NvimConfigToolsInstall %s preinstalls it"):format(
				command,
				feature,
				tool
			)
		)
		return true
	end
	health.warn(("%s is unavailable (%s) until Mise is installed"):format(command, feature), {
		"Run :NvimConfigMiseInstall",
	})
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
		-- Only scripts/check-config needs the validators; the editor does not.
		health.info(("%s is not installed; only scripts/check-config needs it. %s"):format(name, install))
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
	for _, product in ipairs(local_plugins.products()) do
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

local function check_plugins()
	health.start("Plugins")
	local state = plugin_state.inspect()
	if not state.loaded then
		health.info("lazy.nvim is not loaded in this session; plugin state was not inspected")
		return
	end
	if #state.missing == 0 then
		health.ok(("%d plugins installed"):format(state.total))
	else
		health.warn(("%d plugin(s) are not installed: %s"):format(#state.missing, table.concat(state.missing, ", ")), {
			"Restart Neovim with network access; missing plugins install automatically at their locked commits",
			"Or run :Lazy install",
		})
	end
	if #state.drift == 0 then
		health.ok("installed plugin commits match " .. (state.lockfile or "the lockfile"))
		return
	end
	local rows = {}
	for _, item in ipairs(state.drift) do
		rows[#rows + 1] = ("%s (%s, lock %s)"):format(item.name, item.head:sub(1, 7), item.locked:sub(1, 7))
	end
	health.warn(("%d plugin(s) differ from the lockfile: %s"):format(#rows, table.concat(rows, ", ")), {
		"Startup moves them to the locked commits when downloads are allowed; this one could not be moved",
		"Run :Lazy restore",
	})
end

local function check_parsers()
	health.start("Tree-sitter parsers")
	local runtime = package.loaded["config.treesitter_runtime"]
	if type(runtime) ~= "table" or type(runtime.inventory) ~= "function" then
		health.info("Tree-sitter runtime is not configured in this session")
		return
	end
	local ok, inventory = pcall(runtime.inventory)
	if not ok or type(inventory) ~= "table" then
		health.warn("could not inspect the configured parsers: " .. tostring(inventory))
		return
	end
	if inventory.exact then
		health.ok(("%d configured parsers are installed at their pinned revisions"):format(#inventory.required))
		return
	end
	health.warn("parsers are missing or stale: " .. table.concat(inventory.problems, ", "), {
		"They install in the background when Neovim starts with a UI and network access",
		"Or run :NvimConfigParsersInstall (needs Mise for the tree-sitter CLI and a C compiler)",
	})
end

local function check_markdown_view()
	local markdown_view = package.loaded["config.markdown_view"]
	if type(markdown_view) ~= "table" or type(markdown_view.status) ~= "function" then
		return
	end
	local ok, status = pcall(markdown_view.status)
	if not ok or type(status) ~= "table" then
		health.warn("could not read the Markdown reading view state: " .. tostring(status))
	elseif status.error then
		health.warn(status.error, { "Restart Neovim with network access or run :Lazy restore md-render.nvim" })
	elseif status.configured then
		health.ok("Markdown reading view (md-render.nvim) is ready")
	else
		health.info("Markdown reading view is not configured in this session")
	end
end

local function check_usage()
	local usage = package.loaded["config.usage"]
	if type(usage) ~= "table" or type(usage.status) ~= "function" then
		return
	end
	health.start("Usage statistics")
	local ok, status = pcall(usage.status)
	if not ok or type(status) ~= "table" then
		health.warn("could not read the usage statistics state: " .. tostring(status))
	elseif not status.enabled then
		health.info("local usage statistics are disabled in this session (telemetry off, headless, CI or tests)")
	elseif status.error then
		health.warn("local usage statistics are off: " .. tostring(status.error), {
			"Install the host sqlite3 CLI: macOS ships /usr/bin/sqlite3; Ubuntu/Debian: sudo apt install sqlite3; "
				.. "Fedora: sudo dnf install sqlite",
			"Then run :UsageResume, or restart Neovim",
		})
	elseif status.collecting then
		health.ok(("local usage statistics are collected in %s"):format(tostring(status.path)))
	else
		health.info("local usage statistics start once a UI attaches")
	end
end

local AUTO_INSTALL_ADVICE = {
	mise = "Run :NvimConfigMiseInstall (or scripts/install-mise)",
	parsers = "Run :NvimConfigParsersInstall",
}

local function check_auto_install()
	health.start("Automatic installs")
	if vim.env.NVIM_CONFIG_OFFLINE == "1" then
		health.info("NVIM_CONFIG_OFFLINE=1: nothing is downloaded automatically")
	end
	local auto = package.loaded["config.auto_install"]
	if type(auto) ~= "table" or type(auto.status) ~= "function" then
		health.info("automatic installs are not configured in this profile")
		return
	end
	local ok, status = pcall(auto.status)
	if not ok or type(status) ~= "table" then
		health.warn("could not read the automatic install state: " .. tostring(status))
		return
	end
	if status.skipped then
		health.info("automatic installs did not run in this session: " .. status.skipped)
	end
	local steps = vim.tbl_keys(status.failures or {})
	table.sort(steps)
	for _, step in ipairs(steps) do
		local failure = status.failures[step]
		local at = type(failure) == "table" and tonumber(failure.at) or nil
		local when = at and os.date("%Y-%m-%d %H:%M", at) or "an unknown time"
		local retry = at and os.date("%Y-%m-%d %H:%M", at + (status.retry_seconds or 0)) or "the next start"
		health.warn(("%s automatic install failed at %s: %s"):format(step, when, tostring(failure.detail or failure)), {
			AUTO_INSTALL_ADVICE[step] or "Retry the installation manually",
			"The automatic retry runs after " .. retry,
		})
	end
	if #steps == 0 then
		health.ok("no automatic install failures recorded")
	end
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
	check_plugins()
	check_markdown_view()
	check_parsers()
	check_auto_install()
	check_usage()

	health.start("Mise tools")
	check_tool(
		"mise",
		"locked editor tools: LSP servers, formatters, linters, debug adapters and parser builds",
		"The full editor installs it in the background on startup; or run :NvimConfigMiseInstall.",
		true,
		configured
	)
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
	check_managed_tool("mmdflux", "Mermaid ASCII/SVG rendering", configured)
	check_managed_tool("plantuml", "PlantUML ASCII/SVG rendering", configured)
	check_external_tool(
		"rust-analyzer",
		"Rust language intelligence (host/user only)",
		"Install it with rustup or the host package manager; managed and Mason copies are intentionally ignored.",
		configured
	)
	health.info("Rust formatting is disabled until rustfmt has an exact manifest contract")
	check_managed_tool("cmake-language-server", "CMake language intelligence", configured)
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
