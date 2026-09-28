vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/_shared")
vim.opt.runtimepath:prepend(repo .. "/local-plugins/verified-tools.nvim")
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	repo .. "/local-plugins/_shared/lua/?.lua",
	repo .. "/local-plugins/_shared/lua/?/init.lua",
	repo .. "/local-plugins/verified-tools.nvim/lua/?.lua",
	repo .. "/local-plugins/verified-tools.nvim/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function progress_timer()
	local timer = { stopped = false, closed = false }
	function timer:start(timeout, repeating, callback)
		self.timeout = timeout
		self.repeating = repeating
		self.callback = callback
		return true
	end
	function timer:stop()
		self.stopped = true
		return true
	end
	function timer:close()
		self.closed = true
		return true
	end
	function timer:is_closing()
		return self.closed
	end
	return timer
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local managed = fixture .. "/managed"
local mason = fixture .. "/mason"
local state = fixture .. "/state"
local host = fixture .. "/host"
for _, directory in ipairs({ managed, mason, state, host }) do
	assert(vim.fn.mkdir(directory, "p") == 1)
end

local toolchain = require("config.toolchain")
local fs = require("config.fs")
local release_plan_count = 0
local release_install_count = 0
local registry_refresh_count = 0
local mason_install_count = 0
local mason_version_checks = 0
local mutate_mason_at_check
local network_allowed = true
local external = {}

local function write_executable(path, contents)
	assert(vim.fn.mkdir(vim.fs.dirname(path), "p") >= 0)
	assert(vim.fn.writefile({ contents or "#!/bin/sh\nexit 0" }, path, "b") == 0)
	assert(vim.uv.fs_chmod(path, tonumber("755", 8)))
	return path
end

local fake_paths = {
	primary_state_root = function()
		return state
	end,
	managed_root = function()
		return managed
	end,
	mason_root = function()
		return mason
	end,
	external_executable = function(name)
		return external[name] and external[name][1] or nil
	end,
	external_candidates = function(name)
		return vim.deepcopy(external[name] or {})
	end,
	is_managed_path = function(path)
		return path:sub(1, #managed + 1) == managed .. "/"
	end,
	is_mason_path = function(path)
		return path:sub(1, #mason + 1) == mason .. "/"
	end,
	is_verified_shim_path = function()
		return false
	end,
}

local fake_release = {}
function fake_release.plan(name)
	release_plan_count = release_plan_count + 1
	local entry = toolchain.managed_tools[name]
	if not entry then
		return nil, "unknown"
	end
	local asset = entry.assets["darwin-arm64"] or entry.assets["darwin-x86_64"]
	return {
		name = name,
		entry = vim.deepcopy(entry),
		asset = vim.deepcopy(asset),
		target = entry.assets["darwin-arm64"] and "darwin-arm64" or "darwin-x86_64",
		install_root = managed,
		layout = toolchain.release_layout(entry, asset),
		requirements = {},
		url = toolchain.release_url(entry, asset),
	}
end
function fake_release.preflight()
	return true
end
function fake_release.install(plan, callback)
	release_install_count = release_install_count + 1
	local evidence = { kind = "release-install-evidence", archive_sha256 = plan.asset.sha256, artifacts = {} }
	for _, relative in pairs(plan.layout.commands) do
		local path = write_executable(vim.fs.joinpath(managed, relative), "#!/bin/sh\nexit 0")
		evidence.artifacts[relative] = vim.fn.sha256(assert(fs.read_binary(path)))
	end
	for _, relative in ipairs(plan.layout.artifacts) do
		local path = vim.fs.joinpath(managed, relative)
		assert(vim.fn.mkdir(vim.fs.dirname(path), "p") >= 0)
		assert(vim.fn.writefile({ "artifact" }, path, "b") == 0)
		evidence.artifacts[relative] = vim.fn.sha256(assert(fs.read_binary(path)))
	end
	callback(true, evidence)
	return { cancel = function() end }
end

package.loaded["config.tool_paths"] = fake_paths
package.loaded["config.release_installer"] = fake_release
package.loaded["config.npm_release_installer"] = nil
local real_npm_release = require("config.npm_release_installer")
local npm_discovery_count = 0
local npm_install_count = 0
local npm_selected = {
	name = "@devcontainers/cli",
	version = "1.2.3",
	bin = { devcontainer = "devcontainer.js" },
	engines = { node = ">=18.0.0 <25" },
	tarball = "https://registry.npmjs.org/@devcontainers/cli/-/cli-1.2.3.tgz",
	integrity = "sha512-" .. vim.base64.encode(string.rep("a", 64)),
}
local fake_npm_release = {
	plan = real_npm_release.plan,
	validate_metadata = real_npm_release.validate_metadata,
	validate_package = real_npm_release.validate_package,
	preflight = function()
		return true
	end,
	discover = function(_, callback)
		npm_discovery_count = npm_discovery_count + 1
		callback(true, vim.deepcopy(npm_selected))
		return { cancel = function() end }
	end,
	install = function(_, callback)
		npm_install_count = npm_install_count + 1
		callback(false, "fake-npm-install-not-materialized")
		return { cancel = function() end }
	end,
	observe = function()
		return nil, "fake-npm-observation-not-materialized"
	end,
}
package.loaded["config.npm_release_installer"] = fake_npm_release
package.loaded["config.tool_bootstrap"] = nil
local bootstrap = require("config.tool_bootstrap")
bootstrap._notify = function() end
bootstrap._network_authorized = function()
	return network_allowed
end

local fake_package = {}
function fake_package:install(options, callback)
	mason_install_count = mason_install_count + 1
	assert(options.version == toolchain.mason_entry("clangd").version)
	local package_root = mason .. "/packages/clangd"
	local source = write_executable(package_root .. "/clangd", "#!/bin/sh\nexit 0")
	assert(vim.fn.mkdir(mason .. "/bin", "p") >= 0)
	local link = mason .. "/bin/clangd"
	pcall(vim.uv.fs_unlink, link)
	assert(vim.uv.fs_symlink("../packages/clangd/clangd", link))
	assert(vim.fn.writefile({
		vim.json.encode({
			name = "clangd",
			schema_version = "2.0",
			source = { id = "pkg:github/clangd/clangd@" .. toolchain.mason_entry("clangd").version },
			links = { bin = { clangd = "clangd" }, share = {}, opt = {} },
		}),
	}, package_root .. "/mason-receipt.json") == 0)
	assert(vim.fn.executable(source) == 1)
	callback(true)
	return { terminate = function() end }
end
function fake_package:is_installed()
	return mason_install_count > 0
end
function fake_package:get_installed_version()
	mason_version_checks = mason_version_checks + 1
	if mutate_mason_at_check == mason_version_checks then
		local source = mason .. "/packages/clangd/clangd"
		assert(vim.uv.fs_rename(source, source .. ".previous"))
		write_executable(source, "#!/bin/sh\nexit 7")
	end
	return mason_install_count > 0 and toolchain.mason_entry("clangd").version or nil
end

local registry = {}
function registry.refresh(callback)
	registry_refresh_count = registry_refresh_count + 1
	callback(true)
end
function registry.has_package(name)
	return name == "clangd"
end
function registry.get_package(name)
	assert(name == "clangd")
	return fake_package
end
bootstrap._registry = function()
	return registry
end

local legacy_root = state .. "/tool-bootstrap"
assert(vim.fn.mkdir(legacy_root, "p") == 1)
assert(vim.fn.writefile({
	vim.json.encode({
		schema = 1,
		name = "plantuml",
		version = toolchain.managed_tools.plantuml.version,
		identity = "plantuml@1.2026.6",
		status = "succeeded",
		updated_at = os.time(),
		pid = vim.uv.os_getpid(),
	}),
}, legacy_root .. "/plantuml@1.2026.6.json") == 0)

test("setup publishes the manual command without planning", function()
	local verified_tools = require("verified_tools")
	local original_plan = verified_tools.plan
	local original_attest = verified_tools.attest
	verified_tools.plan = function()
		error("setup planned a tool")
	end
	verified_tools.attest = function()
		error("setup attested a tool")
	end
	local before_release_plans = release_plan_count
	local ok, setup_err = pcall(bootstrap.setup)
	verified_tools.plan = original_plan
	verified_tools.attest = original_attest
	assert(ok, setup_err)
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 2)
	assert(bootstrap.setup(), "idempotent setup failed")
	assert(release_plan_count == before_release_plans)
	bootstrap._reset_for_tests()
end)

test("Mason readiness repairs a skipped Lazy init hook without probes or attestation", function()
	local verified_tools = require("verified_tools")
	local original_plan = verified_tools.plan
	local original_attest = verified_tools.attest
	local original_system = bootstrap._system
	local original_registry = bootstrap._registry
	local original_network = bootstrap._network_authorized
	local network_checks = 0
	verified_tools.plan = function()
		error("Mason readiness planned a tool")
	end
	verified_tools.attest = function()
		error("Mason readiness attested a tool")
	end
	bootstrap._system = function()
		error("Mason readiness ran a version probe")
	end
	bootstrap._registry = function()
		error("Mason readiness accessed the registry")
	end
	bootstrap._network_authorized = function()
		network_checks = network_checks + 1
		return true
	end
	local before_release_plans = release_plan_count
	local before_versions = mason_version_checks
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 0)
	local ok, ready_err = pcall(bootstrap.mason_ready)
	verified_tools.plan = original_plan
	verified_tools.attest = original_attest
	bootstrap._system = original_system
	bootstrap._registry = original_registry
	bootstrap._network_authorized = original_network
	assert(ok, ready_err)
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 2)
	assert(network_checks == 0)
	assert(release_plan_count == before_release_plans and mason_version_checks == before_versions)
	bootstrap._reset_for_tests()
end)

