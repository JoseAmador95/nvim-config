-- Bounded, source-coordinate intraline refinement of frozen canonical hunks.
local M = {}

local MAX_GRAPHEMES = 8192
local MAX_INPUT_BYTES = MAX_GRAPHEMES * 16
local LINE_OPTIONS = { result_type = "indices", algorithm = "histogram", indent_heuristic = true, linematch = 60 }
local CHARACTER_OPTIONS = { result_type = "indices", algorithm = "myers" }

local function lines(text)
	local result = {}
	local offset = 1
	while offset <= #text do
		local boundary = text:find("\n", offset, true)
		local value = text:sub(offset, boundary and boundary - 1 or -1)
		if boundary and value:sub(-1) == "\r" then
			value = value:sub(1, -2)
		end
		result[#result + 1] = value
		if not boundary then
			break
		end
		offset = boundary + 1
	end
	return result
end

local function slice(source, first, count)
	local values = {}
	for index = first, first + count - 1 do
		assert(source[index] ~= nil, "intraline hunk exceeds its source")
		values[#values + 1] = source[index]
	end
	return count == 0 and "" or table.concat(values, "\n") .. "\n"
end

local function tokens(source, first, count)
	local result = { values = {}, positions = {}, changed = {} }
	for line = first, first + count - 1 do
		local column = 0
		for _, value in ipairs(vim.fn.split(source[line], "\\zs")) do
			result.values[#result.values + 1] = value
			result.positions[#result.values] = { line = line, start_col = column, end_col = column + #value }
			column = column + #value
		end
		if line < first + count - 1 then
			result.values[#result.values + 1] = "\n"
		end
	end
	return result
end

local function encoded(sequence, first, last)
	local values = {}
	for index = first, last do
		-- Hex keeps real newlines and every UTF-8 grapheme one xdiff line.
		values[#values + 1] = (
			sequence.values[index]:gsub(".", function(byte)
				return ("%02x"):format(byte:byte())
			end)
		)
	end
	return #values == 0 and "" or table.concat(values, "\n") .. "\n"
end

local function append_ranges(target, sequence, first, count)
	for index = first, first + count - 1 do
		local position = sequence.positions[index]
		if position then
			local previous = target[#target]
			if previous and previous.line == position.line and previous.end_col == position.start_col then
				previous.end_col = position.end_col
			else
				target[#target + 1] = vim.deepcopy(position)
			end
		end
	end
end

local function word_grapheme(value)
	-- Fixed spelling rules keep frozen detail independent of buffer 'iskeyword'.
	return value:match("^[A-Za-z0-9_]") ~= nil or vim.fn.tolower(value) ~= vim.fn.toupper(value)
end

local function append_word_ranges(target, sequence)
	local index = 1
	while index <= #sequence.values do
		if word_grapheme(sequence.values[index]) then
			local first, changed = index, 0
			repeat
				changed = changed + (sequence.changed[index] and 1 or 0)
				index = index + 1
			until index > #sequence.values or not word_grapheme(sequence.values[index])
			-- A single surviving letter is noise when the rest of the word changed.
			if changed >= 2 and index - first - changed == 1 then
				for selected = first, index - 1 do
					sequence.changed[selected] = true
				end
			end
		else
			index = index + 1
		end
	end
	for selected = 1, #sequence.values do
		if sequence.changed[selected] then
			append_ranges(target, sequence, selected, 1)
		end
	end
end

local function refine_characters(result, old_source, new_source, old_first, old_count, new_first, new_count)
	if old_count == 0 or new_count == 0 then
		return
	end
	if #slice(old_source, old_first, old_count) + #slice(new_source, new_first, new_count) > MAX_INPUT_BYTES then
		result.limited = true
		return
	end
	local old = tokens(old_source, old_first, old_count)
	local new = tokens(new_source, new_first, new_count)
	local first = 1
	while first <= #old.values and first <= #new.values and old.values[first] == new.values[first] do
		first = first + 1
	end
	local old_last, new_last = #old.values, #new.values
	while old_last >= first and new_last >= first and old.values[old_last] == new.values[new_last] do
		old_last = old_last - 1
		new_last = new_last - 1
	end
	if old_last - first + new_last - first + 2 > MAX_GRAPHEMES then
		result.limited = true
		return
	end
	for _, hunk in
		ipairs(vim.text.diff(encoded(old, first, old_last), encoded(new, first, new_last), CHARACTER_OPTIONS))
	do
		for index = first + hunk[1] - 1, first + hunk[1] + hunk[2] - 2 do
			old.changed[index] = true
		end
		for index = first + hunk[3] - 1, first + hunk[3] + hunk[4] - 2 do
			new.changed[index] = true
		end
	end
	append_word_ranges(result.old, old)
	append_word_ranges(result.new, new)
end

---Refine replacements without altering canonical hunks, bytes, or anchors.
---@param entry table
---@return table? result OLD/NEW ranges: one-based lines, zero-based exclusive byte columns.
---@return string? err
function M.refine(entry)
	local result = { old = {}, new = {}, limited = false }
	if entry.metadata_only or entry.binary then
		return result
	end
	local old_source = lines(entry.old_text or "")
	local new_source = lines(entry.new_text or "")
	local ok, err = pcall(function()
		for _, canonical in ipairs(entry.hunks or {}) do
			local old_first, old_count, new_first, new_count = unpack(canonical)
			if old_count > 0 and new_count > 0 then
				local old_text = slice(old_source, old_first, old_count)
				local new_text = slice(new_source, new_first, new_count)
				for _, hunk in ipairs(vim.text.diff(old_text, new_text, LINE_OPTIONS)) do
					refine_characters(
						result,
						old_source,
						new_source,
						old_first + hunk[1] - 1,
						hunk[2],
						new_first + hunk[3] - 1,
						hunk[4]
					)
				end
			end
		end
	end)
	if not ok then
		return nil, tostring(err)
	end
	return result
end

---Reuse the selected entry's detail across presentation-only transitions.
---@param state table
---@param entry table
---@return table? result
---@return string? err
function M.for_entry(state, entry)
	local cached = state.intraline_cache
	if
		cached
		and cached.old_text == entry.old_text
		and cached.new_text == entry.new_text
		and cached.metadata_only == entry.metadata_only
		and cached.binary == entry.binary
		and vim.deep_equal(cached.hunks, entry.hunks)
	then
		return cached.result
	end
	local result, err = M.refine(entry)
	if result then
		state.intraline_cache = {
			old_text = entry.old_text,
			new_text = entry.new_text,
			hunks = vim.deepcopy(entry.hunks),
			metadata_only = entry.metadata_only,
			binary = entry.binary,
			result = result,
		}
	end
	return result, err
end

return M
