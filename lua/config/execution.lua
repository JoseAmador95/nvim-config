-- Host-owned workspace execution authority. This module never installs tools,
-- prompts implicitly, or treats cached UI state as authorization.
local authority = require("trusted_workspace")
local repo = require("config.repo")

local M = {}

local TITLE = "Workspace execution"
local CAPABILITIES = {
	["lint-format"] = true,
	test = true,
	build = true,
	debug = true,
}
local CAPABILITY_ORDER = { "lint-format", "test", "build", "debug" }
local COMMANDS = {
	"NvimConfigExecutionAuthorize",
	"NvimConfigExecutionRevoke",
	"NvimConfigExecutionStatus",
}

local function notify(message, level)
	vim.notify(tostring(message), level or vim.log.levels.INFO, { title = TITLE })
end

local function exact_capability(value)
	if type(value) ~= "string" or not CAPABILITIES[value] then
		return nil, "capability must be one of lint-format, test, build, debug"
	end
	return value
end

local function absolute_normalized(value, label)
	if
		type(value) ~= "string"
		or value == ""
		or value:find("\0", 1, true)
		or value:sub(1, 1) ~= "/"
		or vim.fs.normalize(value) ~= value
	then
		return nil, label .. " must be one normalized absolute path"
	end
	return value
end

local function validate_workspace(value)
	if
		type(value) ~= "table"
		or vim.islist(value)
		or type(value.runtime) ~= "string"
		or (value.runtime ~= "host" and value.runtime ~= "container")
	then
		return nil, "WorkspaceKey is invalid"
	end
	for key in pairs(value) do
		if key ~= "runtime" and key ~= "root" and key ~= "repo_identity" then
			return nil, "WorkspaceKey contains an unknown field"
		end
	end
	local root, root_err = absolute_normalized(value.root, "WorkspaceKey.root")
	if not root then
		return nil, root_err
	end
	local identity, identity_err = absolute_normalized(value.repo_identity, "WorkspaceKey.repo_identity")
	if not identity then
		return nil, identity_err
	end
	return { runtime = value.runtime, root = root, repo_identity = identity }
end

local function container_workspace()
	local runtime = vim.env.NVIM_EXACT_EDITOR_RUNTIME
	if vim.env.NVIM_DEVCONTAINER ~= "1" and runtime ~= "container" then
		return nil
	end
	if vim.env.NVIM_DEVCONTAINER ~= "1" or runtime ~= "container" then
		return nil, "Dev Container execution identity is incomplete"
	end
	return validate_workspace({
		runtime = "container",
		root = vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT or vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT,
		repo_identity = vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY or vim.env.NVIM_DEVCONTAINER_HOST_ROOT,
	})
end

---Resolve the current exact workspace identity without caching authority.
---@param opts? { buf?: integer, root?: string, workspace?: table }
---@return table? workspace
---@return string? error_message
function M.workspace(opts)
	opts = opts or {}
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "workspace options must be an object"
	end
	for key in pairs(opts) do
		if key ~= "buf" and key ~= "root" and key ~= "workspace" then
			return nil, "workspace options contain an unknown field"
		end
	end
	if opts.workspace ~= nil then
		if opts.buf ~= nil or opts.root ~= nil then
			return nil, "an exact WorkspaceKey cannot be combined with buf or root"
		end
		return validate_workspace(opts.workspace)
	end
	local container, container_err = container_workspace()
	if container or container_err then
		return container, container_err
	end
	local root, root_err
	if opts.root ~= nil then
		root, root_err = repo.root(opts.root)
	else
		root, root_err = repo.current_root(opts.buf or 0)
	end
	if not root then
		return nil, root_err or "workspace is not inside a Git repository"
	end
	local canonical = vim.uv.fs_realpath(root)
	if not canonical or vim.fs.normalize(canonical) ~= root then
		return nil, "repository root is not canonical"
	end
	return { runtime = "host", root = root, repo_identity = root }
end

local function durable_grant(workspace, capability)
	local granted, err = authority.has_grant(workspace.repo_identity, capability)
	if granted == nil then
		return nil, "could not verify durable workspace authority: " .. tostring(err)
	end
	if granted ~= true then
		return nil,
			("workspace is not authorized for %s; run :NvimConfigExecutionAuthorize %s"):format(capability, capability)
	end
	return true
end

---Check one durable grant and return the exact WorkspaceKey it authorized.
---@param capability string
---@param opts? { buf?: integer, root?: string, workspace?: table }
---@return table? workspace
---@return string? error_message
function M.check(capability, opts)
	local requested, capability_err = exact_capability(capability)
	if not requested then
		return nil, capability_err
	end
	local workspace, workspace_err = M.workspace(opts)
	if not workspace then
		return nil, workspace_err
	end
	local granted, grant_err = durable_grant(workspace, requested)
	if not granted then
		return nil, grant_err
	end
	return vim.deepcopy(workspace)
end

