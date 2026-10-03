-- Pure validation of Difftastic 0.71.0's unstable, single-file JSON contract.
local projection = require("native_review.projection")

local M = {}
local SIDES = { old = "lhs", new = "rhs" }
local STATUSES = { changed = true, unchanged = true, created = true, deleted = true }
local HIGHLIGHTS = {
	delimiter = true,
	normal = true,
	string = true,
	type = true,
	comment = true,
	keyword = true,
	tree_sitter_error = true,
}

local function integer(value)
	return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

local function object(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if type(key) ~= "string" then
			return false
		end
	end
	return true
end

local function list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if not integer(key) or key < 1 or key > #value then
			return false
		end
	end
	return true
end

local function boundary_map(text)
	local result = { [0] = true }
	local offset = 1
	while offset <= #text do
		local first = text:byte(offset)
		local length, second_min, second_max = 1, 128, 191
		if first >= 194 and first <= 223 then
			length = 2
		elseif first >= 224 and first <= 239 then
			length = 3
			second_min = first == 224 and 160 or 128
			second_max = first == 237 and 159 or 191
		elseif first >= 240 and first <= 244 then
			length = 4
			second_min = first == 240 and 144 or 128
			second_max = first == 244 and 143 or 191
		elseif first >= 128 then
			return nil, "frozen source is not valid UTF-8"
		end
		for index = 1, length - 1 do
			local byte = text:byte(offset + index)
			local minimum = index == 1 and second_min or 128
			local maximum = index == 1 and second_max or 191
			if not byte or byte < minimum or byte > maximum then
				return nil, "frozen source is not valid UTF-8"
			end
		end
		offset = offset + length
		result[offset - 1] = true
	end
	return result
end

local function source_lines(sources)
	local result = { old = {}, new = {} }
	for side in pairs(SIDES) do
		for index, line in ipairs(sources[side].lines) do
			-- --strip-cr=off retains CR; Neovim's visible DOS line excludes it.
			local text = line.text .. (line.terminator == "\r\n" and "\r" or "")
			local boundaries, err = boundary_map(text)
			if not boundaries then
				return nil, err
			end
			result[side][index] = { boundaries = boundaries, text = text, visible_bytes = #line.text }
		end
	end
	return result
end

local function normalized_alignment(values, sources)
	if not list(values) or #values == 0 then
		return nil, "changed Difftastic output requires aligned_lines"
	end
	local result = {}
	local previous = { old = -1, new = -1 }
	local owners = { old = {}, new = {} }
	for _, pair in ipairs(values) do
		if not list(pair) or #pair ~= 2 then
			return nil, "Difftastic alignment must contain two-element pairs"
		end
		local row = {}
		local has_line = false
		for index, side in ipairs({ "old", "new" }) do
			local value = pair[index]
			if value ~= vim.NIL then
				if not integer(value) or value > sources[side].line_count or value ~= previous[side] + 1 then
					return nil, "Difftastic alignment is out of bounds, repeated, incomplete, or nonmonotonic"
				end
				previous[side] = value
				has_line = true
				-- Difftastic appends a newline even when the original lacks one.
				-- Its final split('\n') element is never an original source line.
				if value < sources[side].line_count then
					row[side .. "_line"] = value + 1
				end
			end
		end
		if not has_line then
			return nil, "Difftastic alignment contains an empty pair"
		end
		if row.old_line or row.new_line then
			result[#result + 1] = row
			for side in pairs(SIDES) do
				if row[side .. "_line"] then
					owners[side][row[side .. "_line"]] = #result
				end
			end
		end
	end
	for side in pairs(SIDES) do
		if previous[side] < sources[side].line_count - 1 then
			return nil, "Difftastic alignment does not cover every original source line"
		end
	end
	return result, nil, owners
end

local function add_changes(result, side, record, lines, owners, seen)
	if not object(record) or not integer(record.line_number) or not list(record.changes) then
		return nil, "Difftastic chunk side has invalid line_number or changes"
	end
	local line = record.line_number + 1
	local source = lines[side][line]
	if not source or not owners[side][line] then
		return nil, "Difftastic chunk line is outside the original alignment"
	elseif seen[side][line] then
		-- Overlapping JSON chunks can repeat the same complete line record.
		-- Reuse its validated ranges while still checking the paired alignment.
		if not vim.deep_equal(seen[side][line], record.changes) then
			return nil, "Difftastic chunks disagree on a repeated source line"
		end
		return owners[side][line]
	end
	for _, change in ipairs(record.changes) do
		if
			not object(change)
			or not integer(change.start)
			or not integer(change["end"])
			or change.start > change["end"]
			or change["end"] > #source.text
			or not source.boundaries[change.start]
			or not source.boundaries[change["end"]]
			or type(change.content) ~= "string"
			or source.text:sub(change.start + 1, change["end"]) ~= change.content
			or not HIGHLIGHTS[change.highlight]
		then
			return nil, "Difftastic change has invalid byte bounds, UTF-8 boundaries, content, or highlight"
		end
		local first = math.min(change.start, source.visible_bytes)
		local last = math.min(change["end"], source.visible_bytes)
		if first < last then
			result.line_changes[side][line] = true
			result.intraline[side][#result.intraline[side] + 1] = { line = line, start_col = first, end_col = last }
		end
	end
	seen[side][line] = record.changes
	return owners[side][line]
end

local function normalize_ranges(ranges)
	table.sort(ranges, function(left, right)
		return left.line < right.line or (left.line == right.line and left.start_col < right.start_col)
	end)
	local result = {}
	for _, range in ipairs(ranges) do
		local previous = result[#result]
		if previous and previous.line == range.line and previous.end_col > range.start_col then
			return nil, "Difftastic changes overlap on a source line"
		elseif previous and previous.line == range.line and previous.end_col == range.start_col then
			previous.end_col = range.end_col
		else
			result[#result + 1] = range
		end
	end
	return result
end

local function normalize_chunks(result, chunks, lines, owners)
	if not list(chunks) or #chunks == 0 then
		return nil, "changed Difftastic output requires chunks"
	end
	local seen = { old = {}, new = {} }
	for _, chunk in ipairs(chunks) do
		if not list(chunk) or #chunk == 0 then
			return nil, "Difftastic chunks must contain line records"
		end
		for _, record in ipairs(chunk) do
			if not object(record) or (record.lhs == nil and record.rhs == nil) then
				return nil, "Difftastic chunk record requires lhs or rhs"
			end
			local owner
			for side, field in pairs(SIDES) do
				if record[field] ~= nil then
					local selected, err = add_changes(result, side, record[field], lines, owners, seen)
					if not selected then
						return nil, err
					elseif owner and owner ~= selected then
						return nil, "Difftastic chunk sides disagree with aligned_lines"
					end
					owner = selected
				end
			end
		end
	end
	local novel = false
	for side in pairs(SIDES) do
		local ranges, err = normalize_ranges(result.intraline[side])
		if not ranges then
			return nil, err
		end
		result.intraline[side] = ranges
		novel = novel or next(result.line_changes[side]) ~= nil
	end
	if not novel then
		return nil, "changed Difftastic output contains no structural ranges"
	end
	return true
end

local function append_row(value, side, line, kind, opposite)
	local source = value.sources[side]
	local record = source.lines[line]
	local row = {
		anchor_side = side,
		anchorable = true,
		display_line = #value.rows + 1,
		kind = kind,
		path = source.path,
		source_line = line,
		terminator = record.terminator,
		text = record.text,
	}
	row[side .. "_line"] = line
	row[side .. "_path"] = source.path
	if opposite then
		local other = side == "old" and "new" or "old"
		row[other .. "_line"] = opposite
		row[other .. "_path"] = value.sources[other].path
	end
	value.rows[#value.rows + 1] = row
	for selected in pairs(SIDES) do
		if row[selected .. "_line"] then
			value.by_source[selected][row[selected .. "_line"]] = row.display_line
		end
	end
end

local function structural_hunks(value)
	local before = { old = 0, new = 0 }
	local current
	for index, row in ipairs(value.rows) do
		if row.kind == "old" or row.kind == "new" then
			if not current then
				current = {
					first = index,
					last = index,
					old_count = 0,
					new_count = 0,
					old_start = before.old,
					new_start = before.new,
				}
				value.hunks[#value.hunks + 1] = current
			end
			row.hunk_index = #value.hunks
			current.last = index
			local side = row.kind
			if current[side .. "_count"] == 0 then
				current[side .. "_start"] = row[side .. "_line"]
			end
			current[side .. "_count"] = current[side .. "_count"] + 1
		else
			current = nil
		end
		for side in pairs(SIDES) do
			if row[side .. "_line"] then
				before[side] = row[side .. "_line"]
			end
		end
	end
end

local function structural_projection(canonical, result)
	local value = {
		by_source = { old = {}, new = {} },
		gutter_digits = canonical.gutter_digits,
		hunks = {},
		rows = {},
		sources = canonical.sources,
	}
	for _, pair in ipairs(result.aligned_lines) do
		local old = pair.old_line and value.sources.old.lines[pair.old_line]
		local new = pair.new_line and value.sources.new.lines[pair.new_line]
		local changed_old = pair.old_line and result.line_changes.old[pair.old_line]
		local changed_new = pair.new_line and result.line_changes.new[pair.new_line]
		if
			old
			and new
			and not changed_old
			and not changed_new
			and old.text .. old.terminator == new.text .. new.terminator
		then
			append_row(value, "new", pair.new_line, "context", pair.old_line)
		else
			for _, side in ipairs({ "old", "new" }) do
				local line = pair[side .. "_line"]
				if line then
					append_row(value, side, line, result.line_changes[side][line] and side or "context")
				end
			end
		end
	end
	if #value.rows == 0 then
		value.rows[1] = vim.deepcopy(canonical.rows[1])
	end
	structural_hunks(value)
	return value
end

local function local_status(result, canonical, decoded)
	for _, field in ipairs({ "aligned_lines", "chunks" }) do
		if decoded[field] ~= nil and (not list(decoded[field]) or #decoded[field] > 0) then
			return nil, "Difftastic " .. result.status .. " output must omit alignment and chunks"
		end
	end
	result.aligned_lines = projection.alignment(canonical)
	if result.status == "created" or result.status == "deleted" then
		local side = result.status == "created" and "new" or "old"
		local other = side == "old" and "new" or "old"
		if canonical.sources[other].line_count ~= 0 or canonical.sources[side].line_count == 0 then
			return nil, "Difftastic creation or deletion status contradicts frozen source bytes"
		end
		for line, record in ipairs(canonical.sources[side].lines) do
			result.line_changes[side][line] = true
			if #record.text > 0 then
				result.intraline[side][#result.intraline[side] + 1] =
					{ line = line, start_col = 0, end_col = #record.text }
			end
		end
	end
	return true
end

---Normalize only structural changes, preserving canonical bytes and anchors.
---@param entry table Frozen canonical review entry.
---@param decoded table Single-file Difftastic 0.71.0 JSON object.
---@return table? analysis
---@return string? err
function M.normalize(entry, decoded)
	local canonical, projection_err = projection.build(entry)
	if not canonical then
		return nil, projection_err
	end
	if
		not object(decoded)
		or type(decoded.language) ~= "string"
		or decoded.language == ""
		or type(decoded.path) ~= "string"
		or not STATUSES[decoded.status]
	then
		return nil, "Difftastic output must be a single-file object with language, path, and status"
	end
	if
		decoded.path ~= canonical.sources.old.path
		and decoded.path ~= canonical.sources.new.path
		and decoded.path ~= entry.path
	then
		return nil, "Difftastic output path does not match the frozen review entry"
	end
	if decoded.language == "Text" or decoded.language:match("^Text %(.+%)$") then
		return { fallback_reason = "Difftastic used " .. decoded.language .. "; using Main for this file" }
	end
	local lines, lines_err = source_lines(canonical.sources)
	if not lines then
		return nil, lines_err
	end
	local result = {
		presentation = "projected",
		structural_only = true,
		relations = {},
		aligned_lines = {},
		intraline = { old = {}, new = {} },
		language = decoded.language,
		line_changes = { old = {}, new = {} },
		status = decoded.status,
	}
	if decoded.status == "changed" then
		local alignment, alignment_err, owners = normalized_alignment(decoded.aligned_lines, canonical.sources)
		if not alignment then
			return nil, alignment_err
		end
		result.aligned_lines = alignment
		local valid, chunks_err = normalize_chunks(result, decoded.chunks, lines, owners)
		if not valid then
			return nil, chunks_err
		end
	else
		local valid, status_err = local_status(result, canonical, decoded)
		if not valid then
			return nil, status_err
		end
	end
	result.projection = structural_projection(canonical, result)
	return result
end

return M
