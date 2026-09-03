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
	{ name = "verified-tools.nvim", module = "verified_tools" },
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
	local configured = require("config.local_config").get("path", {}) or {}
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
	if tool_paths.is_verified_shim_path(path) then
		return "verified-shim", 1
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
	health.info(
		"PATH precedence contract: verified shims > local_config.path > ~/.local/bin > host PATH > managed > Mason"
	)
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

local function has_exact_line(output, expected)
	for line in output:gmatch("[^\r\n]+") do
		if line == expected then
			return true
		end
	end
	return false
end

local function check_validation_tool(name, args, expected_line, configured)
	local path = vim.fn.exepath(name)
	local install = "Run: scripts/install-ci-tools /absolute/path/to/bin"
	if path == "" then
		health.warn(("%s is missing; reproducible validation will fail. %s"):format(name, install))
		return
	end

	local command = { path }
	vim.list_extend(command, args)
	local result = vim.system(command, { text = true }):wait(5000)
	local output = (result.stdout or "") .. (result.stderr or "")
	local origin = path_origin(path, configured)
	if result.code == 0 and has_exact_line(output, expected_line) then
		health.ok(("%s matches the validation pin (%s): %s"):format(name, origin, expected_line))
	else
		health.warn(("%s does not match required version %q. %s"):format(path, expected_line, install))
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

local function local_product_status()
	local rows = {}
	for _, product in ipairs(LOCAL_PRODUCTS) do
		local loaded, plugin = pcall(require, product.module)
		local row = { name = product.name, module = product.module, loaded = loaded }
		if not loaded then
			row.error = tostring(plugin)
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
		else
			local configured = row.status.configured
			local suffix = configured == nil and "" or ("; configured=" .. tostring(configured))
			health.ok(row.name .. ": status and effective configuration available" .. suffix)
		end
	end
end

