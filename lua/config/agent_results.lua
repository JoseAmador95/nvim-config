-- Strict importer for the canonical nvim-review agent result interchange.
local M = {}

local MAX_BYTES = 1024 * 1024
local MAX_ITEMS = 2000
local MAX_RUN_ID = 256
local MAX_MESSAGE = 16 * 1024
local MAX_SOURCE = 256
local MAX_PATH = 4096

local ROOT_KEYS = { version = true, repo_root = true, run_id = true, items = true }
local ITEM_KEYS = { path = true, start = true, ["end"] = true, severity = true, message = true, source = true }
local POSITION_KEYS = { line = true, column = true }
local TYPES = { blocker = "E", warning = "W", nit = "I" }

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Agent results" })
end

local function object(value)
	return type(value) == "table" and not vim.islist(value)
end

local function exact_keys(value, allowed, label)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, string.format("%s contains unknown key %s", label, vim.inspect(key))
		end
	end
	return true
end

local function valid_utf8(value)
	return pcall(vim.str_utfindex, value)
end

local function bounded_string(value, maximum, label)
	if type(value) ~= "string" or value == "" then
		return nil, label .. " must be a non-empty string"
	end
	if value:find("\0", 1, true) then
		return nil, label .. " contains a NUL byte"
	end
	if not valid_utf8(value) then
		return nil, label .. " is not valid UTF-8"
	end
	if #value > maximum then
		return nil, string.format("%s exceeds %d bytes", label, maximum)
	end
	return true
end

local function positive_integer(value, label)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		return nil, label .. " must be a positive integer"
	end
	return true
end

local function position(value, label)
	if not object(value) then
		return nil, label .. " must be an object"
	end
	local keys_ok, keys_err = exact_keys(value, POSITION_KEYS, label)
	if not keys_ok then
		return nil, keys_err
	end
	local line_ok, line_err = positive_integer(value.line, label .. ".line")
	if not line_ok then
		return nil, line_err
	end
	if value.column ~= nil then
		local column_ok, column_err = positive_integer(value.column, label .. ".column")
		if not column_ok then
			return nil, column_err
		end
	end
	return true
end

local function validate_item(item, index, root)
	local label = "items[" .. index .. "]"
	if not object(item) then
		return nil, label .. " must be an object"
	end
	local keys_ok, keys_err = exact_keys(item, ITEM_KEYS, label)
	if not keys_ok then
		return nil, keys_err
	end
	for _, key in ipairs({ "path", "start", "end", "severity", "message", "source" }) do
		if item[key] == nil then
			return nil, label .. " is missing " .. key
		end
	end
	local path_ok, path_err = bounded_string(item.path, MAX_PATH, label .. ".path")
	if not path_ok then
		return nil, path_err
	end
	local absolute, resolve_err = require("config.repo").resolve_relative(root, item.path)
	if not absolute then
		return nil, label .. ".path " .. resolve_err
	end
	local start_ok, start_err = position(item.start, label .. ".start")
	if not start_ok then
		return nil, start_err
	end
	local end_ok, end_err = position(item["end"], label .. ".end")
	if not end_ok then
		return nil, end_err
	end
	if
		item["end"].line < item.start.line
		or (
			item["end"].line == item.start.line
			and item["end"].column ~= nil
			and item.start.column ~= nil
			and item["end"].column < item.start.column
		)
	then
		return nil, label .. ".end is before start"
	end
	if not TYPES[item.severity] then
		return nil, label .. ".severity must be blocker, warning, or nit"
	end
	local message_ok, message_err = bounded_string(item.message, MAX_MESSAGE, label .. ".message")
	if not message_ok then
		return nil, message_err
	end
	local source_ok, source_err = bounded_string(item.source, MAX_SOURCE, label .. ".source")
	if not source_ok then
		return nil, source_err
	end
	return {
		filename = absolute,
		lnum = item.start.line,
		col = item.start.column or 0,
		end_lnum = item["end"].line,
		end_col = item["end"].column or 0,
		type = TYPES[item.severity],
		text = item.message,
		module = item.source,
	}
end

function M.validate(encoded, current_root)
	if type(encoded) ~= "string" then
		return nil, "input must be a JSON string"
	end
	if #encoded > MAX_BYTES then
		return nil, string.format("input is %d bytes; maximum is %d", #encoded, MAX_BYTES)
	end
	if not valid_utf8(encoded) then
		return nil, "input is not valid UTF-8"
	end
	local ok, value = pcall(vim.json.decode, encoded)
	if not ok or not object(value) then
		return nil, "input must be one JSON object"
	end
	local keys_ok, keys_err = exact_keys(value, ROOT_KEYS, "result")
	if not keys_ok then
		return nil, keys_err
	end
	for _, key in ipairs({ "version", "repo_root", "run_id", "items" }) do
		if value[key] == nil then
			return nil, "result is missing " .. key
		end
	end
	if value.version ~= 1 then
		return nil, "version must equal 1"
	end
	if value.repo_root ~= current_root then
		return nil, "repo_root must exactly equal the current canonical Git root"
	end
	local run_ok, run_err = bounded_string(value.run_id, MAX_RUN_ID, "run_id")
	if not run_ok then
		return nil, run_err
	end
	if type(value.items) ~= "table" or not vim.islist(value.items) then
		return nil, "items must be an array"
	end
	if #value.items > MAX_ITEMS then
		return nil, string.format("items contains %d entries; maximum is %d", #value.items, MAX_ITEMS)
	end
	local quickfix = {}
	for index, item in ipairs(value.items) do
		local converted, item_err = validate_item(item, index, current_root)
		if not converted then
			return nil, item_err
		end
		quickfix[#quickfix + 1] = converted
	end
	return { run_id = value.run_id, items = quickfix }
end

function M.import(encoded, dependencies)
	local deps = dependencies or {}
	local report = deps.notify or notify
	local root, root_err = (deps.current_root or require("config.repo").current_root)(0)
	if not root then
		report("Import rejected: " .. root_err, vim.log.levels.ERROR)
		return nil
	end
	local result, validation_err = M.validate(encoded, root)
	if not result then
		report("Import rejected: " .. validation_err, vim.log.levels.ERROR)
		return nil
	end
	local setqflist = deps.setqflist or vim.fn.setqflist
	setqflist({}, " ", { title = "Agent results: " .. result.run_id, items = result.items })
	if deps.open_trouble then
		deps.open_trouble()
	else
		vim.cmd("Trouble qflist open")
	end
	report(string.format("Imported %d agent result(s)", #result.items), vim.log.levels.INFO)
	return result
end

function M.setup()
	vim.api.nvim_create_user_command("AgentResultsImport", function(opts)
		M.import(opts.args)
	end, { nargs = "+", desc = "Import strict agent-result JSON into Trouble quickfix" })
end

M.max_bytes = MAX_BYTES
M.max_items = MAX_ITEMS

return M
