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
		"  plugins = {",
		"    theme_router = { background = 'dark', transparent = true },",
		"    clangd_compile_db = { path = 'host-clangd', profile = 'full' },",
		"    log_workbench = { max_lines = 1000, max_bytes = 4096, continuity_bytes = 32768, max_matches = 5000, scan_lines_per_tick = 250 },",
		"    diagram_view = { cache = { max_bytes = 2 * 1024 * 1024 } },",
		"  },",
		"  dap = { ui = 'dap-view' },",
		"  path = { '/host/bin' },",
		"  env = { HOST_ONLY = 'yes' },",
		"  plugins_dir = { '/host/plugins' },",
		"}",
	}, host_path) == 0)
	assert(vim.fn.writefile({
		"return {",
		"  plugins = {",
		"    clangd_compile_db = { path = 'project-clangd', profile = 'light' },",
		"    native_review = { hunk_context = 9 },",
		"    log_workbench = { max_lines = 77, max_bytes = 2048 },",
		"  },",
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

	equal(
		"project-clangd",
		effective.plugins.clangd_compile_db.path,
		"allowed project clangd path did not override host"
	)
	equal("light", effective.plugins.clangd_compile_db.profile, "allowed project clangd profile did not override host")
	equal(9, effective.plugins.native_review.hunk_context, "allowed project review settings were lost")
	equal(77, effective.plugins.log_workbench.max_lines, "project logs were not handed to the current host API")
	equal(2048, effective.plugins.log_workbench.max_bytes, "project log byte reduction was not applied")
	equal(32768, effective.plugins.log_workbench.continuity_bytes, "project replaced host continuity cost")
	equal(5000, effective.plugins.log_workbench.max_matches, "project replaced host match cap")
	equal(250, effective.plugins.log_workbench.scan_lines_per_tick, "project replaced host scan cost")
	equal("dark", effective.plugins.theme_router.background, "project theme escaped its boundary")
	equal("dap-view", effective.dap.ui, "project DAP setting escaped its boundary")
	equal(2 * 1024 * 1024, effective.plugins.diagram_view.cache.max_bytes, "project diagram cache escaped its boundary")
	equal({ "/host/bin" }, effective.path, "project PATH escaped its boundary")
	equal({ HOST_ONLY = "yes" }, effective.env, "project environment escaped its boundary")
	equal({ "/host/plugins" }, effective.plugins_dir, "project plugin path escaped its boundary")

	local errors = local_config.errors()
	equal({}, errors, "valid canonical project settings produced diagnostics")
	equal("loaded", local_config.sources()[1].status, "host source status changed")
	equal("loaded", local_config.sources()[2].status, "project source status changed")

	effective.plugins.clangd_compile_db.path = "mutated"
	errors[1] = "mutated"
	equal(
		"project-clangd",
		local_config.read().plugins.clangd_compile_db.path,
		"read returned the mutable adapter cache"
	)
	assert(local_config.errors()[1] ~= "mutated", "errors returned the mutable adapter cache")
	equal(
		"project-clangd",
		local_config.plugin("clangd_compile_db").path,
		"plugin API no longer returns effective values"
	)

	local authority = require("trusted_workspace")
	local status = authority.status()
	equal("applied", status.mode, "secure project source remained pending")
	equal(0, #status.pending, "secure project source retained a pending approval")
	equal(
		"local-config-project",
		status.applied.validity.provenance["plugins.clangd_compile_db.path"].id,
		"adapter lost provenance"
	)
	assert(vim.fn.filereadable(vim.fs.joinpath(root, "trust-state", "trusted-workspace.json")) == 1)

	local project_source
	for _, source in ipairs(status.sources) do
		if source.id == "local-config-project" then
			project_source = source
			break
		end
	end
	assert(project_source, "local config project source is missing")
	local authority_path =
		vim.fs.joinpath(repo, "local-plugins", "trusted-workspace.nvim", "lua", "trusted_workspace", "init.lua")
	local external_authority = assert(loadfile(authority_path))()
	assert(external_authority.setup({ state_root = vim.fs.joinpath(root, "trust-state"), mode = "full" }))
	assert(external_authority.revoke_approval(project_source.repo, project_source.id))
	assert(
		external_authority.has_approval(project_source.repo, project_source.id, project_source.fingerprint) == false,
		"second authority instance did not durably revoke local config"
	)

	local authority_approve = authority.approve
	local approval_calls = 0
	authority.approve = function(...)
		approval_calls = approval_calls + 1
		return authority_approve(...)
	end
	local reload_ok, reloaded = xpcall(local_config.reload, debug.traceback)
	authority.approve = authority_approve
	assert(reload_ok, reloaded)
	equal("project-clangd", reloaded.plugins.clangd_compile_db.path, "durable reapproval changed project values")
	equal(1, approval_calls, "local config did not reconcile its durable exact approval")
	assert(
		external_authority.has_approval(project_source.repo, project_source.id, project_source.fingerprint),
		"local config reload did not restore its exact durable approval"
	)

	vim.fn.delete(root, "rf")
end)

test("project local config rejects host-only log indexing controls", function()
	local root = temp_dir()
	local project = vim.fs.joinpath(root, "project")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	local host_path = vim.fs.joinpath(root, "host.lua")
	assert(vim.fn.writefile({
		"return { plugins = { log_workbench = {",
		"  max_lines = 1000, max_bytes = 4096, continuity_bytes = 32768,",
		"  max_matches = 5000, scan_lines_per_tick = 250,",
		"} } }",
	}, host_path) == 0)
	assert(vim.fn.writefile({
		"return { plugins = { log_workbench = { max_lines = 77, max_matches = 1 } } }",
	}, vim.fs.joinpath(project, ".nvim-local.lua")) == 0)

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

	equal(1000, effective.plugins.log_workbench.max_lines, "rejected project source partially reduced log lines")
	equal(5000, effective.plugins.log_workbench.max_matches, "project replaced the host match cap")
	equal(250, effective.plugins.log_workbench.scan_lines_per_tick, "project replaced the host scan budget")
	local errors = table.concat(local_config.errors(), "\n")
	assert(errors:find("project source", 1, true), "project log indexing rejection was not reported")
	assert(errors:find("max_matches", 1, true), "project rejection omitted the forbidden log field")
	equal(0, #require("trusted_workspace").status().pending, "rejected log controls remained pending")

	vim.fn.delete(root, "rf")
end)

test("project local config permits review context only and rejects host-only review controls", function()
	local root = temp_dir()
	local project = vim.fs.joinpath(root, "project")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	local host_path = vim.fs.joinpath(root, "host.lua")
	assert(vim.fn.writefile({
		"return { plugins = { native_review = { hunk_context = 4, max_files = 123, max_file_bytes = 456, max_model_bytes = 789, composer = { style = 'minimal' } } } }",
	}, host_path) == 0)
	assert(vim.fn.writefile({
		"return { plugins = { native_review = { hunk_context = 99, max_files = 1, composer = { style = 'card' } } } }",
	}, vim.fs.joinpath(project, ".nvim-local.lua")) == 0)

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

	equal(4, effective.plugins.native_review.hunk_context, "rejected project source partially changed review context")
	equal(123, effective.plugins.native_review.max_files, "project replaced the host review file limit")
	equal(456, effective.plugins.native_review.max_file_bytes, "project replaced the host per-file review limit")
	equal(789, effective.plugins.native_review.max_model_bytes, "project replaced the host aggregate review limit")
	equal("minimal", effective.plugins.native_review.composer.style, "project replaced the host composer style")
	local errors = table.concat(local_config.errors(), "\n")
	assert(errors:find("project source", 1, true), "project composer rejection was not reported")
	assert(errors:find("native_review", 1, true), "project rejection omitted the forbidden review object")
	assert(
		errors:find("max_files", 1, true) or errors:find("composer", 1, true),
		"project rejection omitted its first forbidden review control"
	)
	equal(0, #require("trusted_workspace").status().pending, "rejected composer remained pending")

	vim.fn.delete(root, "rf")
end)

test("pager mode does not read or execute project Lua", function()
	local root = temp_dir()
	local project = vim.fs.joinpath(root, "project")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	local host_path = vim.fs.joinpath(root, "host.lua")
	assert(vim.fn.writefile({ "return { plugins = { native_review = { hunk_context = 4 } } }" }, host_path) == 0)
	assert(vim.fn.writefile({
		"vim.g.trusted_workspace_project_executed = true",
		"return { plugins = { native_review = { hunk_context = 99 } } }",
	}, vim.fs.joinpath(project, ".nvim-local.lua")) == 0)

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
	equal(4, local_config.plugin("native_review").hunk_context, "host config was not active in pager mode")
	equal("disabled", local_config.sources()[2].status, "project source was not marked disabled")
	assert(vim.g.trusted_workspace_project_executed == nil, "pager executed project Lua")
	local status = require("trusted_workspace").status()
	equal("host-only", status.profile, "pager did not select host-only authority mode")
	equal(0, #status.pending, "pager exposed a project approval")

	vim.fn.delete(root, "rf")
end)

test("project redraw settings reject the complete source without approval", function()
	local root = temp_dir()
	local project = vim.fs.joinpath(root, "project")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	local host_path = vim.fs.joinpath(root, "host.lua")
	assert(vim.fn.writefile({
		"return {",
		"  ui = { redraw_profile = 'low-bandwidth' },",
		"  plugins = { native_review = { hunk_context = 4 } },",
		"}",
	}, host_path) == 0)
	assert(vim.fn.writefile({
		"return {",
		"  ui = { redraw_profile = 'full' },",
		"  plugins = { native_review = { hunk_context = 99 } },",
		"}",
	}, vim.fs.joinpath(project, ".nvim-local.lua")) == 0)

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

	equal("low-bandwidth", effective.ui.redraw_profile, "project UI replaced the host redraw profile")
	equal(4, effective.plugins.native_review.hunk_context, "rejected project source was partially applied")
	local errors = table.concat(local_config.errors(), "\n")
	assert(errors:find("project source:", 1, true), "project UI rejection was not reported")
	assert(errors:find("ui", 1, true), "project UI rejection omitted the forbidden namespace")
	assert(not errors:find("project approval:", 1, true), "rejected project source was sent for approval")
	equal(0, #require("trusted_workspace").status().pending, "rejected project source left a pending approval")

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
