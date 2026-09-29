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

-- A literal ellipsis in a cell is content, not evidence of truncation.
-- Probe a same-width, same-byte-length copy only when the rendered table
-- contains one; any remaining ellipsis was inserted by md-render.
local function generated_ellipsis(parsed, lines, indent, max_width, expanded, buf_dir, original_render)
	if not has_ellipsis(lines) then
		return false
	end
	local substitute = "⋯"
	if vim.api.nvim_strwidth("…") ~= vim.api.nvim_strwidth(substitute) then
		return true
	end
	local copy = vim.deepcopy(parsed)
	for _, cell in ipairs(copy.headers) do
		cell.text = cell.text:gsub("…", substitute)
	end
	for _, row in ipairs(copy.rows) do
		for _, cell in ipairs(row) do
			cell.text = cell.text:gsub("…", substitute)
		end
	end
	local probe_lines = original_render(copy, indent, max_width, expanded, buf_dir)
	return has_ellipsis(probe_lines)
end

local function exceeds_width(lines, max_width)
	for _, line in ipairs(lines) do
		if vim.api.nvim_strwidth(line) > max_width then
			return true
		end
	end
	return false
end

-- A narrow table can have more columns than md-render can fit even when
-- every cell is wrapped. Reflow each source row as bounded key/value rows.
-- Slice parsed cells by byte offset so their inline highlights and links
-- retain the exact ranges supplied by md-render's Markdown parser.
local function slice_cell(cell, first, last)
	local sliced = { text = cell.text:sub(first + 1, last), highlights = {}, links = {} }
	for _, highlight in ipairs(cell.highlights) do
		local ending = highlight.end_col == -1 and #cell.text or highlight.end_col
		local start = math.max(first, highlight.col)
		local finish = math.min(last, ending)
		if start < finish then
			local copy = vim.deepcopy(highlight)
			copy.col = start - first
			copy.end_col = finish - first
			table.insert(sliced.highlights, copy)
		end
	end
	for _, link in ipairs(cell.links) do
		local start = math.max(first, link.col_start)
		local finish = math.min(last, link.col_end)
		if start < finish then
			local copy = vim.deepcopy(link)
			copy.col_start = start - first
			copy.col_end = finish - first
			table.insert(sliced.links, copy)
		end
	end
	return sliced
end

local function grapheme_clusters(text)
	local clusters = {}
	local pending = ""
	for char in text:gmatch("[%z\1-\127\194-\253][\128-\191]*") do
		if pending ~= "" and vim.fn.strchars(pending .. char, 1) > 1 then
			table.insert(clusters, pending)
			pending = char
		else
			pending = pending .. char
		end
	end
	if pending ~= "" then
		table.insert(clusters, pending)
	end
	return clusters
end

