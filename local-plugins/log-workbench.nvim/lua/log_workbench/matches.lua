local M = {}

local DEFAULT_MAX_MATCHES = 20000
local DEFAULT_SCAN_LINES_PER_TICK = 1000

local namespace = vim.api.nvim_create_namespace("log_workbench.matches")
local state = {
	configured = false,
	options = nil,
	buffers = {},
}

local function copy(value)
	return vim.deepcopy(value)
end

local function id_key(id)
	return type(id) .. ":" .. tostring(id)
end

local function valid_id(id)
	return (type(id) == "number" and id == math.floor(id) and id >= 1)
		or (type(id) == "string" and id ~= "" and not id:find("\0", 1, true))
end

local function positive_integer(value, fallback, name)
	if value == nil then
		return fallback
	end
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value ~= value or value == math.huge then
		return nil, name .. " must be a positive integer"
	end
	return value
end

local function public_pattern(pattern)
	return {
		id = pattern.id,
		kind = pattern.kind,
		text = pattern.text,
		hl_group = pattern.hl_group,
		priority = pattern.priority,
		metadata = copy(pattern.metadata),
	}
end

local function emit(kind, buf, extra)
	if not state.options or not state.options.event then
		return
	end
	local event = copy(extra or {})
	event.kind = kind
	event.bufnr = buf
	pcall(state.options.event, event)
end

local function detach(buffer_state)
	buffer_state.active = false
	buffer_state.generation = buffer_state.generation + 1
	if vim.api.nvim_buf_is_valid(buffer_state.buf) then
		pcall(vim.api.nvim_buf_clear_namespace, buffer_state.buf, namespace, 0, -1)
	end
	state.buffers[buffer_state.buf] = nil
end

local request_rescan

local function ensure_buffer(buf)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return nil, "matches require a valid buffer"
	end
	local existing = state.buffers[buf]
	if existing then
		return existing
	end
	local buffer_state = {
		buf = buf,
		active = true,
		attached = false,
		patterns = {},
		by_id = {},
		next_id = 1,
		next_pattern_order = 1,
		locations = {},
		next_row = 0,
		capped = false,
		rescan_from = nil,
		scan_scheduled = false,
		generation = 1,
	}
	state.buffers[buf] = buffer_state
	local attached = vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, firstline)
			if not buffer_state.active or #buffer_state.patterns == 0 then
				return false
			end
			request_rescan(buffer_state, firstline)
			return false
		end,
		on_detach = function()
			buffer_state.active = false
			buffer_state.generation = buffer_state.generation + 1
			state.buffers[buf] = nil
		end,
	})
	if not attached then
		state.buffers[buf] = nil
		return nil, "could not attach match registry to buffer"
	end
	buffer_state.attached = true
	return buffer_state
end

