vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local manifest = require("config.toolchain")
local records = {}
local claims = {}
local notifications = {}
local external = {}
local release_plans = {}
local release_force
local release_failure = false
local release_install_count = 0
local transition_failure = false
local finish_count = 0

local fake_state = {}
function fake_state.inspect(name, version)
	local value = records[name .. "@" .. version]
	return value, value and nil or "absent"
end
function fake_state.claim_auto(name, version)
	local key = name .. "@" .. version
	if records[key] then
		return nil, "consumed"
	end
	local claim = { identity = key, name = name, version = version, mode = "auto" }
	records[key] = { status = "claimed" }
	claims[#claims + 1] = claim
	return claim
end
function fake_state.claim_manual(name, version)
	local claim = { identity = name .. "@" .. version, name = name, version = version, mode = "manual" }
	records[claim.identity] = { status = "claimed" }
	claims[#claims + 1] = claim
	return claim
end
function fake_state.transition(claim, status)
	if transition_failure then
		return nil, "injected"
	end
	records[claim.identity] = { status = status }
	return true
end
function fake_state.finish(claim, ok, detail)
	finish_count = finish_count + 1
	records[claim.identity] = { status = ok and "succeeded" or "failed", detail = detail }
	return true
end

local fake_paths = {
	external_executable = function(name)
		return external[name]
	end,
}

local fake_release = {}
function fake_release.plan(name, options)
	release_force = options and options.force or false
	local value = release_plans[name]
	if value == "external" and not release_force then
		return nil, "external"
	end
	return value ~= nil and { name = name, entry = manifest.managed_tools[name], asset = {} } or nil,
		value == nil and "missing-prerequisite" or nil
end
function fake_release.install(_, callback)
	release_install_count = release_install_count + 1
	callback(not release_failure, release_failure and "mkdir-failed" or nil)
	return not release_failure
end

package.loaded["config.tool_paths"] = fake_paths
package.loaded["config.tool_state"] = fake_state
package.loaded["config.release_installer"] = fake_release
package.loaded["config.pager"] = { active = false }
package.loaded["config.local_config"] = {
	get = function()
		return { auto_install = true }
	end,
}
package.loaded["config.tool_bootstrap"] = nil
local bootstrap = require("config.tool_bootstrap")
bootstrap._notify = function(message, level)
	notifications[#notifications + 1] = { message = message, level = level }
end

local original_offline = vim.env.NVIM_CONFIG_OFFLINE
local original_vscode = vim.g.vscode

local function consume_all_except(...)
	records = {}
	claims = {}
	notifications = {}
	release_plans = {}
	external = {}
	release_failure = false
	release_install_count = 0
	transition_failure = false
	finish_count = 0
	local keep = {}
	for _, name in ipairs({ ... }) do
		keep[name] = true
	end
	for _, name in ipairs(manifest.managed_order) do
		if not keep[name] then
			records[manifest.identity(name, manifest.managed_tools[name])] = { status = "succeeded" }
		end
	end
	for _, name in ipairs(manifest.mason_order) do
		if not keep[name] then
			records[manifest.identity(name, manifest.mason_entry(name))] = { status = "succeeded" }
		end
	end
	bootstrap._reset_for_tests()
	bootstrap._ui_count = function()
		return 1
	end
	vim.env.NVIM_CONFIG_OFFLINE = nil
	vim.g.vscode = nil
end

local function package_fixture(options)
	options = options or {}
	local pkg = {}
	function pkg:is_installed()
		return options.installed == true
	end
	function pkg:get_installed_version()
		return options.installed_version
	end
	function pkg:is_installing()
		return false
	end
	function pkg:is_installable()
		return options.installable ~= false
	end
	function pkg:install(opts, callback)
		options.install_count = (options.install_count or 0) + 1
		options.install_options = opts
		if options.hold then
			options.callback = callback
		else
			callback(options.success ~= false)
		end
	end
	return pkg, options
end

local function registry_for(packages, refresh_success)
	local registry = { refresh_count = 0 }
	function registry.refresh(callback)
		registry.refresh_count = registry.refresh_count + 1
		callback(refresh_success ~= false)
	end
	function registry.has_package(name)
		return packages[name] ~= nil
	end
	function registry.get_package(name)
		return assert(packages[name])
	end
	return registry
end

local function run_auto()
	bootstrap.mason_ready()
	vim.wait(20, function()
		return false
	end)
	assert(
		vim.wait(500, function()
			return not bootstrap.mason_busy()
		end),
		"automatic bootstrap did not settle"
	)
end

test("automatic guards have zero state or registry side effects", function()
	consume_all_except("clangd")
	local pkg = package_fixture({ installed = true, installed_version = "22.1.6" })
	local registry = registry_for({ clangd = pkg })
	bootstrap._registry = function()
		return registry
	end
	bootstrap._ui_count = function()
		return 0
	end
	bootstrap.mason_ready()
	vim.wait(30)
	assert(#claims == 0 and registry.refresh_count == 0)
	assert(next(release_plans) == nil)

	bootstrap._reset_for_tests()
	bootstrap._ui_count = function()
		return 1
	end
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	bootstrap.mason_ready()
	vim.wait(30)
	assert(#claims == 0 and registry.refresh_count == 0)
end)

test("missing package-manager prerequisites stay pending without a claim", function()
	consume_all_except("bash-language-server")
	local registry = registry_for({})
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(#claims == 0 and registry.refresh_count == 0)
	assert(#notifications == 0)
end)

test("prebuilt rust-analyzer installs without its cargo runtime", function()
	consume_all_except("rust-analyzer")
	local pkg, options = package_fixture({ installed = false, success = true })
	local registry = registry_for({ ["rust-analyzer"] = pkg })
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(options.install_count == 1, "prebuilt rust-analyzer download was blocked by missing cargo")
	assert(records["rust-analyzer@2026-08-03"].status == "succeeded")
end)

test("external satisfaction requires the primary runtime executable", function()
	consume_all_except()
	external.node = "/host/node"
	external.npm = "/host/npm"
	external.pyright = "/host/pyright"
	assert(bootstrap.mason_condition(manifest.mason_entry("pyright"))() == true)
	external["pyright-langserver"] = "/host/pyright-langserver"
	assert(bootstrap.mason_condition(manifest.mason_entry("pyright"))() == false)

	external.prettier = "/host/prettier"
	assert(bootstrap.mason_condition(manifest.mason_entry("prettierd"))() == false)
end)

test("Python venv capability is cached per resolved interpreter", function()
	consume_all_except("cmake-language-server", "clang-format", "debugpy")
	external.python3 = "/host/python3"
	local checks = 0
	bootstrap._python_venv = function(path)
		assert(path == "/host/python3")
		checks = checks + 1
		return true
	end
	local registry = registry_for({})
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(checks == 1, "venv was probed more than once for one interpreter")
	assert(registry.refresh_count == 1)
end)

test("managed start failure finishes one claim exactly once", function()
	consume_all_except("mmdflux")
	release_plans.mmdflux = true
	release_failure = true
	run_auto()
	assert(#claims == 1 and finish_count == 1)
	assert(records["mmdflux@2.6.0"].status == "failed")
	assert(#notifications == 1 and notifications[1].message:find("1 failed", 1, true))
end)

test("one refresh records exact installs and installs wrong pins", function()
	consume_all_except("clangd", "lemminx")
	local exact = package_fixture({ installed = true, installed_version = "22.1.6" })
	local wrong, wrong_options = package_fixture({ installed = true, installed_version = "0", success = true })
	local registry = registry_for({ clangd = exact, lemminx = wrong })
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(registry.refresh_count == 1)
	assert(#claims == 2)
	assert(records["clangd@22.1.6"].status == "succeeded")
	assert(records["lemminx@0.29.3"].status == "succeeded")
	assert(wrong_options.install_count == 1)
	assert(wrong_options.install_options.version == "0.29.3")
	assert(#notifications == 1 and notifications[1].message:find("2 succeeded", 1, true))
end)

test("failed installs are silent on the second boot", function()
	consume_all_except("clangd")
	local pkg, options = package_fixture({ installed = false, success = false })
	local registry = registry_for({ clangd = pkg })
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(options.install_count == 1)
	assert(records["clangd@22.1.6"].status == "failed")
	assert(#notifications == 1)

	bootstrap._reset_for_tests()
	notifications = {}
	run_auto()
	assert(options.install_count == 1, "failed exact pin retried")
	assert(registry.refresh_count == 1, "second boot refreshed despite consumed pin")
	assert(#notifications == 0, "second boot repeated the failure notification")
end)

test("registry refresh failure creates no Mason claims", function()
	consume_all_except("clangd")
	local pkg = package_fixture({ installed = false })
	local registry = registry_for({ clangd = pkg }, false)
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(registry.refresh_count == 1 and #claims == 0)
	assert(records["clangd@22.1.6"] == nil)
	assert(#notifications == 0)
end)

test("registry-confirmed unavailable pins are consumed once", function()
	consume_all_except("clangd", "lemminx")
	local unavailable = package_fixture({ installed = false, installable = false })
	local registry = registry_for({ clangd = unavailable })
	bootstrap._registry = function()
		return registry
	end
	run_auto()
	assert(records["clangd@22.1.6"].status == "failed")
	assert(records["clangd@22.1.6"].detail == "mason-package-uninstallable")
	assert(records["lemminx@0.29.3"].status == "failed")
	assert(records["lemminx@0.29.3"].detail == "mason-package-unavailable")
	assert(#notifications == 1 and notifications[1].message:find("2 failed", 1, true))

	bootstrap._reset_for_tests()
	notifications = {}
	run_auto()
	assert(registry.refresh_count == 1, "unavailable pins caused another registry refresh")
	assert(#notifications == 0, "unavailable pins notified again")
end)

test("manual Mason conditions stop before package work while auto is busy", function()
	consume_all_except("clangd")
	local pkg, options = package_fixture({ installed = false, hold = true })
	local registry = registry_for({ clangd = pkg })
	bootstrap._registry = function()
		return registry
	end
	bootstrap.mason_ready()
	assert(vim.wait(500, function()
		return options.callback ~= nil and bootstrap.mason_busy()
	end))
	local condition = bootstrap.mason_condition(manifest.mason_entry("clangd"))
	assert(condition() == false and condition() == false)
	assert(#notifications == 1, "busy Mason warning was repeated")
	options.callback(true)
	assert(vim.wait(500, function()
		return not bootstrap.mason_busy()
	end))
end)

test("managed manual command honors external tools unless forced", function()
	consume_all_except()
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	bootstrap.setup()
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 2, "manual command is absent offline")
	vim.env.NVIM_CONFIG_OFFLINE = nil
	release_plans.mmdflux = "external"
	vim.cmd("NvimConfigToolsInstall mmdflux")
	assert(#claims == 0 and release_force == false)
	vim.cmd("NvimConfigToolsInstall! mmdflux")
	assert(release_force == true and #claims == 1)
	assert(records["mmdflux@2.6.0"].status == "succeeded")

	consume_all_except()
	release_plans.mmdflux = true
	transition_failure = true
	vim.cmd("NvimConfigToolsInstall! mmdflux")
	assert(release_install_count == 0, "manual download started after state transition failed")
	assert(finish_count == 1 and records["mmdflux@2.6.0"].status == "failed")
end)

vim.env.NVIM_CONFIG_OFFLINE = original_offline
vim.g.vscode = original_vscode
for _, name in ipairs({
	"config.tool_paths",
	"config.tool_state",
	"config.release_installer",
	"config.pager",
	"config.local_config",
	"config.tool_bootstrap",
}) do
	package.loaded[name] = nil
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tool_bootstrap_spec: %d tests passed", count))
vim.cmd("quitall!")
