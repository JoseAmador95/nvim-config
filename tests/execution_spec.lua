vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo_root)
package.path = table.concat({ repo_root .. "/lua/?.lua", repo_root .. "/lua/?/init.lua", package.path }, ";")

local equal = require("tests.helpers").equal

local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local outside = vim.fn.tempname()
assert(vim.fn.mkdir(outside, "p", 448) == 1)
outside = assert(vim.uv.fs_realpath(outside))

local original_repo = package.loaded["config.repo"]
local original_execution = package.loaded["config.execution"]
local original_cwd = vim.fn.getcwd()
local original_env = {
	devcontainer = vim.env.NVIM_DEVCONTAINER,
	runtime = vim.env.NVIM_EXACT_EDITOR_RUNTIME,
	root = vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT,
	identity = vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY,
}

local repository_calls = 0
local inside_repository = true
local function repository_root()
	repository_calls = repository_calls + 1
	if inside_repository then
		return fixture
	end
	return nil, "not inside a Git repository: fixture"
end
package.loaded["config.repo"] = {
	root = repository_root,
	current_root = repository_root,
}
package.loaded["config.execution"] = nil
local execution = require("config.execution")

local function host_environment()
	vim.env.NVIM_DEVCONTAINER = nil
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = nil
	vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = nil
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = nil
	inside_repository = true
end

T["host workspace uses one canonical repository identity"] = function()
	host_environment()
	local workspace = assert(execution.workspace())
	equal({ runtime = "host", root = fixture, repo_identity = fixture }, workspace, "host WorkspaceKey changed")
	workspace.root = "/mutated"
	equal(fixture, assert(execution.workspace()).root, "caller mutated host workspace state")
	assert(repository_calls == 2, "workspace resolution unexpectedly cached the repository root")
end

T["every capability is available without a per-repository grant"] = function()
	host_environment()
	for _, capability in ipairs(execution.capabilities()) do
		local workspace = assert(execution.check(capability))
		equal(fixture, workspace.repo_identity, capability .. " used the wrong WorkspaceKey")
		assert(execution.recheck(workspace, capability), capability .. " recheck failed")
	end
	local workspace, err = execution.check("network")
	assert(not workspace and err:find("capability must be one of", 1, true), "unknown capability was accepted")
	for _, name in ipairs({
		"NvimConfigExecutionAuthorize",
		"NvimConfigExecutionRevoke",
		"NvimConfigExecutionStatus",
	}) do
		assert(vim.fn.exists(":" .. name) == 0, "removed authorization command still exists: " .. name)
	end
	assert(execution.authorize == nil and execution.revoke == nil, "authorization APIs still exist")
end

T["files outside Git use their own directory as the workspace"] = function()
	host_environment()
	inside_repository = false
	local file = vim.fs.joinpath(outside, "notes.lua")
	assert(vim.fn.writefile({ "return {}" }, file) == 0)
	local buf = vim.fn.bufadd(file)
	vim.fn.bufload(buf)
	local workspace = assert(execution.workspace({ buf = buf }))
	equal({ runtime = "host", root = outside, repo_identity = outside }, workspace, "buffer directory was not used")
	equal(outside, assert(execution.workspace({ root = file })).root, "explicit file root was not resolved")
	vim.cmd.cd(vim.fn.fnameescape(outside))
	local scratch = vim.api.nvim_create_buf(false, true)
	equal(outside, assert(execution.workspace({ buf = scratch })).root, "unnamed buffer did not use the cwd")
	vim.cmd.cd(vim.fn.fnameescape(original_cwd))
	vim.api.nvim_buf_delete(scratch, { force = true })
	vim.api.nvim_buf_delete(buf, { force = true })
	host_environment()
end

T["resource resolution runs the resolver exactly once"] = function()
	host_environment()
	local resolver_calls = 0
	local resolved, workspace = execution.resolve("lint-format", function()
		resolver_calls = resolver_calls + 1
		return "/verified/tool"
	end)
	equal("/verified/tool", resolved, "verified resource changed")
	equal(fixture, workspace.repo_identity, "resolution returned the wrong WorkspaceKey")
	assert(resolver_calls == 1, "successful resolver did not run exactly once")

	local missing, err = execution.resolve("lint-format", function()
		resolver_calls = resolver_calls + 1
		return nil, "tool is missing"
	end)
	assert(not missing and err == "tool is missing", "resolver failure was hidden")
	local failed, failure = execution.resolve("lint-format", function()
		error("boom")
	end)
	assert(not failed and failure:find("execution resolver failed", 1, true), "resolver error was hidden")
	assert(resolver_calls == 2, "resolver ran an unexpected number of times")
end

T["container WorkspaceKey requires the complete exact-editor identity"] = function()
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
end

hooks.post_once = function()
	package.loaded["config.repo"] = original_repo
	package.loaded["config.execution"] = original_execution
	vim.env.NVIM_DEVCONTAINER = original_env.devcontainer
	vim.env.NVIM_EXACT_EDITOR_RUNTIME = original_env.runtime
	vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT = original_env.root
	vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY = original_env.identity
	vim.cmd.cd(vim.fn.fnameescape(original_cwd))
	vim.fn.delete(fixture, "rf")
	vim.fn.delete(outside, "rf")
end

return T
