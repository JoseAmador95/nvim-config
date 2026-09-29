-- Adapt the pinned md-render table renderer for a reading view. Its compact
-- default discards cell text, and even its expanded mode can truncate a long
-- unbreakable token. Keep the upstream checkout intact and limit the adapter
-- to the exact version checked by config.markdown_view.
local M = {}

local installed

local function frontmatter_offset(lines)
	if not (lines[1] and lines[1]:match("^%-%-%-%s*$")) then
		return 0
	end
	for line = 2, #lines do
		if lines[line]:match("^%-%-%-%s*$") then
			return line
		end
	end
	return 0
end

local function table_start(lines, block_id, offset)
	if type(block_id) ~= "number" or block_id < 1 or block_id + offset > #lines then
		return false
	end
	local line = lines[block_id + offset]
	if type(line) ~= "string" then
		return false
	end
	line = line:gsub("^%s*>+%s*", ""):gsub("^%s*", "")
	return line:sub(1, 1) == "|" or line:lower():match("^<table[%s>]") ~= nil
end

local function split_ascii_characters(word, word_start, leading_space)
	local segments = {}
	for index = 1, #word do
		segments[index] = {
			text = word:sub(index, index),
			byte_pos = word_start + index - 1,
			has_leading_space = index == 1 and leading_space or false,
		}
	end
	return segments
end

local function has_ellipsis(lines)
	for _, line in ipairs(lines) do
		if line:find("…", 1, true) then
			return true
		end
	end
	return false
end

local function restore_link_text(cell, raw_line)
	for _, link in ipairs(cell.links) do
		local first = link.col_start
		local last = link.col_end
		local shown = cell.text:sub(first + 1, last)
		local prefix = shown:match("^(.*)…$")
		if
			prefix
			and link.url ~= shown
			and link.url:sub(1, #prefix) == prefix
			and not raw_line:find(shown, 1, true)
		then
			local delta = #link.url - (last - first)
			cell.text = cell.text:sub(1, first) .. link.url .. cell.text:sub(last + 1)
			for _, highlight in ipairs(cell.highlights) do
				if highlight.col >= last then
					highlight.col = highlight.col + delta
				end
				if highlight.end_col >= last then
					highlight.end_col = highlight.end_col + delta
				end
			end
			for _, other in ipairs(cell.links) do
				if other.col_start >= last then
					other.col_start = other.col_start + delta
				end
				if other.col_end >= last then
					other.col_end = other.col_end + delta
				end
			end
		end
	end
end

local function restore_table_links(parsed)
	for _, cell in ipairs(parsed.headers) do
		restore_link_text(cell, parsed._raw_lines[1])
	end
	for row_index, row in ipairs(parsed.rows) do
		for _, cell in ipairs(row) do
			restore_link_text(cell, parsed._raw_lines[row_index + 2])
		end
	end
	for column = 1, #parsed.headers do
		local width = vim.api.nvim_strwidth(parsed.headers[column].text)
		for _, row in ipairs(parsed.rows) do
			width = math.max(width, vim.api.nvim_strwidth(row[column].text))
		end
		parsed.col_widths[column] = width
	end
	return parsed
end

function M.protect_rebuild(session)
	if session.nvim_config_readonly_rebuild then
		return
	end
	local original_rebuild = session.rebuild
	session.rebuild = function(self, ...)
		local was_readonly = vim.bo[self.buf].readonly
		if was_readonly then
			vim.bo[self.buf].readonly = false
		end
		local ok, err = pcall(original_rebuild, self, ...)
		if vim.api.nvim_buf_is_valid(self.buf) then
			vim.bo[self.buf].readonly = was_readonly
			for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
				if vim.api.nvim_win_is_valid(win) then
					vim.wo[win].wrap = false
				end
			end
		end
		if not ok then
			error(err, 0)
		end
	end
	session.nvim_config_readonly_rebuild = true
end

function M.configure(preview, wrap, markdown_table)
	if installed then
		if
			installed.preview == preview
			and installed.wrap == wrap
			and installed.markdown_table == markdown_table
			and preview.build_content == installed.build_content
			and wrap.split_ascii_syllables == installed.split_characters
			and markdown_table.parse == installed.parse_table
			and markdown_table.render == installed.render_table
		then
			return true
		end
		return nil, "table adapter modules changed after configuration"
	end
	if
		type(preview.build_content) ~= "function"
		or type(wrap.split_ascii_syllables) ~= "function"
		or type(markdown_table.parse) ~= "function"
		or type(markdown_table.render) ~= "function"
	then
		return nil, "v3.10.3 table adapter contract changed"
	end

	local original_build_content = preview.build_content
	local original_split_characters = wrap.split_ascii_syllables
	local original_parse_table = markdown_table.parse
	local original_render_table = markdown_table.render
	local function split_characters(word, word_start, leading_space)
		for index = 1, #word do
			if word:byte(index) > 127 then
				return original_split_characters(word, word_start, leading_space)
			end
		end
		return split_ascii_characters(word, word_start, leading_space)
	end
	local function build_content(lines, opts)
		local content = original_build_content(lines, opts)
		local state = opts and opts.expand_state
		if type(state) ~= "table" then
			return content
		end
		local changed = false
		local offset = frontmatter_offset(lines)
		for _, region in ipairs(content.expandable_regions or {}) do
			local block_id = region.block_id
			if state[block_id] == nil and table_start(lines, block_id, offset) then
				state[block_id] = true
				changed = true
			end
		end
		if changed then
			return original_build_content(lines, opts)
		end
		return content
	end
	local function render_table(parsed, indent, max_width, expanded, buf_dir)
		local lines, highlights, links, images, source_offsets =
			original_render_table(parsed, indent, max_width, expanded, buf_dir)
		if expanded and max_width and has_ellipsis(lines) then
			-- An indivisible glyph or token can still defeat upstream wrapping.
			-- Keep the full table in the buffer and allow horizontal scrolling.
			return original_render_table(parsed, indent, nil, false, buf_dir)
		end
		return lines, highlights, links, images, source_offsets
	end
	local function parse_table(...)
		local parsed = original_parse_table(...)
		return parsed and restore_table_links(parsed) or nil
	end

	preview.build_content = build_content
	wrap.split_ascii_syllables = split_characters
	markdown_table.parse = parse_table
	markdown_table.render = render_table
	installed = {
		preview = preview,
		wrap = wrap,
		markdown_table = markdown_table,
		build_content = build_content,
		split_characters = split_characters,
		parse_table = parse_table,
		render_table = render_table,
	}
	return true
end

return M
