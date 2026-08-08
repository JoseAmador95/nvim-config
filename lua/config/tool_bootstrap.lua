-- One lifecycle for pinned Mason packages and the small set of official
-- release binaries. Automatic attempts are persistent one-shots; explicit
-- commands may retry without turning startup into a package-manager loop.
local M = {}

local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local release = require("config.release_installer")
local state = require("config.tool_state")

local setup_done = false
local mason_configured = false
local auto_started = false
local auto_scheduled = false
local mason_active = false
local busy_warning_sent = false
local python_venv_cache = {}

M._notify = function(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Tools" })
end

M._ui_count = function()
	return #vim.api.nvim_list_uis()
end

M._python_venv = function(python)
	local ok, process = pcall(vim.system, { python, "-c", "import venv" }, { text = true })
	if not ok then
		return false
	end
	return process:wait(10000).code == 0
end

M._registry = function()
	return require("mason-registry")
end

local function full_profile()
	return not vim.g.vscode and not require("config.pager").active
end

local function automatic_allowed()
	if not full_profile() or M._ui_count() == 0 or vim.env.NVIM_CONFIG_OFFLINE == "1" then
		return false
	end
	local mason = require("config.local_config").get("mason", {})
	return mason.auto_install ~= false
end

local function externally_satisfied(entry)
	local probes = entry.satisfies_any or { entry.executables and entry.executables[1] }
	for _, executable in ipairs(probes) do
		if paths.external_executable(executable) then
			return true
		end
	end
	return false
end

local function requirements_available(entry)
	for _, executable in ipairs(entry.requires_all or {}) do
		if not paths.external_executable(executable) then
			return false
		end
	end

	local selected
	if entry.requires_any and #entry.requires_any > 0 then
		for _, executable in ipairs(entry.requires_any) do
			selected = paths.external_executable(executable)
			if selected then
				break
			end
		end
		if not selected then
			return false
		end
	end

	if not entry.requires_python_venv then
		return true
	end
	if python_venv_cache[selected] == nil then
		python_venv_cache[selected] = M._python_venv(selected)
	end
	return python_venv_cache[selected]
end

local function unconsumed(name, entry)
	local record, reason = state.inspect(name, entry.version)
	return record == nil and reason == "absent"
end

local function tracker()
	local batch = { claimed = 0, pending = 0, succeeded = 0, failed = 0, sealed = false }

	function batch:add()
		self.claimed = self.claimed + 1
		self.pending = self.pending + 1
	end

	function batch:done(ok)
		self.pending = self.pending - 1
		self[ok and "succeeded" or "failed"] = self[ok and "succeeded" or "failed"] + 1
		self:finish_if_ready()
	end

	function batch:seal()
		self.sealed = true
		self:finish_if_ready()
	end

	function batch:finish_if_ready()
		if not self.sealed or self.pending ~= 0 then
			return
		end
		mason_active = false
		if self.claimed > 0 then
			M._notify(
				("Automatic tool bootstrap finished: %d succeeded, %d failed"):format(self.succeeded, self.failed),
				self.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
			)
		end
	end

	return batch
end

local function finish_claim(batch, claim, ok, reason)
	local persisted = state.finish(claim, ok, reason)
	batch:done(ok and persisted == true)
end

local function fail_candidate(batch, candidate, reason)
	local claim = state.claim_auto(candidate.name, candidate.entry.version)
	if claim then
		batch:add()
		finish_claim(batch, claim, false, reason)
	end
end

local function start_managed(batch)
	for _, name in ipairs(manifest.managed_order) do
		local entry = manifest.managed_tools[name]
		if unconsumed(name, entry) then
			local plan = release.plan(name)
			if plan then
				local claim = state.claim_auto(name, entry.version)
				if claim then
					batch:add()
					if not state.transition(claim, "installing") then
						finish_claim(batch, claim, false, "state-transition-failed")
					else
						release.install(plan, function(ok, reason)
							finish_claim(batch, claim, ok, reason)
						end)
					end
				end
			end
		end
	end
end

local function mason_candidates()
	local candidates = {}
	for _, name in ipairs(manifest.mason_order) do
		local entry = assert(manifest.mason_entry(name))
		if unconsumed(name, entry) and not externally_satisfied(entry) and requirements_available(entry) then
			candidates[#candidates + 1] = { name = name, entry = entry }
		end
	end
	return candidates
end

local function safe_call(object, method, ...)
	if type(object) ~= "table" or type(object[method]) ~= "function" then
		return false
	end
	return pcall(object[method], object, ...)
end

local function start_mason(batch)
	local candidates = mason_candidates()
	if #candidates == 0 then
		batch:seal()
		return
	end

	local ok, registry = pcall(M._registry)
	if not ok or type(registry) ~= "table" or type(registry.refresh) ~= "function" then
		batch:seal()
		return
	end
	local refresh_ok = pcall(registry.refresh, function(success)
		if not success then
			batch:seal()
			return
		end
		for _, candidate in ipairs(candidates) do
			local has_ok, has_package = pcall(registry.has_package, candidate.name)
			if has_ok and not has_package then
				fail_candidate(batch, candidate, "mason-package-unavailable")
			elseif has_ok and has_package then
				local package_ok, pkg = pcall(registry.get_package, candidate.name)
				if package_ok then
					local installed_ok, installed = safe_call(pkg, "is_installed")
					local version_ok, installed_version = safe_call(pkg, "get_installed_version")
					if installed_ok and installed and version_ok and installed_version == candidate.entry.version then
						local claim = state.claim_auto(candidate.name, candidate.entry.version)
						if claim then
							batch:add()
							finish_claim(batch, claim, true)
						end
					else
						local installing_ok, installing = safe_call(pkg, "is_installing")
						local installable_ok, installable =
							safe_call(pkg, "is_installable", { version = candidate.entry.version })
						if installing_ok and not installing and installable_ok and not installable then
							fail_candidate(batch, candidate, "mason-package-uninstallable")
						elseif installing_ok and not installing and installable_ok and installable then
							local claim = state.claim_auto(candidate.name, candidate.entry.version)
							if claim then
								batch:add()
								if not state.transition(claim, "installing") then
									finish_claim(batch, claim, false, "state-transition-failed")
								else
									local install_ok = pcall(
										pkg.install,
										pkg,
										{ version = candidate.entry.version },
										function(done)
											vim.schedule(function()
												finish_claim(
													batch,
													claim,
													done == true,
													done and nil or "mason-install-failed"
												)
											end)
										end
									)
									if not install_ok then
										finish_claim(batch, claim, false, "mason-install-start-failed")
									end
								end
							end
						end
					end
				end
			end
		end
		batch:seal()
	end)
	if not refresh_ok then
		batch:seal()
	end
end

local function run_automatic()
	auto_scheduled = false
	if auto_started or not mason_configured or not automatic_allowed() then
		return
	end
	auto_started = true
	mason_active = true
	local batch = tracker()
	start_managed(batch)
	start_mason(batch)
end

local function schedule_automatic()
	if auto_scheduled then
		return
	end
	auto_scheduled = true
	vim.schedule(run_automatic)
end

local function manual_reason(name, reason)
	if reason == "external" then
		return name .. " is already provided by the host (use ! to install the managed pin)"
	elseif reason == "unsupported" then
		return name .. " has no pinned release asset for this platform"
	elseif reason == "missing-prerequisite" then
		return name .. " is waiting for a required host command"
	end
	return name .. " cannot be installed (" .. tostring(reason) .. ")"
end

local function manual_managed(target, force)
	if vim.env.NVIM_CONFIG_OFFLINE == "1" then
		M._notify("Tool installation is disabled by NVIM_CONFIG_OFFLINE=1", vim.log.levels.WARN)
		return false
	end
	local names = target == "all" and manifest.managed_order or { target }
	if target ~= "all" and not manifest.managed_tools[target] then
		M._notify("Unknown tool '" .. target .. "'. Choose all, mmdflux, gofumpt, or plantuml.", vim.log.levels.ERROR)
		return false
	end
	for _, name in ipairs(names) do
		local entry = manifest.managed_tools[name]
		local plan, reason = release.plan(name, { force = force })
		if not plan then
			M._notify(manual_reason(name, reason), reason == "external" and vim.log.levels.INFO or vim.log.levels.WARN)
		else
			local claim, claim_err = state.claim_manual(name, entry.version)
			if not claim then
				M._notify(
					name .. " installation is busy or its state is unsafe (" .. tostring(claim_err) .. ")",
					vim.log.levels.WARN
				)
			else
				if not state.transition(claim, "installing") then
					state.finish(claim, false, "state-transition-failed")
					M._notify("Failed to secure installation state for " .. claim.identity, vim.log.levels.ERROR)
					return false
				end
				M._notify("Installing " .. claim.identity .. " from its verified release")
				release.install(plan, function(ok, install_err)
					state.finish(claim, ok, install_err)
					M._notify(
						(ok and "Installed " or "Failed to install ") .. claim.identity,
						ok and vim.log.levels.INFO or vim.log.levels.ERROR
					)
				end)
			end
		end
	end
	return true
end

function M.mason_busy()
	return mason_active
end

-- Public condition used by mason-tool-installer. It exits before that plugin
-- touches a package while the one-shot Mason batch owns the registry.
function M.mason_condition(entry)
	return function()
		if mason_active then
			if not busy_warning_sent then
				busy_warning_sent = true
				M._notify(
					"MasonToolsInstallSync is unavailable while automatic Mason installation is running",
					vim.log.levels.WARN
				)
			end
			return false
		end
		return vim.env.NVIM_CONFIG_OFFLINE ~= "1" and not externally_satisfied(entry) and requirements_available(entry)
	end
end

function M.mason_ready()
	mason_configured = true
	schedule_automatic()
end

function M.setup()
	if setup_done or not full_profile() then
		return
	end
	setup_done = true
	vim.api.nvim_create_user_command("NvimConfigToolsInstall", function(options)
		manual_managed(options.args == "" and "all" or options.args, options.bang)
	end, {
		nargs = "?",
		bang = true,
		complete = function()
			return { "all", "mmdflux", "gofumpt", "plantuml" }
		end,
		desc = "Install exact managed Neovim release tools",
	})
	vim.api.nvim_create_autocmd("UIEnter", {
		group = vim.api.nvim_create_augroup("NvimConfigToolBootstrap", { clear = true }),
		callback = schedule_automatic,
		desc = "Attempt each eligible exact tool pin once",
	})
end

-- Dependency-free specs reload scenarios in one Neovim process. Production
-- code never calls this; persistent records remain the actual cross-startup
-- boundary.
function M._reset_for_tests()
	mason_configured = false
	auto_started = false
	auto_scheduled = false
	mason_active = false
	busy_warning_sent = false
	python_venv_cache = {}
end

return M
