-- Explicit provisioning orchestration. This module is never loaded at startup.
local M = {}

local plugins = require("config.provision_plugins")
local report_store = require("config.provision_report")
local tool_bootstrap = require("config.tool_bootstrap")
local toolchain = require("config.toolchain")
local treesitter = require("config.treesitter_runtime")

local function persist(report)
	local lock_ok = report_store.update_lock(report)
	report_store.write(report)
	return lock_ok
end

function M.initialize()
	return report_store.initialize()
end

function M.fail(code)
	return report_store.fail(code)
end

function M.fail_if_running(code)
	return report_store.fail_if_running(code)
end

function M.provision_plugins(profile, allow_network)
	assert(profile == "editor" or profile == "nvimpager", "invalid runtime profile")
	local report = report_store.load()
	local ok, inventory, changed = plugins.provision({ allow_network = allow_network == true })
	report.profiles[profile].plugins = inventory
	report.changed = report.changed or changed == true
	local lock_ok = persist(report)
	if not lock_ok then
		return report_store.fail("lock-changed")
	end
	if not ok then
		return report_store.fail("plugin-" .. profile)
	end
	return true
end

function M.provision_parsers(profile, allow_network)
	assert(profile == "editor" or profile == "nvimpager", "invalid runtime profile")
	local report = report_store.load()
	local ok, inventory_or_error, changed, failed_inventory = treesitter.provision_exact({
		allow_network = allow_network == true,
		timeout = 300000,
	})
	local inventory = ok and inventory_or_error or failed_inventory
	report.profiles[profile].parsers = inventory or report_store.empty_inventory()
	report.changed = report.changed or changed == true
	local lock_ok = persist(report)
	if not lock_ok then
		return report_store.fail("lock-changed")
	end
	if not ok then
		return report_store.fail("parser-" .. profile)
	end
	return true
end

function M.provision_tools(allow_network)
	local report = report_store.load()
	local ok, inventory, changed, _, error_code = tool_bootstrap.provision_exact({
		allow_network = allow_network == true,
		timeout = 300000,
	})
	if type(inventory) == "table" then
		report.mason = inventory.mason or report.mason
		report.managed_tools = inventory.managed_tools or report.managed_tools
	end
	report.changed = report.changed or changed == true
	local lock_ok = persist(report)
	if not lock_ok then
		return report_store.fail("lock-changed")
	end
	if not ok then
		local code = error_code == "unsupported-platform" and error_code
			or error_code == "mason" and "mason"
			or "managed-tools"
		return report_store.fail(code)
	end
	return true
end

function M.finalize(require_managed)
	local report = report_store.load()
	local exact = report.profiles.editor.plugins.exact == true
		and report.profiles.nvimpager.plugins.exact == true
		and report.profiles.editor.parsers.exact == true
		and report.profiles.nvimpager.parsers.exact == true
		and report.mason.exact == true
	for _, name in ipairs(toolchain.managed_order) do
		local item = report.managed_tools[name]
		exact = exact and type(item) == "table" and item.exact == true
		if require_managed and item and item.shadowed == true then
			report_store.write(report)
			return report_store.fail("strict-managed")
		end
	end
	if not persist(report) then
		return report_store.fail("lock-changed")
	end
	if not exact then
		return report_store.fail("verification")
	end
	report.status = "ok"
	report.error_codes = {}
	report_store.write(report)
	return true
end

M.contract_version = report_store.contract_version
M._json_encode = report_store.json_encode
M._plugin_inventory = plugins.inventory
M._checkout = plugins.checkout

return M
