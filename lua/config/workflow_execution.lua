-- Shared host boundary for workflow execution. Requiring this module is
-- observational: verified tool planning stays inside the authorized resolver.
local execution = require("config.execution")
local deferred = require("config.deferred")

local M = {}

local MAX_MESSAGE_BYTES = 240

local function bounded(message)
	return tostring(message or "execution was rejected"):gsub("[%c]", " "):sub(1, MAX_MESSAGE_BYTES)
end

local function canonical_executable(candidate, label)
	label = label or "executable"
	if
		type(candidate) ~= "string"
		or candidate == ""
		or candidate:find("\0", 1, true)
		or candidate:sub(1, 1) ~= "/"
	then
		return nil, label .. " did not resolve to an absolute path"
	end
	local resolved = vim.uv.fs_realpath(candidate)
	if not resolved then
		return nil, label .. " could not be resolved"
	end
	resolved = vim.fs.normalize(resolved)
	local stat = vim.uv.fs_stat(resolved)
	if not stat or stat.type ~= "file" or vim.fn.executable(resolved) ~= 1 then
		return nil, label .. " is not an executable regular file"
	end
	return resolved
end

---Resolve one resource between two durable grant reads.
---@param capability string
---@param resolver function
---@param opts? table
---@return any? resolved
---@return table|string? workspace_or_error
function M.resolve(capability, resolver, opts)
	local called = { pcall(execution.resolve, capability, resolver, opts) }
	if not called[1] then
		return nil, "authority resolution failed: " .. bounded(called[2])
	end
	if called[2] == nil or called[2] == false then
		return nil, bounded(called[3])
	end
	return called[2], called[3]
end

---Require a capability without resolving a managed executable.
---@param capability string
---@param opts? table
---@return boolean? granted
---@return table|string? workspace_or_error
function M.grant(capability, opts)
	return M.resolve(capability, function()
		return true
	end, opts)
end

---Resolve one manifest command only after the first durable grant read.
---@param capability string
---@param tool string
---@param command string
---@param opts? table
---@return string? path
---@return table|string? workspace_or_error
function M.tool(capability, tool, command, opts)
	return M.resolve(capability, function()
		local path, err = deferred.load("config.tool_bootstrap").resolve(tool, command)
		if not path then
			return nil, err
		end
		return canonical_executable(path, command)
	end, opts)
end

---Resolve the current host executable and optionally bind it to an earlier
---canonical observation. The lookup and validation occur inside the grant.
---@param capability string
---@param resolver function
---@param expected? string
---@param opts? table
---@param label? string
---@return string? path
---@return table|string? workspace_or_error
function M.host_executable(capability, resolver, expected, opts, label)
	return M.resolve(capability, function()
		local candidate, err = resolver()
		if not candidate then
			return nil, err
		end
		local path, path_err = canonical_executable(candidate, label)
		if not path then
			return nil, path_err
		end
		if expected ~= nil and path ~= expected then
			return nil, (label or "executable") .. " changed after discovery"
		end
		return path
	end, opts)
end

function M.notify(title, message, level)
	vim.notify(bounded(message), level or vim.log.levels.WARN, { title = title })
end

return M
