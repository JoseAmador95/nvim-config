-- Visual Markdown comparison. Display bytes never become source coordinates.
local dependencies = require("native_review.dependencies")
local projection = require("native_review.projection")
local adapter = dependencies.get("markdown")

local M = {}
local MAX_BYTES = 128 * 1024
local MAX_TOKENS = 8192

function M.supports(entry)
	return not entry.binary
		and not entry.metadata_only
		and (
			vim.filetype.match({ filename = entry.new_path or "" }) == "markdown"
			or vim.filetype.match({ filename = entry.old_path or "" }) == "markdown"
		)
end

local function word(value)
	return value:match("^[A-Za-z0-9_]") ~= nil or vim.fn.tolower(value) ~= vim.fn.toupper(value)
end

local function tokens(unit)
	local values = {}
	local offset = 0
	for _, char in ipairs(vim.fn.split(unit.text, "\\zs")) do
		local kind = word(char) and "word" or char:match("^%s+$") and "space" or "symbol"
		local last = values[#values]
		if last and kind ~= "symbol" and last.kind == kind then
			last.text, last.last = last.text .. char, offset + #char
		else
			values[#values + 1] = { text = char, kind = kind, first = offset, last = offset + #char }
			if #values > MAX_TOKENS then
				return nil
			end
		end
		offset = offset + #char
	end
	local encoded = {}
	for _, token in ipairs(values) do
		if token.kind == "space" and unit.collapse_whitespace then
			token.text = " "
		end
		local styles = {}
		for _, style in ipairs(unit.styles or {}) do
			if style[1] < token.last and (style[2] == -1 or style[2] > token.first) then
				styles[#styles + 1] = style[3]
			end
		end
		table.sort(styles)
		encoded[#encoded + 1] = vim.fn.sha256(vim.json.encode({ token.text, styles }))
	end
	return values, table.concat(encoded, "\n") .. "\n"
end

local function mark_tokens(block, unit, values, first, count)
	for index = first, first + count - 1 do
		local token = values[index]
		for _, span in ipairs(unit.spans or {}) do
			local start, finish = math.max(token.first, span.first), math.min(token.last, span.last)
			if span.line and finish > start then
				block.detail[span.line] = block.detail[span.line] or {}
				block.detail[span.line][#block.detail[span.line] + 1] = {
					start_col = span.col + start - span.first,
					end_col = span.col + finish - span.first,
				}
			end
		end
	end
end

local function refine(old, new, cached)
	old.detail, new.detail = {}, {}
	if
		not vim.deep_equal(old.correspondence or old.kind, new.correspondence or new.kind)
		or not vim.deep_equal(old.structure, new.structure)
		or #old.units ~= #new.units
	then
		return {}
	end
	local result = {}
	for index, before in ipairs(old.units) do
		local after = new.units[index]
		local detail = cached and cached[index]
		if not cached and #before.text + #after.text <= MAX_BYTES then
			local left, left_text = tokens(before)
			local right, right_text = tokens(after)
			if left and right and #left + #right <= MAX_TOKENS then
				detail = {
					left = left,
					right = right,
					hunks = vim.text.diff(left_text, right_text, { result_type = "indices", algorithm = "myers" }),
				}
			end
		end
		if detail then
			result[index] = detail
			for _, hunk in ipairs(detail.hunks) do
				mark_tokens(old, before, detail.left, hunk[1], hunk[2])
				mark_tokens(new, after, detail.right, hunk[3], hunk[4])
			end
		end
	end
	return result
end

local function signatures(document)
	local result = {}
	for _, block in ipairs(document.blocks) do
		result[#result + 1] = block.fingerprint
	end
	return #result > 0 and table.concat(result, "\n") .. "\n" or ""
end

local function expand_rows(documents)
	local schemas = { old = {}, new = {} }
	for side, document in pairs(documents) do
		for _, block in ipairs(document.blocks) do
			local rows = block.table_rows or block.code_lines
			if rows then
				schemas[side][rows.schema] = true
			end
		end
	end
	for side, document in pairs(documents) do
		local blocks = {}
		local other = schemas[side == "old" and "new" or "old"]
		for _, block in ipairs(document.blocks) do
			local rows = block.table_rows or block.code_lines
			if rows and other[rows.schema] then
				vim.list_extend(blocks, rows.blocks)
			else
				blocks[#blocks + 1] = block
			end
		end
		document.blocks = blocks
	end
end

local function align(old, new)
	local result, left, right = {}, 1, 1
	local function common(until_left)
		while left < until_left do
			result[#result + 1] = {
				old = old.blocks[left],
				new = new.blocks[right],
				old_index = left,
				new_index = right,
				changed = false,
			}
			left, right = left + 1, right + 1
		end
	end
	for _, hunk in
		ipairs(vim.text.diff(signatures(old), signatures(new), { result_type = "indices", algorithm = "histogram" }))
	do
		local first_left = hunk[2] == 0 and hunk[1] + 1 or hunk[1]
		local first_right = hunk[4] == 0 and hunk[3] + 1 or hunk[3]
		common(first_left)
		for offset = 0, math.max(hunk[2], hunk[4]) - 1 do
			local pair = {
				old = offset < hunk[2] and old.blocks[first_left + offset] or nil,
				new = offset < hunk[4] and new.blocks[first_right + offset] or nil,
				old_index = offset < hunk[2] and first_left + offset or nil,
				new_index = offset < hunk[4] and first_right + offset or nil,
				changed = true,
			}
			-- A run with multiple unmatched blocks has no unique positional
			-- correspondence, even when the two sides have the same count.
			if pair.old and pair.new and hunk[2] == 1 and hunk[4] == 1 then
				pair.refinement = refine(pair.old, pair.new)
			elseif pair.old and pair.new then
				pair.refinement = {}
			end
			result[#result + 1] = pair
		end
		left, right = first_left + hunk[2], first_right + hunk[4]
	end
	common(#old.blocks + 1)
	return result
end

local function new_projection(sources)
	return {
		rendered = true,
		rows = {},
		hunks = {},
		by_source = { old = {}, new = {} },
		sources = sources,
		gutter_digits = #tostring(math.max(sources.old.line_count, sources.new.line_count, 1)),
		highlights = {},
		code_blocks = {},
		blocks = {},
	}
end

local function append(value, block, line, side, kind, block_id, old, new)
	local range = block and block.source
	local row = {
		display_line = #value.rows + 1,
		text = block and block.lines[line] or "",
		kind = block and kind or "filler",
		block_id = block_id,
		anchor_side = side,
		anchorable = range ~= nil,
		path = value.sources[side].path,
		source_line = range and range.first or 0,
		terminator = "",
		detail = block and block.detail and block.detail[line] or {},
	}
	for _, source_side in ipairs({ "old", "new" }) do
		local source_block
		if source_side == "old" then
			source_block = old
		else
			source_block = new
		end
		local source_range = source_block and source_block.source
		if source_range then
			row[source_side .. "_range"] = source_range
			row[source_side .. "_line"] = source_range.first
			row[source_side .. "_path"] = value.sources[source_side].path
			for source_line = source_range.first, source_range.last do
				value.by_source[source_side][source_line] = value.by_source[source_side][source_line]
					or row.display_line
			end
		end
	end
	value.rows[#value.rows + 1] = row
	local groups = block and block.highlights[line]
	if groups then
		value.highlights[#value.highlights + 1] = { line = row.display_line - 1, groups = groups }
	end
	for _, code in ipairs(block and block.code_blocks or {}) do
		if code.start_line == line - 1 then
			local copy = vim.deepcopy(code)
			copy.start_line = row.display_line - 1
			copy.end_line = copy.start_line + code.end_line - code.start_line
			value.code_blocks[#value.code_blocks + 1] = copy
		end
	end
end

local function finish_block(value, first, pair, id)
	local last = #value.rows
	if last < first then
		return
	end
	value.blocks[#value.blocks + 1] = { first = first, last = last, id = id }
	if pair.changed then
		local previous = value.hunks[#value.hunks]
		if previous and previous.last == first - 1 then
			previous.last = last
		else
			value.hunks[#value.hunks + 1] = { first = first, last = last }
		end
		for index = first, last do
			value.rows[index].hunk_index = #value.hunks
		end
	end
end

local function projections(pairs, sources)
	local inline, old, new = new_projection(sources), new_projection(sources), new_projection(sources)
	for id, pair in ipairs(pairs) do
		local first = #inline.rows + 1
		for _, side in ipairs(pair.changed and { "old", "new" } or { pair.new and "new" or "old" }) do
			local block = pair[side]
			for line = 1, #(block and block.lines or {}) do
				append(
					inline,
					block,
					line,
					side,
					pair.changed and side or "context",
					id,
					(not pair.changed or side == "old") and pair.old or nil,
					(not pair.changed or side == "new") and pair.new or nil
				)
			end
		end
		finish_block(inline, first, pair, id)
		local split_first = #old.rows + 1
		for line = 1, math.max(#(pair.old and pair.old.lines or {}), #(pair.new and pair.new.lines or {})) do
			for _, side in ipairs({ "old", "new" }) do
				local block = pair[side]
				local available = block and block.lines[line] ~= nil
				append(
					side == "old" and old or new,
					available and block or nil,
					line,
					side,
					pair.changed and side or "context",
					id,
					side == "old" and available and block or nil,
					side == "new" and available and block or nil
				)
			end
		end
		finish_block(old, split_first, pair, id)
		finish_block(new, split_first, pair, id)
	end
	for _, value in ipairs({ inline, old, new }) do
		if #value.rows == 0 then
			append(value, nil, 1, sources.new.path and "new" or "old", "empty", 1)
			value.rows[1].kind = "empty"
		end
	end
	return inline, { old = old, new = new }
end

-- Keep comparison and word edits for this frozen entry; resizing rebuilds
-- only display rows and byte spans, never the visual change classification.
local function comparison_key(entry)
	return {
		identity = entry.identity,
		old_path = entry.old_path,
		new_path = entry.new_path,
		old_text = entry.old_text,
		new_text = entry.new_text,
		version = adapter.version,
	}
end

local function comparison(documents, entry, previous)
	local key = comparison_key(entry)
	local cached = previous and previous.markdown and previous.comparison
	local pairs = {}
	if
		cached
		and vim.deep_equal(cached.key, key)
		and cached.old_count == #documents.old.blocks
		and cached.new_count == #documents.new.blocks
	then
		for _, value in ipairs(cached.pairs) do
			local pair = {
				old = documents.old.blocks[value.old_index],
				new = documents.new.blocks[value.new_index],
				old_index = value.old_index,
				new_index = value.new_index,
				changed = value.changed,
				refinement = value.refinement,
			}
			if pair.old and pair.new and pair.changed then
				refine(pair.old, pair.new, pair.refinement)
			end
			pairs[#pairs + 1] = pair
		end
		return pairs, cached
	end
	pairs = align(documents.old, documents.new)
	local cached_pairs = {}
	for _, pair in ipairs(pairs) do
		cached_pairs[#cached_pairs + 1] = {
			old_index = pair.old_index,
			new_index = pair.new_index,
			changed = pair.changed,
			refinement = pair.refinement,
		}
	end
	return pairs,
		{ key = key, pairs = cached_pairs, old_count = #documents.old.blocks, new_count = #documents.new.blocks }
end

function M.prepare(entry, width, previous)
	if not M.supports(entry) then
		return nil, "Markdown rendering requires a text Markdown entry"
	end
	local canonical, err = projection.build(entry)
	if not canonical then
		return nil, err
	end
	local documents = {}
	for _, side in ipairs({ "old", "new" }) do
		local ok, document, build_err = pcall(
			adapter.build_snapshot,
			{ text = entry[side .. "_text"] or "", path = entry[side .. "_path"], width = width }
		)
		if not ok or not document then
			return nil, ok and build_err or tostring(document)
		end
		documents[side] = document
	end
	expand_rows(documents)
	local pairs, cached_comparison = comparison(documents, entry, previous)
	local inline, split = projections(pairs, canonical.sources)
	return {
		markdown = true,
		presentation = "projected",
		structural_only = false,
		projection = inline,
		split_projections = split,
		intraline = { old = {}, new = {} },
		relations = {},
		selected_engine = "markdown-visual",
		origin_engine = { id = "markdown-visual", version = adapter.version },
		status = #inline.hunks == 0 and "unchanged" or "changed",
		width = width,
		comparison = cached_comparison,
	}
end

return M