local function exact_locations(line, text, limit)
	local result = {}
	local first = 1
	while first <= #line and #result < limit do
		local start_col, end_col = line:find(text, first, true)
		if not start_col then
			break
		end
		result[#result + 1] = { start_col - 1, end_col }
		first = math.max(end_col + 1, start_col + 1)
	end
	return result
end

local function regex_locations(buf, row, line, regex, limit)
	local result = {}
	local offset = 0
	while offset <= #line and #result < limit do
		local start_col, end_col = regex:match_line(buf, row, offset, #line)
		if start_col == nil then
			break
		end
		start_col = start_col + offset
		end_col = end_col + offset
		result[#result + 1] = { start_col, math.max(start_col, end_col) }
		offset = end_col > start_col and end_col or start_col + 1
	end
	return result
end

local function add_extmark(buffer_state, pattern, row, line, start_col, end_col)
	local visible_end = end_col
	if visible_end <= start_col and start_col < #line then
		visible_end = start_col + 1
	end
	local extmark = vim.api.nvim_buf_set_extmark(buffer_state.buf, namespace, row, start_col, {
		end_row = row,
		end_col = visible_end,
		hl_group = pattern.hl_group,
		priority = pattern.priority,
		right_gravity = false,
		end_right_gravity = true,
	})
	return {
		pattern_id = pattern.id,
		pattern_order = pattern.order,
		row = row,
		col = start_col,
		end_col = end_col,
		extmark = extmark,
	}
end

local function drop_suffix(buffer_state, first_row)
	local prefix = {}
	for _, location in ipairs(buffer_state.locations) do
		if location.row < first_row then
			prefix[#prefix + 1] = location
		else
			pcall(vim.api.nvim_buf_del_extmark, buffer_state.buf, namespace, location.extmark)
		end
	end
	buffer_state.locations = prefix
end

local function scan_row(buffer_state, row, line)
	local remaining = state.options.max_matches - #buffer_state.locations
	local row_locations = {}
	for _, pattern in ipairs(buffer_state.patterns) do
		if remaining == 0 then
			break
		end
		local locations = pattern.kind == "exact" and exact_locations(line, pattern.text, remaining)
			or regex_locations(buffer_state.buf, row, line, pattern.compiled, remaining)
		for _, location in ipairs(locations) do
			row_locations[#row_locations + 1] = add_extmark(buffer_state, pattern, row, line, location[1], location[2])
			remaining = remaining - 1
		end
	end
	table.sort(row_locations, function(left, right)
		if left.col ~= right.col then
			return left.col < right.col
		end
		if left.pattern_order ~= right.pattern_order then
			return left.pattern_order < right.pattern_order
		end
		if left.end_col ~= right.end_col then
			return left.end_col < right.end_col
		end
		return left.extmark < right.extmark
	end)
	for _, location in ipairs(row_locations) do
		buffer_state.locations[#buffer_state.locations + 1] = location
	end
	return remaining > 0
end

local schedule_scan

local function finish_scan(buffer_state, truncated)
	buffer_state.capped = truncated
	emit("refreshed", buffer_state.buf, {
		count = #buffer_state.locations,
		truncated = truncated,
	})
end

local function scan_tick(buffer_state)
	if not buffer_state.active or not vim.api.nvim_buf_is_valid(buffer_state.buf) then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(buffer_state.buf)
	if buffer_state.rescan_from ~= nil then
		local first_row = math.min(buffer_state.rescan_from, line_count)
		buffer_state.rescan_from = nil
		drop_suffix(buffer_state, first_row)
		buffer_state.next_row = first_row
		buffer_state.capped = false
	end
	if #buffer_state.patterns == 0 then
		drop_suffix(buffer_state, 0)
		buffer_state.next_row = line_count
		finish_scan(buffer_state, false)
		return
	end

	local last_row = math.min(line_count, buffer_state.next_row + state.options.scan_lines_per_tick)
	local lines = vim.api.nvim_buf_get_lines(buffer_state.buf, buffer_state.next_row, last_row, false)
	for _, line in ipairs(lines) do
		local row = buffer_state.next_row
		if not scan_row(buffer_state, row, line) then
			buffer_state.next_row = row
			finish_scan(buffer_state, true)
			return
		end
		buffer_state.next_row = row + 1
	end
	if buffer_state.next_row >= line_count then
		finish_scan(buffer_state, false)
	else
		schedule_scan(buffer_state)
	end
end

schedule_scan = function(buffer_state)
	if buffer_state.scan_scheduled or not buffer_state.active then
		return
	end
	buffer_state.scan_scheduled = true
	local generation = buffer_state.generation
	state.options.schedule(function()
		if
			not buffer_state.active
			or buffer_state.generation ~= generation
			or state.buffers[buffer_state.buf] ~= buffer_state
		then
			return
		end
		buffer_state.scan_scheduled = false
		scan_tick(buffer_state)
	end)
end

request_rescan = function(buffer_state, first_row)
	if not buffer_state.active or not vim.api.nvim_buf_is_valid(buffer_state.buf) then
		return false
	end
	first_row = math.max(0, math.floor(first_row or 0))
	if buffer_state.capped and first_row > buffer_state.next_row then
		return true
	end
	first_row = math.min(first_row, buffer_state.next_row)
	if buffer_state.rescan_from == nil or first_row < buffer_state.rescan_from then
		buffer_state.rescan_from = first_row
	end
	buffer_state.capped = false
	schedule_scan(buffer_state)
	return true
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "setup options must be an object"
	end
	for key in pairs(opts) do
		if key ~= "schedule" and key ~= "event" and key ~= "max_matches" and key ~= "scan_lines_per_tick" then
			return nil, "setup contains an unknown option: " .. tostring(key)
		end
	end
	if opts.schedule ~= nil and type(opts.schedule) ~= "function" then
		return nil, "setup.schedule must be a function"
	end
	if opts.event ~= nil and type(opts.event) ~= "function" then
		return nil, "setup.event must be a function"
	end
	local max_matches, matches_err = positive_integer(opts.max_matches, DEFAULT_MAX_MATCHES, "setup.max_matches")
	if not max_matches then
		return nil, matches_err
	end
	local scan_lines_per_tick, scan_err =
		positive_integer(opts.scan_lines_per_tick, DEFAULT_SCAN_LINES_PER_TICK, "setup.scan_lines_per_tick")
	if not scan_lines_per_tick then
		return nil, scan_err
	end
	if state.configured then
		M.teardown()
	end
	state.options = {
		schedule = opts.schedule or vim.schedule,
		event = opts.event,
		max_matches = max_matches,
		scan_lines_per_tick = scan_lines_per_tick,
	}
	state.buffers = {}
	state.configured = true
	return true
end

function M.add(buf, spec)
	if not state.configured then
		return nil, "setup must be called first"
	end
	if type(spec) ~= "table" then
		return nil, "pattern spec must be a table"
	end
	if spec.kind ~= "exact" and spec.kind ~= "regex" then
		return nil, "pattern kind must be exact or regex"
	end
	if type(spec.text) ~= "string" or spec.text == "" or spec.text:find("\0", 1, true) then
		return nil, "pattern text must be non-empty and contain no NUL bytes"
	end
	if spec.text:find("\n", 1, true) then
		return nil, "patterns must be single-line"
	end
	if type(spec.hl_group) ~= "string" or spec.hl_group == "" then
		return nil, "pattern hl_group must be a non-empty string"
	end
	if spec.metadata ~= nil and type(spec.metadata) ~= "table" then
		return nil, "pattern metadata must be a table"
	end
	if
		spec.priority ~= nil
		and (type(spec.priority) ~= "number" or spec.priority ~= math.floor(spec.priority) or spec.priority < 0)
	then
		return nil, "pattern priority must be a non-negative integer"
	end
	local buffer_state, buffer_err = ensure_buffer(buf)
	if not buffer_state then
		return nil, buffer_err
	end
	local id = spec.id
	if id == nil then
		while buffer_state.by_id[id_key(buffer_state.next_id)] do
			buffer_state.next_id = buffer_state.next_id + 1
		end
		id = buffer_state.next_id
		buffer_state.next_id = buffer_state.next_id + 1
	elseif not valid_id(id) then
		return nil, "pattern id must be a positive integer or non-empty string"
	end
	if buffer_state.by_id[id_key(id)] then
		return nil, "pattern id already exists"
	end
	local compiled
	if spec.kind == "regex" then
		local ok, result = pcall(vim.regex, spec.text)
		if not ok then
			return nil, "invalid pattern regex: " .. tostring(result)
		end
		compiled = result
	end
	local pattern = {
		id = id,
		kind = spec.kind,
		text = spec.text,
		hl_group = spec.hl_group,
		priority = type(spec.priority) == "number" and spec.priority or 110,
		metadata = copy(spec.metadata or {}),
		compiled = compiled,
		order = buffer_state.next_pattern_order,
	}
	buffer_state.next_pattern_order = buffer_state.next_pattern_order + 1
	buffer_state.patterns[#buffer_state.patterns + 1] = pattern
	buffer_state.by_id[id_key(id)] = pattern
	M.refresh(buf)
	emit("added", buf, { pattern = public_pattern(pattern) })
	return public_pattern(pattern)
end

function M.remove(buf, id)
	local buffer_state = state.buffers[buf]
	if not buffer_state then
		return false
	end
	local pattern = buffer_state.by_id[id_key(id)]
	if not pattern then
		return false
	end
	buffer_state.by_id[id_key(id)] = nil
	local remaining = {}
	for _, entry in ipairs(buffer_state.patterns) do
		if entry ~= pattern then
			remaining[#remaining + 1] = entry
		end
	end
	buffer_state.patterns = remaining
	M.refresh(buf)
	emit("removed", buf, { id = id })
	return true
end

function M.clear(buf, ids)
	local buffer_state = state.buffers[buf]
	if not buffer_state then
		return 0
	end
	local selected
	if ids ~= nil then
		if type(ids) ~= "table" then
			return nil, "clear ids must be a list"
		end
		selected = {}
		for _, id in ipairs(ids) do
			selected[id_key(id)] = true
		end
	end
	local removed = 0
	local remaining = {}
	for _, pattern in ipairs(buffer_state.patterns) do
		if not selected or selected[id_key(pattern.id)] then
			buffer_state.by_id[id_key(pattern.id)] = nil
			removed = removed + 1
		else
			remaining[#remaining + 1] = pattern
		end
	end
	buffer_state.patterns = remaining
	if removed > 0 and #remaining == 0 then
		buffer_state.generation = buffer_state.generation + 1
		buffer_state.scan_scheduled = false
		buffer_state.rescan_from = nil
		buffer_state.capped = false
		buffer_state.next_row = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
		buffer_state.locations = {}
	elseif removed > 0 then
		M.refresh(buf)
	end
	emit("cleared", buf, { count = removed })
	return removed
end

function M.refresh(buf)
	local buffer_state = state.buffers[buf]
	if not buffer_state or not buffer_state.active or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	return request_rescan(buffer_state, 0)
end

function M.effective_config()
	return {
		max_matches = state.configured and state.options.max_matches or DEFAULT_MAX_MATCHES,
		scan_lines_per_tick = state.configured and state.options.scan_lines_per_tick or DEFAULT_SCAN_LINES_PER_TICK,
	}
end

function M.list(buf)
	local buffer_state = state.buffers[buf]
	local result = {}
	for _, pattern in ipairs(buffer_state and buffer_state.patterns or {}) do
		result[#result + 1] = public_pattern(pattern)
	end
	return result
end

function M.locations(buf, id)
	local buffer_state = state.buffers[buf]
	local result = {}
	for _, location in ipairs(buffer_state and buffer_state.locations or {}) do
		if id == nil or id_key(location.pattern_id) == id_key(id) then
			result[#result + 1] = {
				pattern_id = location.pattern_id,
				row = location.row + 1,
				col = location.col + 1,
				end_col = location.end_col + 1,
			}
		end
	end
	return result
end

local function navigate(buf, direction, opts)
	opts = opts or {}
	local buffer_state = state.buffers[buf]
	if not buffer_state then
		return nil, "no log matches"
	end
	local scan_incomplete = buffer_state.rescan_from ~= nil
		or buffer_state.scan_scheduled
		or (not buffer_state.capped and buffer_state.next_row < vim.api.nvim_buf_line_count(buf))
	if #buffer_state.locations == 0 then
		return nil, scan_incomplete and "log match scan is still in progress" or "no log matches"
	end
	local win = opts.winid or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
		return nil, "navigation window does not show the match buffer"
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row = cursor[1] - 1
	local col = cursor[2]
	local candidate
	if direction > 0 then
		for _, location in ipairs(buffer_state.locations) do
			if location.row > row or (location.row == row and location.col > col) then
				candidate = location
				break
			end
		end
		if not candidate and not scan_incomplete and opts.wrap ~= false then
			candidate = buffer_state.locations[1]
		end
	else
		for index = #buffer_state.locations, 1, -1 do
			local location = buffer_state.locations[index]
			if location.row < row or (location.row == row and location.col < col) then
				candidate = location
				break
			end
		end
		if not candidate and not scan_incomplete and opts.wrap ~= false then
			candidate = buffer_state.locations[#buffer_state.locations]
		end
	end
	if not candidate then
		if scan_incomplete then
			return nil, "log match scan is still in progress"
		end
		return nil, "no log match in that direction"
	end
	vim.api.nvim_win_set_cursor(win, { candidate.row + 1, candidate.col })
	return {
		pattern_id = candidate.pattern_id,
		row = candidate.row + 1,
		col = candidate.col + 1,
		end_col = candidate.end_col + 1,
	}
end

function M.next(buf, opts)
	return navigate(buf, 1, opts)
end

function M.previous(buf, opts)
	return navigate(buf, -1, opts)
end

function M.namespace()
	return namespace
end

function M.teardown()
	local buffers = {}
	for _, buffer_state in pairs(state.buffers) do
		buffers[#buffers + 1] = buffer_state
	end
	for _, buffer_state in ipairs(buffers) do
		detach(buffer_state)
	end
	state.buffers = {}
	state.options = nil
	state.configured = false
end

return M