---Re-read authority for the same captured workspace immediately before spawn.
---@param workspace table
---@param capability string
---@return boolean? ok
---@return string? error_message
function M.recheck(workspace, capability)
	local requested, capability_err = exact_capability(capability)
	if not requested then
		return nil, capability_err
	end
	local exact, workspace_err = validate_workspace(workspace)
	if not exact then
		return nil, workspace_err
	end
	return durable_grant(exact, requested)
end

---Run a side-effect-free resolver between two durable grant reads. Callers
---must invoke this at their last seam before spawning the returned executable.
---@param capability string
---@param resolver function
---@param opts? { buf?: integer, root?: string, workspace?: table }
---@return any resolved
---@return table|string? workspace_or_error
function M.resolve(capability, resolver, opts)
	if type(resolver) ~= "function" then
		return nil, "execution resolver must be a function"
	end
	local workspace, authority_err = M.check(capability, opts)
	if not workspace then
		return nil, authority_err
	end
	local called, resolved, resolve_err = xpcall(resolver, debug.traceback)
	if not called then
		return nil, "execution resolver failed: " .. tostring(resolved)
	end
	if resolved == nil or resolved == false then
		return nil, tostring(resolve_err or "execution resource is unavailable")
	end
	local current, recheck_err = M.recheck(workspace, capability)
	if not current then
		return nil, recheck_err
	end
	return resolved, vim.deepcopy(workspace)
end

function M.authorize(capability, opts)
	local requested, capability_err = exact_capability(capability)
	if not requested then
		return nil, capability_err
	end
	local workspace, workspace_err = M.workspace(opts)
	if not workspace then
		return nil, workspace_err
	end
	local ok, err = authority.authorize(workspace.repo_identity, requested)
	if not ok then
		return nil, err
	end
	return vim.deepcopy(workspace)
end

function M.revoke(capability, opts)
	local requested, capability_err = exact_capability(capability)
	if not requested then
		return nil, capability_err
	end
	local workspace, workspace_err = M.workspace(opts)
	if not workspace then
		return nil, workspace_err
	end
	local ok, err = authority.revoke(workspace.repo_identity, requested)
	if not ok then
		return nil, err
	end
	return vim.deepcopy(workspace)
end

function M.status(capability, opts)
	if capability ~= nil and capability ~= "" then
		local requested, capability_err = exact_capability(capability)
		if not requested then
			return nil, capability_err
		end
		capability = requested
	end
	local workspace, workspace_err = M.workspace(opts)
	if not workspace then
		return nil, workspace_err
	end
	local grants = {}
	for _, candidate in ipairs(CAPABILITY_ORDER) do
		if capability == nil or capability == "" or candidate == capability then
			local granted, err = authority.has_grant(workspace.repo_identity, candidate)
			if granted == nil then
				return nil, "could not read durable workspace authority: " .. tostring(err)
			end
			grants[candidate] = granted == true
		end
	end
	return { workspace = vim.deepcopy(workspace), grants = grants }
end

local function completion(prefix)
	local values = {}
	for _, capability in ipairs(CAPABILITY_ORDER) do
		if vim.startswith(capability, prefix) then
			values[#values + 1] = capability
		end
	end
	return values
end

local function report_mutation(action, capability, callback)
	local workspace, err = callback(capability)
	if not workspace then
		notify(err, vim.log.levels.ERROR)
		return
	end
	notify(("%s %s for %s"):format(action, capability, workspace.repo_identity))
end

function M.setup()
	vim.api.nvim_create_user_command("NvimConfigExecutionAuthorize", function(options)
		report_mutation("Authorized", options.args, M.authorize)
	end, {
		nargs = 1,
		complete = completion,
		desc = "Authorize one execution capability for the current repository",
		force = true,
	})
	vim.api.nvim_create_user_command("NvimConfigExecutionRevoke", function(options)
		report_mutation("Revoked", options.args, M.revoke)
	end, {
		nargs = 1,
		complete = completion,
		desc = "Revoke one execution capability for the current repository",
		force = true,
	})
	vim.api.nvim_create_user_command("NvimConfigExecutionStatus", function(options)
		local state, err = M.status(options.args ~= "" and options.args or nil)
		if not state then
			notify(err, vim.log.levels.ERROR)
			return
		end
		local rows = { state.workspace.runtime .. " · " .. state.workspace.repo_identity }
		for _, capability in ipairs(CAPABILITY_ORDER) do
			if state.grants[capability] ~= nil then
				rows[#rows + 1] = ("%s: %s"):format(capability, state.grants[capability] and "authorized" or "blocked")
			end
		end
		notify(table.concat(rows, "\n"))
	end, {
		nargs = "?",
		complete = completion,
		desc = "Read durable execution authority for the current repository",
		force = true,
	})
	return true
end

function M._reset_for_tests()
	for _, command in ipairs(COMMANDS) do
		pcall(vim.api.nvim_del_user_command, command)
	end
end

M.capabilities = function()
	return vim.deepcopy(CAPABILITY_ORDER)
end

return M
