local editor_actions = require("config.editor_actions")

local M = {}

local function capitalize(value)
	if value == "" then
		return value
	end
	local first = vim.fn.strcharpart(value, 0, 1)
	local rest = vim.fn.strcharpart(value, 1)
	return vim.fn.toupper(first) .. vim.fn.tolower(rest)
end

local function words(value)
	value = value:gsub("([a-z0-9])([A-Z])", "%1 %2")
	local result = {}
	for word in value:gmatch("[%w\128-\255]+") do
		result[#result + 1] = vim.fn.tolower(word)
	end
	return result
end

local function identifier_case(value, kind)
	local tokens = words(value)
	if #tokens == 0 then
		return value
	end
	if kind == "title" then
		for index, token in ipairs(tokens) do
			tokens[index] = capitalize(token)
		end
		return table.concat(tokens, " ")
	elseif kind == "camel" then
		for index = 2, #tokens do
			tokens[index] = capitalize(tokens[index])
		end
		return table.concat(tokens)
	elseif kind == "pascal" then
		for index, token in ipairs(tokens) do
			tokens[index] = capitalize(token)
		end
		return table.concat(tokens)
	elseif kind == "snake" then
		return table.concat(tokens, "_")
	elseif kind == "kebab" then
		return table.concat(tokens, "-")
	end
	return value
end

local function toggle_case(value)
	local characters = vim.fn.split(value, "\\zs")
	for index, character in ipairs(characters) do
		local upper = vim.fn.toupper(character)
		local lower = vim.fn.tolower(character)
		if upper ~= lower then
			characters[index] = character == upper and lower or upper
		end
	end
	return table.concat(characters)
end

local function apply_case(value, kind)
	if kind == "upper" then
		return vim.fn.toupper(value)
	elseif kind == "lower" then
		return vim.fn.tolower(value)
	elseif kind == "toggle" then
		return toggle_case(value)
	end
	return identifier_case(value, kind)
end

local function character_end(line, column)
	if column >= #line then
		return #line
	end
	return math.min(column + #vim.fn.strcharpart(line:sub(column + 1), 0, 1), #line)
end

local function ordered_positions(left, right)
	if left.line < right.line or (left.line == right.line and left.col <= right.col) then
		return left, right
	end
	return right, left
end

local function word_range(target)
	local line = vim.api.nvim_buf_get_lines(target.bufnr, target.cursor.line - 1, target.cursor.line, false)[1] or ""
	local offset = 0
	while offset <= #line do
		local match = vim.fn.matchstrpos(line, [[\k\+]], offset)
		local start_col = match[2]
		local end_col = match[3]
		if start_col < 0 then
			break
		end
		if start_col <= target.cursor.col and target.cursor.col < end_col then
			return { { line = target.cursor.line, start_col = start_col, end_col = end_col } }
		end
		offset = math.max(end_col, start_col + 1)
	end
	return nil, "No word under the origin cursor"
end

local function line_range(target)
	local line = vim.api.nvim_buf_get_lines(target.bufnr, target.cursor.line - 1, target.cursor.line, false)[1] or ""
	return { { line = target.cursor.line, start_col = 0, end_col = #line } }
end

local function selection_range(target)
	local selection = target.selection
	if not selection then
		return nil, "No visual selection was captured"
	end
	local first, last = ordered_positions(selection.anchor, selection.cursor)
	local segments = {}

	if selection.mode == "V" then
		for line_number = first.line, last.line do
			local line = vim.api.nvim_buf_get_lines(target.bufnr, line_number - 1, line_number, false)[1] or ""
			segments[#segments + 1] = { line = line_number, start_col = 0, end_col = #line }
		end
		return segments
	end

	if selection.mode == "\22" then
		local start_col = math.min(first.col, last.col)
		local selected_col = math.max(first.col, last.col)
		for line_number = first.line, last.line do
			local line = vim.api.nvim_buf_get_lines(target.bufnr, line_number - 1, line_number, false)[1] or ""
			segments[#segments + 1] = {
				line = line_number,
				start_col = math.min(start_col, #line),
				end_col = character_end(line, math.min(selected_col, #line)),
			}
		end
		return segments
	end

	for line_number = first.line, last.line do
		local line = vim.api.nvim_buf_get_lines(target.bufnr, line_number - 1, line_number, false)[1] or ""
		local start_col = line_number == first.line and first.col or 0
		local end_col = line_number == last.line and character_end(line, last.col) or #line
		segments[#segments + 1] = {
			line = line_number,
			start_col = math.min(start_col, #line),
			end_col = math.min(end_col, #line),
		}
	end
	return segments
end

local function ranges(scope, target)
	if scope == "word" then
		return word_range(target)
	elseif scope == "line" then
		return line_range(target)
	elseif scope == "selection" then
		return selection_range(target)
	end
	return nil, "Unknown transform scope: " .. tostring(scope)
end

---@param kind "upper"|"lower"|"toggle"|"title"|"camel"|"pascal"|"snake"|"kebab"
---@param scope "word"|"line"|"selection"
---@param target table
---@return boolean, string?
function M.apply(kind, scope, target)
	local success
	local failure
	local ok, err = editor_actions.with_target(target, { modifiable = true }, function(origin)
		local segments, range_err = ranges(scope, origin)
		if not segments then
			failure = range_err
			return
		end
		local view = vim.api.nvim_win_is_valid(origin.winid) and vim.fn.winsaveview() or nil
		local changed = false
		for index = #segments, 1, -1 do
			local segment = segments[index]
			local text = vim.api.nvim_buf_get_text(
				origin.bufnr,
				segment.line - 1,
				segment.start_col,
				segment.line - 1,
				segment.end_col,
				{}
			)[1] or ""
			local replacement = apply_case(text, kind)
			if replacement ~= text then
				if changed then
					pcall(vim.cmd, "undojoin")
				end
				vim.api.nvim_buf_set_text(
					origin.bufnr,
					segment.line - 1,
					segment.start_col,
					segment.line - 1,
					segment.end_col,
					{ replacement }
				)
				changed = true
			end
		end
		if view then
			vim.fn.winrestview(view)
		end
		success = changed
		if not changed then
			failure = "Transform made no changes"
		end
	end)
	if not ok then
		return false, tostring(err)
	end
	return success == true, failure
end

return M
