local M = {}

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
	if vim.api.nvim_buf_is_valid(buffer_state.buf) then
		pcall(vim.api.nvim_buf_clear_namespace, buffer_state.buf, namespace, 0, -1)
	end
	state.buffers[buffer_state.buf] = nil
end

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
		locations = {},
		refresh_pending = false,
	}
	state.buffers[buf] = buffer_state
	local attached = vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			if not buffer_state.active or buffer_state.refresh_pending then
				return false
			end
			buffer_state.refresh_pending = true
			state.options.schedule(function()
				buffer_state.refresh_pending = false
				if buffer_state.active and vim.api.nvim_buf_is_valid(buf) then
					M.refresh(buf)
				end
			end)
			return false
		end,
		on_detach = function()
			buffer_state.active = false
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

local function exact_locations(line, text)
	local result = {}
	local first = 1
	while first <= #line do
		local start_col, end_col = line:find(text, first, true)
		if not start_col then
			break
		end
		result[#result + 1] = { start_col - 1, end_col }
		first = math.max(end_col + 1, start_col + 1)
	end
	return result
end

local function regex_locations(line, regex)
	local result = {}
	local offset = 0
	while offset <= #line do
		local start_col, end_col = regex:match_str(line:sub(offset + 1))
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

local function add_extmark(buffer_state, pattern, row, start_col, end_col)
	local line = vim.api.nvim_buf_get_lines(buffer_state.buf, row, row + 1, false)[1] or ""
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
	buffer_state.locations[#buffer_state.locations + 1] = {
		pattern_id = pattern.id,
		row = row,
		col = start_col,
		end_col = end_col,
		extmark = extmark,
	}
end

function M.setup(opts)
	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	if opts.schedule ~= nil and type(opts.schedule) ~= "function" then
		return nil, "setup.schedule must be a function"
	end
	if opts.event ~= nil and type(opts.event) ~= "function" then
		return nil, "setup.event must be a function"
	end
	if state.configured then
		M.teardown()
	end
	state.options = { schedule = opts.schedule or vim.schedule, event = opts.event }
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
	}
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
	M.refresh(buf)
	emit("cleared", buf, { count = removed })
	return removed
end

function M.refresh(buf)
	local buffer_state = state.buffers[buf]
	if not buffer_state or not buffer_state.active or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	buffer_state.locations = {}
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for _, pattern in ipairs(buffer_state.patterns) do
		for row, line in ipairs(lines) do
			local locations = pattern.kind == "exact" and exact_locations(line, pattern.text)
				or regex_locations(line, pattern.compiled)
			for _, location in ipairs(locations) do
				add_extmark(buffer_state, pattern, row - 1, location[1], location[2])
			end
		end
	end
	table.sort(buffer_state.locations, function(left, right)
		if left.row ~= right.row then
			return left.row < right.row
		end
		if left.col ~= right.col then
			return left.col < right.col
		end
		return tostring(left.pattern_id) < tostring(right.pattern_id)
	end)
	emit("refreshed", buf, { count = #buffer_state.locations })
	return true
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
	if not buffer_state or #buffer_state.locations == 0 then
		return nil, "no log matches"
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
		if not candidate and opts.wrap ~= false then
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
		if not candidate and opts.wrap ~= false then
			candidate = buffer_state.locations[#buffer_state.locations]
		end
	end
	if not candidate then
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
	state.configured = false
end

return M
