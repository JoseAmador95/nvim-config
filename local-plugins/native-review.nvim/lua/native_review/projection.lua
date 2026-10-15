-- Pure unified display-row projections for exact native_review.changes entries.
local M = {}

local function integer(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function source(text, path, side)
	if type(text) ~= "string" then
		return nil, side .. " review text must be a string"
	end
	local lines = {}
	local offset = 1
	while offset <= #text do
		local boundary = text:find("\n", offset, true)
		if not boundary then
			lines[#lines + 1] = { text = text:sub(offset), terminator = "" }
			break
		end
		local value = text:sub(offset, boundary - 1)
		local terminator = "\n"
		if value:sub(-1) == "\r" then
			value = value:sub(1, -2)
			terminator = "\r\n"
		end
		lines[#lines + 1] = { text = value, terminator = terminator }
		offset = boundary + 1
	end

	local format
	for _, line in ipairs(lines) do
		if line.terminator ~= "" then
			local current = line.terminator == "\r\n" and "dos" or "unix"
			if format == nil then
				format = current
			elseif format ~= current then
				format = "mixed"
			end
		end
	end
	return {
		endofline = lines[#lines] ~= nil and lines[#lines].terminator ~= "" or false,
		fileformat = format or "unix",
		line_count = #lines,
		lines = lines,
		path = path,
		raw = text,
		side = side,
	}
end

local function raw_line(line)
	return line.text .. line.terminator
end

local function append_row(projection, row)
	row.display_line = #projection.rows + 1
	projection.rows[#projection.rows + 1] = row
	if row.old_line then
		if projection.by_source.old[row.old_line] then
			error("OLD source line maps to more than one display row")
		end
		projection.by_source.old[row.old_line] = row.display_line
	end
	if row.new_line then
		if projection.by_source.new[row.new_line] then
			error("NEW source line maps to more than one display row")
		end
		projection.by_source.new[row.new_line] = row.display_line
	end
end

local function append_context(projection, old_first, new_first, count)
	local old_source = projection.sources.old
	local new_source = projection.sources.new
	for offset = 0, count - 1 do
		local old_line = old_first + offset
		local new_line = new_first + offset
		local old_record = old_source.lines[old_line]
		local new_record = new_source.lines[new_line]
		if not old_record or not new_record then
			error("unchanged review context exceeds a source boundary")
		end
		if raw_line(old_record) ~= raw_line(new_record) then
			error("review hunk leaves unequal text in an unchanged region")
		end
		local anchor_side = new_source.path and "new" or "old"
		local anchor = anchor_side == "new" and new_record or old_record
		append_row(projection, {
			anchor_side = anchor_side,
			anchorable = true,
			hunk_index = nil,
			kind = "context",
			new_line = new_line,
			new_path = new_source.path,
			old_line = old_line,
			old_path = old_source.path,
			path = anchor_side == "new" and new_source.path or old_source.path,
			source_line = anchor_side == "new" and new_line or old_line,
			terminator = anchor.terminator,
			text = anchor.text,
		})
	end
end

local function append_changed(projection, side, first, count, hunk_index)
	local selected = projection.sources[side]
	if count > 0 and not selected.path then
		error(side:upper() .. " hunk rows have no source path")
	end
	for line = first, first + count - 1 do
		local record = selected.lines[line]
		if not record then
			error(side:upper() .. " hunk exceeds its source boundary")
		end
		append_row(projection, {
			anchor_side = side,
			anchorable = true,
			hunk_index = hunk_index,
			kind = side,
			new_line = side == "new" and line or nil,
			new_path = side == "new" and selected.path or nil,
			old_line = side == "old" and line or nil,
			old_path = side == "old" and selected.path or nil,
			path = selected.path,
			source_line = line,
			terminator = record.terminator,
			text = record.text,
		})
	end
end

local function validate_hunk(hunk, index)
	if type(hunk) ~= "table" then
		return nil, ("review hunk %d must be a list"):format(index)
	end
	local old_start, old_count, new_start, new_count = unpack(hunk)
	if
		not integer(old_start)
		or not integer(old_count)
		or not integer(new_start)
		or not integer(new_count)
		or old_count + new_count == 0
	then
		return nil, ("review hunk %d has invalid indices"):format(index)
	end
	return { old_start, old_count, new_start, new_count }
end

---Build one deterministic, synthetic unified projection.
---@param entry table
---@return table? projection
---@return string? err
function M.build(entry)
	if type(entry) ~= "table" then
		return nil, "review entry is required"
	end
	local old_source, old_err = source(entry.old_text or "", entry.old_path, "old")
	if not old_source then
		return nil, old_err
	end
	local new_source, new_err = source(entry.new_text or "", entry.new_path, "new")
	if not new_source then
		return nil, new_err
	end
	local projection = {
		by_source = { old = {}, new = {} },
		hunks = {},
		rows = {},
		sources = { old = old_source, new = new_source },
	}
	local old_next = 1
	local new_next = 1
	local hunks = entry.hunks or vim.diff(old_source.raw, new_source.raw, { result_type = "indices" })
	local ok, build_err = pcall(function()
		for index, candidate in ipairs(hunks) do
			local hunk, hunk_err = validate_hunk(candidate, index)
			if not hunk then
				error(hunk_err)
			end
			local old_start, old_count, new_start, new_count = unpack(hunk)
			local old_first = old_count == 0 and old_start + 1 or old_start
			local new_first = new_count == 0 and new_start + 1 or new_start
			local old_gap = old_first - old_next
			local new_gap = new_first - new_next
			if old_gap < 0 or new_gap < 0 then
				error(("review hunk %d overlaps or is out of order"):format(index))
			elseif old_gap ~= new_gap then
				error(("review hunk %d has unequal unchanged prefixes"):format(index))
			end
			append_context(projection, old_next, new_next, old_gap)
			local first = #projection.rows + 1
			append_changed(projection, "old", old_start, old_count, index)
			append_changed(projection, "new", new_start, new_count, index)
			projection.hunks[index] = {
				first = first,
				last = #projection.rows,
				new_count = new_count,
				new_start = new_start,
				old_count = old_count,
				old_start = old_start,
			}
			old_next = old_first + old_count
			new_next = new_first + new_count
		end
		local old_tail = old_source.line_count - old_next + 1
		local new_tail = new_source.line_count - new_next + 1
		if old_tail < 0 or new_tail < 0 or old_tail ~= new_tail then
			error("review hunks leave unequal or out-of-bounds source tails")
		end
		append_context(projection, old_next, new_next, old_tail)
	end)
	if not ok then
		return nil, tostring(build_err):gsub("^.-:%d+: ", "")
	end

	if #projection.rows == 0 then
		local side = new_source.path and "new" or "old"
		local selected = projection.sources[side]
		if not selected.path then
			return nil, "empty review entry has no source path"
		end
		append_row(projection, {
			anchor_side = side,
			anchorable = false,
			hunk_index = nil,
			kind = "empty",
			new_path = side == "new" and selected.path or nil,
			old_path = side == "old" and selected.path or nil,
			path = selected.path,
			source_line = 0,
			terminator = "",
			text = "",
		})
	end

	local maximum = math.max(old_source.line_count, new_source.line_count, 1)
	projection.gutter_digits = math.max(3, #tostring(maximum))
	return projection
end

---Align changed hunk rows while preserving each source's original order.
function M.alignment(canonical)
	local result = {}
	local index = 1
	while index <= #canonical.rows do
		local row = canonical.rows[index]
		if row.old_line and row.new_line then
			result[#result + 1] = { old_line = row.old_line, new_line = row.new_line }
		elseif row.hunk_index then
			local hunk = canonical.hunks[row.hunk_index]
			for offset = 0, math.max(hunk.old_count, hunk.new_count) - 1 do
				result[#result + 1] = {
					old_line = offset < hunk.old_count and hunk.old_start + offset or nil,
					new_line = offset < hunk.new_count and hunk.new_start + offset or nil,
				}
			end
			while canonical.rows[index + 1] and canonical.rows[index + 1].hunk_index == row.hunk_index do
				index = index + 1
			end
		end
		index = index + 1
	end
	return result
end

local function source_side(side)
	if side == "left" then
		return "old"
	elseif side == "right" then
		return "new"
	end
	return side
end

-- Rendered rows name complete source blocks. Repeated rows are intentional;
-- fillers and crossings between OLD and NEW can never become comment anchors.
local function rendered_range(projection, first, last, preferred_side)
	local side = preferred_side
	for line = first, last do
		local row = projection.rows[line]
		if not row or not row.anchorable then
			return nil, "rendered selection includes a non-anchorable row; use the source view"
		end
		local only = not row.old_range and "new" or not row.new_range and "old" or nil
		if only and side and side ~= only then
			return nil, "rendered selection crosses OLD and NEW blocks"
		end
		side = only or side
	end
	side = side or "new"
	local start_line, end_line, previous_first
	for line = first, last do
		local range = projection.rows[line][side .. "_range"]
		if not range then
			return nil, "rendered block has no range on the selected source side"
		elseif end_line and range.first > end_line + 1 then
			for gap = end_line + 1, range.first - 1 do
				if vim.trim(projection.sources[side].lines[gap].text) ~= "" then
					return nil, "rendered selection skips source content; use the source view"
				end
			end
		elseif previous_first and range.first < previous_first then
			return nil, "rendered selection reverses source order"
		end
		start_line = start_line or range.first
		end_line = math.max(end_line or 0, range.last)
		previous_first = range.first
	end
	return {
		display_first = first,
		display_last = last,
		path = projection.sources[side].path,
		side = side,
		start_line = start_line,
		end_line = end_line,
	}
end

---Resolve one display row to its canonical source anchor.
---@param projection table
---@param display_line integer
---@return table? source_ref
---@return string? err
function M.source_at(projection, display_line)
	if not integer(display_line) or display_line < 1 then
		return nil, "display line must be a positive integer"
	end
	local row = projection and projection.rows and projection.rows[display_line]
	if not row then
		return nil, "display line is outside the unified projection"
	end
	return {
		anchorable = row.anchorable,
		display_line = display_line,
		kind = row.kind,
		new_line = row.new_line,
		new_path = row.new_path,
		old_line = row.old_line,
		old_path = row.old_path,
		path = row.path,
		side = row.anchor_side,
		source_line = row.source_line,
		terminator = row.terminator,
	}
end

---Resolve a contiguous display selection to one representable source range.
---@param projection table
---@param first integer
---@param last integer
---@param preferred_side? "old"|"new"|"left"|"right"
---@return table? source_range
---@return string? err
function M.resolve_range(projection, first, last, preferred_side)
	if not integer(first) or not integer(last) or first < 1 or last < 1 then
		return nil, "display range must use positive integer lines"
	end
	first, last = math.min(first, last), math.max(first, last)
	preferred_side = source_side(preferred_side)
	if preferred_side ~= nil and preferred_side ~= "old" and preferred_side ~= "new" then
		return nil, "preferred source side must be old/new or left/right"
	end
	if projection and projection.rendered then
		return rendered_range(projection, first, last, preferred_side)
	end

	local rows = {}
	local has_old_only = false
	local has_new_only = false
	for display_line = first, last do
		local row = projection and projection.rows and projection.rows[display_line]
		if not row then
			return nil, "display line is outside the unified projection"
		elseif not row.anchorable then
			if first == last and row.kind == "empty" then
				return nil, "empty review content has no line anchor; use a file comment"
			end
			return nil, "display range includes a non-anchorable row"
		end
		rows[#rows + 1] = row
		has_old_only = has_old_only or (row.old_line ~= nil and row.new_line == nil)
		has_new_only = has_new_only or (row.new_line ~= nil and row.old_line == nil)
	end
	if has_old_only and has_new_only then
		return nil, "display range crosses OLD-only and NEW-only source rows"
	end

	local side = has_old_only and "old" or has_new_only and "new" or preferred_side or "new"
	local line_field = side .. "_line"
	local path_field = side .. "_path"
	local path
	local start_line
	local previous
	for _, row in ipairs(rows) do
		local source_line = row[line_field]
		local source_path = row[path_field]
		if not source_line or not source_path then
			return nil, "display range is not representable on the selected source side"
		elseif path and source_path ~= path then
			return nil, "display range crosses source paths"
		elseif previous and source_line ~= previous + 1 then
			return nil, "display range is not consecutive in its source"
		end
		path = path or source_path
		start_line = start_line or source_line
		previous = source_line
	end
	return {
		display_first = first,
		display_last = last,
		end_line = previous,
		path = path,
		side = side,
		start_line = start_line,
	}
end

---Reverse-map one canonical source location to a display row.
---@param projection table
---@param side "old"|"new"|"left"|"right"
---@param line integer
---@param path? string
---@return integer? display_line
---@return string? err
function M.locate(projection, side, line, path)
	side = source_side(side)
	if side ~= "old" and side ~= "new" then
		return nil, "source side must be old/new or left/right"
	elseif not integer(line) or line < 1 then
		return nil, "source line must be a positive integer"
	end
	local selected = projection and projection.sources and projection.sources[side]
	if not selected then
		return nil, "unified projection source is unavailable"
	elseif path and selected.path ~= path then
		return nil, "source path is not represented by this unified projection"
	end
	local display_line = projection.by_source[side][line]
	if not display_line then
		return nil, "source line is not represented by this unified projection"
	end
	return display_line
end

---Return every display row represented by a canonical source range.
---@param projection table
---@param side "old"|"new"|"left"|"right"
---@param first integer
---@param last integer
---@param path? string
---@return integer[]? rows
---@return string? err
function M.rows_for_range(projection, side, first, last, path)
	if not integer(first) or not integer(last) or first < 1 or last < 1 then
		return nil, "source range must use positive integer lines"
	end
	first, last = math.min(first, last), math.max(first, last)
	if projection and projection.rendered then
		side = source_side(side)
		for line = first, last do
			local located, err = M.locate(projection, side, line, path)
			if not located then
				return nil, err
			end
		end
		local result = {}
		for index, row in ipairs(projection.rows) do
			local range = row[side .. "_range"]
			if range and range.first <= last and range.last >= first then
				result[#result + 1] = index
			end
		end
		return result
	end
	local rows = {}
	for line = first, last do
		local display_line, locate_err = M.locate(projection, side, line, path)
		if not display_line then
			return nil, locate_err
		end
		rows[#rows + 1] = display_line
	end
	return rows
end

---Build merged visible display sections around projected hunks.
---@param projection table
---@param context integer
---@return table[]
function M.sections(projection, context)
	context = math.max(0, math.floor(tonumber(context) or 0))
	local values = {}
	for index, hunk in ipairs(projection and projection.hunks or {}) do
		local first, last = math.max(1, hunk.first - context), math.min(#projection.rows, hunk.last + context)
		if projection.rendered then
			local first_block, last_block
			for block, range in ipairs(projection.blocks) do
				if range.first <= hunk.first and range.last >= hunk.first then
					first_block = block
				end
				if range.first <= hunk.last and range.last >= hunk.last then
					last_block = block
				end
			end
			first = projection.blocks[math.max(1, first_block - context)].first
			last = projection.blocks[math.min(#projection.blocks, last_block + context)].last
		end
		values[#values + 1] = {
			first = first,
			hunks = { index },
			last = last,
		}
	end
	local merged = {}
	for _, value in ipairs(values) do
		local previous = merged[#merged]
		if previous and value.first <= previous.last + 1 then
			previous.last = math.max(previous.last, value.last)
			vim.list_extend(previous.hunks, value.hunks)
		else
			merged[#merged + 1] = value
		end
	end
	return merged
end

return M
