vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

require("config.local_plugins").setup()

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p", 448) == 1, "could not create temporary directory")
	return path
end

local function contains(messages, needle)
	for _, message in ipairs(messages) do
		if message:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local original_cwd = vim.fn.getcwd()
local original_config_file = vim.env.NVIM_CONFIG_FILE
local original_state_root = vim.env.NVIM_CONFIG_TRUST_STATE_ROOT
local original_appname = vim.env.NVIM_APPNAME
local original_secure_read = vim.secure.read
local original_notify = vim.notify
local original_local_config = package.loaded["config.local_config"]
local notifications = {}

vim.notify = function(message)
	notifications[#notifications + 1] = tostring(message)
end

test("local_config delegates merge and snapshots while preserving host APIs", function()
	local root = temp_dir()
	local project = vim.fs.joinpath(root, "project")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	local host_path = vim.fs.joinpath(root, "host.lua")
	local project_path = vim.fs.joinpath(project, ".nvim-local.lua")
	assert(vim.fn.writefile({
		"return {",
		"  theme = { background = 'dark', transparent = true },",
		"  clangd = { path = 'host-clangd', profile = 'full' },",
		"  dap = { ui = 'dap-view' },",
		"  mason = { auto_install = false },",
		"  diagram_cache = { max_bytes = 1234 },",
		"  path = { '/host/bin' },",
		"  env = { HOST_ONLY = 'yes' },",
		"  plugins_dir = { '/host/plugins' },",
		"}",
	}, host_path) == 0)
	assert(vim.fn.writefile({
		"return {",
		"  clangd = { path = 'project-clangd', profile = 'light', forbidden = true },",
		"  review = { hunk_context = 9 },",
		"  logs = { max_lines = 77, max_bytes = 2048 },",
		"  theme = { background = 'light' },",
		"  dap = { ui = 'dap-ui' },",
		"  mason = { auto_install = true },",
		"  diagram_cache = { max_bytes = 1 },",
		"  path = { '/project/bin' },",
		"  env = { PROJECT_VALUE = 'must-not-escape' },",
		"  plugins_dir = { '/project/plugins' },",
		"}",
	}, project_path) == 0)

	vim.cmd.cd(vim.fn.fnameescape(project))
	vim.env.NVIM_CONFIG_FILE = host_path
	vim.env.NVIM_CONFIG_TRUST_STATE_ROOT = vim.fs.joinpath(root, "trust-state")
	vim.env.NVIM_APPNAME = nil
	vim.secure.read = function(path)
		return table.concat(vim.fn.readfile(path), "\n")
	end
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local effective = local_config.read()

	equal("project-clangd", effective.clangd.path, "allowed project clangd path did not override host")
	equal("light", effective.clangd.profile, "allowed project clangd profile did not override host")
	equal(9, effective.review.hunk_context, "allowed project review settings were lost")
	equal(77, effective.log_watch.max_lines, "project logs were not handed to the current host API")
	equal("dark", effective.theme.background, "project theme escaped its boundary")
	equal("dap-view", effective.dap.ui, "project DAP setting escaped its boundary")
	equal(false, effective.mason.auto_install, "project Mason setting escaped its boundary")
	equal(1234, effective.diagram_cache.max_bytes, "project diagram cache escaped its boundary")
	equal({ "/host/bin" }, effective.path, "project PATH escaped its boundary")
	equal({ HOST_ONLY = "yes" }, effective.env, "project environment escaped its boundary")
	equal({ "/host/plugins" }, effective.plugins_dir, "project plugin path escaped its boundary")

	local errors = local_config.errors()
	for _, field in ipairs({ "theme", "dap", "mason", "diagram_cache", "path", "env", "plugins_dir" }) do
		assert(
			contains(errors, field .. ": project field is not allowed"),
			"missing project boundary error for " .. field
		)
	end
	assert(contains(errors, "clangd.forbidden: project field is not allowed"), "missing nested clangd error")
	equal("loaded", local_config.sources()[1].status, "host source status changed")
	equal("loaded", local_config.sources()[2].status, "project source status changed")

	effective.clangd.path = "mutated"
	errors[1] = "mutated"
	equal("project-clangd", local_config.read().clangd.path, "read returned the mutable adapter cache")
	assert(local_config.errors()[1] ~= "mutated", "errors returned the mutable adapter cache")
	equal("project-clangd", local_config.get("clangd", {}).path, "get API no longer returns effective values")

	local authority = require("trusted_workspace")
	local status = authority.status()
	equal("applied", status.mode, "secure project source remained pending")
	equal(0, #status.pending, "secure project source retained a pending approval")
	equal("local-config-project", status.applied.validity.provenance["clangd.path"].id, "adapter lost provenance")
	assert(vim.fn.filereadable(vim.fs.joinpath(root, "trust-state", "trusted-workspace.json")) == 1)

	vim.fn.delete(root, "rf")
end)

test("pager mode does not read or execute project Lua", function()
	local root = temp_dir()
	local project = vim.fs.joinpath(root, "project")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	local host_path = vim.fs.joinpath(root, "host.lua")
	assert(vim.fn.writefile({ "return { review = { hunk_context = 4 } }" }, host_path) == 0)
	assert(
		vim.fn.writefile(
			{ "vim.g.trusted_workspace_project_executed = true", "return { review = { hunk_context = 99 } }" },
			vim.fs.joinpath(project, ".nvim-local.lua")
		) == 0
	)

	vim.cmd.cd(vim.fn.fnameescape(project))
	vim.env.NVIM_CONFIG_FILE = host_path
	vim.env.NVIM_CONFIG_TRUST_STATE_ROOT = vim.fs.joinpath(root, "trust-state")
	vim.env.NVIM_APPNAME = "nvimpager"
	vim.g.trusted_workspace_project_executed = nil
	vim.secure.read = function()
		error("project trust flow must not run in pager mode")
	end
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	equal(4, local_config.read().review.hunk_context, "host config was not active in pager mode")
	equal("disabled", local_config.sources()[2].status, "project source was not marked disabled")
	assert(vim.g.trusted_workspace_project_executed == nil, "pager executed project Lua")
	local status = require("trusted_workspace").status()
	equal("host-only", status.profile, "pager did not select host-only authority mode")
	equal(0, #status.pending, "pager exposed a project approval")

	vim.fn.delete(root, "rf")
end)

vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.env.NVIM_CONFIG_FILE = original_config_file
vim.env.NVIM_CONFIG_TRUST_STATE_ROOT = original_state_root
vim.env.NVIM_APPNAME = original_appname
vim.secure.read = original_secure_read
vim.notify = original_notify
package.loaded["config.local_config"] = original_local_config

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("trusted_workspace host spec: %d tests passed"):format(count))
