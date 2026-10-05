-- Markdown image reference parsing. Pure string work: no filesystem access, no
-- buffers, and no host policy. Resolving a reference to a file, deciding what is
-- loadable, and reading it stay with the host adapter.
local M = {}

local SOF = "^%s*%[(.-)%]:%s*(.*)$"

local function after_spaces(line, pos)
	return line:find("[^ \t]", pos) or (#line + 1)
end

---Read a bracketed span starting at `pos`, honoring nesting and escapes.
---@param line string
---@param pos integer index of the opening bracket
---@return string|nil text, integer|nil next_pos
local function bracketed(line, pos)
	local depth = 0
	local start = pos + 1
	local index = pos
	while index <= #line do
		local char = line:sub(index, index)
		if char == "\\" then
			index = index + 2
		elseif char == "[" then
			depth = depth + 1
			index = index + 1
		elseif char == "]" then
			depth = depth - 1
			if depth == 0 then
				return line:sub(start, index - 1), index + 1
			end
			index = index + 1
		else
			index = index + 1
		end
	end
	return nil
end

---Read an inline destination plus its optional title, ending past the ")".
---@param line string
---@param pos integer index just past the opening parenthesis
---@return string|nil destination, integer|nil next_pos
local function destination(line, pos)
	pos = after_spaces(line, pos)
	local text
	if line:sub(pos, pos) == "<" then
		local close = line:find(">", pos + 1, true)
		if not close then
			return nil
		end
		text = line:sub(pos + 1, close - 1)
		pos = close + 1
	else
		local depth = 0
		local start = pos
		while pos <= #line do
			local char = line:sub(pos, pos)
			if char == "\\" then
				pos = pos + 2
			elseif char == "(" then
				depth = depth + 1
				pos = pos + 1
			elseif char == ")" then
				if depth == 0 then
					break
				end
				depth = depth - 1
				pos = pos + 1
			elseif char == " " or char == "\t" then
				break
			else
				pos = pos + 1
			end
		end
		text = line:sub(start, pos - 1)
	end
	pos = after_spaces(line, pos)
	local quote = line:sub(pos, pos)
	if quote == '"' or quote == "'" or quote == "(" then
		local close = line:find(quote == "(" and ")" or quote, pos + 1, true)
		if not close then
			return nil
		end
		pos = after_spaces(line, close + 1)
	end
	if line:sub(pos, pos) ~= ")" then
		return nil
	end
	return text, pos + 1
end

local function markdown_images(line, images)
	local pos = 1
	while true do
		local bang = line:find("![", pos, true)
		if not bang then
			return
		end
		pos = bang + 2
		local alt, after = bracketed(line, bang + 1)
		if alt then
			local char = line:sub(after, after)
			if char == "(" then
				local link, finish = destination(line, after + 1)
				if link then
					images[#images + 1] = {
						link = link,
						alt = alt,
						style = "inline",
						start_col = bang,
						end_col = finish - 1,
					}
					pos = finish
				end
			elseif char == "[" then
				local label, finish = bracketed(line, after)
				if label then
					images[#images + 1] = {
						alt = alt,
						label = label ~= "" and label or alt,
						style = "reference",
						start_col = bang,
						end_col = finish - 1,
					}
					pos = finish
				end
			end
		end
	end
end

local function attribute(tag, name)
	return tag:match("[%s\"']" .. name .. '%s*=%s*"([^"]*)"')
		or tag:match("[%s\"']" .. name .. "%s*=%s*'([^']*)'")
		or tag:match("[%s\"']" .. name .. "%s*=%s*([^%s>]+)")
end

local function html_images(line, images)
	local pos = 1
	while true do
		local start = line:find("<[iI][mM][gG][%s/>]", pos)
		if not start then
			return
		end
		local close = line:find(">", start + 4, true)
		local finish = close or #line
		local tag = line:sub(start, finish)
		local link = attribute(tag, "[sS][rR][cC]")
		if link and link ~= "" then
			images[#images + 1] = {
				link = link,
				alt = attribute(tag, "[aA][lL][tT]"),
				style = "html",
				start_col = start,
				end_col = finish,
			}
		end
		pos = finish + 1
	end
end

---Return every image reference in one line, ordered by column.
---@param line string
---@return table[]|nil images, string|nil error
function M.parse_line(line)
	if type(line) ~= "string" then
		return nil, "line must be a string"
	end
	local images = {}
	markdown_images(line, images)
	html_images(line, images)
	table.sort(images, function(left, right)
		return left.start_col < right.start_col
	end)
	return images
end

---Return the destination of a link reference definition, if the lines carry one.
---@param lines string[]
---@param label string
---@return string|nil
function M.definition(lines, label)
	if type(lines) ~= "table" or type(label) ~= "string" then
		return nil
	end
	local wanted = label:lower()
	for _, line in ipairs(lines) do
		if type(line) == "string" then
			local name, rest = line:match(SOF)
			if name and name:lower() == wanted then
				rest = vim.trim(rest)
				local angled = rest:match("^<(.-)>")
				if angled then
					return angled
				end
				local link = rest:match("^(%S+)")
				if link and link ~= "" then
					return link
				end
			end
		end
	end
	return nil
end

---Return the image reference that owns `col` on `row`, else the row's first one.
---A nil column is normal: the rendered reading view maps rows, never columns.
---@param lines string[]
---@param row integer
---@param col integer|nil one-based column
---@return table|nil image, string|nil error
function M.at(lines, row, col)
	if type(lines) ~= "table" then
		return nil, "lines must be a list"
	end
	local line = lines[row]
	if type(line) ~= "string" then
		return nil, "image row is out of range"
	end
	local images, parse_err = M.parse_line(line)
	if not images then
		return nil, parse_err
	end
	if #images == 0 then
		return nil
	end
	local chosen
	if type(col) == "number" then
		for _, image in ipairs(images) do
			if col >= image.start_col and col <= image.end_col then
				chosen = image
				break
			end
		end
	end
	chosen = chosen or images[1]
	if chosen.style == "reference" then
		local link = M.definition(lines, chosen.label)
		if not link then
			return nil, ("no link definition for [%s]"):format(chosen.label)
		end
		chosen = vim.tbl_extend("force", chosen, { link = link })
	end
	return chosen
end

return M
