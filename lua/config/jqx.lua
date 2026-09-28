-- Safe host replacement for nvim-jqx's shell-string execution. Every jq
-- invocation uses the absolute path from verified-tools and argv/stdin rather
-- than PATH lookup or shell interpolation.
local M = {}

local deferred = require("config.deferred")

local MAX_INPUT_BYTES = 16 * 1024 * 1024
local MAX_OUTPUT_BYTES = 16 * 1024 * 1024
local MAX_LIST_ITEMS = 4096
local MAX_RESULT_LINES = 4096
local STALE_MESSAGE = "JSON buffer changed while JQX was using its snapshot; results were discarded"
local TYPES = { array = true, boolean = true, null = true, number = true, object = true, string = true }
local upstream_config
local upstream_attempted = false

M._notify = function(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "JQX" })
end
M._resolve = function()
	return deferred.load("config.tool_bootstrap").resolve("jq", "jq")
end
M._system = function(argv, options, callback)
	return vim.system(argv, options, callback)
end

local function bounded(message)
	return tostring(message or "jq failed"):gsub("[%c]", " "):sub(1, 240)
end

local function exact_path(path)
	if
		type(path) ~= "string"
		or path == ""
		or path:find("\0", 1, true)
		or path:sub(1, 1) ~= "/"
		or vim.fs.normalize(path) ~= path
	then
		return nil, "verified jq resolution did not return one normalized absolute path"
	end
	return path
end

local function buffer_measurement(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return nil, "JSON buffer is no longer loaded"
	end
	local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local eol = vim.bo[bufnr].eol
	local measured, total = pcall(vim.api.nvim_buf_get_offset, bufnr, line_count)
	if not measured or type(total) ~= "number" or total < 0 then
		return nil, "JSON buffer size could not be measured"
	end
	-- nvim_buf_get_offset() includes the final EOL when 'eol' is set, while
	-- table.concat(lines, "\n") below does not append one after the last line.
	local input_bytes = math.max(0, total - (eol and 1 or 0))
	return {
		changedtick = changedtick,
		line_count = line_count,
		eol = eol,
		input_bytes = input_bytes,
	}
end

local function measurement_is_current(bufnr, measurement)
	return vim.api.nvim_buf_is_valid(bufnr)
		and vim.api.nvim_buf_is_loaded(bufnr)
		and vim.api.nvim_buf_get_changedtick(bufnr) == measurement.changedtick
		and vim.api.nvim_buf_line_count(bufnr) == measurement.line_count
		and vim.bo[bufnr].eol == measurement.eol
end

local function snapshot()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].filetype ~= "json" then
		return nil, "JQX is available only for JSON buffers; verified yq is not configured"
	end
	local measurement, measurement_err = buffer_measurement(bufnr)
	if not measurement then
		return nil, measurement_err
	end
	if measurement.input_bytes > MAX_INPUT_BYTES then
		return nil, ("JSON buffer exceeds the %d-byte JQX limit"):format(MAX_INPUT_BYTES)
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not measurement_is_current(bufnr, measurement) then
		return nil, "JSON buffer changed while it was being captured"
	end
	local input = table.concat(lines, "\n")
	if #input > MAX_INPUT_BYTES then
		return nil, ("JSON buffer exceeds the %d-byte JQX limit"):format(MAX_INPUT_BYTES)
	end
	return {
		bufnr = bufnr,
		winid = vim.api.nvim_get_current_win(),
		changedtick = measurement.changedtick,
		input = input,
		lines = lines,
	}
end

local function current(snapshot_value)
	return vim.api.nvim_buf_is_valid(snapshot_value.bufnr)
		and vim.api.nvim_buf_get_changedtick(snapshot_value.bufnr) == snapshot_value.changedtick
end

local function revalidate(snapshot_value)
	if current(snapshot_value) then
		return true
	end
	M._notify(STALE_MESSAGE, vim.log.levels.WARN)
	return nil, STALE_MESSAGE
end

