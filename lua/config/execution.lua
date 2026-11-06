-- Workspace identity for lint/format, test, build and debug execution.
-- Execution is never gated on per-repository trust: every capability is
-- available in every directory. Callers still pass through resolve() so the
-- capability and the exact workspace stay explicit at each spawn boundary.
local repo = require("config.repo")

local M = {}

local CAPABILITIES = {
	["lint-format"] = true,
	test = true,
	build = true,
	debug = true,
}
local CAPABILITY_ORDER = { "lint-format", "test", "build", "debug" }

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

local function canonical_directory(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local real = vim.uv.fs_realpath(path)
	local stat = real and vim.uv.fs_stat(real) or nil
	if stat and stat.type ~= "directory" then
		real = vim.uv.fs_realpath(vim.fs.dirname(real))
		stat = real and vim.uv.fs_stat(real) or nil
	end
	if not stat or stat.type ~= "directory" then
		return nil
	end
	return vim.fs.normalize(real)
end

-- Outside Git the directory that owns the request is the workspace: the
-- explicit root, the buffer's directory, then the current directory.
local function directory_workspace(opts)
	local candidates = {}
	if opts.root ~= nil then
		candidates[#candidates + 1] = opts.root
	else
		local buf = opts.buf or 0
		if type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" and not name:match("^%a[%w+.-]*://") then
				candidates[#candidates + 1] = vim.fs.dirname(name)
			end
		end
		candidates[#candidates + 1] = vim.uv.cwd()
	end
	for _, candidate in ipairs(candidates) do
		local directory = canonical_directory(candidate)
		if directory then
			return { runtime = "host", root = directory, repo_identity = directory }
		end
	end
	return nil, "workspace directory is unavailable"
end

---Resolve the current exact workspace identity.
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
	local root
	if opts.root ~= nil then
		root = repo.root(opts.root)
	else
		root = repo.current_root(opts.buf or 0)
	end
	local canonical = root and vim.uv.fs_realpath(root) or nil
	if canonical and vim.fs.normalize(canonical) == root then
		return { runtime = "host", root = root, repo_identity = root }
	end
	return directory_workspace(opts)
end

---Validate one capability and return the exact workspace it applies to.
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
	return vim.deepcopy(workspace)
end

---Validate a previously captured workspace immediately before spawn.
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
	return true
end

---Run a side-effect-free resolver for one capability. Callers invoke this at
---their last seam before spawning the returned executable.
---@param capability string
---@param resolver function
---@param opts? { buf?: integer, root?: string, workspace?: table }
---@return any resolved
---@return table|string? workspace_or_error
function M.resolve(capability, resolver, opts)
	if type(resolver) ~= "function" then
		return nil, "execution resolver must be a function"
	end
	local workspace, workspace_err = M.check(capability, opts)
	if not workspace then
		return nil, workspace_err
	end
	local called, resolved, resolve_err = xpcall(resolver, debug.traceback)
	if not called then
		return nil, "execution resolver failed: " .. tostring(resolved)
	end
	if resolved == nil or resolved == false then
		return nil, tostring(resolve_err or "execution resource is unavailable")
	end
	return resolved, vim.deepcopy(workspace)
end

M.capabilities = function()
	return vim.deepcopy(CAPABILITY_ORDER)
end

return M