local function split_cell(cell, width)
	if cell.text == "" then
		return { slice_cell(cell, 0, 0) }
	end
	local slices = {}
	local first = 0
	local cursor = 0
	local display_width = 0
	local last_space
	for _, cluster in ipairs(grapheme_clusters(cell.text)) do
		local cluster_width = vim.api.nvim_strwidth(cluster)
		if display_width + cluster_width > width and cursor > first then
			local finish = last_space and last_space > first and last_space or cursor
			table.insert(slices, slice_cell(cell, first, finish))
			first = finish
			display_width = vim.api.nvim_strwidth(cell.text:sub(first + 1, cursor))
			last_space = nil
		end
		cursor = cursor + #cluster
		display_width = display_width + cluster_width
		if cluster:match("%s") then
			last_space = cursor
		end
	end
	if first < #cell.text then
		table.insert(slices, slice_cell(cell, first, #cell.text))
	end
	return slices
end

local function empty_cell()
	return { text = "", highlights = {}, links = {} }
end

local function stacked_table(parsed, indent, max_width, buf_dir, original_render)
	local content_width = max_width - vim.api.nvim_strwidth(indent) - 7
	if content_width < 4 then
		return nil
	end
	local header_width = 0
	for _, header in ipairs(parsed.headers) do
		header_width = math.max(header_width, vim.api.nvim_strwidth(header.text))
	end
	local key_width = math.min(content_width - 2, math.max(2, math.min(header_width, math.floor(content_width / 3))))
	local value_width = content_width - key_width
	local result_lines, result_highlights, result_links, result_images, result_offsets = {}, {}, {}, {}, {}
	local row_count = math.max(1, #parsed.rows)
	for row_index = 1, row_count do
		local original_row = parsed.rows[row_index]
		local card_rows = {}
		for column, header in ipairs(parsed.headers) do
			local value = original_row and original_row[column] or empty_cell()
			local keys = split_cell(header, key_width)
			local values = split_cell(value, value_width)
			for part = 1, math.max(#keys, #values) do
				table.insert(card_rows, { keys[part] or empty_cell(), values[part] or empty_cell() })
			end
		end
		local card = {
			headers = { empty_cell(), empty_cell() },
			alignments = { "left", "left" },
			rows = card_rows,
			col_widths = { key_width, value_width },
			_raw_lines = {},
			empty_header = true,
		}
		local lines, highlights, links, images = original_render(card, indent, nil, false, buf_dir)
		local base_line = #result_lines
		for index, line in ipairs(lines) do
			table.insert(result_lines, line)
			table.insert(result_highlights, highlights[index])
			table.insert(result_links, links[index])
			table.insert(result_offsets, original_row and row_index + 1 or 0)
		end
		for _, image in ipairs(images or {}) do
			image.line_offset = image.line_offset + base_line
			table.insert(result_images, image)
		end
		if row_index < row_count then
			local border = indent
				.. "│"
				.. string.rep("─", key_width + 2)
				.. "│"
				.. string.rep("─", value_width + 2)
				.. "│"
			table.insert(result_lines, border)
			table.insert(result_highlights, { { col = #indent, end_col = #border, hl = "FloatBorder" } })
			table.insert(result_links, {})
			table.insert(result_offsets, row_index + 1)
		end
	end
	return result_lines, result_highlights, result_links, result_images, result_offsets
end

-- The row's FloatBorder spans identify real column boundaries. Cell text can
-- contain a literal │, so neither scanning the text nor parsed widths are
-- reliable sources for the corners and junctions.
local function border_positions(line, highlights, indent)
	if type(line) ~= "string" or type(highlights) ~= "table" or line:sub(1, #indent) ~= indent then
		return nil
	end
	local positions = {}
	for _, highlight in ipairs(highlights) do
		if
			highlight.hl == "FloatBorder"
			and type(highlight.col) == "number"
			and type(highlight.end_col) == "number"
			and highlight.col >= #indent
			and highlight.end_col <= #line
		then
			local span = line:sub(highlight.col + 1, highlight.end_col)
			if span == "│ " or span == "│" then
				table.insert(positions, vim.api.nvim_strwidth(line:sub(1, highlight.col)))
			end
		end
	end
	local border_width = vim.api.nvim_strwidth("│")
	if
		#positions < 2
		or positions[1] ~= vim.api.nvim_strwidth(indent)
		or positions[#positions] + border_width ~= vim.api.nvim_strwidth(line)
	then
		return nil
	end
	for index = 2, #positions do
		if positions[index] - positions[index - 1] <= border_width then
			return nil
		end
	end
	return positions
end

local function cap_line(indent, positions, top)
	local border_width = vim.api.nvim_strwidth("│")
	local rule_width = vim.api.nvim_strwidth("─")
	local narrow_rule_width = vim.api.nvim_strwidth("╌")
	if
		border_width < 1
		or rule_width < 1
		or narrow_rule_width ~= 1
		or vim.api.nvim_strwidth(top and "┌" or "└") ~= border_width
		or vim.api.nvim_strwidth(top and "┬" or "┴") ~= border_width
		or vim.api.nvim_strwidth(top and "┐" or "┘") ~= border_width
	then
		return nil
	end
	local parts = { indent, top and "┌" or "└" }
	for index = 2, #positions do
		local gap = positions[index] - positions[index - 1] - border_width
		parts[#parts + 1] = string.rep("─", math.floor(gap / rule_width))
		if gap % rule_width ~= 0 then
			parts[#parts + 1] = string.rep("╌", gap % rule_width)
		end
		parts[#parts + 1] = index == #positions and (top and "┐" or "┘") or (top and "┬" or "┴")
	end
	return table.concat(parts)
end

local function add_table_caps(lines, highlights, links, images, source_offsets, indent)
	if
		type(lines) ~= "table"
		or #lines == 0
		or type(highlights) ~= "table"
		or #highlights ~= #lines
		or type(links) ~= "table"
		or #links ~= #lines
		or type(source_offsets) ~= "table"
		or #source_offsets ~= #lines
		or type(source_offsets[#lines]) ~= "number"
		or type(indent) ~= "string"
		or (images ~= nil and type(images) ~= "table")
	then
		return lines, highlights, links, images, source_offsets
	end
	local positions
	for row, line in ipairs(lines) do
		if type(highlights[row]) ~= "table" or type(links[row]) ~= "table" then
			return lines, highlights, links, images, source_offsets
		end
		local row_positions = border_positions(line, highlights[row], indent)
		if row_positions then
			if positions then
				if not vim.deep_equal(positions, row_positions) then
					return lines, highlights, links, images, source_offsets
				end
			else
				positions = row_positions
			end
		end
	end
	if not positions then
		return lines, highlights, links, images, source_offsets
	end
	for _, image in ipairs(images or {}) do
		if type(image) ~= "table" or type(image.line_offset) ~= "number" then
			return lines, highlights, links, images, source_offsets
		end
	end
	local top = cap_line(indent, positions, true)
	local bottom = cap_line(indent, positions, false)
	local row_width = positions[#positions] + vim.api.nvim_strwidth("│")
	if
		not top
		or not bottom
		or vim.api.nvim_strwidth(top) ~= row_width
		or vim.api.nvim_strwidth(bottom) ~= row_width
	then
		return lines, highlights, links, images, source_offsets
	end
	local last_offset = source_offsets[#source_offsets]
	table.insert(lines, 1, top)
	table.insert(highlights, 1, { { col = #indent, end_col = #top, hl = "FloatBorder" } })
	table.insert(links, 1, {})
	table.insert(source_offsets, 1, 0)
	table.insert(lines, bottom)
	table.insert(highlights, { { col = #indent, end_col = #bottom, hl = "FloatBorder" } })
	table.insert(links, {})
	table.insert(source_offsets, last_offset)
	for _, image in ipairs(images or {}) do
		image.line_offset = image.line_offset + 1
	end
	return lines, highlights, links, images, source_offsets
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
					vim.wo[win].wrap = true
				end
			end
		end
		if not ok then
			error(err, 0)
		end
	end
	session.nvim_config_readonly_rebuild = true
end

function M.configure(preview, wrap, markdown_table, postprocess)
	if installed then
		if
			installed.preview == preview
			and installed.wrap == wrap
			and installed.markdown_table == markdown_table
			and installed.postprocess == postprocess
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
		or (postprocess ~= nil and type(postprocess) ~= "function")
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
		if type(state) == "table" then
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
				content = original_build_content(lines, opts)
			end
		end
		return postprocess and postprocess(content, opts) or content
	end
	local function render_table(parsed, indent, max_width, expanded, buf_dir)
		local lines, highlights, links, images, source_offsets =
			original_render_table(parsed, indent, max_width, expanded, buf_dir)
		if
			max_width
			and (
				exceeds_width(lines, max_width)
				or (
					expanded
					and generated_ellipsis(parsed, lines, indent, max_width, expanded, buf_dir, original_render_table)
				)
			)
		then
			local card_lines, card_highlights, card_links, card_images, card_offsets =
				stacked_table(parsed, indent, max_width, buf_dir, original_render_table)
			if card_lines then
				lines, highlights, links, images, source_offsets =
					card_lines, card_highlights, card_links, card_images, card_offsets
			end
		end
		return add_table_caps(lines, highlights, links, images, source_offsets, indent)
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
		postprocess = postprocess,
		build_content = build_content,
		split_characters = split_characters,
		parse_table = parse_table,
		render_table = render_table,
	}
	return true
end

return M
