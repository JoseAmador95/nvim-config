local M = {}

local image_link = require("diagram_view.image_link")

local LANGUAGES = {
	mermaid = "mermaid",
	plantuml = "plantuml",
	puml = "plantuml",
	uml = "plantuml",
}

local function copy(value)
	return vim.deepcopy(value)
end

local function normalized_lines(opts)
	if type(opts.lines) == "table" then
		local lines = {}
		for index, line in ipairs(opts.lines) do
			if type(line) ~= "string" then
				return nil, ("lines[%d] must be a string"):format(index)
			end
			lines[index] = line
		end
		return lines
	end
	if type(opts.bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(opts.bufnr) then
		return nil, "extract requires lines or a valid bufnr"
	end
	return vim.api.nvim_buf_get_lines(opts.bufnr, 0, -1, false)
end

local function source_position(opts)
	local explicit_row
	if type(opts.row) == "number" and opts.row >= 1 and opts.row % 1 == 0 then
		explicit_row = opts.row
	end
	local explicit_col
	if type(opts.col) == "number" and opts.col >= 1 and opts.col % 1 == 0 then
		explicit_col = opts.col
	end
	if explicit_row and explicit_col then
		return explicit_row, explicit_col
	end
	local buf = opts.bufnr
	if not buf then
		return explicit_row or 1, explicit_col
	end
	local function cursor_for_window(win)
		if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			return vim.api.nvim_win_get_cursor(win)
		end
	end
	local cursor = cursor_for_window(opts.winid) or cursor_for_window(vim.api.nvim_get_current_win())
	if not cursor then
		for _, win in ipairs(vim.fn.win_findbuf(buf)) do
			cursor = cursor_for_window(win)
			if cursor then
				break
			end
		end
	end
	if cursor then
		-- An explicit row wins: the rendered reading view maps rows only, so its
		-- cursor column belongs to the render, never to the source line.
		if explicit_row then
			return explicit_row, explicit_col
		end
		return cursor[1], explicit_col or (cursor[2] + 1)
	end
	if explicit_row then
		return explicit_row, explicit_col
	end
	local mark = vim.api.nvim_buf_get_mark(buf, '"')
	return mark[1] > 0 and mark[1] or 1, explicit_col
end

function M.find_fences(lines, accepted)
	if type(lines) ~= "table" then
		return nil, "lines must be a list"
	end
	accepted = accepted or LANGUAGES
	local result = {}
	local open
	for index, line in ipairs(lines) do
		if type(line) ~= "string" then
			return nil, ("lines[%d] must be a string"):format(index)
		end
		local fence, rest = line:match("^%s*(```+)(.*)$")
		if fence and rest:sub(1, 1) == "~" then
			fence, rest = nil, nil
		end
		if not fence then
			fence, rest = line:match("^%s*(~~~+)(.*)$")
			if fence and rest:sub(1, 1) == "`" then
				fence, rest = nil, nil
			end
		end
		if fence then
			if not open then
				local language = (vim.trim(rest):match("^(%S*)") or ""):lower()
				open = { char = fence:sub(1, 1), length = #fence, language = language, start_row = index }
			elseif fence:sub(1, 1) == open.char and #fence >= open.length and vim.trim(rest) == "" then
				local kind = accepted[open.language]
				if kind then
					result[#result + 1] = {
						kind = kind == true and open.language or kind,
						language = open.language,
						start_row = open.start_row,
						end_row = index,
						source = table.concat(vim.list_slice(lines, open.start_row + 1, index - 1), "\n"),
					}
				end
				open = nil
			end
		end
	end
	return result
end

local function infer_kind(filetype, explicit)
	if explicit ~= nil then
		if explicit ~= "mermaid" and explicit ~= "plantuml" then
			return nil, "kind must be mermaid or plantuml"
		end
		return explicit
	end
	return LANGUAGES[(filetype or ""):lower()] or "mermaid"
end

function M.extract(opts)
	if type(opts) ~= "table" then
		return nil, "extract options must be a table"
	end
	local lines, lines_err = normalized_lines(opts)
	if not lines then
		return nil, lines_err
	end
	local filetype = opts.filetype
	if filetype == nil and opts.bufnr then
		filetype = vim.bo[opts.bufnr].filetype
	end
	filetype = type(filetype) == "string" and filetype:lower() or ""
	local kind, kind_err = infer_kind(filetype, opts.kind)
	if not kind then
		return nil, kind_err
	end

	if opts.selection ~= nil then
		if type(opts.selection) ~= "table" then
			return nil, "selection must be a table"
		end
		local first = opts.selection.start_row
		local last = opts.selection.end_row
		if
			type(first) ~= "number"
			or type(last) ~= "number"
			or first % 1 ~= 0
			or last % 1 ~= 0
			or first < 1
			or last < first
			or last > #lines
		then
			return nil, "selection rows are invalid"
		end
		return {
			kind = kind,
			source = table.concat(vim.list_slice(lines, first, last), "\n"),
			origin = { type = "selection", start_row = first, end_row = last },
		}
	end

	if filetype == "markdown" then
		local fences, fence_err = M.find_fences(lines, LANGUAGES)
		if not fences then
			return nil, fence_err
		end
		local row, col = source_position(opts)
		for _, fence in ipairs(fences) do
			if row >= fence.start_row and row <= fence.end_row then
				return {
					kind = fence.kind,
					source = fence.source,
					origin = {
						type = "fence",
						language = fence.language,
						start_row = fence.start_row,
						end_row = fence.end_row,
					},
				}
			end
		end
		local image, image_err = image_link.at(lines, row, col)
		if image then
			return {
				kind = "image",
				source = image.link,
				origin = {
					type = "image",
					style = image.style,
					alt = image.alt,
					label = image.label,
					row = row,
					start_col = image.start_col,
					end_col = image.end_col,
				},
			}
		end
		if image_err then
			return nil, image_err
		end
		return nil, "no mermaid/plantuml diagram or image under the cursor"
	end

	return {
		kind = kind,
		source = table.concat(lines, "\n"),
		origin = { type = "buffer", start_row = 1, end_row = #lines },
	}
end

function M.languages()
	return copy(LANGUAGES)
end

return M