local function joined_pins(order, entries)
	local pins = {}
	for _, name in ipairs(order) do
		pins[#pins + 1] = toolchain.identity(name, entries[name])
	end
	return table.concat(pins, ", ")
end

local function state_summary()
	local bootstrap = require("config.tool_bootstrap")
	local grouped = {}
	for _, record in ipairs(bootstrap.engine().records() or {}) do
		local status = record.status
		local identity = record.identity.backend .. ":" .. record.identity.name .. "@" .. record.identity.version
		if record and type(record.detail) == "string" and record.detail ~= "" then
			local detail = record.detail:gsub("[%c]", " "):sub(1, 160)
			identity = identity .. " (" .. detail .. ")"
		end
		grouped[status] = grouped[status] or {}
		grouped[status][#grouped[status] + 1] = identity
	end
	local parts = {}
	for _, status in ipairs({
		"succeeded",
		"failed",
		"drift",
		"repair-required",
		"running",
		"queued",
		"claimed",
		"cancelled",
	}) do
		if grouped[status] then
			parts[#parts + 1] = status .. "=[" .. table.concat(grouped[status], ", ") .. "]"
		end
	end
	health.info("Verified tool state: " .. (#parts > 0 and table.concat(parts, "; ") or "no attempts"))
	if grouped.failed then
		health.warn("Tool failures never auto-retry; inspect the reason, then use :NvimConfigToolsInstall[!]")
	end
	if grouped.drift or grouped["repair-required"] then
		health.warn("Drift and legacy failures require explicit :NvimConfigToolsInstall! repair")
	end
end

local function safe_relative(value)
	if type(value) ~= "string" or value == "" or value:sub(1, 1) == "/" or vim.fs.normalize(value) ~= value then
		return false
	end
	for segment in value:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return false
		end
	end
	return true
end

local function mason_receipt_status(name, expected)
	local entry = toolchain.mason_entry(name)
	if not entry then
		return "missing"
	end
	local receipt = vim.fs.joinpath(tool_paths.mason_root(), "packages", name, "mason-receipt.json")
	local receipt_stat = vim.uv.fs_lstat(receipt)
	if not receipt_stat then
		return "missing"
	end
	if receipt_stat.type ~= "file" or receipt_stat.nlink ~= 1 or receipt_stat.size > 262144 then
		return "corrupt"
	end
	local ok, lines = pcall(vim.fn.readfile, receipt)
	if not ok then
		return "corrupt"
	end
	local decoded_ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
	if
		not decoded_ok
		or type(value) ~= "table"
		or value.name ~= name
		or not ({ ["1.0"] = true, ["1.1"] = true, ["2.0"] = true })[value.schema_version]
	then
		return "corrupt"
	end
	local source = value.schema_version == "2.0" and value.source or value.primary_source
	local source_id = type(source) == "table" and source.id or nil
	if type(source_id) ~= "string" then
		return "corrupt"
	end
	local actual = source_id:match("@([^@]+)$")
	if not actual or actual == "" then
		return "corrupt"
	end
	if actual ~= expected then
		return "wrong", actual
	end
	local links = type(value.links) == "table" and value.links.bin or nil
	local executables = toolchain.executable_map(entry)
	if type(links) ~= "table" or vim.tbl_count(links) ~= vim.tbl_count(executables) then
		return "corrupt"
	end
	local package_root = vim.fs.joinpath(tool_paths.mason_root(), "packages", name)
	local canonical_package = vim.uv.fs_realpath(package_root)
	if not canonical_package then
		return "corrupt"
	end
	for command in pairs(executables) do
		local relative = links[command]
		if not safe_relative(relative) then
			return "corrupt"
		end
		local command_path = vim.fs.joinpath(tool_paths.mason_root(), "bin", command)
		local source_path = vim.fs.joinpath(package_root, relative)
		local source_real = vim.uv.fs_realpath(source_path)
		local source_stat = source_real and vim.uv.fs_stat(source_real) or nil
		if
			not source_real
			or not (source_real == canonical_package or source_real:sub(1, #canonical_package + 1) == canonical_package .. "/")
			or vim.uv.fs_realpath(command_path) ~= source_real
			or not source_stat
			or source_stat.type ~= "file"
			or vim.fn.executable(command_path) ~= 1
		then
			return "corrupt"
		end
	end
	for command in pairs(links) do
		if not executables[command] then
			return "corrupt"
		end
	end
	local private = vim.fs.joinpath(tool_paths.mason_root(), ".verified-tools", "receipts", name .. ".json")
	local private_stat = vim.uv.fs_lstat(private)
	if not private_stat then
		return "unverified"
	end
	if private_stat.type ~= "file" or private_stat.nlink ~= 1 or private_stat.mode % 512 ~= 384 then
		return "corrupt"
	end
	local private_ok, private_lines = pcall(vim.fn.readfile, private)
	local private_decoded, private_value = false, nil
	if private_ok then
		private_decoded, private_value = pcall(vim.json.decode, table.concat(private_lines, "\n"))
	end
	local expected_private = { package = name, version = expected, source_version = expected }
	return private_decoded and vim.deep_equal(private_value, expected_private) and "exact" or "corrupt", actual
end

local function check_mason_receipts()
	local grouped = { exact = {}, wrong = {}, missing = {}, unverified = {}, corrupt = {} }
	for _, name in ipairs(toolchain.mason_order) do
		local entry = toolchain.mason_tools[name]
		local status, actual = mason_receipt_status(name, entry.version)
		local label = toolchain.identity(name, entry)
		if status == "wrong" then
			label = label .. " (installed " .. actual .. ")"
		end
		grouped[status][#grouped[status] + 1] = label
	end
	for _, status in ipairs({ "exact", "wrong", "missing", "unverified", "corrupt" }) do
		if #grouped[status] > 0 then
			local message = "Mason receipts " .. status .. ": " .. table.concat(grouped[status], ", ")
			if status == "wrong" or status == "unverified" or status == "corrupt" then
				health.warn(message)
			else
				health.info(message)
			end
		end
	end
end

local function check_managed_release_eligibility()
	local release = require("config.release_installer")
	local results = {}
	for _, name in ipairs(toolchain.managed_order) do
		local entry = toolchain.managed_tools[name]
		local plan, reason = release.plan(name, { force = true })
		results[#results + 1] = toolchain.identity(name, entry) .. "=" .. (plan and plan.target or reason)
	end
	health.info("Managed release platform/prerequisites: " .. table.concat(results, ", "))
end

local python_venv = {}
local function missing_requirements(entry)
	local missing = {}
	for _, executable in ipairs(entry.requires_all or {}) do
		if not tool_paths.external_executable(executable) then
			missing[#missing + 1] = executable
		end
	end

	local selected
	if entry.requires_any then
		for _, executable in ipairs(entry.requires_any) do
			selected = tool_paths.external_executable(executable)
			if selected then
				break
			end
		end
		if not selected then
			missing[#missing + 1] = table.concat(entry.requires_any, "|")
		end
	end

	if entry.requires_python_venv and selected then
		if python_venv[selected] == nil then
			local result = vim.system({ selected, "-c", "import venv" }, { text = true }):wait(5000)
			python_venv[selected] = result.code == 0
		end
		if not python_venv[selected] then
			missing[#missing + 1] = "python-venv"
		end
	end
	return missing
end

local function check_mason_inventory()
	local managers = { prebuilt = {}, npm = {}, pypi = {} }
	local blocked = {}
	for _, name in ipairs(toolchain.mason_order) do
		local entry = toolchain.mason_tools[name]
		managers[entry.manager][#managers[entry.manager] + 1] = toolchain.identity(name, entry)
		local missing = missing_requirements(entry)
		if #missing > 0 then
			blocked[#blocked + 1] = name .. " (" .. table.concat(missing, "+") .. ")"
		end
	end
	for _, manager in ipairs({ "prebuilt", "npm", "pypi" }) do
		health.info(("Mason %-8s %s"):format(manager .. ":", table.concat(managers[manager], ", ")))
	end
	if #blocked == 0 then
		health.ok("All declared Mason installer prerequisites are available")
	else
		health.warn("One-shot Mason skips tools blocked by host prerequisites: " .. table.concat(blocked, ", "))
	end
end

local function check_validation_contract(configured)
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
	check_validation_tool("stylua", { "--version" }, "stylua " .. toolchain.versions.stylua, configured)
	check_validation_tool("shellcheck", { "--version" }, "version: " .. toolchain.versions.shellcheck, configured)
	check_validation_tool("actionlint", { "-version" }, toolchain.versions.actionlint, configured)
	check_validation_tool("tree-sitter", { "--version" }, "tree-sitter " .. toolchain.versions.tree_sitter, configured)
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

	health.start("Pinned tool bootstrap")
	health.info("Managed release pins: " .. joined_pins(toolchain.managed_order, toolchain.managed_tools))
	health.info("Mason exact pins: " .. joined_pins(toolchain.mason_order, toolchain.mason_tools))
	health.ok("Startup leaves verified-tools unloaded; health and explicit commands own plan/probe/attest/install")
	state_summary()
	check_managed_release_eligibility()
	check_mason_receipts()
	health.info("Install or repair release and Mason pins with :NvimConfigToolsInstall[!] [all|name]")
	check_mason_inventory()

	health.start("Optional feature dependencies")
	check_tool("mmdflux", "Mermaid ASCII/SVG rendering", "Run :NvimConfigToolsInstall mmdflux.", false, configured)
	check_tool("plantuml", "PlantUML ASCII/SVG rendering", "Run :NvimConfigToolsInstall plantuml.", false, configured)
	check_external_tool(
		"rust-analyzer",
		"Rust language intelligence (host/user only)",
		"Install it with rustup or the host package manager; managed and Mason copies are intentionally ignored.",
		configured
	)
	check_external_tool(
		"rustfmt",
		"Rust formatting (host/user only)",
		"Install it with rustup or the host package manager; managed and Mason copies are intentionally ignored.",
		configured
	)
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
	check_tool(
		"devcontainer",
		"Dev Containers CLI editor lifecycle",
		"Install @devcontainers/cli explicitly; startup never downloads or refreshes it.",
		false,
		configured
	)
	check_pager_profile()

	health.start("Reproducible validation")
	check_validation_contract(configured)

	health.start("Persistent undo")
	check_undo()
end

-- Small test seam for origin classification; no filesystem or state mutation.
M._path_origin = path_origin
M._mason_receipt_status = mason_receipt_status
M._local_product_status = local_product_status

return M
