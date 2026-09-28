-- Host-owned formatting execution boundary. Conform remains responsible for
-- formatter arguments and edits; durable workspace authority and exact tool
-- resolution are checked immediately before its runner builds the command.
local execution = require("config.execution")
local deferred = require("config.deferred")

local M = {}

local TITLE = "Format"
local MAX_MESSAGE_BYTES = 240
local WRAPPER_MARKER = "_nvim_config_verified_format_v1"
local FORMATTERS = {
	["clang-format"] = { tool = "clang-format", command = "clang-format" },
	prettierd = { tool = "prettierd", command = "prettierd" },
	ruff_format = { tool = "ruff", command = "ruff" },
	shfmt = { tool = "shfmt", command = "shfmt" },
	stylua = { tool = "stylua", command = "stylua" },
	tombi = { tool = "tombi", command = "tombi" },
}

local function bounded(message)
	return tostring(message or "formatting failed"):gsub("[%c]", " "):sub(1, MAX_MESSAGE_BYTES)
end

M._notify = function(message, level)
	vim.notify(bounded(message), level, { title = TITLE })
end

local function current_buffer(opts)
	local bufnr = type(opts) == "table" and (opts.bufnr or opts.buf) or 0
	if type(bufnr) ~= "number" or bufnr < 0 then
		return nil, "format buffer must be a non-negative number"
	end
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "format buffer is invalid"
	end
	return bufnr
end

local function exact_path(path, formatter)
	if
		type(path) ~= "string"
		or path == ""
		or path:find("\0", 1, true)
		or path:sub(1, 1) ~= "/"
		or vim.fs.normalize(path) ~= path
	then
		return nil, ("verified resolution for formatter '%s' did not return an exact absolute path"):format(formatter)
	end
	return path
end

---Build a Conform command resolver for one manifest-backed formatter.
---@param formatter string
---@return function
function M.command(formatter)
	local spec = FORMATTERS[formatter]
	assert(spec, "unknown verified formatter: " .. tostring(formatter))
	return function(_, context)
		local bufnr = type(context) == "table" and context.buf or 0
		local path, resolve_err = execution.resolve("lint-format", function()
			return deferred.load("config.tool_bootstrap").resolve(spec.tool, spec.command)
		end, { buf = bufnr })
		if not path then
			error(("Cannot run formatter '%s': %s"):format(formatter, bounded(resolve_err)), 0)
		end
		local resolved, path_err = exact_path(path, formatter)
		if not resolved then
			error(path_err, 0)
		end
		return resolved
	end
end

local function formatter_names(conform, opts, bufnr)
	local names = opts.formatters
	if names == nil then
		if type(conform.list_formatters_for_buffer) ~= "function" then
			return nil, "Conform cannot enumerate configured formatters"
		end
		local called, resolved = pcall(conform.list_formatters_for_buffer, bufnr)
		if not called then
			return nil, "Could not enumerate configured formatters: " .. bounded(resolved)
		end
		names = resolved
	end
	if type(names) ~= "table" or not vim.islist(names) then
		return nil, "formatter selection must be a list"
	end
	for _, name in ipairs(names) do
		if type(name) ~= "string" or not FORMATTERS[name] then
			return nil, "formatter is not manifest-backed: " .. bounded(name)
		end
	end
	return names
end

local function once(callback)
	local called = false
	return function(...)
		if called then
			return
		end
		called = true
		if callback then
			return callback(...)
		end
	end
end

local function copied_options(opts)
	if opts ~= nil and type(opts) ~= "table" then
		return nil, "format options must be a table"
	end
	local copied, value = pcall(vim.deepcopy, opts or {})
	if not copied then
		return nil, "format options could not be copied: " .. bounded(value)
	end
	-- Never allow the compatibility lsp_fallback option to undo this policy.
	value.lsp_format = "never"
	value.lsp_fallback = false
	if value.bufnr == nil and value.buf ~= nil then
		value.bufnr = value.buf
	end
	return value
end

---Install the idempotent guard around Conform's central public API.
---@param conform table
---@return boolean? ok
---@return string? error_message
function M.setup(conform)
	if type(conform) ~= "table" or type(conform.format) ~= "function" then
		return nil, "Conform does not expose its format API"
	end
	if conform[WRAPPER_MARKER] then
		return true
	end
	local original = conform.format
	conform.format = function(opts, callback)
		local done = once(callback)
		local notified = false
		local function reject(message)
			message = bounded(message)
			if not notified then
				notified = true
				pcall(M._notify, message, vim.log.levels.WARN)
			end
			done(message)
			return false
		end

		local safe_opts, copy_err = copied_options(opts)
		if not safe_opts then
			return reject(copy_err)
		end
		local bufnr, buffer_err = current_buffer(safe_opts)
		if not bufnr then
			return reject(buffer_err)
		end
		safe_opts.bufnr = bufnr
		local names, names_err = formatter_names(conform, safe_opts, bufnr)
		if not names then
			return reject(names_err)
		end

		local returned = { pcall(original, safe_opts, done) }
		if not returned[1] then
			return reject("Formatting was blocked before spawn: " .. bounded(returned[2]))
		end
		return unpack(returned, 2)
	end
	conform[WRAPPER_MARKER] = true
	return true
end

local function conform_or_notify(callback)
	local conform = package.loaded.conform
	if type(conform) == "table" and type(conform.format) == "function" then
		return conform
	end
	local message = "Conform is not available; no formatter was run"
	pcall(M._notify, message, vim.log.levels.WARN)
	if callback then
		callback(message)
	end
	return nil
end

function M.on_save(bufnr)
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	return { bufnr = bufnr, timeout_ms = 2000, lsp_format = "never", lsp_fallback = false }
end

function M.format(opts, callback)
	local done = once(callback)
	local conform = conform_or_notify(done)
	if not conform then
		return false
	end
	local safe_opts, copy_err = copied_options(opts)
	if not safe_opts then
		pcall(M._notify, copy_err, vim.log.levels.WARN)
		done(copy_err)
		return false
	end
	return conform.format(safe_opts, done) ~= false
end

return M
