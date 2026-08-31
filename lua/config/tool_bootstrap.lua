-- Host adapter for verified-tools.nvim. Commands live here; lifecycle state,
-- locking, scheduling, retries, and attestation live in the local plugin.
local M = {}
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local release = require("config.release_installer")
local engine = require("verified_tools")

local setup_done = false
local command_done = false
local plans = {}

M._notify = function(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Tools" })
end
M._registry = function()
	return require("mason-registry")
end
M._network_authorized = function()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end

local function platform_target()
	local uname = vim.uv.os_uname()
	return manifest.target_key(uname.sysname, uname.machine) or (uname.sysname .. "-" .. uname.machine):lower()
end

local function external_probe(identity, spec)
	local entry = spec.manifest and spec.manifest.entry
	local executables = entry and (entry.satisfies_any or entry.executables or { entry.executable }) or {}
	for _, executable in ipairs(executables) do
		local path = paths.external_executable(executable)
		if path then
			local ok, process = pcall(vim.system, { path, "--version" }, { text = true })
			local result = ok and process:wait(2000) or nil
			local output = result and ((result.stdout or "") .. "\n" .. (result.stderr or "")) or ""
			return {
				path = path,
				compatible = result ~= nil and result.code == 0 and output:find(identity.version, 1, true) ~= nil,
				observed = output:gsub("[%c]+", " "):sub(1, 160),
			}
		end
	end
	return nil
end

local release_backend = {}
function release_backend.run(plan, done, control)
	local controller = release.install(plan.manifest.release_plan, done)
	if type(controller) == "table" and type(controller.cancel) == "function" then
		control.set_cancel(controller.cancel)
	end
	return nil
end
function release_backend.attest(plan, done)
	local path = vim.fs.joinpath(plan.identity.install_root, "bin", plan.manifest.entry.executable)
	local stat = vim.uv.fs_lstat(path)
	local ok = stat and stat.type == "file" and vim.fn.executable(path) == 1
	done(ok == true, ok and { path = path, digest = plan.identity.digest } or "managed-executable-missing")
end

local mason_backend = {}
function mason_backend.run(plan, done, control)
	local available, registry = pcall(M._registry)
	if not available or type(registry) ~= "table" then
		done(false, "mason-registry-unavailable")
		return false
	end
	local refresh_ok = pcall(registry.refresh, function(success)
		if not success or not registry.has_package(plan.identity.name) then
			done(false, success and "mason-package-unavailable" or "mason-refresh-failed")
			return
		end
		local pkg = registry.get_package(plan.identity.name)
		local ok, handle = pcall(pkg.install, pkg, { version = plan.identity.version }, function(installed)
			done(installed == true, installed and nil or "mason-install-failed")
		end)
		if not ok then
			done(false, "mason-install-start-failed:" .. tostring(handle))
		elseif type(handle) == "table" then
			local cancel = handle.cancel or handle.terminate
			if type(cancel) == "function" then
				control.set_cancel(function()
					pcall(cancel, handle)
				end)
			end
		end
	end)
	if not refresh_ok then
		done(false, "mason-refresh-start-failed")
		return false
	end
	return nil
end
function mason_backend.attest(plan, done)
	local available, registry = pcall(M._registry)
	if not available or not registry.has_package(plan.identity.name) then
		done(false, "mason-package-unavailable")
		return
	end
	local pkg = registry.get_package(plan.identity.name)
	local installed = pkg:is_installed()
	local version = installed and pkg:get_installed_version() or nil
	local executable = plan.manifest.entry.executables[1]
	local path = vim.fs.joinpath(plan.identity.install_root, "bin", executable)
	local stat = vim.uv.fs_lstat(path)
	local ok = installed and version == plan.identity.version and stat and stat.type == "file"
	done(ok == true, ok and { path = path, digest = plan.identity.digest } or "mason-attestation-failed")
end

local function release_spec(name)
	local plan, reason = release.plan(name, { force = true })
	if not plan then
		return nil, reason
	end
	return {
		identity = {
			backend = "release",
			name = name,
			version = plan.entry.version,
			target = plan.target,
			digest = plan.asset.sha256:lower(),
			install_root = paths.managed_root(),
		},
		manifest = { entry = plan.entry, release_plan = plan },
		requires_network = true,
	}
end

local function mason_spec(name)
	local entry = manifest.mason_entry(name)
	if not entry then
		return nil, "unknown"
	end
	return {
		identity = {
			backend = "mason",
			name = name,
			version = entry.version,
			target = platform_target(),
			digest = "manifest:" .. vim.fn.sha256(name .. "@" .. entry.version),
			install_root = paths.mason_root(),
		},
		manifest = { entry = entry },
		requires_network = true,
	}
end

function M.spec(name)
	if manifest.managed_tools[name] then
		return release_spec(name)
	end
	return mason_spec(name)
end

local function catalog_names()
	local names = vim.deepcopy(manifest.managed_order)
	vim.list_extend(names, manifest.mason_order)
	return names
end

function M.plan_all()
	plans = {}
	for _, name in ipairs(catalog_names()) do
		local spec = M.spec(name)
		if spec then
			local plan = engine.plan(spec)
			if plan then
				plans[name] = plan
			end
		end
	end
	return vim.deepcopy(plans)
end

function M.import_legacy()
	local legacy = require("config.tool_state")
	for _, name in ipairs(catalog_names()) do
		local spec = M.spec(name)
		if spec and engine.status(spec.identity) == nil then
			local record, reason = legacy.inspect(name, spec.identity.version)
			if record then
				engine.import_legacy(spec, record)
			elseif reason ~= "absent" then
				engine.import_legacy(spec, { status = reason })
			end
		end
	end
end

local function report(prefix, name, ok, reason)
	M._notify((ok and prefix or "Failed to " .. prefix:lower()) .. name .. (reason and ": " .. reason or ""))
end

local function start(name, force_repair)
	local spec, spec_err = M.spec(name)
	if not spec then
		M._notify(name .. " cannot be planned (" .. tostring(spec_err) .. ")", vim.log.levels.WARN)
		return false
	end
	local plan = assert(engine.plan(spec))
	if plan.strategy == "external" and not force_repair then
		M._notify(name .. " is supplied by a compatible external executable")
		return true
	end
	local current = engine.status(plan.identity)
	if current and current.status == "failed" and not force_repair then
		return engine.retry(spec, function(ok, reason)
			report("Installed ", name, ok, reason)
		end) ~= nil
	end
	if current then
		if not force_repair then
			M._notify(name .. " requires :NvimConfigToolsInstall! " .. name, vim.log.levels.WARN)
			return false
		end
		return engine.repair(spec, function(ok, reason)
			report("Repaired ", name, ok, reason)
		end) ~= nil
	end
	local claim, claim_err = engine.claim(plan, { mode = "auto" })
	if not claim then
		M._notify(name .. " was not started (" .. tostring(claim_err) .. ")", vim.log.levels.WARN)
		return false
	end
	return engine.run(claim, function(ok, reason)
		report("Installed ", name, ok, reason)
	end) ~= nil
end

function M.install(target, force)
	local names = target == "all" and catalog_names() or { target }
	if target ~= "all" and not manifest.managed_tools[target] and not manifest.mason_entry(target) then
		M._notify("Unknown tool '" .. target .. "'", vim.log.levels.ERROR)
		return false
	end
	local ok = true
	for _, name in ipairs(names) do
		ok = start(name, force) and ok
	end
	return ok
end

function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	engine.setup({
		state_root = function()
			return vim.fs.joinpath(paths.primary_state_root(), "verified-tools")
		end,
		backends = { release = release_backend, mason = mason_backend },
		probe_external = external_probe,
		network_authorized = M._network_authorized,
		notify = M._notify,
	})
	M.plan_all()
	if not command_done then
		command_done = true
		vim.api.nvim_create_user_command("NvimConfigToolsInstall", function(options)
			M.install(options.args == "" and "all" or options.args, options.bang)
		end, {
			nargs = "?",
			bang = true,
			complete = catalog_names,
			desc = "Install or repair exact verified tools",
		})
	end
end

function M.mason_ready()
	-- Mason is ready for explicit commands. Never refresh/install at startup.
	M.plan_all()
	M.import_legacy()
end

function M.mason_busy()
	local _, active = engine._queue_size()
	return active > 0
end

function M.mason_condition()
	return function()
		return false
	end
end

function M.engine()
	if not setup_done then
		M.setup()
	end
	return engine
end

function M._reset_for_tests()
	plans = {}
	engine._reset_for_tests()
end

return M
