-- Last-mile LSP process boundary. Managed server paths are resolved from a
-- durable verified-tools record immediately before vim.lsp.rpc starts them.
-- Requiring this module is observational: it does not resolve or probe tools.
local M = {}

local deferred = require("config.deferred")
local rust_tools = require("config.rust_tools")

local MAX_ERROR_BYTES = 240
local reported = {}

M._resolve = function(tool, command)
	return deferred.load("config.tool_bootstrap").resolve(tool, command)
end
M._rust_analyzer = function()
	return rust_tools.rust_analyzer()
end
M._notify = function(message, level)
	vim.notify(message, level, { title = "LSP" })
end

local function bounded(message)
	return tostring(message or "unavailable"):gsub("[%c]", " "):sub(1, MAX_ERROR_BYTES)
end

local function exact_absolute(path, label)
	if
		type(path) ~= "string"
		or path == ""
		or path:find("\0", 1, true)
		or path:sub(1, 1) ~= "/"
		or vim.fs.normalize(path) ~= path
	then
		return nil, label .. " did not resolve to one normalized absolute path"
	end
	return path
end

local function rpc_options(config)
	return {
		cwd = config and config.cmd_cwd or nil,
		env = config and config.cmd_env or nil,
		detached = config and config.detached or nil,
	}
end

local function start(argv, dispatchers, config)
	return vim.lsp.rpc.start(argv, dispatchers, rpc_options(config))
end

local function resolve_managed(binding)
	local path, resolve_err = M._resolve(binding.package, binding.command)
	if not path then
		return nil, ("Cannot start LSP '%s': %s"):format(binding.name, bounded(resolve_err))
	end
	return exact_absolute(path, binding.name)
end

local function resolve_external_rust(binding)
	local path = M._rust_analyzer()
	if not path then
		return nil, "Cannot start LSP 'rust_analyzer': rust-analyzer is absent from the explicit host/user PATH"
	end
	return exact_absolute(path, binding.name)
end

function M.available(binding)
	if binding.package then
		return resolve_managed(binding)
	end
	if binding.name == "rust_analyzer" then
		return resolve_external_rust(binding)
	end
	return nil, "LSP server has no executable authority"
end

---Gate native autoactivation before Neovim constructs a client. The command
---function resolves again at the actual RPC seam, closing changes between the
---root decision and spawn without letting ordinary absence abort FileType.
function M.wrap_root_dir(binding, upstream)
	return function(bufnr, on_dir)
		local path, available_err = M.available(binding)
		if not path then
			-- rust_tools owns the richer one-shot edit-only guidance for Rust.
			if binding.name ~= "rust_analyzer" and reported[binding.name] ~= available_err then
				reported[binding.name] = available_err
				M._notify(available_err, vim.log.levels.WARN)
			end
			return
		end
		reported[binding.name] = nil
		return upstream(bufnr, on_dir)
	end
end

---Start one manifest-backed language server from its attested absolute path.
---@param binding { name: string, package: string, command: string, args?: string[] }
---@param dispatchers table
---@param config table?
---@param extra_args? string[]
---@param expected_path? string
---@return table
function M.managed_start(binding, dispatchers, config, extra_args, expected_path)
	local resolved, path_err = resolve_managed(binding)
	if not resolved then
		error(path_err, 0)
	end
	if expected_path ~= nil and expected_path ~= binding.command then
		local expanded = vim.fs.normalize(vim.fn.expand(expected_path))
		local canonical = vim.uv.fs_realpath(expanded) or expanded
		if canonical ~= resolved then
			error(
				("Cannot start LSP '%s': configured path does not match the attested executable"):format(binding.name),
				0
			)
		end
	end
	local argv = { resolved }
	vim.list_extend(argv, vim.deepcopy(extra_args or binding.args or {}))
	return start(argv, dispatchers, config)
end

---Start the deliberate host/user rust-analyzer exception. tool_paths excludes
---managed, Mason and verified-shim roots, so this can never silently fall back
---to an unattested Mason installation.
function M.external_rust_start(binding, dispatchers, config)
	local resolved, path_err = resolve_external_rust(binding)
	if not resolved then
		error(path_err, 0)
	end
	local argv = { resolved }
	vim.list_extend(argv, vim.deepcopy(binding.args or {}))
	return start(argv, dispatchers, config)
end

function M._reset_for_tests()
	reported = {}
end

return M
