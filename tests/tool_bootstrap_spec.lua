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
	assert(bootstrap.install("clangd", false))
	assert(registry_refresh_count == 1 and mason_install_count == 1)
	local release_record = assert(bootstrap.engine().status(assert(bootstrap.spec("mmdflux")).identity))
	assert(release_record.status == "succeeded" and release_record.proof.kind == "release-sha256")
	local mason_record = assert(bootstrap.engine().status(assert(bootstrap.spec("clangd")).identity))
	assert(mason_record.status == "succeeded" and mason_record.proof.kind == "mason-local-integrity")
	local private = mason .. "/.verified-tools/receipts/clangd.json"
	assert(vim.uv.fs_lstat(private).mode % 512 == tonumber("600", 8))
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

test("bang bypasses a compatible external probe while prerequisites block before claim", function()
	local external_markdown = write_executable(host .. "/markdown-preview")
	external["markdown-preview"] = { external_markdown }
	bootstrap._system = function()
		return {
			wait = function()
				return { code = 0, stdout = "markdown-preview 0.0.10", stderr = "" }
			end,
		}
	end
	local before = release_install_count
	assert(bootstrap.install("markdown-preview", false))
	assert(
		release_install_count == before
			and bootstrap.engine().status(assert(bootstrap.spec("markdown-preview")).identity) == nil
	)
	assert(bootstrap.install("markdown-preview", true))
	assert(release_install_count == before + 1)
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

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tool_bootstrap_spec: %d tests passed", count))
vim.cmd("quitall!")
