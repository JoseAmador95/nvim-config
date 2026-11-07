-- :checkhealth nvimconfig
--
-- Health only observes: it never starts processes, installs tools or writes
-- files (tests/health_spec.lua enforces this). Every check records findings in
-- a report that prints "Problems" first (errors, then warnings, each with the
-- fix for this platform) and then a short "Summary" of what works.
-- `:let g:nvimconfig_health_details = 1` also prints the PATH order and the
-- locked Mise catalog.
local M = {}

local health = vim.health
local uv = vim.uv
local host_packages = require("config.host_packages")
local local_plugins = require("config.local_plugins")
local plugin_state = require("config.plugin_state")
local tool_paths = require("config.tool_paths")
local toolchain = require("config.toolchain")

local DETAILS_HINT = "PATH order and the Mise catalog: :let g:nvimconfig_health_details = 1 | checkhealth nvimconfig"

local Report = {}
Report.__index = Report

local function new_report(platform)
	return setmetatable({ platform = platform, errors = {}, warnings = {}, summary = {}, details = {} }, Report)
end

local function advice_list(advice)
	if advice == nil then
		return nil
	end
	advice = type(advice) == "table" and advice or { advice }
	return #advice > 0 and advice or nil
end

function Report:error(message, advice)
	self.errors[#self.errors + 1] = { message = message, advice = advice_list(advice) }
end

function Report:warn(message, advice)
	self.warnings[#self.warnings + 1] = { message = message, advice = advice_list(advice) }
end

function Report:ok(message)
	self.summary[#self.summary + 1] = { kind = "ok", message = message }
end

function Report:info(message)
	self.summary[#self.summary + 1] = { kind = "info", message = message }
end

function Report:detail(message)
	self.details[#self.details + 1] = message
end

---Install commands for a host dependency on this platform, then any follow-up steps.
function Report:install(name, ...)
	return vim.list_extend(host_packages.advice(name, self.platform), { ... })
end

local function enabled(value)
	return value ~= nil and value ~= false and value ~= 0 and value ~= ""
end

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

local function config_paths()
	local config_home = vim.env.XDG_CONFIG_HOME
	if not config_home or config_home == "" then
		config_home = vim.fn.expand("~/.config")
	else
		config_home = vim.fn.expand(config_home)
	end
	return vim.fs.joinpath(config_home, "nvim"), vim.fs.joinpath(config_home, "nvimpager")
end

local function config_root()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function profile_name()
	if vim.g.vscode == 1 or vim.g.vscode == true then
		return "VSCode profile (terminal IDE services are off)"
	elseif vim.env.NVIM_APPNAME == "nvimpager" then
		return "nvimpager profile"
	end
	return "full editor profile"
end

local function check_neovim(report)
	local version = version_string()
	if vim.fn.has("nvim-0.12") ~= 1 then
		report:error(
			("Neovim %s is unsupported: this configuration needs 0.12 or newer"):format(version),
			report:install("neovim")
		)
		return
	end
	local pinned = toolchain.versions.neovim
	local pin = version == pinned and "" or (" (validation pins " .. pinned .. ")")
	report:ok(("Neovim %s%s, %s"):format(version, pin, profile_name()))
end

local REQUIRED_TOOLS = {
	{ name = "git", effect = "lazy.nvim cannot install or restore plugins and Git workflows fail" },
	{
		name = "mise",
		effect = "language servers, formatters, linters, debug adapters, diagram renderers and parser builds are unavailable",
		advice = { "Run :NvimConfigMiseInstall (the full editor also installs it in the background at startup)" },
	},
	{ name = "cc", effect = "Tree-sitter parsers cannot be built" },
}

local function check_required_tools(report)
	local found = {}
	for _, tool in ipairs(REQUIRED_TOOLS) do
		if vim.fn.exepath(tool.name) ~= "" then
			found[#found + 1] = tool.name
		else
			report:error(("%s is missing: %s"):format(tool.name, tool.effect), tool.advice or report:install(tool.name))
		end
	end
	if #found > 0 then
		report:ok("Required tools found: " .. table.concat(found, ", "))
	end
	return vim.tbl_contains(found, "mise")
end

local function check_path_order(report, configured)
	local previous_rank = 0
	local late = {}
	report:detail("PATH precedence: Mise launchers > local_config.path > ~/.local/bin > host PATH")
	for index, path in ipairs(split_path(vim.env.PATH)) do
		local origin, rank = path_origin(path, configured)
		report:detail(("PATH[%02d] %-12s %s"):format(index, origin, normalized(path)))
		if rank < previous_rank then
			late[#late + 1] = ("%s (%s)"):format(normalized(path), origin)
		end
		previous_rank = math.max(previous_rank, rank)
	end
	if #late > 0 then
		report:warn("PATH lists " .. table.concat(late, ", ") .. " after lower-precedence entries", {
			"Expected order: Mise launchers, local_config.path, ~/.local/bin, then the host PATH",
			"Review local_config.path in ~/.nvim-local.lua and your shell PATH, then restart Neovim",
		})
	end
end

local function check_plugins(report)
	local state = plugin_state.inspect()
	if not state.loaded then
		report:info("lazy.nvim is not loaded in this session; plugins were not inspected")
		return
	end
	if #state.missing > 0 then
		report:warn(("%d plugin(s) are not installed: %s"):format(#state.missing, table.concat(state.missing, ", ")), {
			"Restart Neovim with network access: missing plugins install at their locked commits",
			"Or run :Lazy install",
		})
	end
	if #state.drift > 0 then
		local rows = {}
		for _, item in ipairs(state.drift) do
			rows[#rows + 1] = ("%s (%s, lock %s)"):format(item.name, item.head:sub(1, 7), item.locked:sub(1, 7))
		end
		report:warn(("%d plugin(s) differ from lazy-lock.json: %s"):format(#rows, table.concat(rows, ", ")), {
			"Run :Lazy restore",
			"Startup moves clean checkouts to the locked commits when downloads are allowed",
		})
	end
	if #state.missing == 0 and #state.drift == 0 then
		report:ok(("%d plugins installed at their locked commits"):format(state.total))
	end
end

local function check_parsers(report)
	local runtime = package.loaded["config.treesitter_runtime"]
	if type(runtime) ~= "table" or type(runtime.inventory) ~= "function" then
		return
	end
	local ok, inventory = pcall(runtime.inventory)
	if not ok or type(inventory) ~= "table" then
		report:warn("Could not inspect the configured Tree-sitter parsers: " .. tostring(inventory))
	elseif inventory.exact then
		report:ok(("%d Tree-sitter parsers installed at their pinned revisions"):format(#inventory.required))
	else
		report:warn("Tree-sitter parsers are missing or stale: " .. table.concat(inventory.problems, ", "), {
			"Run :NvimConfigParsersInstall (needs Mise and a C compiler)",
			"Neovim also builds them in the background when it starts with a UI and network access",
		})
	end
end

local function check_markdown_view(report)
	local markdown_view = package.loaded["config.markdown_view"]
	if type(markdown_view) ~= "table" or type(markdown_view.status) ~= "function" then
		return
	end
	local ok, status = pcall(markdown_view.status)
	if not ok or type(status) ~= "table" then
		report:warn("Could not read the Markdown reading view state: " .. tostring(status))
	elseif status.error then
		report:warn(status.error, { "Run :Lazy restore md-render.nvim, or restart Neovim with network access" })
	elseif status.configured then
		report:ok("Markdown reading view (md-render.nvim) is ready")
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

local function check_local_products(report)
	local loaded, waiting = 0, 0
	for _, row in ipairs(local_product_status()) do
		if row.error then
			report:error(("Local plugin %s is broken: %s"):format(row.name, row.error))
		elseif row.loaded then
			loaded = loaded + 1
		else
			waiting = waiting + 1
		end
	end
	report:ok(("Local plugins: %d loaded, %d load on first use"):format(loaded, waiting))
end

local MANAGED_TOOLS = {
	{ tool = "mmdflux", feature = "Mermaid rendering" },
	{ tool = "plantuml", feature = "PlantUML rendering" },
	{ tool = "cmake-language-server", feature = "CMake language intelligence" },
}

local function check_managed_tools(report, mise_found)
	if mise_found then
		report:ok("Mise installs locked tools on first use; :NvimConfigToolsInstall [all|name] preinstalls them")
	end
	local uname = uv.os_uname()
	local target = toolchain.target_key(uname.sysname, uname.machine)
	local unsupported = {}
	for _, item in ipairs(MANAGED_TOOLS) do
		local command = toolchain.tools[item.tool].commands[1]
		if vim.fn.exepath(command) == "" and not toolchain.supported(item.tool, target) then
			unsupported[#unsupported + 1] = ("%s (%s)"):format(command, item.feature)
		end
	end
	if #unsupported > 0 then
		report:info("Not available on this platform: " .. table.concat(unsupported, ", "))
	end
end

local function check_optional_tools(report)
	local found = {}
	local function optional(name, path, effect)
		if path and path ~= "" then
			found[#found + 1] = name
		else
			report:warn(("%s is missing: %s"):format(name, effect), report:install(name))
		end
	end
	optional("lazygit", vim.fn.exepath("lazygit"), "the Git terminal UI (<leader>gl) is unavailable")
	optional(
		"rsvg-convert",
		vim.fn.exepath("rsvg-convert"),
		"diagrams fall back to ASCII and images cannot be previewed"
	)
	-- Managed and Mason copies are ignored on purpose: Rust uses host/user tools only.
	optional(
		"rust-analyzer",
		tool_paths.external_executable("rust-analyzer"),
		"Rust files are edit-only (no language server)"
	)
	if #found > 0 then
		report:ok("Optional tools found: " .. table.concat(found, ", "))
	end
end

local function check_pager_profile(report)
	local main_path, pager_path = config_paths()
	local stat = uv.fs_lstat(pager_path)
	local link = ("ln -s %s %s"):format(main_path, pager_path)
	local installed = vim.fn.exepath("nvimpager") ~= ""
	if not stat then
		report:info(
			installed and ("nvimpager does not use this config yet; link it with: " .. link)
				or ("Pager profile (optional) is not set up: install nvimpager, then run " .. link)
		)
		return
	end
	local relink = ("ln -sfn %s %s"):format(main_path, pager_path)
	if stat.type ~= "link" then
		report:warn(("%s is not a symlink to this config, so nvimpager ignores it"):format(pager_path), {
			("Move %s aside, then run: %s"):format(pager_path, link),
		})
		return
	end
	local actual, expected = uv.fs_realpath(pager_path), uv.fs_realpath(main_path)
	if not actual then
		report:warn("The pager profile symlink is broken: " .. pager_path, { relink })
	elseif expected and actual ~= expected then
		report:warn(("The pager profile points to %s instead of this config"):format(actual), { relink })
	elseif not installed then
		report:warn("nvimpager is missing: the linked pager profile cannot be used", report:install("nvimpager"))
	else
		report:ok("Pager profile: nvimpager uses this config")
	end
end

local function check_usage(report)
	local usage = package.loaded["config.usage"]
	if type(usage) ~= "table" or type(usage.status) ~= "function" then
		return
	end
	local ok, status = pcall(usage.status)
	if not ok or type(status) ~= "table" then
		report:warn("Could not read the usage statistics state: " .. tostring(status))
	elseif not status.enabled then
		report:info("Usage statistics are disabled in this session (telemetry off, headless, CI or tests)")
	elseif status.error and vim.fn.exepath("sqlite3") == "" then
		report:warn(
			"sqlite3 is missing: local usage statistics are off",
			report:install("sqlite3", "Then run :UsageResume, or restart Neovim")
		)
	elseif status.error then
		report:warn("Local usage statistics are off: " .. tostring(status.error), { "Run :UsageResume to retry" })
	elseif status.collecting then
		report:ok("Usage statistics are collected in " .. tostring(status.path))
	else
		report:info("Usage statistics start once a UI attaches")
	end
end

local AUTO_INSTALL_ADVICE = {
	mise = "Run :NvimConfigMiseInstall (or scripts/install-mise)",
	parsers = "Run :NvimConfigParsersInstall",
}

local function check_auto_install(report)
	local offline = vim.env.NVIM_CONFIG_OFFLINE == "1"
	local auto = package.loaded["config.auto_install"]
	if type(auto) ~= "table" or type(auto.status) ~= "function" then
		if offline then
			report:info("NVIM_CONFIG_OFFLINE=1: nothing is downloaded automatically")
		end
		return
	end
	local ok, status = pcall(auto.status)
	if not ok or type(status) ~= "table" then
		report:warn("Could not read the automatic install state: " .. tostring(status))
		return
	end
	if status.skipped then
		report:info("Automatic installs did not run in this session: " .. status.skipped)
	elseif offline then
		report:info("NVIM_CONFIG_OFFLINE=1: nothing is downloaded automatically")
	end
	local steps = vim.tbl_keys(status.failures or {})
	table.sort(steps)
	for _, step in ipairs(steps) do
		local failure = status.failures[step]
		local at = type(failure) == "table" and tonumber(failure.at) or nil
		local when = at and os.date("%Y-%m-%d %H:%M", at) or "an unknown time"
		local retry = at and os.date("%Y-%m-%d %H:%M", at + (status.retry_seconds or 0)) or "the next start"
		local detail = type(failure) == "table" and failure.detail or failure
		report:warn(("The automatic %s install failed at %s: %s"):format(step, when, tostring(detail)), {
			AUTO_INSTALL_ADVICE[step] or "Retry the installation manually",
			"Neovim retries it automatically after " .. retry,
		})
	end
end

local function check_undo(report)
	local active = vim.fs.joinpath(vim.fn.stdpath("state"), "undo")
	local stat = uv.fs_stat(active)
	local healthy = true
	if not stat or stat.type ~= "directory" then
		healthy = false
		report:error("The persistent undo directory is missing: " .. active, {
			"mkdir -p -m 700 " .. active,
			"Startup creates it, so also check the startup messages (:messages)",
		})
	else
		local permissions = bit.band(stat.mode or 0, tonumber("777", 8))
		if permissions ~= tonumber("700", 8) then
			healthy = false
			report:error(
				("The persistent undo directory mode is %03o, expected 700: %s"):format(permissions, active),
				{ "chmod 700 " .. active }
			)
		end
	end
	if not vim.o.undodir:find(active, 1, true) then
		healthy = false
		report:error(
			"'undodir' does not use " .. active,
			{ "Something overrides it: :verbose set undodir? shows what" }
		)
	end
	if healthy then
		report:ok("Persistent undo is stored owner-only in " .. active)
	end
	local legacy = vim.fs.joinpath(config_root(), ".undodir")
	if uv.fs_stat(legacy) then
		report:warn("The legacy undo directory is no longer used: " .. legacy, { "Review it, then: rm -r " .. legacy })
	end
end

local VALIDATORS = {
	{ name = "stylua", version = "stylua " .. toolchain.versions.stylua },
	{ name = "shellcheck", version = "version: " .. toolchain.versions.shellcheck },
	{ name = "actionlint", version = toolchain.versions.actionlint },
	{ name = "tree-sitter", version = "tree-sitter " .. toolchain.versions.tree_sitter },
}

local function check_validation(report)
	local root = config_root()
	if vim.fn.filereadable(vim.fs.joinpath(root, "lazy-lock.json")) ~= 1 then
		report:error("lazy-lock.json is missing, so plugins are not pinned", {
			("git -C %s checkout -- lazy-lock.json"):format(root),
		})
	end
	for _, name in ipairs({ "bootstrap-config", "check-config", "install-ci-tools", "provision-runtime" }) do
		if vim.fn.executable(vim.fs.joinpath(root, "scripts", name)) ~= 1 then
			report:error(("scripts/%s is missing or not executable"):format(name), {
				("git -C %s checkout -- scripts/%s"):format(root, name),
			})
		end
	end
	local missing = {}
	for _, validator in ipairs(VALIDATORS) do
		local path = vim.fn.exepath(validator.name)
		if path == "" then
			missing[#missing + 1] = validator.name
		end
		report:detail(
			("%s for scripts/check-config: %s (expects %q)"):format(
				validator.name,
				path ~= "" and path or "missing",
				validator.version
			)
		)
	end
	if #missing > 0 then
		report:info(
			("scripts/check-config validators are not installed: %s (scripts/install-ci-tools /absolute/path/to/bin)"):format(
				table.concat(missing, ", ")
			)
		)
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

local function add_catalog_details(report)
	report:detail(
		("Mise %s or newer; tools in ~/.local/share/mise/installs, state in ~/.local/state/mise"):format(
			toolchain.versions.mise
		)
	)
	for _, entry in ipairs(tool_contract()) do
		report:detail(entry.name .. "@" .. entry.version .. " (" .. entry.backend .. ")")
	end
end

local function render(report, details)
	health.start("Problems")
	if #report.errors == 0 and #report.warnings == 0 then
		health.ok("No problems found")
	end
	for _, item in ipairs(report.errors) do
		health.error(item.message, item.advice)
	end
	for _, item in ipairs(report.warnings) do
		health.warn(item.message, item.advice)
	end

	health.start("Summary")
	for _, item in ipairs(report.summary) do
		health[item.kind](item.message)
	end
	if not details then
		health.info(DETAILS_HINT)
		return
	end

	health.start("Details")
	for _, line in ipairs(report.details) do
		health.info(line)
	end
end

---@param opts? { platform?: table, details?: boolean } test seams; :checkhealth passes none
function M.check(opts)
	opts = opts or {}
	local report = new_report(opts.platform or host_packages.detect())
	local details = opts.details
	if details == nil then
		details = enabled(vim.g.nvimconfig_health_details)
	end

	check_neovim(report)
	report:info("Platform: " .. host_packages.describe(report.platform))
	local mise_found = check_required_tools(report)
	check_path_order(report, local_path_set())
	check_plugins(report)
	check_parsers(report)
	check_markdown_view(report)
	check_local_products(report)
	check_managed_tools(report, mise_found)
	check_optional_tools(report)
	check_pager_profile(report)
	check_usage(report)
	check_auto_install(report)
	check_undo(report)
	check_validation(report)
	if details then
		add_catalog_details(report)
	end
	render(report, details)
end

-- Small test seam for origin classification; no filesystem or state mutation.
M._path_origin = path_origin
M._local_product_status = local_product_status
M._tool_contract = tool_contract

return M
