vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/verified-tools.nvim")
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
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
local release_install_count = 0
local registry_refresh_count = 0
local mason_install_count = 0
local toolchain = require("config.toolchain")

local legacy_root = state .. "/tool-bootstrap"
assert(vim.fn.mkdir(legacy_root, "p") == 1)
assert(vim.fn.mkdir(managed .. "/bin", "p") == 1)
local legacy_plantuml = managed .. "/bin/plantuml"
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, legacy_plantuml) == 0)
assert(vim.uv.fs_chmod(legacy_plantuml, tonumber("700", 8)))
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
	external_executable = function()
		return nil
	end,
}

local fake_release = {}
function fake_release.plan(name)
	local entry = toolchain.managed_tools[name]
	if not entry then
		return nil, "unknown"
	end
	return {
		name = name,
		entry = entry,
		asset = { sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
		target = "test-x86_64",
	}
end
function fake_release.install(plan, callback)
	release_install_count = release_install_count + 1
	assert(vim.fn.mkdir(managed .. "/bin", "p") >= 0)
	local path = managed .. "/bin/" .. plan.entry.executable
	assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path) == 0)
	assert(vim.uv.fs_chmod(path, tonumber("700", 8)))
	callback(true)
	return true
end

package.loaded["config.tool_paths"] = fake_paths
package.loaded["config.release_installer"] = fake_release
package.loaded["config.tool_bootstrap"] = nil
local bootstrap = require("config.tool_bootstrap")
bootstrap._network_authorized = function()
	return true
end
bootstrap._notify = function() end

local fake_package = {}
function fake_package:install(options, callback)
	mason_install_count = mason_install_count + 1
	assert(options.version == toolchain.mason_entry("clangd").version)
	assert(vim.fn.mkdir(mason .. "/bin", "p") >= 0)
	local path = mason .. "/bin/clangd"
	assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path) == 0)
	assert(vim.uv.fs_chmod(path, tonumber("700", 8)))
	callback(true)
end
function fake_package:is_installed()
	return mason_install_count > 0
end
function fake_package:get_installed_version()
	return toolchain.mason_entry("clangd").version
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

test("setup and Mason readiness only plan and probe", function()
	bootstrap.setup()
	local plans = bootstrap.plan_all()
	assert(plans.mmdflux and plans.clangd)
	assert(release_install_count == 0 and registry_refresh_count == 0 and mason_install_count == 0)
	bootstrap.mason_ready()
	assert(release_install_count == 0 and registry_refresh_count == 0 and mason_install_count == 0)
	local migrated = assert(bootstrap.engine().status(assert(bootstrap.spec("plantuml")).identity))
	assert(migrated.status == "succeeded" and migrated.attestation.path == legacy_plantuml)
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 2)
	assert(vim.fn.exists(":MasonToolsInstallSync") == 0)
end)

test("manual release and Mason installs route through the shared engine", function()
	assert(bootstrap.install("mmdflux", false))
	assert(release_install_count == 1)
	assert(bootstrap.install("clangd", false))
	assert(registry_refresh_count == 1 and mason_install_count == 1)
	local statuses = bootstrap.engine().status()
	local seen = {}
	for _, value in ipairs(statuses) do
		seen[value.identity.backend .. ":" .. value.identity.name] = value.status
	end
	assert(seen["release:mmdflux"] == "succeeded")
	assert(seen["mason:clangd"] == "succeeded")
end)

test("offline manual denial consumes no attempt", function()
	bootstrap._network_authorized = function()
		return false
	end
	-- Reconfigure the injected authorization callback without starting work.
	local engine = bootstrap.engine()
	engine.setup({
		state_root = state .. "/offline",
		backends = {},
		network_authorized = bootstrap._network_authorized,
	})
	local spec = assert(bootstrap.spec("plantuml"))
	local plan = assert(engine.plan(spec))
	local claim, reason = engine.claim(plan)
	assert(claim == nil and reason == "blocked/offline")
	assert(engine.status(plan.identity) == nil)
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
