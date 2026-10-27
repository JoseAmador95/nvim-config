-- Adapt the guarded, pinned renderer to immutable review documents. The
-- adapter returns values only: native-review owns buffers and coordinates.
local M = { version = "visual-v3 / md-render 3.10.3" }

local markdown_view = require("config.markdown_view")
local markdown_layout = require("markdown_view.layout")
local markdown_codeblocks = require("markdown_view.decorations")
local image_link = require("diagram_view.image_link")

local function source_lines(text)
	local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- Structural correspondence is separate from visual equality: equivalent
-- heading/list syntax can render alike without sharing source node types.
local function structural_shape(node)
	local kind = node:type()
	if kind == "atx_heading" or kind == "setext_heading" then
		for child in node:iter_children() do
			local level = child:type():match("^atx_h([1-6])_marker$")
				or child:type():match("^setext_h([12])_underline$")
			if level then
				return { "heading", tonumber(level) }
			end
		end
	elseif kind:match("^list_marker_") then
		return (kind == "list_marker_dot" or kind == "list_marker_parenthesis") and "ordered" or "unordered"
	end
	-- Code languages and table dimensions are captured from the renderer.
	if kind == "fenced_code_block" or kind == "indented_code_block" then
		return "code"
	end
	local shape = { kind }
	if kind == "list_item" or kind == "list" or kind == "block_quote" then
		for child in node:iter_children() do
			if child:named() and child:type() ~= "block_continuation" and child:type() ~= "block_quote_marker" then
				shape[#shape + 1] = structural_shape(child)
			end
		end
	end
	return shape
end

local function ranges_for(text, lines)
	local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown", { error = false })
	if not ok or not parser then
		return nil, "Markdown parser unavailable; run :NvimConfigParsersInstall"
	end
	local trees = parser:parse()
	local ranges, fences = {}, {}
	local function collect_fences(node)
		if node:type() == "fenced_code_block" then
			local first, _, last, col = node:range()
			local fence = { first = first + 1, last = last + (col > 0 and 1 or 0), language = "" }
			for child in node:iter_children() do
				if child:type() == "info_string" then
					fence.language = vim.treesitter.get_node_text(child, text):match("^%s*(%S+)") or ""
				elseif child:type() == "code_fence_content" then
					local start, _, finish, ending = child:range()
					for row = start + 1, finish + (ending > 0 and 1 or 0) do
						fences[row] = fence
					end
				end
			end
		else
			for child in node:iter_children() do
				if child:named() then
					collect_fences(child)
				end
			end
		end
	end
	collect_fences(trees[1]:root())
	local function walk(node)
		local kind = node:type()
		if kind == "document" or kind == "section" or kind == "list" or kind == "block_quote" then
			for child in node:iter_children() do
				if child:named() then
					walk(child)
				end
			end
		else
			local first, _, last, col = node:range()
			local quotes, parent = 0, node:parent()
			while parent do
				quotes = quotes + (parent:type() == "block_quote" and 1 or 0)
				parent = parent:parent()
			end
			local range = {
				first = first + 1,
				last = math.min(#lines, last + (col > 0 and 1 or 0)),
				kind = kind,
				correspondence = { structural_shape(node), quotes },
			}
			for line = range.first, range.last do
				ranges[line] = range
			end
		end
	end
	walk(trees[1]:root())
	-- md-render renders YAML properties as one block, unlike the Markdown AST.
	if lines[1] and lines[1]:match("^%-%-%-%s*$") then
		for line = 2, #lines do
			if lines[line]:match("^%-%-%-%s*$") then
				local range = { first = 1, last = line, kind = "properties" }
				for index = 1, line do
					ranges[index] = range
				end
				break
			end
		end
	end
	return ranges, nil, fences
end

local function style_values(groups)
	local values = {}
	for _, group in ipairs(groups or {}) do
		-- Syntax is decoration from the complete frozen code, not line identity.
		-- A changed multiline token must not turn unchanged code into edits.
		if not group.syntax then
			values[#values + 1] = { group.col, group.end_col, group.hl }
		end
	end
	return values
end

local function is_code(range)
	return range and (range.kind == "fenced_code_block" or range.kind == "indented_code_block")
end

-- Read image syntax from the inline AST so escaped text and code spans do
-- not acquire media rows. Reference destinations come from this snapshot.
local function media_references(text, lines, ranges)
	local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown_inline", { error = false })
	if not ok or not parser then
		return nil, "Markdown inline parser unavailable; run :NvimConfigParsersInstall"
	end
	local references = {}
	local function walk(node)
		local kind = node:type()
		if kind == "image" or kind == "html_tag" then
			local first = node:range() + 1
			if not is_code(ranges[first]) and not (ranges[first] and ranges[first].kind == "properties") then
				local value = vim.treesitter.get_node_text(node, text)
				local images = image_link.parse_line(value)
				if kind == "image" and #images == 0 then
					images = image_link.parse_line(value .. "[]")
				end
				for _, reference in ipairs(images) do
					local target = reference.link or image_link.definition(lines, reference.label)
					local visible = "!["
						.. (reference.alt or "image")
						.. "]"
						.. (target and "(" .. target .. ")" or "[" .. (reference.label or "") .. "]")
					references[first] = references[first] or {}
					references[first][#references[first] + 1] = visible
				end
			end
		else
			for child in node:iter_children() do
				if child:named() then
					walk(child)
				end
			end
		end
	end
	walk(parser:parse()[1]:root())
	return references
end

local function display_parts(value, width)
	local parts, part, offset, first = {}, "", 0, 0
	for _, char in ipairs(vim.fn.split(value, "\\zs")) do
		if part ~= "" and vim.fn.strdisplaywidth(part .. char) > width then
			parts[#parts + 1] = { text = part, first = first, last = offset }
			part, first = "", offset
		end
		part, offset = part .. char, offset + #char
	end
	parts[#parts + 1] = { text = part, first = first, last = offset }
	return parts
end

-- Upstream appends footnotes after the body without resetting its source
-- line. Give those rows their actual definition range, never the last body
-- block's coordinates. Separator rows have no source anchor.
local function footnotes(content, captures, ranges, lines, render)
	local anchors, definitions = {}, {}
	for line, text in ipairs(lines) do
		local label = text:match("^%[%^([^%]]+)%]:%s+(.+)$")
		if label and not definitions[label] and not is_code(ranges[line]) then
			local last = line
			while lines[last + 1] and lines[last + 1]:match("^%s%s+") do
				last = last + 1
			end
			local range = { first = line, last = last, kind = "footnote" }
			definitions[label] = range
			for index = line, last do
				ranges[index] = range
			end
		end
	end
	for name, row in pairs(content.footnote_anchors or {}) do
		local label = name:match("^footnote%-def%-(.+)$")
		if label then
			anchors[#anchors + 1] = { first = row + 1, label = label }
		end
	end
	table.sort(anchors, function(a, b)
		return a.first < b.first
	end)
	local defs, numbers = render.Markdown.parse_footnotes(lines)
	local texts = {}
	for _, def in ipairs(defs) do
		texts[def.label] = def.text
	end
	local links = render.Markdown.parse_reference_links(lines)
	for index, anchor in ipairs(anchors) do
		local last = anchors[index + 1] and anchors[index + 1].first - 1 or #content.lines
		local range = definitions[anchor.label]
		for row = anchor.first, last do
			content.source_line_map[row] = range and range.first or 0
		end
		if index == 1 and anchor.first > 1 then
			content.source_line_map[anchor.first - 1] = 0
		end
		local text, groups = render.Markdown.render(texts[anchor.label] or "", nil, nil, links, numbers)
		local unit = {
			first = anchor.first,
			last = last,
			text = text,
			styles = style_values(groups),
			collapse_whitespace = true,
			structure = { "footnote", numbers[anchor.label] },
			spans = {},
		}
		local next_byte = 1
		for row = anchor.first, last do
			local raw = content.lines[row]
			local value = row == anchor.first and raw:match("^%s*%S+%s+(.*)$") or vim.trim(raw)
			local at = value and value ~= "" and text:find(value, next_byte, true)
			if at then
				local col = row == anchor.first and #raw - #value or #(raw:match("^%s*") or "")
				unit.spans[#unit.spans + 1] = { line = row, col = col, first = at - 1, last = at - 1 + #value }
				next_byte = at + #value
			end
		end
		captures[#captures + 1] = unit
	end
end

local function table_borders(content, index)
	local borders = {}
	for _, entry in ipairs(content.highlights) do
		if entry.line == index - 1 then
			for _, hl in ipairs(entry.groups) do
				if hl.hl == "FloatBorder" then
					local part = content.lines[index]:sub(hl.col + 1, hl.end_col)
					if part:find("─", 1, true) then
						return {} -- Rules contain no cell text, even in a stacked card.
					end
					local at = 1
					while true do
						local found = part:find("│", at, true)
						if not found then
							break
						end
						borders[#borders + 1] = hl.col + found - 1
						at = found + #"│"
					end
				end
			end
		end
	end
	table.sort(borders)
	return borders
end

local function table_cell_span(unit, row, content, column, next_byte)
	local left, right = row.borders[column], row.borders[column + 1]
	if not unit or not left or not right then
		return next_byte
	end
	local value = content.lines[row.line]:sub(left + #"│" + 1, right)
	local leading = #(value:match("^%s*") or "")
	value = vim.trim(value)
	local at = value ~= "" and unit.text:find(value, next_byte, true)
	if at then
		unit.spans[#unit.spans + 1] =
			{ line = row.line, col = left + #"│" + leading, first = at - 1, last = at - 1 + #value }
		return at + #value
	end
	return next_byte
end

-- Capture cell bytes before general reflow can split a physical border row.
-- Stacked cards repeat headers beside each source row, so walk each field's
-- key/value fragments together instead of using the original column number.
local function table_spans(capture, content)
	local rows, columns = {}, capture.structure[2]
	for index = capture.first, capture.last do
		local borders = table_borders(content, index)
		if #borders >= 2 then
			rows[#rows + 1] = { line = index, source = content.source_line_map[index], borders = borders }
		end
	end
	if not capture.stacked then
		for _, unit in ipairs(capture.cells) do
			local next_byte = 1
			local wanted = unit.row == 1 and capture.source or capture.source + unit.row
			for _, row in ipairs(rows) do
				if row.source == wanted then
					next_byte = table_cell_span(unit, row, content, unit.column, next_byte)
				end
			end
		end
		return
	end
	local cursors = {}
	for _, row in ipairs(rows) do
		local cursor = cursors[row.source] or { column = 1, key = 1, value = 1 }
		cursors[row.source] = cursor
		local header = capture.cells[cursor.column]
		local source_row = row.source - capture.source
		local value = source_row >= 2 and capture.cells[(source_row - 1) * columns + cursor.column] or nil
		if cursor.column <= columns then
			cursor.key = table_cell_span(header, row, content, 1, cursor.key)
			cursor.value = table_cell_span(value, row, content, 2, cursor.value)
			if
				vim.trim(header.text:sub(cursor.key)) == ""
				and (not value or vim.trim(value.text:sub(cursor.value)) == "")
			then
				cursor.column, cursor.key, cursor.value = cursor.column + 1, 1, 1
			end
		end
	end
end

-- Parse each complete frozen fence before wrapping or mixing OLD/NEW rows.
-- Optional language parsers affect decoration only, never comparison identity.
local function code_highlights(content, fences, render)
	local known, groups = {}, {}
	for _, code in ipairs(content.code_blocks) do
		code.source = fences[content.source_line_map[code.start_line + 1]]
		if code.source then
			known[code.source] = true
		end
	end
	local missing = {}
	for row, source in ipairs(content.source_line_map) do
		local fence = fences[source]
		if fence and not known[fence] then
			local code = missing[fence]
			if not code then
				code = {
					language = fence.language,
					start_line = row - 1,
					prefix_len = #(content.lines[row]:match("^%s*") or ""),
					source = fence,
				}
				missing[fence] = code
				content.code_blocks[#content.code_blocks + 1] = code
			end
			code.end_line = row - 1
		end
	end
	table.sort(content.code_blocks, function(left, right)
		return left.start_line < right.start_line
	end)
	for _, entry in ipairs(content.highlights) do
		groups[entry.line] = entry.groups
	end
	for _, code in ipairs(content.code_blocks) do
		local text = code.source_lines
		if not text then
			text = {}
			for row = code.start_line + 1, code.end_line + 1 do
				text[#text + 1] = content.lines[row]:sub((code.prefix_len or 0) + 1)
			end
		end
		text = table.concat(text, "\n")
		local lang = render.resolve_language(code.language)
		local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, lang, { error = false })
		local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
		if ok_parser and parser and ok_query and query then
			local ok, captures = pcall(function()
				local result = {}
				local tree = parser:parse()[1]
				for id, node, metadata in query:iter_captures(tree:root(), text) do
					local name = query.captures[id]
					if not name:match("^_") then
						local range = vim.treesitter.get_range(node, text, metadata[id])
						local first, start, last, finish = range[1], range[2], range[4], range[5]
						local priority = tonumber(metadata[id] and metadata[id].priority or metadata.priority) or 100
						for row = first, math.min(last, code.end_line - code.start_line) do
							local line = code.start_line + row
							local prefix = code.prefix_len or 0
							local from = row == first and start + prefix or prefix
							local to = math.min(#content.lines[line + 1], row == last and finish + prefix or math.huge)
							if to > from then
								result[#result + 1] = {
									line = line,
									group = {
										col = from,
										end_col = to,
										hl = "@" .. name .. "." .. lang,
										syntax = true,
										priority = 4200 + math.max(0, priority),
									},
								}
							end
						end
					end
				end
				return result
			end)
			if ok then
				for _, capture in ipairs(captures) do
					if not groups[capture.line] then
						groups[capture.line] = {}
						content.highlights[#content.highlights + 1] =
							{ line = capture.line, groups = groups[capture.line] }
					end
					groups[capture.line][#groups[capture.line] + 1] = capture.group
				end
			end
		end
	end
end

-- Pre-wrap every output row, including expanded code, to the shared width.
-- Owned split rows therefore have identical screen heights; filler rows do
-- not depend on native diff or on a second interpretation of Markdown.
local function reflow(content, captures, width)
	local rows, maps, highlights, source_map = {}, {}, {}, {}
	local groups_by_row = {}
	for _, entry in ipairs(content.highlights) do
		groups_by_row[entry.line] = entry.groups
	end
	for _, code in ipairs(content.code_blocks) do
		code.visual_lines = vim.list_slice(content.lines, code.start_line + 1, code.end_line + 1)
		for row = code.start_line + 1, code.end_line + 1 do
			local groups = groups_by_row[row - 1] or {}
			captures[#captures + 1] = {
				first = row,
				last = row,
				text = content.lines[row],
				styles = style_values(groups),
				spans = { { line = row, col = 0, first = 0, last = #content.lines[row] } },
				code = code,
				source = content.source_line_map[row],
			}
		end
	end
	for row, value in ipairs(content.lines) do
		local parts = display_parts(value, width)
		maps[row] = parts
		for _, segment in ipairs(parts) do
			rows[#rows + 1] = segment.text
			segment.line = #rows
			source_map[#rows] = content.source_line_map[row]
		end
	end
	for _, entry in ipairs(content.highlights) do
		for _, segment in ipairs(maps[entry.line + 1]) do
			local groups = {}
			for _, group in ipairs(entry.groups) do
				local first = math.max(segment.first, group.col)
				local last = math.min(segment.last, group.end_col == -1 and segment.last or group.end_col)
				if last > first then
					local copy = vim.deepcopy(group)
					copy.col, copy.end_col = first - segment.first, last - segment.first
					groups[#groups + 1] = copy
				end
			end
			highlights[#highlights + 1] = { line = segment.line - 1, groups = groups }
		end
	end
	for _, code in ipairs(content.code_blocks) do
		code.start_line = maps[code.start_line + 1][1].line - 1
		local ending = maps[code.end_line + 1]
		code.end_line = ending[#ending].line - 1
	end
	for _, capture in ipairs(captures) do
		if capture.cells then
			table_spans(capture, content)
			-- Keep renderer-owned row boundaries before wrapping splits borders.
			-- Headers include the delimiter; the bottom cap is a separate frame.
			capture.parts = {}
			for row = 1, capture.structure[3] + 1 do
				capture.parts[row] = { indices = {}, source = row == 1 and capture.source or capture.source + row }
			end
			capture.parts[#capture.parts + 1] = { indices = {} }
			for index = capture.first, capture.last do
				local source = content.source_line_map[index]
				local row = source and source - capture.source
				local part = row and capture.parts[row <= 1 and 1 or row]
				if index == capture.last and content.lines[index]:match("^%s*└") then
					part = capture.parts[#capture.parts]
				end
				if part then
					for _, segment in ipairs(maps[index]) do
						part.indices[#part.indices + 1] = segment.line
					end
				else
					capture.parts = nil
					break
				end
			end
		end
		for _, unit in ipairs(capture.cells or { capture }) do
			local spans = {}
			for _, span in ipairs(unit.spans) do
				for _, segment in ipairs(maps[span.line]) do
					local first = math.max(segment.first, span.col)
					local last = math.min(segment.last, span.col + span.last - span.first)
					if last > first then
						spans[#spans + 1] = {
							line = segment.line,
							col = first - segment.first,
							first = span.first + first - span.col,
							last = span.first + last - span.col,
						}
					end
				end
			end
			unit.spans = spans
		end
		capture.first = maps[capture.first][1].line
		local ending = maps[capture.last]
		capture.last = ending[#ending].line
	end
	content.lines, content.highlights, content.source_line_map = rows, highlights, source_map
end

local function visual_signature(unit)
	local function normalized(value, prefix)
		if not unit.collapse_whitespace then
			return value
		end
		value = value:gsub("%s+", " "):gsub("^%s+", "")
		return prefix and value or value:gsub("%s+$", "")
	end
	local styles = {}
	for _, style in ipairs(unit.styles) do
		local first = #normalized(unit.text:sub(1, style[1]), true)
		local last = #normalized(unit.text:sub(1, style[2] == -1 and #unit.text or style[2]), true)
		styles[#styles + 1] = { first, last, style[3] }
	end
	return { normalized(unit.text), styles, unit.row, unit.column }
end

local function finish_references(block, references, width)
	if block.source then
		for line = block.source.first, block.source.last do
			for _, value in ipairs(references[line] or {}) do
				for _, part in ipairs(display_parts("  " .. value, width)) do
					block.lines[#block.lines + 1] = part.text
				end
				block.signature[#block.signature + 1] = { "image-reference", value }
			end
		end
	end
	block.fingerprint = vim.fn.sha256(vim.json.encode({ block.signature, block.structure }))
end

-- A table retains its original whole-block fallback. Compatible tables also
-- expose stable header/row/frame blocks, independent of wrapping and row index.
local function table_rows(block, capture, row_blocks, references, width)
	if not capture.parts or not block.source or block.source.kind ~= "pipe_table" then
		return nil
	end
	local children, local_rows = {}, {}
	for index, part in ipairs(capture.parts) do
		local kind = index == 1 and "table_header" or part.source and "table_row" or "table_frame"
		local source = part.source
				and {
					first = part.source,
					last = index == 1 and part.source + 1 or part.source,
					kind = kind,
				}
			or nil
		local child = {
			source = source,
			kind = kind,
			correspondence = { kind, block.correspondence },
			lines = {},
			highlights = {},
			units = {},
			structure = { { kind, capture.structure[2], capture.structure[4] } },
			code_blocks = {},
			signature = {},
		}
		for _, line in ipairs(part.indices) do
			local mapped = row_blocks[line]
			if not mapped or mapped.block ~= block then
				return nil
			end
			child.lines[#child.lines + 1] = block.lines[mapped.row]
			child.highlights[#child.lines] = block.highlights[mapped.row]
			local_rows[mapped.row] = { block = index, row = #child.lines }
		end
		children[index] = child
	end
	-- The builder may leave spacing after a table in the same AST block.
	-- Keep those display rows with its unanchorable closing frame.
	local frame = children[#children]
	for row, text in ipairs(block.lines) do
		if not local_rows[row] then
			if vim.trim(text) ~= "" then
				return nil
			end
			frame.lines[#frame.lines + 1] = text
			frame.highlights[#frame.lines] = block.highlights[row]
		end
	end
	for _, unit in ipairs(capture.cells) do
		local copies = {}
		local first, last = unit.row == 1 and 1 or unit.row, unit.row == 1 and #children - 1 or unit.row
		for index = first, last do
			local child = children[index]
			if child then
				local copy = {
					text = unit.text,
					styles = vim.deepcopy(unit.styles),
					row = unit.row == 1 and 1 or 2,
					column = unit.column,
					spans = {},
				}
				copies[index] = copy
				child.units[#child.units + 1] = copy
				child.signature[#child.signature + 1] = visual_signature(copy)
			end
		end
		for _, span in ipairs(unit.spans) do
			local mapped = span.line and local_rows[span.line]
			local copy = mapped and copies[mapped.block]
			if copy then
				local value = vim.deepcopy(span)
				value.line = mapped.row
				copy.spans[#copy.spans + 1] = value
			end
		end
	end
	for _, child in ipairs(children) do
		finish_references(child, references, width)
	end
	return {
		schema = vim.fn.sha256(vim.json.encode({ children[1].signature, children[1].structure, block.correspondence })),
		blocks = children,
	}
end

-- Split code by original logical lines after labels and spans have been moved.
-- Surrounding prose/labels remain separate frames; syntax never parses these
-- synthetic fragments, since full-fence captures are already in highlights.
local function code_lines(block, references, width)
	local owners, languages, children, mapped = {}, {}, {}, {}
	for _, code in ipairs(block.code_blocks) do
		languages[#languages + 1] = code.language
	end
	for _, unit in ipairs(block.units) do
		if unit.code then
			if not unit.source or not unit.code.source or not unit.render_first then
				return nil
			end
			for row = unit.render_first, unit.render_last do
				owners[row] = unit
			end
		end
	end
	local row = 1
	while row <= #block.lines do
		local unit, first = owners[row], row
		local kind = unit and "code_line" or "code_frame"
		local child = {
			kind = kind,
			correspondence = { kind, languages, block.correspondence },
			structure = { { kind, languages, block.correspondence } },
			lines = {},
			highlights = {},
			units = {},
			signature = {},
			code_blocks = {},
		}
		local source_first, source_last
		while row <= #block.lines and owners[row] == unit do
			child.lines[#child.lines + 1] = block.lines[row]
			child.highlights[#child.lines] = block.highlights[row]
			mapped[row] = { child = child, row = #child.lines }
			if unit then
				child.code_blocks[#child.code_blocks + 1] = {
					language = unit.code.language,
					start_line = #child.lines - 1,
					end_line = #child.lines - 1,
					prefix_len = row == first and unit.code.prefix_len or 0,
				}
			elseif vim.trim(block.lines[row]) ~= "" then
				local source = block.source_rows[row]
				source_first = source_first or source
				source_last = source
			end
			row = row + 1
		end
		if unit then
			child.source = { first = unit.source, last = unit.source, kind = kind }
		elseif source_first then
			child.source = { first = source_first, last = source_last, kind = kind }
		end
		children[#children + 1] = child
	end
	for _, unit in ipairs(block.units) do
		local copies = {}
		for _, span in ipairs(unit.spans) do
			local target = span.line and mapped[span.line]
			if target then
				local copy = copies[target.child]
				if not copy then
					copy = {
						text = unit.text,
						styles = unit.styles,
						collapse_whitespace = unit.collapse_whitespace,
						spans = {},
					}
					copies[target.child] = copy
					target.child.units[#target.child.units + 1] = copy
					target.child.signature[#target.child.signature + 1] = visual_signature(copy)
				end
				local value = vim.deepcopy(span)
				value.line = target.row
				copy.spans[#copy.spans + 1] = value
			end
		end
	end
	for _, code in ipairs(block.code_blocks) do
		if code.label_row then
			local child = mapped[code.label_row].child
			child.signature[#child.signature + 1] = { "code-label", code.language }
		end
	end
	for _, child in ipairs(children) do
		finish_references(child, references, width)
	end
	return {
		schema = vim.fn.sha256(vim.json.encode({ "code-lines", languages, block.correspondence })),
		blocks = children,
	}
end

local function documents(content, captures, ranges, lines, references, width)
	local blocks, row_blocks = {}, {}
	local last
	for index, text in ipairs(content.lines) do
		local range = ranges[content.source_line_map[index]]
		local blank = vim.trim(text) == ""
		if not last or not blank and last.source ~= range then
			last = {
				source = range,
				kind = range and range.kind or "decoration",
				correspondence = range and range.correspondence or { range and range.kind or "decoration" },
				lines = {},
				highlights = {},
				units = {},
				structure = {},
				code_blocks = {},
				source_rows = {},
				signature = {},
			}
			blocks[#blocks + 1] = last
		end
		last.lines[#last.lines + 1] = text
		last.source_rows[#last.lines] = content.source_line_map[index]
		row_blocks[index] = { block = last, row = #last.lines }
	end
	local covered = {}
	for _, capture in ipairs(captures) do
		local owner = row_blocks[capture.first]
		if owner then
			local block = owner.block
			if capture.cells then
				block.table_capture = capture
			end
			block.structure[#block.structure + 1] = capture.structure
			for _, unit in ipairs(capture.cells or { capture }) do
				if unit.code then
					local ending = row_blocks[capture.last]
					if ending and ending.block == block then
						unit.render_first, unit.render_last = owner.row, ending.row
					end
				end
				for _, span in ipairs(unit.spans) do
					local mapped = row_blocks[span.line]
					if mapped and mapped.block == block then
						span.line = mapped.row
					else
						span.line = nil
					end
				end
				block.units[#block.units + 1] = unit
				block.signature[#block.signature + 1] = visual_signature(unit)
			end
			for index = capture.first, capture.last do
				covered[index] = true
			end
		end
	end
	for _, entry in ipairs(content.highlights) do
		local owner = row_blocks[entry.line + 1]
		if owner then
			owner.block.highlights[owner.row] = vim.deepcopy(entry.groups)
		end
	end
	for _, code in ipairs(content.code_blocks) do
		local owner = row_blocks[code.start_line + 1]
		if owner then
			local copy = vim.deepcopy(code)
			copy.start_line = owner.row - 1
			copy.end_line = copy.start_line + code.end_line - code.start_line
			owner.block.code_blocks[#owner.block.code_blocks + 1] = copy
			owner.block.structure[#owner.block.structure + 1] = { "code", code.language }
			owner.block.signature[#owner.block.signature + 1] = { "code", code.language, code.visual_lines }
			for row = code.start_line + 1, code.end_line + 1 do
				covered[row] = true
			end
		end
	end
	for index, owner in ipairs(row_blocks) do
		if not covered[index] then
			local visual = content.lines[index]
			if visual:match("^[%s─]+$") and visual:find("─", 1, true) then
				owner.block.signature[#owner.block.signature + 1] = { "horizontal-rule", "FloatBorder" }
			else
				owner.block.signature[#owner.block.signature + 1] =
					{ visual, style_values(owner.block.highlights[owner.row]) }
			end
		end
	end
	for _, block in ipairs(blocks) do
		for index = #block.code_blocks, 1, -1 do
			local code = block.code_blocks[index]
			local language = type(code.language) == "string" and code.language:match("^%s*([%w%._+#/%-%:]+)")
			if language then
				local at = code.start_line + 1
				local parts = display_parts("  " .. language:sub(1, 32), width)
				for row, part in ipairs(parts) do
					table.insert(block.lines, at + row - 1, part.text)
					table.insert(
						block.source_rows,
						at + row - 1,
						code.source and code.source.first or block.source.first
					)
				end
				local extra = #parts
				local shifted = {}
				for row, groups in pairs(block.highlights) do
					shifted[row >= at and row + extra or row] = groups
				end
				for row, part in ipairs(parts) do
					shifted[at + row - 1] = { { col = 0, end_col = #part.text, hl = "MdRenderCodeBlockLabel" } }
				end
				block.highlights = shifted
				for _, unit in ipairs(block.units) do
					if unit.render_first and unit.render_first >= at then
						unit.render_first, unit.render_last = unit.render_first + extra, unit.render_last + extra
					end
					for _, span in ipairs(unit.spans) do
						if span.line and span.line >= at then
							span.line = span.line + extra
						end
					end
				end
				for _, item in ipairs(block.code_blocks) do
					if item.start_line >= at - 1 then
						item.start_line, item.end_line = item.start_line + extra, item.end_line + extra
					end
					if item.label_row and item.label_row >= at then
						item.label_row = item.label_row + extra
					end
				end
				code.label_row = at
			end
		end
		-- References are review text, never a picture from the live worktree.
		if block.table_capture then
			block.table_rows = table_rows(block, block.table_capture, row_blocks, references, width)
			block.table_capture = nil
		end
		if #block.code_blocks > 0 then
			block.code_lines = code_lines(block, references, width)
		end
		finish_references(block, references, width)
	end
	return { blocks = blocks }
end

function M.build_snapshot(request)
	local lines = source_lines(request.text)
	if #lines == 0 then
		return { blocks = {} }
	end
	local ranges, err, fences = ranges_for(table.concat(lines, "\n") .. "\n", lines)
	if not ranges then
		return nil, err
	end
	local references, media_err = media_references(table.concat(lines, "\n") .. "\n", lines, ranges)
	if not references then
		return nil, media_err
	end
	local content, build_err, captures, render = markdown_view.build_snapshot(lines, {
		buf_dir = "",
		max_width = math.max(1, request.width - 2),
		nvim_config_page_width = request.width,
		nvim_config_block_width = request.width,
		nvim_config_wrap = true,
		nvim_config_review = true,
		text_scale = false,
		fold_state = setmetatable({}, {
			__index = function()
				return false
			end,
		}),
	})
	if not content then
		return nil, build_err
	end
	footnotes(content, captures, ranges, lines, render)
	code_highlights(content, fences, render)
	reflow(content, captures, request.width)
	return documents(content, captures, ranges, lines, references, request.width)
end

function M.decorate(request)
	local projection = request.projection
	local code_blocks = {}
	-- Code padding is virtual text, so its background would cover the line
	-- diff beyond EOL. Let changed rows keep the presenter's full diff band.
	for _, code in ipairs(projection.code_blocks) do
		for row = code.start_line, code.end_line do
			if projection.rows[row + 1].kind == "context" then
				code_blocks[#code_blocks + 1] = vim.tbl_extend("force", code, { start_line = row, end_line = row })
			end
		end
	end
	markdown_codeblocks.decorate({
		buf = request.buf,
		win = request.win,
		opts = {
			max_width = request.width - 2,
			nvim_config_page_width = request.width,
			nvim_config_wrap = true,
			nvim_config_code_labels = false,
		},
		content = {
			lines = vim.tbl_map(function(row)
				return row.text
			end, projection.rows),
			highlights = projection.highlights,
			code_blocks = code_blocks,
		},
	})
	markdown_layout.pad(request.buf, 0)
end

return M
