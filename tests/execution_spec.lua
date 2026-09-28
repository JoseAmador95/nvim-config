vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo_root)
package.path = table.concat({ repo_root .. "/lua/?.lua", repo_root .. "/lua/?/init.lua", package.path }, ";")

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
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
fixture = assert(vim.uv.fs_realpath(fixture))

local original_authority = package.loaded.trusted_workspace
local original_repo = package.loaded["config.repo"]
local original_execution = package.loaded["config.execution"]
local original_notify = vim.notify
local original_env = {
	devcontainer = vim.env.NVIM_DEVCONTAINER,
	runtime = vim.env.NVIM_EXACT_EDITOR_RUNTIME,
	root = vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT,
	identity = vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY,
}

local grants = {}
local reads = {}
local mutations = {}
local grant_error
package.loaded.trusted_workspace = {
	has_grant = function(identity, capability)
		reads[#reads + 1] = { identity, capability }
		if grant_error then
			return nil, grant_error
		end
		return grants[identity .. "\0" .. capability] == true
	end,
	authorize = function(identity, capability)
		mutations[#mutations + 1] = { "authorize", identity, capability }
		grants[identity .. "\0" .. capability] = true
		return true
	end,
	revoke = function(identity, capability)
		mutations[#mutations + 1] = { "revoke", identity, capability }
		grants[identity .. "\0" .. capability] = nil
		return true
	end,
}
local repository_calls = 0
package.loaded["config.repo"] = {
	root = function()
		repository_calls = repository_calls + 1
		return fixture
	end,
	current_root = function()
		repository_calls = repository_calls + 1
		return fixture
	end,
}
package.loaded["config.execution"] = nil
local execution = require("config.execution")

local function host_environment()
	vim.env.NVIM_DEVCONTAINER = nil
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = nil
	vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = nil
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = nil
end

test("host workspace uses one canonical repository identity", function()
	host_environment()
	local workspace = assert(execution.workspace())
	equal({ runtime = "host", root = fixture, repo_identity = fixture }, workspace, "host WorkspaceKey changed")
	workspace.root = "/mutated"
	equal(fixture, assert(execution.workspace()).root, "caller mutated host workspace state")
	assert(repository_calls == 2, "workspace resolution unexpectedly cached repository authority")
end)

test("grant checks reread durable authority and distinguish denial from corruption", function()
	host_environment()
	reads = {}
	local workspace, err = execution.check("build")
	assert(not workspace and err:find("not authorized", 1, true), "missing grant was accepted")
	grants[fixture .. "\0build"] = true
	workspace = assert(execution.check("build"))
	equal({ fixture, "build" }, reads[#reads], "grant used the wrong durable key")
	grants[fixture .. "\0build"] = nil
	local ok, recheck_err = execution.recheck(workspace, "build")
	assert(not ok and recheck_err:find("not authorized", 1, true), "revoked grant survived a recheck")
	grant_error = "state file permissions changed"
	workspace, err = execution.check("test")
	assert(not workspace and err:find("could not verify durable", 1, true), "authority read error became denial")
	grant_error = nil
	assert(#reads == 4, "durable grant checks were cached")
end)

test("resource resolution is bracketed by durable authority reads", function()
	host_environment()
	local key = fixture .. "\0lint-format"
	local resolver_calls = 0
	grants[key] = nil
	local resolved, err = execution.resolve("lint-format", function()
		resolver_calls = resolver_calls + 1
		return "/verified/tool"
	end)
	assert(not resolved and err:find("not authorized", 1, true), "denied resolution was accepted")
	assert(resolver_calls == 0, "resolver ran before initial authority")

	grants[key] = true
	resolved, err = execution.resolve("lint-format", function()
		resolver_calls = resolver_calls + 1
		grants[key] = nil
		return "/verified/tool"
	end)
	assert(not resolved and err:find("not authorized", 1, true), "mid-resolution revocation was ignored")
	assert(resolver_calls == 1, "resolver did not run exactly once")

	grants[key] = true
	local workspace
	resolved, workspace = execution.resolve("lint-format", function()
		resolver_calls = resolver_calls + 1
		return "/verified/tool"
	end)
	equal("/verified/tool", resolved, "verified resource changed")
	equal(fixture, workspace.repo_identity, "resolution returned the wrong WorkspaceKey")
	assert(resolver_calls == 2, "successful resolver did not run exactly once")
end)

test("container WorkspaceKey requires the complete exact-editor identity", function()
	vim.env.NVIM_DEVCONTAINER = "1"
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = "container"
	vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = "/workspaces/example"
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = "/host/example"
	local calls_before = repository_calls
	local workspace = assert(execution.workspace())
	equal(
		{ runtime = "container", root = "/workspaces/example", repo_identity = "/host/example" },
		workspace,
		"container WorkspaceKey changed"
	)
	assert(repository_calls == calls_before, "container identity fell back to host Git discovery")
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = ""
	local missing, err = execution.workspace()
	assert(not missing and err:find("repo_identity", 1, true), "incomplete container identity was accepted")
	host_environment()
end)

test("public mutation and status APIs use exact capabilities and fresh reads", function()
	host_environment()
	assert(not execution.authorize("network"), "unknown capability was accepted")
	local workspace = assert(execution.authorize("debug"))
	equal({ "authorize", fixture, "debug" }, mutations[#mutations], "authorize used the wrong key")
	local state = assert(execution.status("debug"))
	assert(state.grants.debug and state.grants.build == nil, "filtered status exposed the wrong grants")
	state.grants.debug = false
	assert(assert(execution.status("debug")).grants.debug, "status leaked mutable grant state")
	assert(execution.revoke("debug"))
	equal({ "revoke", fixture, "debug" }, mutations[#mutations], "revoke used the wrong key")
	assert(not assert(execution.status("debug")).grants.debug, "revoked grant remained visible")
end)

test("commands expose only explicit authorization mutations", function()
	host_environment()
	local notifications = {}
	vim.notify = function(message, level)
		notifications[#notifications + 1] = { message = tostring(message), level = level }
	end
	execution.setup()
	for _, name in ipairs({
		"NvimConfigExecutionAuthorize",
		"NvimConfigExecutionRevoke",
		"NvimConfigExecutionStatus",
	}) do
		assert(vim.fn.exists(":" .. name) == 2, "missing execution command " .. name)
	end
	vim.cmd("NvimConfigExecutionAuthorize lint-format")
	assert(grants[fixture .. "\0lint-format"], "authorize command did not persist its grant")
	vim.cmd("NvimConfigExecutionStatus lint-format")
	assert(notifications[#notifications].message:find("lint%-format: authorized"), "status command hid authority")
	vim.cmd("NvimConfigExecutionRevoke lint-format")
	assert(not grants[fixture .. "\0lint-format"], "revoke command retained its grant")
	execution._reset_for_tests()
end)

vim.notify = original_notify
package.loaded.trusted_workspace = original_authority
package.loaded["config.repo"] = original_repo
package.loaded["config.execution"] = original_execution
vim.env.NVIM_DEVCONTAINER = original_env.devcontainer
vim.env.NVIM_EXACT_EDITOR_RUNTIME = original_env.runtime
vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = original_env.root
vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = original_env.identity
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("execution_spec: %d tests passed"):format(count))