test("targeted planning and aggregate planning are explicit", function()
	bootstrap.setup()
	local verified_tools = require("verified_tools")
	local original_plan = verified_tools.plan
	local planned = {}
	verified_tools.plan = function(spec)
		planned[#planned + 1] = spec.identity.name
		return original_plan(spec)
	end
	local targeted = assert(bootstrap.plan("mmdflux"))
	assert(targeted.identity.name == "mmdflux")
	assert(vim.deep_equal(planned, { "mmdflux" }), "targeted plan expanded to the catalog")
	local plans = bootstrap.plan_all()
	verified_tools.plan = original_plan
	assert(plans.mmdflux and plans.clangd)
	assert(#planned > 1, "explicit plan_all did not enumerate the catalog")
	assert(release_install_count == 0 and registry_refresh_count == 0 and mason_install_count == 0)
	bootstrap.mason_ready()
	assert(release_install_count == 0 and registry_refresh_count == 0 and mason_install_count == 0)
	assert(not bootstrap.install(nil), "install accepted an implicit target")
	assert(bootstrap.import_legacy("plantuml"))
	local migrated = assert(bootstrap.engine().status(assert(bootstrap.spec("plantuml")).identity))
	assert(migrated.status == "repair-required")
	assert(not bootstrap.import_legacy("unknown-tool"), "legacy import accepted an unknown target")
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 2)
end)

test("dynamic latest discovery is explicit and runtime resolution uses only the active slot", function()
	local before = npm_discovery_count
	local unversioned, unversioned_err = bootstrap.plan("devcontainers-cli")
	assert(unversioned == nil and unversioned_err == "dynamic-version-requires-explicit-install")
	assert(npm_discovery_count == before, "planning performed latest discovery")
	local engine = bootstrap.engine()
	local original_resolve_active = engine.resolve_active
	local original_spec = bootstrap.spec
	local original_network = bootstrap._network_authorized
	engine.resolve_active = function(slot)
		assert(slot == "devcontainers-cli")
		return {
			identity = { backend = "npm-release", name = slot, version = "1.2.3" },
			commands = { devcontainer = fixture .. "/active/devcontainer" },
		}
	end
	bootstrap.spec = function()
		error("runtime resolution planned an unversioned dynamic spec")
	end
	bootstrap._network_authorized = function()
		error("runtime resolution consulted network policy")
	end
	local ok, resolved = xpcall(function()
		return bootstrap.resolve("devcontainers-cli", "devcontainer")
	end, debug.traceback)
	engine.resolve_active = original_resolve_active
	bootstrap.spec = original_spec
	bootstrap._network_authorized = original_network
	assert(ok, resolved)
	assert(resolved == fixture .. "/active/devcontainer")
	assert(npm_discovery_count == before, "runtime resolution performed latest discovery")
end)

test("dynamic install blocks offline before discovery claim and attempt", function()
	local before = npm_discovery_count
	local engine = bootstrap.engine()
	local original_claim = engine.claim
	local claims = 0
	engine.claim = function(...)
		claims = claims + 1
		return original_claim(...)
	end
	network_allowed = false
	local accepted = bootstrap.install("devcontainers-cli")
	network_allowed = true
	engine.claim = original_claim
	assert(accepted == false)
	assert(npm_discovery_count == before and claims == 0)
end)

test("explicit dynamic install discovers once and activates only after engine success", function()
	local engine = bootstrap.engine()
	local original_plan = bootstrap.plan
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	local original_activate = engine.activate
	local sequence = {}
	bootstrap.plan = function(name, options)
		assert(name == "devcontainers-cli" and vim.deep_equal(options.selected, npm_selected))
		sequence[#sequence + 1] = "plan"
		return {
			strategy = "managed",
			identity = { backend = "npm-release", name = name, version = npm_selected.version },
			manifest = { npm_release_plan = {} },
			executables = { devcontainer = "devcontainer" },
		}
	end
	engine.status = function()
		return nil
	end
	engine.claim = function(plan)
		sequence[#sequence + 1] = "claim"
		return plan
	end
	engine.run = function(_, callback)
		sequence[#sequence + 1] = "run"
		callback(true)
		return true
	end
	engine.activate = function(slot, identity)
		assert(slot == "devcontainers-cli" and identity.version == npm_selected.version)
		sequence[#sequence + 1] = "activate"
		return { slot = slot }
	end
	local before = npm_discovery_count
	local ok, err = xpcall(function()
		assert(bootstrap.install("devcontainers-cli"))
	end, debug.traceback)
	bootstrap.plan = original_plan
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	engine.activate = original_activate
	assert(ok, err)
	assert(npm_discovery_count == before + 1)
	assert(vim.deep_equal(sequence, { "plan", "claim", "run", "activate" }), vim.inspect(sequence))
end)

test("throwing dynamic activation always settles install and re-attestation chains", function()
	local engine = bootstrap.engine()
	local original_plan = bootstrap.plan
	local original_status = engine.status
	local original_resolve = engine.resolve
	local original_attest = engine.attest
	local original_claim = engine.claim
	local original_run = engine.run
	local original_activate = engine.activate
	local original_notify = bootstrap._notify
	local succeeded = false
	local activations = 0
	local notices = {}
	bootstrap.plan = function(name, options)
		assert(name == "devcontainers-cli" and vim.deep_equal(options.selected, npm_selected))
		return {
			strategy = "managed",
			identity = { backend = "npm-release", name = name, version = npm_selected.version },
			manifest = { npm_release_plan = {} },
			executables = { devcontainer = "devcontainer" },
		}
	end
	engine.status = function()
		return succeeded and { status = "succeeded" } or nil
	end
	engine.resolve = function()
		return { devcontainer = fixture .. "/active/devcontainer" }
	end
	engine.attest = function(_, callback)
		callback(true)
		return true
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(_, callback)
		callback(true)
		return true
	end
	engine.activate = function()
		activations = activations + 1
		error("injected activation failure")
	end
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	local ok, err = xpcall(function()
		assert(not bootstrap.install("devcontainers-cli"), "install activation failure reported acceptance")
		assert(not bootstrap.busy(), "throwing install activation stranded host busy state")
		succeeded = true
		assert(not bootstrap.install("devcontainers-cli"), "re-attestation activation failure reported acceptance")
		assert(not bootstrap.busy(), "throwing re-attestation activation stranded host busy state")
		assert(activations == 2)
		assert(#notices == 4, vim.inspect(notices))
		for _, index in ipairs({ 1, 3 }) do
			assert(notices[index]:find("activation raised an error", 1, true), vim.inspect(notices))
			assert(not notices[index]:find(": nil", 1, true), vim.inspect(notices))
		end
		for _, index in ipairs({ 2, 4 }) do
			assert(notices[index]:find("0 succeeded, 1 failed (1 total)", 1, true), vim.inspect(notices))
			assert(notices[index]:find("Failed tools: devcontainers-cli", 1, true), vim.inspect(notices))
		end
	end, debug.traceback)
	bootstrap.plan = original_plan
	engine.status = original_status
	engine.resolve = original_resolve
	engine.attest = original_attest
	engine.claim = original_claim
	engine.run = original_run
	engine.activate = original_activate
	bootstrap._notify = original_notify
	assert(ok, err)
end)

test("busy includes asynchronous latest discovery before any engine claim", function()
	local original_discover = fake_npm_release.discover
	local original_plan = bootstrap.plan
	local pending
	fake_npm_release.discover = function(_, callback)
		pending = callback
		return { cancel = function() end }
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("devcontainers-cli"))
		assert(type(pending) == "function", "latest discovery did not remain pending")
		assert(bootstrap.busy() and bootstrap.mason_busy(), "host queue ignored pending discovery")
		pending(false, "injected-discovery-failure")
		assert(not bootstrap.busy() and not bootstrap.mason_busy(), "failed discovery stranded host busy state")
		bootstrap.plan = function()
			error("injected continuation failure")
		end
		assert(bootstrap.install("devcontainers-cli"))
		assert(bootstrap.busy(), "second pending discovery was not tracked")
		pending(true, vim.deepcopy(npm_selected))
		assert(not bootstrap.busy(), "throwing discovery continuation stranded host busy state")
	end, debug.traceback)
	fake_npm_release.discover = original_discover
	bootstrap.plan = original_plan
	assert(ok, err)
end)

test("direct installs share the bounded grouped scheduler", function()
	local original_plan = bootstrap.plan
	local original_import = bootstrap.import_legacy
	local engine = bootstrap.engine()
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	local pending_imports = {}
	local pending_runs = {}
	local active = 0
	local maximum = 0
	local active_groups = {}
	local started = {}
	local finished = 0
	local function group_for(name)
		return toolchain.managed_tools[name] and "release" or "mason"
	end
	bootstrap.plan = function(name)
		local group = group_for(name)
		active = active + 1
		active_groups[group] = (active_groups[group] or 0) + 1
		maximum = math.max(maximum, active)
		assert(active <= 2, "direct install bypassed the global chain bound")
		assert(active_groups[group] == 1, "direct installs sharing a root overlapped")
		started[#started + 1] = name
		return {
			strategy = "managed",
			identity = { backend = "release", name = name },
			manifest = { release_plan = {} },
		}
	end
	bootstrap.import_legacy = function(name, callback)
		pending_imports[#pending_imports + 1] = { name = name, callback = callback }
		return true, nil, true
	end
	engine.status = function()
		return { status = "failed" }
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(plan, callback)
		pending_runs[#pending_runs + 1] = { name = plan.identity.name, callback = callback }
		return true
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("mmdflux", true))
		assert(bootstrap.install("plantuml", true))
		assert(bootstrap.install("clangd", true))
		assert(bootstrap.install("marksman", true))
		assert(vim.deep_equal(started, { "mmdflux", "clangd" }), vim.inspect(started))
		assert(bootstrap.busy(), "queued direct installs were not reported busy")
		while #pending_imports > 0 or #pending_runs > 0 do
			if #pending_imports > 0 then
				table.remove(pending_imports, 1).callback(false, "legacy-repair-required")
			end
			if #pending_runs > 0 then
				local item = table.remove(pending_runs, 1)
				local group = group_for(item.name)
				active = active - 1
				active_groups[group] = active_groups[group] - 1
				finished = finished + 1
				item.callback(true)
			end
		end
		assert(finished == 4 and active == 0 and maximum == 2)
		assert(vim.deep_equal(started, { "mmdflux", "clangd", "plantuml", "marksman" }), vim.inspect(started))
		assert(not bootstrap.busy(), "completed direct installs stranded host busy state")
	end, debug.traceback)
	bootstrap.plan = original_plan
	bootstrap.import_legacy = original_import
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	assert(ok, err)
end)

test("dynamic discovery through activation shares the two-chain scheduler without leaks", function()
	local original_managed_order = toolchain.managed_order
	local original_dynamic_order = toolchain.dynamic_order
	local original_mason_order = toolchain.mason_order
	local original_discover = fake_npm_release.discover
	local original_plan = bootstrap.plan
	local original_import = bootstrap.import_legacy
	local original_notify = bootstrap._notify
	local engine = bootstrap.engine()
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	local original_activate = engine.activate
	toolchain.managed_order = {}
	toolchain.dynamic_order = { "devcontainers-cli" }
	toolchain.mason_order = { "clangd", "marksman", "lemminx" }
	local active = {}
	local active_count = 0
	local maximum = 0
	local discoveries = {}
	local runs = {}
	local started = {}
	local activated = 0
	local finished = 0
	local notices = {}
	local function begin(name)
		assert(not active[name], name .. " began twice")
		active[name] = true
		active_count = active_count + 1
		maximum = math.max(maximum, active_count)
		assert(active_count <= 2, "more than two complete tool chains were active")
		started[#started + 1] = name
	end
	local function complete(name)
		assert(active[name], name .. " completed without an active chain")
		active[name] = nil
		active_count = active_count - 1
		finished = finished + 1
	end
	fake_npm_release.discover = function(_, callback)
		begin("devcontainers-cli")
		discoveries[#discoveries + 1] = callback
		return { cancel = function() end }
	end
	bootstrap.plan = function(name, options)
		if name == "devcontainers-cli" then
			assert(active[name], "dynamic plan did not remain in its discovery chain")
			assert(options.force_managed and vim.deep_equal(options.selected, npm_selected))
			return {
				strategy = "managed",
				identity = { backend = "npm-release", name = name, version = npm_selected.version },
				manifest = { npm_release_plan = {} },
				executables = { devcontainer = "devcontainer" },
			}
		end
		begin(name)
		return {
			strategy = "managed",
			identity = { backend = "mason", name = name },
			manifest = { entry = {} },
		}
	end
	bootstrap.import_legacy = function(_, callback)
		callback(false, "legacy-repair-required")
		return true, nil, true
	end
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	engine.status = function()
		return { status = "failed" }
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(plan, callback)
		runs[plan.identity.name] = callback
		return true
	end
	engine.activate = function(slot, identity)
		assert(slot == "devcontainers-cli" and identity.name == slot)
		assert(active[slot], "dynamic activation ran outside its complete chain")
		activated = activated + 1
		complete(slot)
		return { slot = slot }
	end
	local ok, err = xpcall(function()
		assert(not bootstrap.busy(), "test began with a busy host queue")
		assert(bootstrap.install("all", true))
		assert(#discoveries == 1 and runs.clangd and active_count == 2)
		assert(vim.deep_equal(started, { "devcontainers-cli", "clangd" }), vim.inspect(started))
		assert(bootstrap.busy(), "pending discovery/backend work was not reported busy")

		complete("clangd")
		runs.clangd(true)
		assert(runs.marksman and active_count == 2, "next Mason chain did not start at the completion boundary")

		table.remove(discoveries, 1)(true, vim.deepcopy(npm_selected))
		assert(runs["devcontainers-cli"] and active_count == 2, "dynamic discovery did not continue into its backend")

		complete("marksman")
		runs.marksman(true)
		assert(runs.lemminx and active_count == 2)

		runs["devcontainers-cli"](true)
		assert(activated == 1 and active_count == 1, "dynamic activation did not settle exactly once")
		complete("lemminx")
		runs.lemminx(true)

		assert(finished == 4 and active_count == 0 and maximum == 2)
		assert(vim.deep_equal(started, { "devcontainers-cli", "clangd", "marksman", "lemminx" }), vim.inspect(started))
		assert(not bootstrap.busy() and not bootstrap.mason_busy(), "completed dynamic batch leaked host busy state")
		assert(
			vim.iter(notices):all(function(message)
				return not message:find(": nil", 1, true)
			end),
			vim.inspect(notices)
		)
	end, debug.traceback)
	toolchain.managed_order = original_managed_order
	toolchain.dynamic_order = original_dynamic_order
	toolchain.mason_order = original_mason_order
	fake_npm_release.discover = original_discover
	bootstrap.plan = original_plan
	bootstrap.import_legacy = original_import
	bootstrap._notify = original_notify
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	engine.activate = original_activate
	bootstrap._reset_for_tests()
	assert(ok, err)
end)

test("release and Mason specs expose exact executable and integrity maps", function()
	local release_spec = assert(bootstrap.spec("mmdflux"))
	assert(vim.deep_equal(release_spec.executables, { mmdflux = "mmdflux" }))
	assert(release_spec.manifest.integrity.kind == "release-sha256")
	assert(release_spec.manifest.integrity.commands.mmdflux == "bin/mmdflux")
	local mason_spec = assert(bootstrap.spec("ty"))
	assert(vim.deep_equal(mason_spec.executables, { ty = "ty" }))
	assert(mason_spec.identity.version == "0.0.77")
	assert(mason_spec.manifest.integrity.receipt_path == ".verified-tools/receipts/ty.json")
	assert(mason_spec.manifest.integrity.commands.ty == "bin/ty")
end)

test("manual release and Mason installs produce persisted proofs", function()
	assert(bootstrap.install("mmdflux", false))
	assert(release_install_count == 1)
	local refreshes_before = registry_refresh_count
	local installs_before = mason_install_count
	assert(bootstrap.install("clangd", false))
	assert(
		registry_refresh_count == refreshes_before + 1 and mason_install_count == installs_before,
		"synchronous Mason refresh callback was not deferred"
	)
	local release_record = assert(bootstrap.engine().status(assert(bootstrap.spec("mmdflux")).identity))
	assert(release_record.status == "succeeded" and release_record.proof.kind == "release-sha256")
	local mason_identity = assert(bootstrap.spec("clangd")).identity
	assert(
		vim.wait(3000, function()
			local record = bootstrap.engine().status(mason_identity)
			return record and record.status == "succeeded"
		end, 10),
		"deferred Mason install did not settle"
	)
	assert(mason_install_count == installs_before + 1)
	local mason_record = assert(bootstrap.engine().status(mason_identity))
	assert(mason_record.status == "succeeded" and mason_record.proof.kind == "mason-local-integrity")
	local private = mason .. "/.verified-tools/receipts/clangd.json"
	assert(vim.uv.fs_lstat(private).mode % 512 == tonumber("600", 8))
end)

test("successful notifications never append a nil reason", function()
	local original_notify = bootstrap._notify
	local notices = {}
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("mmdflux", true))
	end, debug.traceback)
	bootstrap._notify = original_notify
	assert(ok, err)
	assert(#notices == 2 and notices[1] == "Attested mmdflux", vim.inspect(notices))
	assert(notices[2] == "Tool install request complete: 1 succeeded, 0 failed (1 total)", vim.inspect(notices))
	assert(not notices[1]:find(": nil", 1, true))
end)

test("tool result notifications use exact success and failure grammar", function()
	local original_notify = bootstrap._notify
	local notices = {}
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	local ok, err = xpcall(function()
		for _, action in ipairs({ "install", "repair", "attest" }) do
			bootstrap._report(action, "example", true)
			bootstrap._report(action, "example", false, "reason")
		end
	end, debug.traceback)
	bootstrap._notify = original_notify
	assert(ok, err)
	assert(
		vim.deep_equal(notices, {
			"Installed example",
			"Failed to install example: reason",
			"Repaired example",
			"Failed to repair example: reason",
			"Attested example",
			"Failed to attest example: reason",
		}),
		vim.inspect(notices)
	)
end)

test("runtime resolution uses only durable authority and performs no probes", function()
	local verified_tools = require("verified_tools")
	local original_plan = verified_tools.plan
	local original_system = bootstrap._system
	local original_registry = bootstrap._registry
	local original_release_plan = fake_release.plan
	local original_external_candidates = fake_paths.external_candidates
	local original_external_executable = fake_paths.external_executable
	local installs_before =
		{ release = release_install_count, mason = mason_install_count, refresh = registry_refresh_count }
	local external_clangd = write_executable(host .. "/runtime-path/clangd")
	external.clangd = { external_clangd }
	local ok, err = xpcall(function()
		verified_tools.plan = function()
			error("runtime resolution planned a tool")
		end
		bootstrap._system = function()
			error("runtime resolution ran an external process")
		end
		bootstrap._registry = function()
			error("runtime resolution accessed the Mason registry")
		end
		fake_release.plan = function()
			error("runtime resolution built an install plan")
		end
		fake_paths.external_candidates = function()
			error("runtime resolution inspected PATH candidates")
		end
		fake_paths.external_executable = function()
			error("runtime resolution inspected PATH")
		end
		local clangd = assert(bootstrap.resolve("clangd", "clangd"))
		assert(clangd == assert(vim.uv.fs_realpath(mason .. "/packages/clangd/clangd")))
		local mmdflux = assert(bootstrap.resolve("mmdflux", "mmdflux"))
		assert(mmdflux == assert(vim.uv.fs_realpath(managed .. "/bin/mmdflux")))
		local missing, missing_err = bootstrap.resolve("clangd", "not-a-command")
		assert(not missing and missing_err:find("does not provide", 1, true))
		local absent, absent_err = bootstrap.resolve("marksman", "marksman")
		assert(not absent and absent_err:find(":NvimConfigToolsInstall marksman", 1, true))
		assert(absent_err:find("use ! to force managed", 1, true))
		assert(not bootstrap.resolve("", "clangd"), "empty tool name was accepted")
		assert(not bootstrap.resolve("clangd", ""), "empty command name was accepted")
	end, debug.traceback)
	verified_tools.plan = original_plan
	bootstrap._system = original_system
	bootstrap._registry = original_registry
	fake_release.plan = original_release_plan
	fake_paths.external_candidates = original_external_candidates
	fake_paths.external_executable = original_external_executable
	external.clangd = nil
	assert(ok, err)
	assert(
		vim.deep_equal(installs_before, {
			release = release_install_count,
			mason = mason_install_count,
			refresh = registry_refresh_count,
		}),
		"runtime resolution installed, repaired, or refreshed a tool"
	)
end)

test("compatible external tools are explicitly certified and recertified without runtime probes", function()
	local spec = assert(bootstrap.spec("lemminx"))
	local external_lemminx = write_executable(host .. "/external/lemminx")
	external.lemminx = { external_lemminx }
	local original_system = bootstrap._system
	local original_notify = bootstrap._notify
	local notices = {}
	local probe_calls = 0
	bootstrap._system = function()
		probe_calls = probe_calls + 1
		return {
			wait = function()
				return { code = 0, stdout = "lemminx " .. spec.identity.version, stderr = "" }
			end,
		}
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("lemminx", false))
		assert(probe_calls == 1)
		assert(bootstrap.engine().status(spec.identity) == nil, "external certification created managed state")
		local probes_before_resolve = probe_calls
		local resolved = assert(bootstrap.resolve("lemminx", "lemminx"))
		assert(resolved == assert(vim.uv.fs_realpath(external_lemminx)))
		assert(probe_calls == probes_before_resolve, "external runtime resolution probed again")

		write_executable(external_lemminx, "#!/bin/sh\nexit 9")
		local drifted, drift_err = bootstrap.resolve("lemminx", "lemminx")
		assert(not drifted and tostring(drift_err):find("rerun :NvimConfigToolsInstall lemminx", 1, true))
		assert(bootstrap.install("lemminx", false), "explicit recertification failed")
		assert(probe_calls == probes_before_resolve + 1)
		assert(bootstrap.resolve("lemminx", "lemminx") == vim.uv.fs_realpath(external_lemminx))

		local identity = spec.identity
		local identity_key = vim.fn.sha256(vim.json.encode({
			identity.backend,
			identity.name,
			identity.version,
			identity.target,
			identity.digest,
			identity.install_root,
		}))
		local receipt = state .. "/verified-tools/external-records/" .. identity_key .. ".json"
		assert(vim.uv.fs_chmod(receipt, tonumber("644", 8)))
		local unsafe, unsafe_err = bootstrap.resolve("lemminx", "lemminx")
		assert(not unsafe and tostring(unsafe_err):find("will not be overwritten", 1, true))
		assert(tostring(unsafe_err):find(":NvimConfigToolsInstall! lemminx", 1, true))
		bootstrap._notify = function(message)
			notices[#notices + 1] = tostring(message)
		end
		assert(not bootstrap.install("lemminx", false), "unsafe external receipt was silently replaced")
		assert(#notices == 2 and notices[1]:find("will not be overwritten", 1, true))
		assert(notices[1]:find(":NvimConfigToolsInstall! lemminx", 1, true))
		assert(notices[2]:find("0 succeeded, 1 failed (1 total)", 1, true))
		assert(notices[2]:find("Failed tools: lemminx", 1, true))
		assert(vim.uv.fs_lstat(receipt).mode % 512 == tonumber("644", 8))
		assert(vim.uv.fs_chmod(receipt, tonumber("600", 8)))
	end, debug.traceback)
	bootstrap._system = original_system
	bootstrap._notify = original_notify
	external.lemminx = nil
	assert(ok, err)
end)

test("Mason state changing between validation and proof is rejected", function()
	local spec = assert(bootstrap.spec("clangd"))
	local plan = assert(bootstrap.engine().plan(spec))
	mutate_mason_at_check = mason_version_checks + 2
	local observation, reason = bootstrap._mason_observation(plan, false)
	mutate_mason_at_check = nil
	assert(observation == nil and reason == "mason-state-changed")
	local source = mason .. "/packages/clangd/clangd"
	assert(vim.uv.fs_unlink(source))
	assert(vim.uv.fs_rename(source .. ".previous", source))
end)

test("private receipt permission changes during a read fail closed", function()
	local spec = assert(bootstrap.spec("clangd"))
	local plan = assert(bootstrap.engine().plan(spec))
	local private = mason .. "/.verified-tools/receipts/clangd.json"
	local original_read = vim.uv.fs_read
	local reads = 0
	vim.uv.fs_read = function(...)
		reads = reads + 1
		local data, err = original_read(...)
		if reads == 2 then
			assert(vim.uv.fs_chmod(private, tonumber("644", 8)))
		end
		return data, err
	end
	local ok, observation, reason = xpcall(function()
		local value, failure = bootstrap._mason_observation(plan, false)
		return value, failure
	end, debug.traceback)
	vim.uv.fs_read = original_read
	assert(vim.uv.fs_chmod(private, tonumber("600", 8)))
	assert(ok, observation)
	assert(observation == nil and tostring(reason):find("private%-receipt%-invalid"))
end)

test("Mason receipt tamper becomes drift without registry refresh", function()
	local private = mason .. "/.verified-tools/receipts/clangd.json"
	assert(
		vim.fn.writefile(
			{ vim.json.encode({ package = "clangd", version = "wrong", source_version = "wrong" }) },
			private
		) == 0
	)
	assert(vim.uv.fs_chmod(private, tonumber("600", 8)))
	local identity = assert(bootstrap.spec("clangd")).identity
	local attested
	assert(bootstrap.engine().attest(identity, function(ok)
		attested = ok
	end))
	assert(attested == false)
	assert(bootstrap.engine().status(identity).status == "drift")
	assert(registry_refresh_count == 1, "local attestation refreshed the Mason registry")
end)

test("markdown-preview is managed-only and bang keeps managed authority", function()
	local external_markdown = write_executable(host .. "/markdown-preview")
	external["markdown-preview"] = { external_markdown }
	local probe_calls = 0
	bootstrap._system = function()
		probe_calls = probe_calls + 1
		return {
			wait = function()
				return { code = 0, stdout = "markdown-preview 0.0.10", stderr = "" }
			end,
		}
	end
	local before = release_install_count
	assert(bootstrap.install("markdown-preview", false))
	assert(release_install_count == before + 1)
	assert(bootstrap.engine().status(assert(bootstrap.spec("markdown-preview")).identity).status == "succeeded")
	assert(probe_calls == 0, "managed-only markdown-preview probed an external executable")
	assert(bootstrap.install("markdown-preview", true))
	assert(release_install_count == before + 1)
	local probes_before_resolve = probe_calls
	local resolved = assert(bootstrap.resolve("markdown-preview", "markdown-preview"))
	assert(resolved == assert(vim.uv.fs_realpath(managed .. "/bin/markdown-preview")))
	assert(resolved ~= vim.uv.fs_realpath(external_markdown))
	assert(probe_calls == probes_before_resolve, "runtime resolution probed the compatible external executable")
	external["markdown-preview"] = nil

	local ty = assert(bootstrap.spec("ty", { force_managed = true }))
	assert(not bootstrap.install("ty", true))
	assert(bootstrap.engine().status(ty.identity) == nil, "missing prerequisites consumed an attempt")
end)

test("strict probes inspect every candidate and reject errors", function()
	local first = write_executable(host .. "/one/probe")
	local second = write_executable(host .. "/two/probe")
	external.probe = { first, second }
	local calls = {}
	bootstrap._system = function(argv)
		calls[#calls + 1] = argv[1]
		return {
			wait = function()
				return { code = 0, stdout = argv[1] == second and "probe 1.2.3" or "probe 1.2.30", stderr = "" }
			end,
		}
	end
	local observed = bootstrap._external_probe({ version = "1.2.3" }, { executables = { probe = "probe" } })
	assert(observed.outcome == "incompatible" and #calls == 2)
	bootstrap._system = function(argv)
		return {
			wait = function()
				return { code = 0, stdout = "probe 1.2.3", stderr = "" }
			end,
		}
	end
	observed = bootstrap._external_probe({ version = "1.2.3" }, { executables = { probe = "probe" } })
	assert(observed.outcome == "compatible" and observed.paths.probe == first)
	bootstrap._system = function()
		return {
			wait = function()
				return { code = 124, stdout = "", stderr = "" }
			end,
		}
	end
	observed = bootstrap._external_probe({ version = "1.2.3" }, { executables = { probe = "probe" } })
	assert(observed.outcome == "error" and observed.detail:find("timeout", 1, true))

	local companion = write_executable(host .. "/two/probe-helper")
	external["probe-helper"] = { companion }
	bootstrap._system = function()
		return {
			wait = function()
				return { code = 0, stdout = "probe 1.2.3", stderr = "" }
			end,
		}
	end
	observed = bootstrap._external_probe(
		{ version = "1.2.3" },
		{ executables = { probe = "probe", ["probe-helper"] = "probe-helper" } }
	)
	assert(observed.outcome == "incompatible" and observed.detail:find("different%-install%-root"))
	external.probe = nil
	external["probe-helper"] = nil
end)

test("an unsafe external candidate is rejected before any version process runs", function()
	local safe = write_executable(host .. "/preflight-safe/probe")
	local unsafe_root = host .. "/preflight-unsafe"
	local unsafe = write_executable(unsafe_root .. "/probe")
	assert(vim.uv.fs_chmod(unsafe_root, tonumber("777", 8)))
	external.probe = { safe, unsafe }
	local original_system = bootstrap._system
	local process_count = 0
	bootstrap._system = function()
		process_count = process_count + 1
		error("unsafe candidate preflight started a process")
	end
	local ok, observed = xpcall(function()
		return bootstrap._external_probe({ version = "1.2.3" }, { executables = { probe = "probe" } })
	end, debug.traceback)
	bootstrap._system = original_system
	external.probe = nil
	assert(vim.uv.fs_chmod(unsafe_root, tonumber("700", 8)))
	assert(ok, observed)
	assert(observed.outcome == "incompatible" and observed.detail:find("unsafe", 1, true))
	assert(process_count == 0, "a version process ran before every candidate passed authority validation")
end)

test("external probes execute the validated canonical path across a lexical symlink swap", function()
	local canonical = write_executable(host .. "/canonical-probe/probe")
	local rival = write_executable(host .. "/rival-probe/probe")
	local lexical = host .. "/probe-link"
	assert(vim.uv.fs_symlink(canonical, lexical))
	external.probe = { lexical }
	local engine = bootstrap.engine()
	local original_validate = engine.validate_external_candidate
	local original_system = bootstrap._system
	local validations = 0
	local executed
	engine.validate_external_candidate = function(path)
		if path == lexical then
			validations = validations + 1
			if validations == 2 then
				assert(vim.uv.fs_unlink(lexical))
				assert(vim.uv.fs_symlink(rival, lexical))
			end
			return canonical
		end
		return original_validate(path)
	end
	bootstrap._system = function(argv)
		executed = argv[1]
		return {
			wait = function()
				return { code = 0, stdout = "probe 1.2.3", stderr = "" }
			end,
		}
	end
	local ok, observed = xpcall(function()
		return bootstrap._external_probe({ version = "1.2.3" }, { executables = { probe = "probe" } })
	end, debug.traceback)
	engine.validate_external_candidate = original_validate
	bootstrap._system = original_system
	external.probe = nil
	assert(ok, observed)
	assert(validations == 2, "probe candidate was not revalidated at the execution boundary")
	assert(executed == canonical, "probe executed the mutable lexical candidate")
	assert(observed.outcome == "compatible" and observed.paths.probe == canonical)
	assert(vim.uv.fs_realpath(lexical) == rival, "race injection did not replace the lexical candidate")
	assert(vim.uv.fs_unlink(lexical))
end)

test("offline denial consumes no attempt", function()
	network_allowed = false
	local spec = assert(bootstrap.spec("marksman", { force_managed = true }))
	local plan = assert(bootstrap.engine().plan(spec))
	local claim, reason = bootstrap.engine().claim(plan)
	assert(claim == nil and reason == "blocked/offline")
	assert(bootstrap.engine().status(plan.identity) == nil)
	network_allowed = true
end)

test("provision inventory stays offline and preserves unclaimed tools", function()
	local release_before = release_install_count
	local refresh_before = registry_refresh_count
	local mason_before = mason_install_count
	local untouched = assert(bootstrap.spec("marksman", { force_managed = true })).identity
	assert(bootstrap.engine().status(untouched) == nil)
	local ok, inventory, changed = bootstrap.provision_exact({ allow_network = false, timeout = 1000 })
	assert(not ok and changed == false)
	assert(type(inventory.managed_tools["markdown-preview"]) == "table")
	assert(#inventory.mason.required == #toolchain.mason_order)
	assert(release_install_count == release_before)
	assert(registry_refresh_count == refresh_before and mason_install_count == mason_before)
	assert(bootstrap.engine().status(untouched) == nil, "offline inventory consumed a one-shot attempt")
end)

test("Mason identity covers immutable manifest fields", function()
	local entry = assert(toolchain.mason_entry("clangd"))
	local original_manager = entry.manager
	local before = assert(bootstrap.spec("clangd")).identity.digest
	entry.manager = original_manager .. "-changed"
	local after = assert(bootstrap.spec("clangd")).identity.digest
	entry.manager = original_manager
	assert(before ~= after, "Mason manager drift reused the prior ToolIdentity")
	assert(assert(bootstrap.spec("clangd")).identity.digest == before, "Mason identity encoding is unstable")
end)

test("install repairs a succeeded record when the current manifest no longer matches", function()
	local entry = assert(toolchain.managed_tools.mmdflux)
	local original_repository = entry.repository
	local before = release_install_count
	entry.repository = original_repository .. "-changed"
	local ok, err = xpcall(function()
		assert(bootstrap.install("mmdflux", true))
		assert(release_install_count == before + 1, "stale succeeded plan was merely re-attested")
		local record = assert(bootstrap.engine().status(assert(bootstrap.spec("mmdflux")).identity))
		assert(record.status == "succeeded")
		assert(record.plan.manifest.entry.repository == entry.repository)
	end, debug.traceback)
	entry.repository = original_repository
	assert(ok, err)
end)

test("an explicit install locally attests valid raw Mason Marksman state", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/raw-marksman-managed"
	mason = fixture .. "/raw-marksman-mason"
	state = fixture .. "/raw-marksman-state"
	for _, directory in ipairs({ managed, mason, state }) do
		assert(vim.fn.mkdir(directory, "p") == 1)
	end
	local entry = assert(toolchain.mason_entry("marksman"))
	local package_root = mason .. "/packages/marksman"
	write_executable(package_root .. "/marksman-macos")
	assert(vim.fn.mkdir(mason .. "/bin", "p") >= 0)
	assert(vim.uv.fs_symlink("../packages/marksman/marksman-macos", mason .. "/bin/marksman"))
	assert(vim.fn.writefile({
		vim.json.encode({
			name = "marksman",
			schema_version = "2.0",
			source = { id = "pkg:github/artempyanykh/marksman@" .. entry.version },
			links = { bin = { marksman = "marksman-macos" }, share = {}, opt = {} },
		}),
	}, package_root .. "/mason-receipt.json") == 0)
	local refreshes = 0
	local installs = 0
	local package = {
		is_installed = function()
			return true
		end,
		get_installed_version = function()
			return entry.version
		end,
		install = function()
			installs = installs + 1
			error("valid raw Marksman state reached network installation")
		end,
	}
	local original_registry = bootstrap._registry
	bootstrap._registry = function()
		return {
			refresh = function()
				refreshes = refreshes + 1
				error("valid raw Marksman state refreshed the registry")
			end,
			has_package = function(name)
				return name == "marksman"
			end,
			get_package = function(name)
				assert(name == "marksman")
				return package
			end,
		}
	end
	local ok, err = xpcall(function()
		local spec = assert(bootstrap.spec("marksman", { force_managed = true }))
		local projected = assert(bootstrap.engine().import_legacy(spec, {
			status = "succeeded",
			origin = "unverified-old-Mason-state",
		}))
		assert(projected.status == "repair-required")
		assert(bootstrap.install("marksman", false))
		local record = assert(bootstrap.engine().status(spec.identity))
		assert(
			record.status == "succeeded" and record.proof and record.proof.kind == "mason-local-integrity",
			vim.inspect(record)
		)
		local receipt = mason .. "/.verified-tools/receipts/marksman.json"
		assert(vim.uv.fs_lstat(receipt).mode % 512 == tonumber("600", 8))
		assert(bootstrap.resolve("marksman", "marksman") == vim.uv.fs_realpath(package_root .. "/marksman-macos"))
		assert(refreshes == 0 and installs == 0)
	end, debug.traceback)
	bootstrap._registry = original_registry
	assert(ok, err)
end)

test("a consumed raw Mason adoption continues through one explicit repair", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/consumed-raw-managed"
	mason = fixture .. "/consumed-raw-mason"
	state = fixture .. "/consumed-raw-state"
	for _, directory in ipairs({ managed, mason, state }) do
		assert(vim.fn.mkdir(directory, "p") == 1)
	end
	local entry = assert(toolchain.mason_entry("marksman"))
	local package_root = mason .. "/packages/marksman"
	write_executable(package_root .. "/marksman-macos")
	assert(vim.fn.mkdir(mason .. "/bin", "p") >= 0)
	assert(vim.uv.fs_symlink("../packages/marksman/marksman-macos", mason .. "/bin/marksman"))
	assert(vim.fn.writefile({
		vim.json.encode({
			name = "marksman",
			schema_version = "2.0",
			source = { id = "pkg:github/artempyanykh/marksman@" .. entry.version },
			links = { bin = { marksman = "marksman-macos" }, share = {}, opt = {} },
		}),
	}, package_root .. "/mason-receipt.json") == 0)
	local refreshes = 0
	local installs = 0
	local package = {
		is_installed = function()
			return true
		end,
		get_installed_version = function()
			return entry.version
		end,
		install = function(_, options, callback)
			installs = installs + 1
			assert(options.version == entry.version and options.force == true)
			callback(true)
			return { terminate = function() end }
		end,
	}
	local original_registry = bootstrap._registry
	local original_notify = bootstrap._notify
	local notices = {}
	bootstrap._registry = function()
		return {
			refresh = function(callback)
				refreshes = refreshes + 1
				callback(true)
			end,
			has_package = function(name)
				return name == "marksman"
			end,
			get_package = function(name)
				assert(name == "marksman")
				return package
			end,
		}
	end
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	local engine = bootstrap.engine()
	local original_import = engine.import_legacy
	local original_claim = engine.claim
	local original_run = engine.run
	local consumed = 0
	local claim_modes = {}
	local runs = 0
	local completions = 0
	local ok, err = xpcall(function()
		local plan = assert(bootstrap.plan("marksman"))
		local claim = assert(original_claim(plan))
		local child = vim.system({ "/bin/sh", "-c", "exit 0" }, { text = true })
		local dead_pid = assert(child.pid)
		local child_result = child:wait(5000)
		assert(child_result.code == 0 and child_result.signal == 0, vim.inspect(child_result))
		local dead_record = vim.deepcopy(claim.record)
		dead_record.pid = dead_pid
		dead_record.instance_token = string.rep("d", 64)
		local record_path = state .. "/verified-tools/records/" .. plan.identity_key .. ".json"
		assert(vim.fn.writefile({ vim.json.encode(dead_record) }, record_path) == 0)
		assert(vim.uv.fs_chmod(record_path, tonumber("600", 8)))
		local projected = assert(engine.status(plan.identity))
		assert(
			projected.status == "repair-required"
				and projected.original_status == "claimed"
				and projected.detail == "dead-owner",
			vim.inspect(projected)
		)

		engine.import_legacy = function(...)
			local imported, import_err = original_import(...)
			if import_err == "consumed" then
				consumed = consumed + 1
			end
			return imported, import_err
		end
		engine.claim = function(next_plan, options)
			claim_modes[#claim_modes + 1] = options and options.mode or nil
			return original_claim(next_plan, options)
		end
		engine.run = function(next_claim, callback)
			runs = runs + 1
			return original_run(next_claim, function(run_ok, reason)
				completions = completions + 1
				callback(run_ok, reason)
			end)
		end

		assert(bootstrap.install("marksman", false))
		assert(
			vim.wait(3000, function()
				local record = engine.status(plan.identity)
				return record and record.status == "succeeded" and not bootstrap.busy()
			end, 10),
			"consumed raw adoption did not settle: "
				.. vim.inspect({ status = engine.status(plan.identity), notices = notices })
		)
		local record = assert(engine.status(plan.identity))
		assert(record.status == "succeeded" and record.attempt == 2, vim.inspect(record))
		assert(consumed == 1, "raw Mason adoption did not exercise consumed state")
		assert(vim.deep_equal(claim_modes, { "repair" }), vim.inspect(claim_modes))
		assert(refreshes == 1 and installs == 1 and runs == 1 and completions == 1)
		assert(not bootstrap.busy(), "consumed raw adoption retained the install queue")
		assert(
			vim.iter(notices):all(function(message)
				return not message:find("existing Mason state could not be imported", 1, true)
			end),
			vim.inspect(notices)
		)
	end, debug.traceback)
	engine.import_legacy = original_import
	engine.claim = original_claim
	engine.run = original_run
	bootstrap._registry = original_registry
	bootstrap._notify = original_notify
	assert(ok, err)
end)

test("Mason refresh and install callbacks leave an actual fast event before state work", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/fast-mason-managed"
	mason = fixture .. "/fast-mason-root"
	state = fixture .. "/fast-mason-state"
	for _, directory in ipairs({ managed, mason, state }) do
		assert(vim.fn.mkdir(directory, "p") == 1)
	end
	local entry = assert(toolchain.mason_entry("clangd"))
	local installed = false
	local refresh_fast = false
	local install_fast = false
	local notifications_on_main = true
	local notices = {}
	local timers = {}
	local package = {}
	function package:is_installed()
		return installed
	end
	function package:get_installed_version()
		return installed and entry.version or nil
	end
	function package:install(options, callback)
		assert(not vim.in_fast_event(), "Mason install began inside the refresh fast event")
		assert(options.version == entry.version)
		local package_root = mason .. "/packages/clangd"
		write_executable(package_root .. "/clangd")
		assert(vim.fn.mkdir(mason .. "/bin", "p") >= 0)
		assert(vim.uv.fs_symlink("../packages/clangd/clangd", mason .. "/bin/clangd"))
		assert(vim.fn.writefile({
			vim.json.encode({
				name = "clangd",
				schema_version = "2.0",
				source = { id = "pkg:github/clangd/clangd@" .. entry.version },
				links = { bin = { clangd = "clangd" }, share = {}, opt = {} },
			}),
		}, package_root .. "/mason-receipt.json") == 0)
		installed = true
		local timer = assert(vim.uv.new_timer())
		timers[#timers + 1] = timer
		timer:start(0, 0, function()
			install_fast = vim.in_fast_event()
			timer:stop()
			timer:close()
			callback(true)
		end)
		return { terminate = function() end }
	end
	local original_registry = bootstrap._registry
	local original_notify = bootstrap._notify
	bootstrap._registry = function()
		return {
			refresh = function(callback)
				local timer = assert(vim.uv.new_timer())
				timers[#timers + 1] = timer
				timer:start(0, 0, function()
					refresh_fast = vim.in_fast_event()
					timer:stop()
					timer:close()
					callback(true)
				end)
			end,
			has_package = function(name)
				return name == "clangd"
			end,
			get_package = function(name)
				assert(name == "clangd")
				return package
			end,
		}
	end
	bootstrap._notify = function(message)
		notifications_on_main = notifications_on_main and not vim.in_fast_event()
		notices[#notices + 1] = tostring(message)
	end
	local ok, err = xpcall(function()
		local spec = assert(bootstrap.spec("clangd", { force_managed = true }))
		assert(bootstrap.install("clangd", true))
		assert(
			vim.wait(3000, function()
				local record = bootstrap.engine().status(spec.identity)
				return record and record.status == "succeeded"
			end, 10),
			"fast-event Mason install did not settle: "
				.. vim.inspect({
					status = bootstrap.engine().status(spec.identity),
					notices = notices,
				})
		)
		assert(refresh_fast and install_fast, "Mason callbacks did not execute in actual fast events")
		assert(notifications_on_main, "Mason completion notified from a fast event")
	end, debug.traceback)
	bootstrap._registry = original_registry
	bootstrap._notify = original_notify
	for _, timer in ipairs(timers) do
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
	assert(ok, err)
end)

test("Mason refresh continuation exceptions settle once and release the queue", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/refresh-exception-managed"
	mason = fixture .. "/refresh-exception-mason"
	state = fixture .. "/refresh-exception-state"
	for _, directory in ipairs({ managed, mason, state }) do
		assert(vim.fn.mkdir(directory, "p") == 1)
	end
	local entry = assert(toolchain.mason_entry("clangd"))
	local original_requires_all = entry.requires_all
	local original_external_executable = fake_paths.external_executable
	local original_notify = bootstrap._notify
	local prerequisite = write_executable(host .. "/refresh-exception/prerequisite")
	local prerequisite_calls = 0
	local throw_on_refresh_continuation = true
	local notices = {}
	entry.requires_all = { "refresh-exception-prerequisite" }
	fake_paths.external_executable = function(name)
		if name ~= "refresh-exception-prerequisite" then
			return original_external_executable(name)
		end
		prerequisite_calls = prerequisite_calls + 1
		if throw_on_refresh_continuation and prerequisite_calls == 3 then
			error("injected refresh continuation failure")
		end
		return prerequisite
	end
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	local ok, err = xpcall(function()
		local identity = assert(bootstrap.spec("clangd", { force_managed = true })).identity
		assert(bootstrap.install("clangd", true))
		assert(
			vim.wait(3000, function()
				return not bootstrap.busy()
			end, 10),
			"refresh continuation exception stranded the host queue"
		)
		local failed = assert(bootstrap.engine().status(identity))
		assert(
			failed.status == "failed"
				and failed.detail
				and failed.detail:find("mason-refresh-continuation-crashed", 1, true),
			vim.inspect(failed)
		)
		assert(prerequisite_calls == 3, "the post-refresh prerequisite boundary was not exercised")
		assert(#vim.fn.glob(state .. "/verified-tools/locks/resources/*.ticket.*", false, true) == 0)
		assert(#vim.fn.glob(state .. "/verified-tools/locks/global/*.ticket.*", false, true) == 0)
		local failures = vim.iter(notices)
			:filter(function(message)
				return message:find("mason-refresh-continuation-crashed", 1, true) ~= nil
			end)
			:totable()
		assert(#failures == 1, vim.inspect(notices))
		assert(
			vim.iter(notices):all(function(message)
				return not message:find(": nil", 1, true)
			end),
			vim.inspect(notices)
		)

		throw_on_refresh_continuation = false
		assert(bootstrap.install("clangd", true), "queue did not accept a retry after the continuation failure")
		assert(
			vim.wait(3000, function()
				local record = bootstrap.engine().status(identity)
				return record and record.status == "succeeded"
			end, 10),
			"Mason queue did not progress after the refresh continuation failure"
		)
	end, debug.traceback)
	entry.requires_all = original_requires_all
	fake_paths.external_executable = original_external_executable
	bootstrap._notify = original_notify
	assert(ok, err)
end)

test("Mason post-install observation exceptions settle once and release the queue", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/observation-exception-managed"
	mason = fixture .. "/observation-exception-mason"
	state = fixture .. "/observation-exception-state"
	for _, directory in ipairs({ managed, mason, state }) do
		assert(vim.fn.mkdir(directory, "p") == 1)
	end
	local original_observation = bootstrap._mason_observation
	local original_notify = bootstrap._notify
	local observation_calls = 0
	local fail_observation = true
	local notices = {}
	bootstrap._mason_observation = function(...)
		observation_calls = observation_calls + 1
		if fail_observation then
			error("injected post-install observation failure")
		end
		return original_observation(...)
	end
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	local ok, err = xpcall(function()
		local identity = assert(bootstrap.spec("clangd", { force_managed = true })).identity
		assert(bootstrap.install("clangd", true))
		assert(
			vim.wait(3000, function()
				return not bootstrap.busy()
			end, 10),
			"post-install exception stranded the host queue"
		)
		local failed = assert(bootstrap.engine().status(identity))
		assert(
			failed.status == "failed" and failed.detail and failed.detail:find("mason-post-install-crashed", 1, true),
			vim.inspect(failed)
		)
		assert(observation_calls == 1, "post-install observation completion ran more than once")
		assert(#vim.fn.glob(state .. "/verified-tools/locks/resources/*.ticket.*", false, true) == 0)
		assert(#vim.fn.glob(state .. "/verified-tools/locks/global/*.ticket.*", false, true) == 0)
		local failures = vim.iter(notices)
			:filter(function(message)
				return message:find("mason-post-install-crashed", 1, true) ~= nil
			end)
			:totable()
		assert(#failures == 1, vim.inspect(notices))
		assert(
			vim.iter(notices):all(function(message)
				return not message:find(": nil", 1, true)
			end),
			vim.inspect(notices)
		)

		fail_observation = false
		assert(bootstrap.install("clangd", true), "queue did not accept a retry after the observation failure")
		assert(
			vim.wait(3000, function()
				local record = bootstrap.engine().status(identity)
				return record and record.status == "succeeded"
			end, 10),
			"Mason queue did not progress after the post-install observation failure"
		)
	end, debug.traceback)
	bootstrap._mason_observation = original_observation
	bootstrap._notify = original_notify
	assert(ok, err)
end)

test("Mason cancellation does not terminate an already closed handle", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/closed-handle-managed"
	mason = fixture .. "/closed-handle-mason"
	state = fixture .. "/closed-handle-state"
	for _, directory in ipairs({ managed, mason, state }) do
		assert(vim.fn.mkdir(directory, "p") == 1)
	end
	local original_install = fake_package.install
	local terminate_calls = 0
	local identity = assert(bootstrap.spec("clangd", { force_managed = true })).identity
	fake_package.install = function(package, options, callback)
		local handle = original_install(package, options, function(installed)
			callback(installed)
			assert(bootstrap.engine().cancel(identity))
			assert(bootstrap.engine().cancel(identity))
		end)
		handle.is_closed = function()
			return true
		end
		handle.terminate = function()
			terminate_calls = terminate_calls + 1
		end
		return handle
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("clangd", true))
		assert(
			vim.wait(3000, function()
				local record = bootstrap.engine().status(identity)
				return record and record.status == "cancelled" and not bootstrap.busy()
			end, 10),
			"closed-handle cancellation did not settle"
		)
		assert(terminate_calls == 0, "cancellation terminated a closed Mason handle")
		assert(#vim.fn.glob(state .. "/verified-tools/locks/resources/*.ticket.*", false, true) == 0)
		assert(#vim.fn.glob(state .. "/verified-tools/locks/global/*.ticket.*", false, true) == 0)
	end, debug.traceback)
	fake_package.install = original_install
	assert(ok, err)
end)

test("install all bounds complete chains and serializes shared install roots", function()
	local original_managed_order = toolchain.managed_order
	local original_dynamic_order = toolchain.dynamic_order
	local original_mason_order = toolchain.mason_order
	local original_plan = bootstrap.plan
	local original_import = bootstrap.import_legacy
	local original_notify = bootstrap._notify
	local engine = bootstrap.engine()
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	toolchain.managed_order = { "mmdflux", "plantuml", "markdown-preview" }
	toolchain.dynamic_order = {}
	toolchain.mason_order = { "clangd", "marksman", "lemminx" }
	local pending = {}
	local notices = {}
	local active = 0
	local active_groups = {}
	local maximum = 0
	local completed = 0
	local legacy_imports = 0
	local started = {}
	bootstrap.plan = function(name)
		local group = toolchain.managed_tools[name] and "release" or "mason"
		active = active + 1
		active_groups[group] = (active_groups[group] or 0) + 1
		maximum = math.max(maximum, active)
		assert(active <= 2, "more than two complete tool chains were active")
		assert(active_groups[group] == 1, "tools sharing an install root overlapped")
		started[#started + 1] = name
		return {
			strategy = "managed",
			identity = { backend = group, name = name },
			manifest = group == "release" and { release_plan = {} } or { entry = {} },
		}
	end
	bootstrap.import_legacy = function(name, callback)
		legacy_imports = legacy_imports + 1
		pending[#pending + 1] = {
			kind = "legacy",
			plan = { identity = { backend = toolchain.managed_tools[name] and "release" or "mason" } },
			callback = callback,
		}
		return true, nil, true
	end
	bootstrap._notify = function(message)
		notices[#notices + 1] = tostring(message)
	end
	engine.status = function()
		return { status = "failed" }
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(plan, callback)
		pending[#pending + 1] = { kind = "run", plan = plan, callback = callback }
		return true
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("all", true))
		assert(#pending == 2 and active == 2)
		while #pending > 0 do
			local item = table.remove(pending, 1)
			if item.kind == "legacy" then
				item.callback(false, "legacy-repair-required")
			else
				local group = item.plan.identity.backend
				active = active - 1
				active_groups[group] = active_groups[group] - 1
				completed = completed + 1
				item.callback(true)
			end
		end
		assert(completed == 6 and legacy_imports == 6 and #started == 6 and active == 0)
		assert(maximum == 2)
		assert(
			vim.iter(notices):all(function(message)
				return not message:find("locked", 1, true)
			end),
			vim.inspect(notices)
		)
	end, debug.traceback)
	toolchain.managed_order = original_managed_order
	toolchain.dynamic_order = original_dynamic_order
	toolchain.mason_order = original_mason_order
	bootstrap.plan = original_plan
	bootstrap.import_legacy = original_import
	bootstrap._notify = original_notify
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	assert(ok, err)
end)

test("throwing bridge and notifier callbacks cannot strand the install queue", function()
	local original_managed_order = toolchain.managed_order
	local original_dynamic_order = toolchain.dynamic_order
	local original_mason_order = toolchain.mason_order
	local original_plan = bootstrap.plan
	local original_import = bootstrap.import_legacy
	local original_notify = bootstrap._notify
	local original_plugin_root = bootstrap._markdown_plugin_root
	local markdown_bridge = require("verified_tools.markdown_preview")
	local original_repair = markdown_bridge.repair
	local engine = bootstrap.engine()
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	toolchain.managed_order = { "markdown-preview", "mmdflux", "plantuml" }
	toolchain.dynamic_order = {}
	toolchain.mason_order = {}
	local succeeded = {}
	local started = {}
	local bridge_calls = 0
	local notifier_failures = 0
	local notices = {}
	bootstrap.plan = function(name)
		return {
			strategy = "managed",
			identity = { backend = "release", name = name },
			manifest = { release_plan = {} },
		}
	end
	bootstrap.import_legacy = function(_, callback)
		callback(false)
		return true, nil, true
	end
	bootstrap._markdown_plugin_root = function()
		return fixture .. "/plugin"
	end
	markdown_bridge.repair = function()
		bridge_calls = bridge_calls + 1
		error("injected bridge failure")
	end
	bootstrap._notify = function(message)
		if tostring(message):find("mmdflux", 1, true) then
			notifier_failures = notifier_failures + 1
			error("injected notifier failure")
		end
		notices[#notices + 1] = tostring(message)
	end
	engine.status = function(identity)
		return {
			status = succeeded[identity.name] and "succeeded" or "failed",
			identity = identity,
		}
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(plan, callback)
		started[#started + 1] = plan.identity.name
		succeeded[plan.identity.name] = true
		callback(true)
		return true
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("all", true))
		assert(vim.deep_equal(started, { "markdown-preview", "mmdflux", "plantuml" }), vim.inspect(started))
		assert(bridge_calls == 1, "throwing bridge was not exercised")
		assert(notifier_failures == 1, "throwing notifier was not exercised")
		assert(
			vim.iter(notices):any(function(message)
				return message:find("bridge repair raised an error", 1, true) ~= nil
			end),
			vim.inspect(notices)
		)
	end, debug.traceback)
	toolchain.managed_order = original_managed_order
	toolchain.dynamic_order = original_dynamic_order
	toolchain.mason_order = original_mason_order
	bootstrap.plan = original_plan
	bootstrap.import_legacy = original_import
	bootstrap._notify = original_notify
	bootstrap._markdown_plugin_root = original_plugin_root
	markdown_bridge.repair = original_repair
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	bootstrap._reset_for_tests()
	assert(ok, err)
end)

test("install progress is persistent and the mixed aggregate waits for every request item", function()
	bootstrap._reset_for_tests()
	local original_managed_order = toolchain.managed_order
	local original_dynamic_order = toolchain.dynamic_order
	local original_mason_order = toolchain.mason_order
	local original_plan = bootstrap.plan
	local original_import = bootstrap.import_legacy
	local original_notify = bootstrap._notify
	local original_visual_notify = bootstrap._visual_notify
	local original_visual_hide = bootstrap._visual_hide
	local original_new_timer = bootstrap._new_timer
	local original_schedule = bootstrap._schedule
	local engine = bootstrap.engine()
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	toolchain.managed_order = { "mmdflux", "plantuml" }
	toolchain.dynamic_order = {}
	toolchain.mason_order = { "clangd" }
	local frames = {}
	local notices = {}
	local runs = {}
	local timer = progress_timer()
	bootstrap._visual_notify = function(message, level, options)
		frames[#frames + 1] = { message = message, level = level, options = options }
		return true
	end
	bootstrap._visual_hide = function() end
	bootstrap._new_timer = function()
		return timer
	end
	bootstrap._schedule = function(callback)
		callback()
	end
	bootstrap._notify = function(message, level, options)
		notices[#notices + 1] = { message = tostring(message), level = level, options = options }
	end
	bootstrap.plan = function(name)
		local backend = toolchain.managed_tools[name] and "release" or "mason"
		return {
			strategy = "managed",
			identity = { backend = backend, name = name },
			manifest = backend == "release" and { release_plan = {} } or { entry = {} },
		}
	end
	bootstrap.import_legacy = function(_, callback)
		callback(false, "legacy-repair-required")
		return true, nil, true
	end
	engine.status = function()
		return { status = "failed" }
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(plan, callback)
		runs[plan.identity.name] = callback
		return true
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("all", true))
		assert(#frames == 1 and timer.timeout == 500 and timer.repeating == 500)
		local id = frames[1].options.id
		assert(id:find("nvim%-config:tools%-install:%d+"))
		assert(frames[1].message:find("⠋", 1, true) == 1)
		assert(frames[1].options.title == "Tools")
		assert(frames[1].options.timeout == false and frames[1].options.history == false)
		timer.callback()
		assert(#frames == 2 and frames[2].message:find("⠙", 1, true) == 1)
		assert(frames[2].options.id == id and #notices == 0)
		runs.mmdflux(true)
		assert(type(runs.plantuml) == "function" and not timer.closed)
		assert(not vim.iter(notices):any(function(notice)
			return notice.options and notice.options.id == id
		end))
		runs.clangd(false)
		assert(not vim.iter(notices):any(function(notice)
			return notice.options and notice.options.id == id
		end))
		local progress_frames = #frames
		runs.plantuml(true)
		local terminal = notices[#notices]
		local visual_terminal = frames[#frames]
		assert(
			terminal.message == "Tool install request complete: 2 succeeded, 1 failed (3 total)\nFailed tools: clangd"
		)
		assert(terminal.level == vim.log.levels.WARN)
		assert(terminal.options.id == id and terminal.options.title == "Tools" and terminal.options.timeout == false)
		assert(
			#frames == progress_frames + 1
				and visual_terminal.message == terminal.message
				and visual_terminal.level == terminal.level
		)
		assert(
			visual_terminal.options.id == id
				and visual_terminal.options.timeout == false
				and visual_terminal.options.history == false
		)
		assert(timer.stopped and timer.closed)
		assert(#vim.iter(notices)
			:filter(function(notice)
				return notice.options and notice.options.id == id
			end)
			:totable() == 1)
		local terminal_frames = #frames
		timer.callback()
		assert(#frames == terminal_frames, "a stale timer callback redrew completed progress")
	end, debug.traceback)
	bootstrap._reset_for_tests()
	toolchain.managed_order = original_managed_order
	toolchain.dynamic_order = original_dynamic_order
	toolchain.mason_order = original_mason_order
	bootstrap.plan = original_plan
	bootstrap.import_legacy = original_import
	bootstrap._notify = original_notify
	bootstrap._visual_notify = original_visual_notify
	bootstrap._visual_hide = original_visual_hide
	bootstrap._new_timer = original_new_timer
	bootstrap._schedule = original_schedule
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	assert(ok, err)
end)

test("overlapping identical install requests keep independent progress and terminal IDs", function()
	bootstrap._reset_for_tests()
	local original_plan = bootstrap.plan
	local original_import = bootstrap.import_legacy
	local original_notify = bootstrap._notify
	local original_visual_notify = bootstrap._visual_notify
	local original_visual_hide = bootstrap._visual_hide
	local original_new_timer = bootstrap._new_timer
	local original_schedule = bootstrap._schedule
	local engine = bootstrap.engine()
	local original_status = engine.status
	local original_claim = engine.claim
	local original_run = engine.run
	local frames = {}
	local notices = {}
	local runs = {}
	local timers = {}
	bootstrap._visual_notify = function(message, level, options)
		frames[#frames + 1] = { message = message, level = level, options = options }
		return true
	end
	bootstrap._visual_hide = function() end
	bootstrap._new_timer = function()
		local timer = progress_timer()
		timers[#timers + 1] = timer
		return timer
	end
	bootstrap._schedule = function(callback)
		callback()
	end
	bootstrap._notify = function(message, level, options)
		notices[#notices + 1] = { message = tostring(message), level = level, options = options }
	end
	bootstrap.plan = function(name)
		return {
			strategy = "managed",
			identity = { backend = "release", name = name },
			manifest = { release_plan = {} },
		}
	end
	bootstrap.import_legacy = function(_, callback)
		callback(false, "legacy-repair-required")
		return true, nil, true
	end
	engine.status = function()
		return { status = "failed" }
	end
	engine.claim = function(plan)
		return plan
	end
	engine.run = function(_, callback)
		runs[#runs + 1] = callback
		return true
	end
	local ok, err = xpcall(function()
		assert(bootstrap.install("mmdflux", true))
		assert(bootstrap.install("mmdflux", true))
		assert(#frames == 2 and #timers == 2 and #runs == 1)
		local first_id = frames[1].options.id
		local second_id = frames[2].options.id
		assert(first_id ~= second_id)
		runs[1](true)
		assert(#runs == 2 and timers[1].closed and not timers[2].closed)
		local first_terminal = notices[#notices]
		assert(first_terminal.options.id == first_id and first_terminal.level == vim.log.levels.INFO)
		assert(first_terminal.options.timeout == 3000)
		runs[2](true)
		local second_terminal = notices[#notices]
		assert(second_terminal.options.id == second_id and second_terminal.level == vim.log.levels.INFO)
		assert(second_terminal.options.timeout == 3000 and timers[2].closed)
	end, debug.traceback)
	bootstrap._reset_for_tests()
	bootstrap.plan = original_plan
	bootstrap.import_legacy = original_import
	bootstrap._notify = original_notify
	bootstrap._visual_notify = original_visual_notify
	bootstrap._visual_hide = original_visual_hide
	bootstrap._new_timer = original_new_timer
	bootstrap._schedule = original_schedule
	engine.status = original_status
	engine.claim = original_claim
	engine.run = original_run
	assert(ok, err)
end)

test(
	"unavailable or throwing progress UI cannot create timers or strand installs, and reset cleans displayed progress",
	function()
		bootstrap._reset_for_tests()
		local original_plan = bootstrap.plan
		local original_import = bootstrap.import_legacy
		local original_notify = bootstrap._notify
		local original_visual_notify = bootstrap._visual_notify
		local original_visual_hide = bootstrap._visual_hide
		local original_new_timer = bootstrap._new_timer
		local original_schedule = bootstrap._schedule
		local engine = bootstrap.engine()
		local original_status = engine.status
		local original_claim = engine.claim
		local original_run = engine.run
		local old_snacks = rawget(_G, "Snacks")
		local old_loaded_snacks = package.loaded.snacks
		local old_preload_snacks = package.preload.snacks
		local require_calls = 0
		local visual_calls = 0
		local timer_calls = 0
		local synchronous = true
		local pending
		local hidden = {}
		local cleanup_timer
		local displayed_id
		bootstrap.plan = function(name)
			return {
				strategy = "managed",
				identity = { backend = "release", name = name },
				manifest = { release_plan = {} },
			}
		end
		bootstrap.import_legacy = function(_, callback)
			callback(false, "legacy-repair-required")
			return true, nil, true
		end
		engine.status = function()
			return { status = "failed" }
		end
		engine.claim = function(plan)
			return plan
		end
		engine.run = function(_, callback)
			if synchronous then
				callback(true)
			else
				pending = callback
			end
			return true
		end
		bootstrap._notify = function() end
		bootstrap._schedule = function(callback)
			callback()
		end
		bootstrap._visual_hide = function(id)
			hidden[#hidden + 1] = id
			return true
		end
		local ok, err = xpcall(function()
			bootstrap._visual_notify = function()
				visual_calls = visual_calls + 1
				return true
			end
			bootstrap._new_timer = function()
				timer_calls = timer_calls + 1
				return progress_timer()
			end
			assert(not bootstrap.install(nil))
			assert(not bootstrap.install(""))
			assert(not bootstrap.install("unknown-tool"))
			assert(visual_calls == 0 and timer_calls == 0 and not bootstrap.busy())

			rawset(_G, "Snacks", nil)
			package.loaded.snacks = nil
			package.preload.snacks = function()
				require_calls = require_calls + 1
				error("Snacks must not be required for progress")
			end
			bootstrap._visual_notify = original_visual_notify
			bootstrap._new_timer = function()
				timer_calls = timer_calls + 1
				error("timer must not be created without a visible toast")
			end
			assert(bootstrap.install("mmdflux", true))
			assert(require_calls == 0 and timer_calls == 0 and not bootstrap.busy())

			bootstrap._visual_notify = function()
				error("injected visual failure")
			end
			assert(bootstrap.install("mmdflux", true))
			assert(timer_calls == 0 and not bootstrap.busy())

			bootstrap._visual_notify = function(_, _, options)
				displayed_id = options.id
				return true
			end
			bootstrap._new_timer = function()
				timer_calls = timer_calls + 1
				error("injected timer failure")
			end
			assert(bootstrap.install("mmdflux", true))
			assert(timer_calls == 1 and not bootstrap.busy())

			local start_failure_timer = progress_timer()
			start_failure_timer.start = function()
				error("injected timer start failure")
			end
			bootstrap._new_timer = function()
				timer_calls = timer_calls + 1
				return start_failure_timer
			end
			assert(bootstrap.install("mmdflux", true))
			assert(timer_calls == 2 and start_failure_timer.stopped and start_failure_timer.closed)
			assert(not bootstrap.busy())

			synchronous = false
			cleanup_timer = progress_timer()
			bootstrap._new_timer = function()
				return cleanup_timer
			end
			assert(bootstrap.install("mmdflux", true))
			assert(type(pending) == "function" and type(displayed_id) == "string" and not cleanup_timer.closed)
			local stale_pending = pending
			local stale_id = displayed_id
			bootstrap._reset_for_tests()
			assert(cleanup_timer.stopped and cleanup_timer.closed)
			assert(vim.deep_equal(hidden, { stale_id }))

			pending = nil
			cleanup_timer = progress_timer()
			bootstrap._new_timer = function()
				return cleanup_timer
			end
			assert(bootstrap.install("mmdflux", true))
			local current_pending = pending
			assert(type(current_pending) == "function" and bootstrap.busy())
			stale_pending(true)
			assert(bootstrap.busy() and not cleanup_timer.closed, "stale pre-reset settlement corrupted the new queue")
			current_pending(true)
			assert(not bootstrap.busy() and cleanup_timer.stopped and cleanup_timer.closed)
		end, debug.traceback)
		bootstrap._reset_for_tests()
		rawset(_G, "Snacks", old_snacks)
		package.loaded.snacks = old_loaded_snacks
		package.preload.snacks = old_preload_snacks
		bootstrap.plan = original_plan
		bootstrap.import_legacy = original_import
		bootstrap._notify = original_notify
		bootstrap._visual_notify = original_visual_notify
		bootstrap._visual_hide = original_visual_hide
		bootstrap._new_timer = original_new_timer
		bootstrap._schedule = original_schedule
		engine.status = original_status
		engine.claim = original_claim
		engine.run = original_run
		assert(ok, err)
	end
)

test("explicit managed install supports initially absent roots and runtime drift never falls back", function()
	bootstrap._reset_for_tests()
	managed = fixture .. "/initially-absent-managed"
	state = fixture .. "/initially-empty-state-parent"
	assert(vim.fn.mkdir(state, "p") == 1)
	assert(vim.uv.fs_lstat(managed) == nil and vim.uv.fs_lstat(state .. "/verified-tools") == nil)
	external.mmdflux = nil
	assert(bootstrap.install("mmdflux", true))
	assert(vim.uv.fs_lstat(managed).type == "directory")
	assert(vim.uv.fs_lstat(state .. "/verified-tools").type == "directory")
	local managed_command = assert(vim.uv.fs_realpath(managed .. "/bin/mmdflux"))
	local original_system = bootstrap._system
	local external_command = write_executable(host .. "/runtime-fallback/mmdflux")
	external.mmdflux = { external_command }
	local ok, err = xpcall(function()
		bootstrap._system = function()
			error("runtime resolution probed an external fallback")
		end
		assert(bootstrap.resolve("mmdflux", "mmdflux") == managed_command)
		assert(vim.uv.fs_chmod(managed_command, tonumber("777", 8)))
		local drifted, drift_err = bootstrap.resolve("mmdflux", "mmdflux")
		assert(not drifted and tostring(drift_err):find("verified command changed", 1, true))
		assert(vim.uv.fs_lstat(managed_command).mode % 512 == tonumber("777", 8))
	end, debug.traceback)
	bootstrap._system = original_system
	external.mmdflux = nil
	assert(ok, err)
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tool_bootstrap_spec: %d tests passed", count))
vim.cmd("quitall!")