local function run(arguments, input, callback, before_spawn)
	local path, resolve_err = M._resolve()
	if not path then
		local message = "jq is unavailable: " .. bounded(resolve_err)
		M._notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	local resolved, path_err = exact_path(path)
	if not resolved then
		M._notify(path_err, vim.log.levels.ERROR)
		return nil, path_err
	end
	if before_spawn then
		local valid, validation_err = before_spawn()
		if not valid then
			return nil, validation_err
		end
	end
	local argv = { resolved }
	vim.list_extend(argv, arguments)
	local stdout = {}
	local stderr = {}
	local output_bytes = 0
	local overflow = false
	local stream_error
	local process
	local function collect(target, err, data)
		if err and not stream_error then
			stream_error = tostring(err)
		end
		if not data or overflow then
			return
		end
		output_bytes = output_bytes + #data
		if output_bytes > MAX_OUTPUT_BYTES then
			overflow = true
			if process and type(process.kill) == "function" then
				pcall(process.kill, process, 15)
			end
			return
		end
		target[#target + 1] = data
	end
	local on_exit = vim.schedule_wrap(function(result)
		result = type(result) == "table" and result or {}
		result.stdout = table.concat(stdout)
		result.stderr = table.concat(stderr)
		result.output_overflow = overflow
		result.stream_error = stream_error
		callback(result)
	end)
	local called
	called, process = pcall(M._system, argv, {
		text = true,
		stdin = input,
		stdout = function(err, data)
			collect(stdout, err, data)
		end,
		stderr = function(err, data)
			collect(stderr, err, data)
		end,
	}, on_exit)
	if not called or not process then
		local message = "jq could not start: " .. bounded(process)
		M._notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	return process
end

local function output(result)
	if result.output_overflow then
		return nil, ("jq output exceeds the %d-byte JQX limit"):format(MAX_OUTPUT_BYTES)
	end
	if result.stream_error then
		return nil, bounded(result.stream_error)
	end
	if type(result) ~= "table" or result.code ~= 0 then
		return nil, bounded(type(result) == "table" and result.stderr or result)
	end
	local stdout = result.stdout or ""
	if #stdout > MAX_OUTPUT_BYTES then
		return nil, ("jq output exceeds the %d-byte JQX limit"):format(MAX_OUTPUT_BYTES)
	end
	return stdout
end

local function decode_list_keys(contents)
	local keys = {}
	for encoded in contents:gmatch("[^\r\n]+") do
		if #keys >= MAX_LIST_ITEMS then
			return nil, ("jq returned more than the %d-item JQX limit"):format(MAX_LIST_ITEMS)
		end
		local decoded, key = pcall(vim.json.decode, encoded)
		if not decoded then
			return nil, "jq returned a key that is not valid JSON"
		end
		if type(key) == "string" then
			keys[#keys + 1] = { kind = "string", value = key, text = key }
		elseif type(key) == "number" and key >= 0 and key % 1 == 0 then
			keys[#keys + 1] = { kind = "integer", value = key, text = tostring(key) }
		else
			return nil, "jq returned a key that is neither a string nor a non-negative integer"
		end
	end
	return keys
end

local function valid_key(key)
	return type(key) == "table"
		and (
			(key.kind == "string" and type(key.value) == "string")
			or (key.kind == "integer" and type(key.value) == "number" and key.value >= 0 and key.value % 1 == 0)
		)
end

local function json_string_end(line, start_column)
	local escaped = false
	for column = start_column + 1, #line do
		local byte = line:byte(column)
		if escaped then
			escaped = false
		elseif byte == 92 then -- backslash
			escaped = true
		elseif byte == 34 then -- double quote
			return column
		end
	end
	return nil
end

-- Index top-level object keys in one lexical pass. JSON strings cannot contain
-- literal newlines, so each candidate token is self-contained in one line.
local function key_positions(lines, keys)
	local wanted = {}
	for _, key in ipairs(keys) do
		if key.kind == "string" then
			wanted[key.value] = true
		end
	end
	local positions = {}
	local depth = 0
	for row, line in ipairs(lines) do
		local column = 1
		while column <= #line do
			local byte = line:byte(column)
			if byte == 34 then -- double quote
				local closing = json_string_end(line, column)
				if not closing then
					return nil, "JSON source contains an unterminated string"
				end
				local next_column = closing + 1
				while next_column <= #line and line:sub(next_column, next_column):match("%s") do
					next_column = next_column + 1
				end
				if depth == 1 and line:byte(next_column) == 58 then -- colon
					local decoded, key = pcall(vim.json.decode, line:sub(column, closing))
					if decoded and type(key) == "string" and wanted[key] then
						-- JSON permits duplicate object names. jq observes the last value,
						-- so point at the last matching top-level declaration too.
						positions[key] = { row = row, column = column }
					end
				end
				column = closing + 1
			elseif byte == 123 or byte == 91 then -- { or [
				depth = depth + 1
				column = column + 1
			elseif byte == 125 or byte == 93 then -- } or ]
				depth = math.max(0, depth - 1)
				column = column + 1
			else
				column = column + 1
			end
		end
	end
	return positions
end

local function visual_config()
	if not upstream_attempted then
		upstream_attempted = true
		pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "NvimConfigJqxUi", modeline = false })
		local ok, config = deferred.try("nvim-jqx.config")
		if ok and type(config) == "table" then
			upstream_config = config
		end
	end
	return upstream_config
		or {
			geometry = { width = 0.4, height = 0.3, wrap = true, border = "rounded" },
			close_window_key = "<Esc>",
		}
end

local function open_result(title, contents)
	local line_count = contents == "" and 0 or 1
	local cursor = 1
	while line_count <= MAX_RESULT_LINES do
		local newline = contents:find("\n", cursor, true)
		if not newline then
			break
		end
		line_count = line_count + 1
		cursor = newline + 1
	end
	if line_count > MAX_RESULT_LINES then
		return nil, ("jq returned more than the %d-line JQX result limit"):format(MAX_RESULT_LINES)
	end
	local lines = vim.split(contents, "\n", { plain = true, trimempty = true })
	if #lines == 0 then
		lines = { "(no output)" }
	end
	local config = visual_config()
	local geometry = type(config.geometry) == "table" and config.geometry or {}
	local max_width = math.max(1, vim.o.columns - 2)
	local max_height = math.max(1, vim.o.lines - 4)
	local requested_width = tonumber(geometry.width) or 0.4
	requested_width = requested_width <= 1 and math.floor(vim.o.columns * requested_width) or requested_width
	local requested_height = tonumber(geometry.height) or 0.3
	requested_height = requested_height <= 1 and math.floor(vim.o.lines * requested_height) or requested_height
	local width = math.max(1, math.min(math.floor(requested_width), max_width))
	local height = math.max(1, math.min(#lines, math.floor(requested_height), max_height))
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "jqx"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		style = "minimal",
		border = geometry.border or "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	})
	vim.wo[winid].wrap = geometry.wrap ~= false
	for _, lhs in ipairs({ "q", config.close_window_key or "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			if vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_close(winid, true)
			end
		end, { buffer = bufnr, nowait = true, desc = "Close JQX result" })
	end
	return true
end

local function query_key(snapshot_value, key)
	if not valid_key(key) then
		local message = "JQX selected key is neither a string nor a non-negative integer"
		M._notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	local argument = key.kind == "integer" and "--argjson" or "--arg"
	local encoded = key.kind == "integer" and tostring(key.value) or key.value
	return run({ "-r", argument, "key", encoded, ".[$key]" }, snapshot_value.input, function(result)
		if not revalidate(snapshot_value) then
			return
		end
		local stdout, result_err = output(result)
		if not stdout then
			M._notify("jq query failed: " .. result_err, vim.log.levels.ERROR)
			return
		end
		local opened, open_err = open_result("jq .[" .. vim.json.encode(key.value) .. "]", stdout)
		if not opened then
			M._notify("jq query failed: " .. open_err, vim.log.levels.ERROR)
		end
	end, function()
		return revalidate(snapshot_value)
	end)
end

function M.list(kind)
	kind = vim.trim(kind or "")
	if kind ~= "" and not TYPES[kind] then
		local message = "JQX type must be one of: " .. table.concat(vim.tbl_keys(TYPES), ", ")
		M._notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	local captured, capture_err = snapshot()
	if not captured then
		M._notify(capture_err, vim.log.levels.WARN)
		return nil, capture_err
	end
	local config = visual_config()
	local arguments
	if kind == "" then
		arguments = { "-r", config.sort == false and "keys_unsorted[] | @json" or "keys[] | @json" }
	else
		arguments = { "-r", "--arg", "kind", kind, "to_entries[] | select(.value|type == $kind) | .key | @json" }
	end
	return run(arguments, captured.input, function(result)
		local stdout, result_err = output(result)
		if not stdout then
			M._notify("Could not build JSON tree: " .. result_err, vim.log.levels.ERROR)
			return
		end
		if not revalidate(captured) then
			return
		end
		local keys, keys_err = decode_list_keys(stdout)
		if not keys then
			M._notify("Could not build JSON tree: " .. keys_err, vim.log.levels.ERROR)
			return
		end
		local positions, positions_err = key_positions(captured.lines, keys)
		if not positions then
			M._notify("Could not build JSON tree: " .. positions_err, vim.log.levels.ERROR)
			return
		end
		local items = {}
		for _, key in ipairs(keys) do
			local position = key.kind == "string" and positions[key.value] or nil
			position = position or { row = 1, column = 1 }
			items[#items + 1] = {
				bufnr = captured.bufnr,
				lnum = position.row,
				col = position.column,
				text = key.text,
				user_data = { jqx_key = vim.deepcopy(key) },
			}
		end
		local listbuf
		if config.use_quickfix == false and vim.api.nvim_win_is_valid(captured.winid) then
			vim.api.nvim_win_call(captured.winid, function()
				vim.fn.setloclist(0, {}, " ", { title = "JQX JSON keys", items = items })
				vim.cmd("lopen")
				listbuf = vim.api.nvim_get_current_buf()
			end)
		else
			vim.fn.setqflist({}, " ", { title = "JQX JSON keys", items = items })
			vim.cmd("copen")
			listbuf = vim.api.nvim_get_current_buf()
		end
		vim.keymap.set("n", config.query_key or "X", function()
			local state = config.use_quickfix == false and vim.fn.getloclist(0, { idx = 0, items = 0 })
				or vim.fn.getqflist({ idx = 0, items = 0 })
			local item = state.items and state.items[state.idx] or nil
			local key = item and type(item.user_data) == "table" and item.user_data.jqx_key or nil
			if valid_key(key) then
				query_key(captured, key)
			end
		end, { buffer = listbuf, nowait = true, desc = "Query selected JSON key" })
	end, function()
		return revalidate(captured)
	end)
end

function M.query(query)
	query = vim.trim(query or "")
	if query == "" then
		local captured = vim.api.nvim_get_current_buf()
		vim.ui.input({ prompt = "jq query: " }, function(value)
			if value and value ~= "" and vim.api.nvim_buf_is_valid(captured) then
				vim.api.nvim_buf_call(captured, function()
					M.query(value)
				end)
			end
		end)
		return true
	end
	local captured, capture_err = snapshot()
	if not captured then
		M._notify(capture_err, vim.log.levels.WARN)
		return nil, capture_err
	end
	local filter = query:sub(1, 1) == "." and query or "." .. query
	return run({ filter }, captured.input, function(result)
		if not revalidate(captured) then
			return
		end
		local stdout, result_err = output(result)
		if not stdout then
			M._notify("jq query failed: " .. result_err, vim.log.levels.ERROR)
			return
		end
		local opened, open_err = open_result("jq " .. filter, stdout)
		if not opened then
			M._notify("jq query failed: " .. open_err, vim.log.levels.ERROR)
		end
	end, function()
		return revalidate(captured)
	end)
end

function M.complete_types(prefix)
	local values = {}
	for kind in pairs(TYPES) do
		if vim.startswith(kind, prefix or "") then
			values[#values + 1] = kind
		end
	end
	table.sort(values)
	return values
end

function M.complete_keys(prefix)
	if vim.bo.filetype ~= "json" then
		return {}
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local measurement = buffer_measurement(bufnr)
	if not measurement or measurement.input_bytes > MAX_INPUT_BYTES then
		return {}
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not measurement_is_current(bufnr, measurement) then
		return {}
	end
	local input = table.concat(lines, "\n")
	if #input > MAX_INPUT_BYTES then
		return {}
	end
	local ok, value = pcall(vim.json.decode, input)
	if not ok or type(value) ~= "table" or vim.islist(value) then
		return {}
	end
	local keys = {}
	for key in pairs(value) do
		if type(key) == "string" and vim.startswith(key, prefix or "") then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	return keys
end

return M
