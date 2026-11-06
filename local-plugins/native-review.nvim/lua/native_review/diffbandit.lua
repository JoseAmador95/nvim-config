-- Validate the worker's textual presentation against the exact frozen sources.
local projection = require("native_review.projection")
local M = {}

local function integer(value)
	return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

local function boundary(text, col)
	local byte = text:byte(col + 1)
	return not byte or byte < 128 or byte >= 192
end

function M.normalize(entry, decoded)
	if type(decoded) ~= "table" or type(decoded.hunks) ~= "table" or not vim.islist(decoded.hunks) then
		return nil, "Diffbandit output requires textual hunks"
	end
	for _, hunk in ipairs(decoded.hunks) do
		if type(hunk) ~= "table" or not vim.islist(hunk) or #hunk ~= 4 then
			return nil, "Diffbandit hunk must contain four indices"
		end
	end
	local value, err = projection.build({
		old_text = entry.old_text,
		new_text = entry.new_text,
		old_path = entry.old_path,
		new_path = entry.new_path,
		hunks = decoded.hunks,
	})
	if not value then
		return nil, "Invalid Diffbandit hunks: " .. err
	end
	local result = {
		presentation = "projected",
		structural_only = false,
		projection = value,
		aligned_lines = projection.alignment(value),
		line_changes = { old = {}, new = {} },
		intraline = { old = {}, new = {} },
	}
	for _, row in ipairs(value.rows) do
		if row.kind == "old" or row.kind == "new" then
			result.line_changes[row.kind][row.source_line] = true
		end
	end
	if type(decoded.intraline) ~= "table" then
		return nil, "Diffbandit output requires intraline ranges"
	end
	for _, side in ipairs({ "old", "new" }) do
		local ranges = decoded.intraline[side]
		if type(ranges) ~= "table" or not vim.islist(ranges) then
			return nil, "Diffbandit intraline ranges must be lists"
		end
		for _, range in ipairs(ranges) do
			if
				type(range) ~= "table"
				or not integer(range.line)
				or not integer(range.start_col)
				or not integer(range.end_col)
			then
				return nil, "Diffbandit range requires integer coordinates"
			end
			local line = value.sources[side].lines[range.line]
			local text = line and (line.text .. (line.terminator == "\r\n" and "\r" or ""))
			if
				not text
				or not result.line_changes[side][range.line]
				or range.start_col >= range.end_col
				or range.end_col > #text
				or not boundary(text, range.start_col)
				or not boundary(text, range.end_col)
			then
				return nil, "Diffbandit range is outside changed source bytes or UTF-8 boundaries"
			end
			local first, last = math.min(range.start_col, #line.text), math.min(range.end_col, #line.text)
			if first < last then
				result.intraline[side][#result.intraline[side] + 1] =
					{ line = range.line, start_col = first, end_col = last }
			end
		end
		table.sort(result.intraline[side], function(a, b)
			return a.line < b.line or (a.line == b.line and a.start_col < b.start_col)
		end)
	end
	return result
end

return M
