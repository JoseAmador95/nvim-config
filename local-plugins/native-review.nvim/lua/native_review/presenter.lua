-- Native ordinary-window presenter for exact native_review.changes entries.
local M = {}

local dependencies = require("native_review.dependencies")
local lsp_navigation = dependencies.get("lsp_navigation")
local config = dependencies.get("config")
local repo = dependencies.get("repo")
local review_lsp = require("native_review.lsp")
local review_mode = require("native_review.mode")
local review_projection = require("native_review.projection")
local review_diff = require("native_review.diff")

local BAND_HIGHLIGHT = "NvimReviewNativeHunkBand"
local OLD_LINE_HIGHLIGHT = "NvimReviewNativeDiffOld"
local NEW_LINE_HIGHLIGHT = "NvimReviewNativeDiffNew"
local OLD_TEXT_HIGHLIGHT = "NvimReviewNativeDiffOldText"
local NEW_TEXT_HIGHLIGHT = "NvimReviewNativeDiffNewText"
local OLD_NUMBER_HIGHLIGHT = "NvimReviewUnifiedOldNumber"
local NEW_NUMBER_HIGHLIGHT = "NvimReviewUnifiedNewNumber"
local STATUSCOLUMN = "%!v:lua.require('native_review.presenter').statuscolumn()"
local presentation_generation = 0
local gutters = {}

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function integer(value)
	return type(value) == "number" and value % 1 == 0
end

local function gutter_number(value, width)
	return value and string.format("%" .. width .. "d", value) or string.rep(" ", width)
end

---Render the owning unified review window's fold, signs, and OLD/NEW source columns.
---@return string
function M.statuscolumn()
	local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
	local gutter = gutters[win]
	if
		not gutter
		or not valid_win(win)
		or not valid_buf(gutter.buf)
		or vim.api.nvim_win_get_buf(win) ~= gutter.buf
		or gutter.presentation.generation ~= gutter.generation
	then
		return "%C%s"
	end
	local width = gutter.projection.gutter_digits
	local row = vim.v.virtnum == 0 and gutter.projection.rows[vim.v.lnum] or nil
	local old = gutter_number(row and row.old_line or nil, width)
	local new = gutter_number(row and row.new_line or nil, width)
	local old_highlight = row and row.kind == "old" and OLD_NUMBER_HIGHLIGHT or "LineNr"
	local new_highlight = row and row.kind == "new" and NEW_NUMBER_HIGHLIGHT or "LineNr"
	return table.concat({
		"%C%s%=",
		"%#",
		old_highlight,
		"#",
		old,
		"%* │ %#",
		new_highlight,
		"#",
		new,
		"%* ",
	})
end

local function highlight_color(name, field, fallback)
	local value = vim.api.nvim_get_hl(0, { name = name, link = false })[field]
	return type(value) == "number" and value or fallback
end

local function stronger_background(base, accent)
	local channels = {}
	for _, shift in ipairs({ 16, 8, 0 }) do
		local background = math.floor(base / 2 ^ shift) % 256
		local foreground = math.floor(accent / 2 ^ shift) % 256
		channels[#channels + 1] = math.floor(background * 0.6 + foreground * 0.4 + 0.5)
	end
	local blended = channels[1] * 65536 + channels[2] * 256 + channels[3]
	if blended == base then
		return stronger_background(base, base < 0x808080 and 0xFFFFFF or 0x000000)
	end
	return blended
end

local function define_band_highlight()
	vim.api.nvim_set_hl(0, BAND_HIGHLIGHT, { default = true, link = "StatusLine" })
	vim.api.nvim_set_hl(0, OLD_NUMBER_HIGHLIGHT, { default = true, link = "DiffDelete" })
	vim.api.nvim_set_hl(0, NEW_NUMBER_HIGHLIGHT, { default = true, link = "DiffAdd" })
	local background = highlight_color("Normal", "bg", vim.o.background == "light" and 0xFFFFFF or 0x1F2335)
	for _, side in ipairs({ { OLD_LINE_HIGHLIGHT, "DiffDelete" }, { NEW_LINE_HIGHLIGHT, "DiffAdd" } }) do
		local theme = vim.api.nvim_get_hl(0, { name = side[2], link = false })
		vim.api.nvim_set_hl(0, side[1], { bg = theme.bg or background, ctermbg = theme.ctermbg })
	end
	for _, side in ipairs({
		{ OLD_TEXT_HIGHLIGHT, "DiffDelete", "DiagnosticError", 0xF7768E, 1 },
		{ NEW_TEXT_HIGHLIGHT, "DiffAdd", "DiagnosticOk", 0x9ECE6A, 2 },
	}) do
		vim.api.nvim_set_hl(0, side[1], {
			bg = stronger_background(
				highlight_color(side[2], "bg", background),
				highlight_color(side[3], "fg", side[4])
			),
			bold = true,
			ctermbg = side[5],
		})
	end
end

define_band_highlight()
local band_highlight_group = vim.api.nvim_create_augroup("NvimReviewNativePresenterHighlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
	group = band_highlight_group,
	desc = "Restore native review hunk band highlights",
	callback = define_band_highlight,
})

local function text_area_width(win)
	local info = vim.fn.getwininfo(win)[1] or {}
	return math.max(1, vim.api.nvim_win_get_width(win) - (tonumber(info.textoff) or 0))
end

local function fit_display_width(value, width)
	width = math.max(0, width)
	local display_width = vim.fn.strdisplaywidth(value)
	if display_width > width then
		local ellipsis = "…"
		local ellipsis_width = vim.fn.strdisplaywidth(ellipsis)
		if ellipsis_width > width then
			value = ""
		else
			local budget = width - ellipsis_width
			local used = 0
			local characters = {}
			for index = 0, vim.fn.strchars(value) - 1 do
				local character = vim.fn.strcharpart(value, index, 1)
				local character_width = vim.fn.strdisplaywidth(character)
				if used + character_width > budget then
					break
				end
				characters[#characters + 1] = character
				used = used + character_width
			end
			value = table.concat(characters) .. ellipsis
		end
		display_width = vim.fn.strdisplaywidth(value)
	end
	return value .. string.rep(" ", math.max(0, width - display_width))
end

local function scope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		return pcall(vim.api.nvim_win_add_ns, win, namespace)
	end
	if type(vim.api.nvim__ns_set) == "function" then
		return pcall(vim.api.nvim__ns_set, namespace, { wins = { win } })
	end
	return false, "window-scoped namespaces are unavailable"
end

local function unscope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		if valid_win(win) then
			pcall(vim.api.nvim_win_remove_ns, win, namespace)
		end
	elseif type(vim.api.nvim__ns_set) == "function" then
		pcall(vim.api.nvim__ns_set, namespace, { wins = {} })
	end
end

local function text_lines(text)
	if text == "" then
		return { "" }, false, "unix"
	end
	local fileformat = "unix"
	if text:find("\r\n", 1, true) then
		fileformat = "dos"
		text = text:gsub("\r\n", "\n")
	elseif text:find("\r", 1, true) and not text:find("\n", 1, true) then
		fileformat = "mac"
		text = text:gsub("\r", "\n")
	end
	local endofline = text:sub(-1) == "\n"
	if endofline then
		text = text:sub(1, -2)
	end
	return vim.split(text, "\n", { plain = true }), endofline, fileformat
end

local function source_line_count(text)
	return text == "" and 0 or #text_lines(text)
end

local function buffer_text(buf)
	local separator = ({ dos = "\r\n", mac = "\r" })[vim.bo[buf].fileformat] or "\n"
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), separator)
	return vim.bo[buf].endofline and text .. separator or text
end

local function read_file(path)
	local handle, open_err = vim.uv.fs_open(path, "r", 0)
	if not handle then
		return nil, open_err
	end
	local stat, stat_err = vim.uv.fs_fstat(handle)
	if not stat then
		vim.uv.fs_close(handle)
		return nil, stat_err
	end
	local value, read_err = vim.uv.fs_read(handle, stat.size, 0)
	vim.uv.fs_close(handle)
	return value, read_err
end

local function named_buffer(path)
	local normalized = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if valid_buf(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
			local name = vim.api.nvim_buf_get_name(buf)
			if vim.fs.normalize(vim.uv.fs_realpath(name) or name) == normalized then
				return buf
			end
		end
	end
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	return buf
end

local function current_buffer(state, entry)
	if not entry.new_path or entry.metadata_only then
		return nil
	end
	local path, resolved_or_err = repo.resolve_relative(state.workspace.root, entry.new_path)
	if not path then
		return nil, resolved_or_err
	end
	local disk, disk_err = read_file(path)
	if disk == nil then
		return nil, disk_err
	end
	if disk ~= entry.new_text then
		return nil, "current file differs from the selected review content"
	end
	local buf = named_buffer(path)
	if vim.bo[buf].modified or buffer_text(buf) ~= entry.new_text then
		return nil, "current buffer differs from the selected review content"
	end
	local enrolled, enroll_err = review_mode.enroll(state, buf)
	if not enrolled then
		return nil, enroll_err
	end
	return buf, nil, path
end

local function metadata_lines(entry)
	local kind = entry.submodule and "submodule" or entry.binary and "binary file" or "metadata"
	return {
		("[%s]"):format(kind),
		("status: %s%s"):format(entry.status, entry.layer and " (" .. entry.layer .. ")" or ""),
		("old: %s"):format(entry.old_path or "<none>"),
		("new: %s"):format(entry.new_path or "<none>"),
		("old object: %s"):format(entry.old_oid or "<none>"),
		("new object: %s"):format(entry.new_oid or "<none>"),
	}
end

local function set_filetype(buf, path)
	if not path then
		return
	end
	local filetype = vim.filetype.match({ filename = path, buf = buf })
	if filetype then
		vim.bo[buf].filetype = filetype
	end
end

local function definition_options(state, buf, win, generation, buffer_role)
	local callback = state.handlers and state.handlers.definition_options
	if type(callback) ~= "function" then
		return nil
	end
	return callback(state, {
		buf = buf,
		generation = generation,
		role = buffer_role,
		win = win,
	})
end

local function scratch(entry, side, state)
	local buf = vim.api.nvim_create_buf(false, true)
	local is_old = side == "old"
	local role = is_old and "old" or "snapshot"
	local path = is_old and entry.old_path or entry.new_path
	local generation = state.presentation and state.presentation.generation or nil
	local metadata = {
		root = state.workspace.root,
		path = path,
		current_path = entry.new_path,
		side = side,
		entry = entry,
		bridge = not entry.metadata_only,
		navigation = lsp_navigation,
		definition_options = function(win)
			return definition_options(state, buf, win, generation, role)
		end,
	}
	-- The role deliberately precedes filetype assignment and all FileType consumers.
	review_lsp.mark(buf, role, metadata)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local lines
	local endofline = false
	local fileformat = "unix"
	if entry.metadata_only then
		lines = metadata_lines(entry)
	else
		lines, endofline, fileformat = text_lines(is_old and entry.old_text or entry.new_text)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].fileformat = fileformat
	vim.bo[buf].endofline = endofline
	vim.bo[buf].fixendofline = false
	vim.b[buf].nvim_review_path = path
	vim.b[buf].nvim_review_side = is_old and "left" or "right"
	vim.b[buf].nvim_review_layer = entry.layer or "history"
	set_filetype(buf, path)
	local protected, protect_err = review_mode.protect_transient(state, buf)
	if not protected then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		error("Could not protect review scratch buffer: " .. tostring(protect_err))
	end
	return buf
end

local function side_buffer(state, entry, side)
	if side == "new" then
		local buf, _, path = current_buffer(state, entry)
		if buf then
			return buf, true, path
		end
	end
	return scratch(entry, side, state), false
end

local function unified_scratch(entry, projection, generation, state, side)
	local buf = vim.api.nvim_create_buf(false, true)
	local metadata = {
		bridge = true,
		context = state.presentation.context,
		current_path = entry.new_path,
		entry = entry,
		generation = generation,
		navigation = lsp_navigation,
		projection = projection,
		root = state.workspace.root,
		visible_sections = state.presentation.context == "hunks" and state.presentation.visibility[side or "unified"]
			or nil,
		definition_options = function(win)
			return definition_options(state, buf, win, generation, "unified")
		end,
	}
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(
		buf,
		0,
		-1,
		false,
		vim.tbl_map(function(row)
			return row.text
		end, projection.rows)
	)
	-- This is a synthetic projection. Exact per-source terminators live in the projection model.
	vim.bo[buf].fileformat = "unix"
	vim.bo[buf].endofline = false
	vim.bo[buf].fixendofline = false
	vim.b[buf].nvim_review_entry_identity = entry.identity
	vim.b[buf].nvim_review_layer = entry.layer or "history"
	vim.b[buf].nvim_review_projection_generation = generation
	if not review_lsp.mark(buf, "unified", metadata) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		error("Could not mark unified review projection before FileType")
	end
	set_filetype(buf, side == "old" and entry.old_path or entry.new_path or entry.old_path)
	local protected, protect_err = review_mode.protect_transient(state, buf)
	if not protected then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		error("Could not protect unified review projection: " .. tostring(protect_err))
	end
	vim.keymap.set("n", "[h", function()
		M.prev_hunk(state)
	end, { buffer = buf, silent = true, desc = "Previous review hunk" })
	vim.keymap.set("n", "]h", function()
		M.next_hunk(state)
	end, { buffer = buf, silent = true, desc = "Next review hunk" })
	return buf
end

local function sections(entry, side, line_count, context)
	context = math.max(0, context)
	local values = {}
	for index, hunk in ipairs(entry.hunks or {}) do
		local start = side == "old" and hunk[1] or hunk[3]
		local count = side == "old" and hunk[2] or hunk[4]
		local changed_first = count == 0 and start + 1 or start
		local changed_last = count == 0 and start or start + count - 1
		values[#values + 1] = {
			first = math.min(line_count + 1, math.max(1, changed_first - context)),
			hunks = { index },
			last = math.max(0, math.min(line_count, changed_last + context)),
		}
	end
	table.sort(values, function(left, right)
		return left.first < right.first
	end)
	local merged = {}
	for _, value in ipairs(values) do
		local previous = merged[#merged]
		if previous and value.first <= previous.last + 1 then
			previous.last = math.max(previous.last, value.last)
			vim.list_extend(previous.hunks, value.hunks)
		else
			merged[#merged + 1] = value
		end
	end
	return merged
end

local function side_text(entry, side)
	return side == "old" and entry.old_text or entry.new_text
end

local function side_path(entry, side)
	return side == "old" and entry.old_path or entry.new_path
end

local function declaration_name(node, source, kind)
	local ok_field, fields = pcall(node.field, node, "name")
	if ok_field and fields and fields[1] then
		local ok_text, value = pcall(vim.treesitter.get_node_text, fields[1], source)
		if ok_text and type(value) == "string" and vim.trim(value) ~= "" then
			return vim.trim(value):gsub("%s+", " ")
		end
	end
	local start_row = node:range()
	local line = vim.split(source, "\n", { plain = true })[start_row + 1] or ""
	local patterns = kind == "class" and { "class%s+([%w_.$:]+)", "struct%s+([%w_.$:]+)", "interface%s+([%w_.$:]+)" }
		or {
			"function%s+([%w_.$:]+)",
			"def%s+([%w_.$:]+)",
			"fn%s+([%w_.$:]+)",
			"func%s+([%w_.$:]+)",
		}
	for _, pattern in ipairs(patterns) do
		local value = line:match(pattern)
		if value then
			return value
		end
	end
	return nil
end

local function collect_symbol_candidates(presentation, side)
	local cached = presentation.symbol_candidates[side]
	if cached then
		return cached
	end
	local candidates = {}
	presentation.symbol_candidates[side] = candidates
	local path = side_path(presentation.entry, side)
	local text = side_text(presentation.entry, side)
	if not path or type(text) ~= "string" or text == "" then
		return candidates
	end
	local filetype = vim.filetype.match({ filename = path })
	if not filetype then
		return candidates
	end
	local ok_lang, lang = pcall(vim.treesitter.language.get_lang, filetype)
	lang = ok_lang and lang or filetype
	local ok_query, query = pcall(vim.treesitter.query.get, lang, "textobjects")
	if not ok_query or not query then
		return candidates
	end
	local lines = text_lines(text)
	local source = table.concat(lines, "\n")
	local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, lang, { error = false })
	if not ok_parser or not parser then
		return candidates
	end
	local ok_trees, trees = pcall(parser.parse, parser)
	if not ok_trees or not trees or not trees[1] then
		return candidates
	end
	pcall(function()
		for capture, node in query:iter_captures(trees[1]:root(), source, 0, -1) do
			local capture_name = query.captures[capture]
			local kind = capture_name == "function.outer" and "function"
				or capture_name == "class.outer" and "class"
				or nil
			if kind then
				local start_row, start_col, end_row, end_col = node:range()
				local name = declaration_name(node, source, kind)
				if name then
					candidates[#candidates + 1] = {
						declaration = start_row + 1,
						first = start_row + 1,
						label = kind .. " " .. name,
						last = math.max(start_row + 1, end_row + (end_col > 0 and 1 or 0)),
						size = (end_row - start_row) * 100000 + math.max(0, end_col - start_col),
					}
				end
			end
		end
	end)
	return candidates
end

local function line_is_visible(presentation, side, line)
	local projection = presentation.projection
		or presentation.split_projections and presentation.split_projections[side]
	if projection then
		local display_line = projection.by_source[side][line]
		if not display_line then
			return false
		end
		for _, section in ipairs(presentation.visibility[presentation.projection and "unified" or side] or {}) do
			if display_line >= section.first and display_line <= section.last then
				return true
			end
		end
		return false
	end
	for _, section in ipairs(presentation.visibility[side] or {}) do
		if line >= section.first and line <= section.last then
			return true
		end
	end
	return false
end

local function containing_symbol(presentation, side, hunk_index)
	local probe
	if presentation.structural then
		local projection = presentation.projection or presentation.split_projections[side]
		local hunk = projection.hunks[hunk_index]
		for line = hunk.first, hunk.last do
			probe = projection.rows[line][side .. "_line"] or probe
		end
	else
		local hunk = presentation.entry.hunks[hunk_index]
		local start = side == "old" and hunk[1] or hunk[3]
		local count = side == "old" and hunk[2] or hunk[4]
		probe = math.max(1, start + math.max(0, count - 1))
	end
	if not probe then
		return nil
	end
	local best
	for _, candidate in ipairs(collect_symbol_candidates(presentation, side)) do
		if probe >= candidate.first and probe <= candidate.last and (not best or candidate.size < best.size) then
			best = candidate
		end
	end
	return best
end

local function hunk_symbol_label(presentation, hunk_index)
	local cached = presentation.symbol_labels[hunk_index]
	if cached ~= nil then
		return cached ~= false and cached or nil
	end
	for _, side in ipairs({ "new", "old" }) do
		local candidate = containing_symbol(presentation, side, hunk_index)
		if candidate then
			local label = not line_is_visible(presentation, side, candidate.declaration) and candidate.label or false
			presentation.symbol_labels[hunk_index] = label
			return label ~= false and label or nil
		end
	end
	presentation.symbol_labels[hunk_index] = false
	return nil
end

local function section_symbol_label(presentation, section)
	for _, hunk_index in ipairs(section.hunks) do
		local label = hunk_symbol_label(presentation, hunk_index)
		if label then
			return label
		end
	end
	return nil
end

local function side_reaches_end(start, count, line_count)
	return (count == 0 and start == line_count) or (count > 0 and start + count - 1 == line_count)
end

local function section_band_edges(presentation, section)
	if section.first > section.last then
		return false, false
	end
	if presentation.layout ~= "split" or not presentation.right then
		return true, true
	end
	local show_start = true
	local show_end = true
	for _, hunk_index in ipairs(section.hunks) do
		local hunk = presentation.entry.hunks[hunk_index]
		if (hunk[2] == 0 and hunk[1] == 0) or (hunk[4] == 0 and hunk[3] == 0) then
			show_start = false
		end
		if
			hunk[2] ~= hunk[4]
			and side_reaches_end(hunk[1], hunk[2], presentation.source_line_counts.old)
			and side_reaches_end(hunk[3], hunk[4], presentation.source_line_counts.new)
		then
			show_end = false
		end
	end
	return show_start, show_end
end

local function conceal_range(buf, namespace, first, last)
	return {
		first = first,
		last = last,
		id = vim.api.nvim_buf_set_extmark(buf, namespace, first - 1, 0, {
			conceal_lines = "",
			end_row = last - 1,
			end_col = 0,
		}),
	}
end

local function hide_context(buf, win, namespace, visible)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local omitted = {}
	local first = 1
	for _, section in ipairs(visible) do
		if first < section.first then
			omitted[#omitted + 1] = conceal_range(buf, namespace, first, section.first - 1)
		end
		first = section.last + 1
	end
	if first <= line_count then
		omitted[#omitted + 1] = conceal_range(buf, namespace, first, line_count)
	end
	return omitted
end

local function nearest_boundary(line, before, after)
	if not before then
		return after and after.first or nil
	elseif not after then
		return before.last
	end
	local backward = line - before.last
	local forward = after.first - line
	return forward <= backward and after.first or before.last
end

local function gap_boundaries(sections_value, line)
	local before
	for _, section in ipairs(sections_value) do
		if line < section.first then
			return before, section
		elseif line <= section.last then
			return nil
		end
		before = section
	end
	return before, nil
end

local function correct_concealed_cursor(guard)
	if
		not guard.active
		or guard.adjusting
		or not valid_win(guard.win)
		or not valid_buf(guard.buf)
		or vim.api.nvim_win_get_buf(guard.win) ~= guard.buf
	then
		return
	end
	local line = vim.api.nvim_win_get_cursor(guard.win)[1]
	local before, after = gap_boundaries(guard.sections, line)
	if before == nil and after == nil then
		guard.last_line = line
		return
	end
	local previous = guard.last_line
	local target
	if previous and math.abs(line - previous) == 1 then
		if line > previous then
			target = after and after.first or before and before.last
		else
			target = before and before.last or after and after.first
		end
	end
	target = target or nearest_boundary(line, before, after)
	if not target or target == line then
		guard.last_line = line
		return
	end
	guard.adjusting = true
	local moved = pcall(vim.api.nvim_win_set_cursor, guard.win, { target, 0 })
	guard.adjusting = false
	if moved then
		guard.last_line = target
	end
end

local function clear_one_cursor_guard(presentation, win)
	local guard = presentation and presentation.cursor_guards and presentation.cursor_guards[win]
	if not guard then
		return
	end
	presentation.cursor_guards[win] = nil
	guard.active = false
	guard.redraw_pending = false
	for _, id in ipairs(guard.autocmds or {}) do
		pcall(vim.api.nvim_del_autocmd, id)
	end
end

local function clear_cursor_guards(presentation)
	for win in pairs((presentation and presentation.cursor_guards) or {}) do
		clear_one_cursor_guard(presentation, win)
	end
end

local function install_cursor_guard(state, presentation, buf, win, visible, omitted)
	if #visible == 0 or #omitted == 0 then
		return
	end
	local guard = {
		active = true,
		autocmds = {},
		buf = buf,
		generation = presentation.generation,
		sections = vim.deepcopy(visible),
		win = win,
	}
	presentation.cursor_guards[win] = guard
	guard.autocmds[#guard.autocmds + 1] = vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		desc = "Keep the native review cursor inside visible hunks",
		callback = function(event)
			if
				event.buf ~= guard.buf
				or vim.api.nvim_get_current_win() ~= guard.win
				or state.presentation ~= presentation
				or presentation.cursor_guards[guard.win] ~= guard
				or guard.generation ~= presentation.generation
			then
				return
			end
			correct_concealed_cursor(guard)
		end,
	})
	guard.autocmds[#guard.autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		desc = "Release native review cursor ownership",
		callback = function()
			clear_one_cursor_guard(presentation, win)
		end,
	})
	if presentation.layout == "inline" then
		guard.autocmds[#guard.autocmds + 1] = vim.api.nvim_create_autocmd("WinScrolled", {
			pattern = tostring(win),
			desc = "Invalidate scrolled native review hunk rows",
			callback = function()
				if not guard.active or guard.redraw_pending or state.presentation ~= presentation then
					return
				end
				guard.redraw_pending = true
				vim.schedule(function()
					guard.redraw_pending = false
					if
						not guard.active
						or state.presentation ~= presentation
						or presentation.cursor_guards[win] ~= guard
						or not valid_win(win)
						or vim.api.nvim_win_get_buf(win) ~= buf
					then
						return
					end
					-- Concealed gaps plus virtual bands can leave duplicate screen rows
					-- after scrolling with scrolloff. Invalidate after the scroll completes;
					-- doing this inside WinScrolled still permits stale cached rows.
					vim.api.nvim__redraw({ win = win, valid = false })
				end)
			end,
		})
	end
	guard.last_line = vim.api.nvim_win_get_cursor(win)[1]
	correct_concealed_cursor(guard)
end

local function statusline_escape(value)
	return tostring(value):gsub("%%", "%%%%")
end

local function review_winbar(state, entry, side, layout, context)
	local workspace = state.workspace or {}
	local scope = workspace.scope or {}
	local mode_on = workspace.mode_on
	if type(mode_on) ~= "boolean" then
		mode_on = state.enabled == true
	end
	local scope_kind = scope.kind or "review"
	local scope_label = scope.label or scope.id or "unknown"
	local layer = entry.layer or "history"
	local path = side == "old" and entry.old_path
		or side == "unified" and (entry.old_path ~= entry.new_path and entry.old_path and entry.new_path) and (entry.old_path .. " → " .. entry.new_path)
		or entry.new_path
		or entry.old_path
	local comments = workspace.inline_comments
	if type(comments) ~= "boolean" then
		comments = workspace.inline_comments_visible
	end
	local values = {
		"REV " .. (mode_on and "ON" or "OFF"),
		scope_kind .. ":" .. scope_label,
		layer,
		layout .. "/" .. context,
	}
	local presentation = state.presentation or {}
	local origin = presentation.origin_engine
	local selected = presentation.selected_engine or "main"
	values[#values + 1] = "engine:" .. selected
	if origin and origin.id ~= selected then
		values[#values + 1] = "effective:" .. origin.id .. " (" .. (presentation.fallback_reason or "fallback") .. ")"
	end
	if presentation.structural and presentation.structural.status == "unchanged" then
		values[#values + 1] = "No structural changes"
	end
	if type(comments) == "boolean" then
		values[#values + 1] = "comments:" .. (comments and "on" or "off")
	end
	values[#values + 1] = side == "old" and "OLD" or side == "unified" and "OLD │ NEW" or "CURRENT"
	values[#values + 1] = path or entry.path or "<none>"
	return " " .. table.concat(vim.tbl_map(statusline_escape, values), " · ") .. " "
end

local function set_review_winbar(state, presentation, side)
	if valid_win(side.win) and vim.api.nvim_win_get_buf(side.win) == side.buf then
		vim.wo[side.win].winbar =
			review_winbar(state, presentation.entry, side.side, presentation.layout, presentation.context)
	end
end

---Refresh winbars owned by the current review presentation only.
---@param state table
---@return boolean
function M.refresh_winbars(state)
	local presentation = state and state.presentation
	if not presentation then
		return false
	end
	for _, name in ipairs({ "inline", "left", "right" }) do
		local side = presentation[name]
		if side then
			set_review_winbar(state, presentation, side)
		end
	end
	return true
end

local function highlight_lines(buf, namespace, first, count, group)
	for line = first, first + count - 1 do
		if line >= 1 and line <= vim.api.nvim_buf_line_count(buf) then
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				hl_group = group,
				end_row = line,
				end_col = 0,
				hl_eol = true,
				priority = 80,
			})
		end
	end
end

local function apply_split_highlight_links(item, side)
	local real_group = side == "old" and OLD_LINE_HIGHLIGHT or NEW_LINE_HIGHLIGHT
	for _, link in ipairs({
		{ real_group, real_group },
		{ "DiffDelete", "Normal" },
	}) do
		local group, target = link[1], link[2]
		local ok, err = pcall(vim.api.nvim_set_hl, item.namespace, group, { link_global = target })
		if not ok then
			return nil, err
		end
	end
	-- Native diff UI backgrounds otherwise override both line and character
	-- extmarks. Keep diff alignment/fillers, with our ranges owning real rows.
	for _, group in ipairs({ "DiffAdd", "DiffChange", "DiffTextAdd", "DiffText" }) do
		local ok, err = pcall(vim.api.nvim_set_hl, item.namespace, group, {})
		if not ok then
			return nil, err
		end
	end
	return true
end

local function configure_split_highlights(item, side)
	local ok_previous, previous = pcall(vim.api.nvim_get_hl_ns, { winid = item.win })
	if not ok_previous then
		return nil, previous
	end
	local ok_active, active_err = pcall(vim.api.nvim_win_set_hl_ns, item.win, item.namespace)
	if not ok_active then
		return nil, active_err
	end
	item.previous_hl_namespace = previous
	item.split_highlight_namespace = true
	return apply_split_highlight_links(item, side)
end

local function set_band_extmark(item, band, width)
	width = width or text_area_width(item.win)
	local options = {
		virt_lines = { { { fit_display_width(band.label, width), BAND_HIGHLIGHT } } },
		virt_lines_above = band.above,
	}
	if band.id then
		options.id = band.id
	end
	band.id = vim.api.nvim_buf_set_extmark(item.buf, item.namespace, band.row, 0, options)
	band.rendered_width = width
end

local function add_band(item, row, above, label)
	local band = { above = above, label = label, row = row }
	set_band_extmark(item, band)
	item.bands[#item.bands + 1] = band
end

local function decorate_intraline(presentation, item, side, projected)
	local detail = presentation.intraline
	for _, source_side in ipairs(projected and { "old", "new" } or { side }) do
		local group = source_side == "old" and OLD_TEXT_HIGHLIGHT or NEW_TEXT_HIGHLIGHT
		for _, range in ipairs(detail[source_side] or {}) do
			local line = projected and projected.by_source[source_side][range.line] or not projected and range.line
			if line and range.end_col > range.start_col then
				vim.api.nvim_buf_set_extmark(item.buf, item.namespace, line - 1, range.start_col, {
					end_col = range.end_col,
					hl_group = group,
					priority = 150,
				})
			end
		end
	end
end

local function decorate(state, entry, buf, win, side, context, inline)
	if entry.metadata_only then
		return true
	end
	local presentation = state.presentation
	local projected = presentation.inline and presentation.inline.buf == buf and presentation.projection
		or presentation.left and presentation.left.buf == buf and presentation.left.projection
		or presentation.right and presentation.right.buf == buf and presentation.right.projection
		or nil
	local unified = projected ~= nil
	local namespace = vim.api.nvim_create_namespace(("nvim_review_native_%d_%d"):format(win, buf))
	local scoped = false
	if not unified then
		local scope_err
		scoped, scope_err = scope_namespace(win, namespace)
		if not scoped then
			return nil, "Could not scope review decorations: " .. tostring(scope_err)
		end
	end
	local item = {
		bands = {},
		buf = buf,
		namespace = namespace,
		scoped = scoped,
		win = win,
	}
	presentation.decorations[#presentation.decorations + 1] = item
	if not inline then
		local configured, configure_err = configure_split_highlights(item, side)
		if not configured then
			return nil, "Could not configure split review highlights: " .. tostring(configure_err)
		end
	end
	if unified then
		for display_line, row in ipairs(projected.rows) do
			local group = row.kind == "old" and OLD_LINE_HIGHLIGHT or row.kind == "new" and NEW_LINE_HIGHLIGHT or nil
			if group then
				highlight_lines(buf, namespace, display_line, 1, group)
			end
		end
	else
		local line_highlight = side == "old" and OLD_LINE_HIGHLIGHT or NEW_LINE_HIGHLIGHT
		if presentation.structural then
			for line in pairs(presentation.structural.line_changes[side]) do
				highlight_lines(buf, namespace, line, 1, line_highlight)
			end
		else
			for _, hunk in ipairs(entry.hunks or {}) do
				if side == "old" then
					highlight_lines(buf, namespace, hunk[1], hunk[2], line_highlight)
				else
					highlight_lines(buf, namespace, hunk[3], hunk[4], line_highlight)
				end
			end
		end
	end
	decorate_intraline(presentation, item, side, projected)
	if presentation.structural and presentation.structural.status == "unchanged" then
		add_band(item, 0, true, " No structural changes ")
	end
	if context == "hunks" then
		local visible = projected and (inline and presentation.visibility.unified or presentation.visibility[side])
			or presentation.visibility[side]
		if #visible == 0 then
			return true
		end
		vim.wo[win].conceallevel = math.max(2, vim.wo[win].conceallevel)
		vim.wo[win].concealcursor = "nvic"
		local omitted = hide_context(buf, win, namespace, visible)
		item.omitted = omitted
		for index, section in ipairs(visible) do
			local show_start, show_end = section_band_edges(state.presentation, section)
			if show_start then
				local label = section_symbol_label(state.presentation, section)
				local header = (" HUNK %d/%d "):format(index, #visible)
				if label then
					header = header:sub(1, -2) .. " · " .. label .. " "
				end
				add_band(item, section.first - 1, true, header)
			end
			if show_end then
				add_band(item, section.last - 1, false, (" END HUNK %d/%d "):format(index, #visible))
			end
		end
		local cursor_sections = vim.tbl_filter(function(section)
			return section.first <= section.last
		end, visible)
		install_cursor_guard(state, state.presentation, buf, win, cursor_sections, omitted)
	end
	return true
end

local function refresh_presentation_bands(state, presentation, force)
	if state.presentation ~= presentation or presentation.context ~= "hunks" then
		return false
	end
	local refreshed = false
	for _, item in ipairs(presentation.decorations) do
		if
			#item.bands > 0
			and valid_win(item.win)
			and valid_buf(item.buf)
			and vim.api.nvim_win_get_buf(item.win) == item.buf
		then
			local width = text_area_width(item.win)
			for _, band in ipairs(item.bands) do
				if force or band.rendered_width ~= width then
					set_band_extmark(item, band, width)
					refreshed = true
				end
			end
		end
	end
	return refreshed
end

local function schedule_band_refresh(state, presentation, force)
	if state.presentation ~= presentation or presentation.context ~= "hunks" then
		return false
	end
	presentation.band_refresh_force = presentation.band_refresh_force or force == true
	if presentation.band_refresh_pending then
		return true
	end
	presentation.band_refresh_pending = true
	local generation = presentation.generation
	vim.schedule(function()
		if not presentation.band_refresh_pending then
			return
		end
		presentation.band_refresh_pending = false
		local refresh_force = presentation.band_refresh_force == true
		presentation.band_refresh_force = false
		if state.presentation ~= presentation or presentation.generation ~= generation then
			return
		end
		refresh_presentation_bands(state, presentation, refresh_force)
	end)
	return true
end

local function band_event_targets_presentation(presentation, event)
	if event.event == "VimResized" or event.event == "WinResized" then
		return true
	end
	for _, item in ipairs(presentation.decorations) do
		if item.buf == event.buf and #item.bands > 0 then
			return true
		end
	end
	return false
end

local function install_band_refresh(state, presentation)
	local has_bands = vim.iter(presentation.decorations):any(function(item)
		return #item.bands > 0
	end)
	if presentation.context ~= "hunks" or not has_bands then
		return
	end
	presentation.band_refresh_autocmd = vim.api.nvim_create_autocmd(
		{ "VimResized", "WinResized", "CursorMoved", "CursorHold", "DiagnosticChanged" },
		{
			desc = "Refresh native review hunk band widths",
			callback = function(event)
				if band_event_targets_presentation(presentation, event) then
					schedule_band_refresh(state, presentation, false)
				end
			end,
		}
	)
end

---Schedule an in-place refresh of the current presentation's hunk bands.
---@param state table
---@return boolean
function M.refresh_bands(state)
	local presentation = state and state.presentation
	if not presentation then
		return false
	end
	return schedule_band_refresh(state, presentation, true)
end

local function enable_native_diff(left_win, right_win)
	for _, win in ipairs({ left_win, right_win }) do
		vim.api.nvim_win_call(win, function()
			vim.cmd("diffthis")
		end)
		vim.wo[win].foldenable = false
	end
end

local function set_blank_diff_filler(win)
	vim.api.nvim_win_call(win, function()
		local fillchars = vim.opt_local.fillchars:get()
		fillchars.diff = " "
		vim.opt_local.fillchars = fillchars
	end)
end

local function prepare_review_window(win, layout)
	vim.wo[win].foldenable = false
	vim.wo[win].number = true
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "auto:1-9"
	vim.wo[win].statuscolumn = ""
	if layout == "split" then
		set_blank_diff_filler(win)
	end
end

local function configure_unified_gutter(presentation, win, buf, projection)
	projection = projection or presentation.projection
	local width = projection.gutter_digits * 2 + 3
	vim.wo[win].number = true
	vim.wo[win].relativenumber = false
	vim.wo[win].numberwidth = math.max(1, math.min(20, width))
	gutters[win] = {
		buf = buf,
		generation = presentation.generation,
		presentation = presentation,
		projection = projection,
	}
	vim.wo[win].statuscolumn = STATUSCOLUMN
end

local function release_unified_gutter(presentation)
	for _, name in ipairs({ "inline", "left", "right" }) do
		local target = presentation and presentation[name]
		local gutter = target and gutters[target.win]
		if gutter and gutter.presentation == presentation then
			gutters[target.win] = nil
		end
	end
end

local function capture_inline_view(state, entry)
	local presentation = state.presentation
	local inline = presentation and presentation.inline
	if
		not inline
		or presentation.layout ~= "inline"
		or not presentation.projection
		or presentation.entry.identity ~= entry.identity
		or not valid_win(inline.win)
		or vim.api.nvim_win_get_buf(inline.win) ~= inline.buf
	then
		return nil
	end
	local snapshot = { cursor = vim.api.nvim_win_get_cursor(inline.win) }
	vim.api.nvim_win_call(inline.win, function()
		snapshot.view = vim.fn.winsaveview()
	end)
	return snapshot
end

local function restore_inline_view(inline, snapshot)
	if not snapshot or not valid_win(inline.win) or vim.api.nvim_win_get_buf(inline.win) ~= inline.buf then
		return
	end
	local count = vim.api.nvim_buf_line_count(inline.buf)
	local cursor = vim.deepcopy(snapshot.cursor)
	cursor[1] = math.max(1, math.min(cursor[1], count))
	vim.api.nvim_win_set_cursor(inline.win, cursor)
	if snapshot.view then
		local view = vim.deepcopy(snapshot.view)
		view.lnum = cursor[1]
		view.topline = math.max(1, math.min(view.topline, count))
		vim.api.nvim_win_call(inline.win, function()
			vim.fn.winrestview(view)
		end)
	end
end

local function option_set(value)
	local values = {}
	for option in value:gmatch("[^,]+") do
		values[option] = true
	end
	return values
end

local function added_options(before, after)
	local original = option_set(before)
	local added = {}
	for option in after:gmatch("[^,]+") do
		if not original[option] then
			added[option] = true
		end
	end
	return added
end

local function other_diff_exists()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if valid_win(win) and vim.wo[win].diff then
			return true
		end
	end
	return false
end

local function restore_scroll_options(added)
	if not added or other_diff_exists() then
		return
	end
	local retained = {}
	for option in vim.o.scrollopt:gmatch("[^,]+") do
		if not added[option] then
			retained[#retained + 1] = option
		end
	end
	vim.o.scrollopt = table.concat(retained, ",")
end

local function put_buffer(win, buf)
	if valid_win(win) and valid_buf(buf) then
		vim.api.nvim_win_set_buf(win, buf)
	end
end

local function create_split(state, buf)
	local win = vim.api.nvim_open_win(buf, false, { split = "right", win = state.origin.win })
	review_mode.capture_window(state, win)
	review_mode.set_auxiliary(state, "right", win, buf)
	return win
end

local function remember_owned(presentation, buf)
	presentation.owned_buffers[buf] = vim.bo[buf].buftype == "nofile"
end

local function split_projection(analysis, side)
	local source = analysis.projection.sources[side]
	local value = {
		sources = analysis.projection.sources,
		rows = {},
		hunks = {},
		by_source = { old = {}, new = {} },
		gutter_digits = analysis.projection.gutter_digits,
	}
	local hunk
	for index, pair in ipairs(analysis.aligned_lines) do
		local line = pair[side .. "_line"]
		local record = line and source.lines[line]
		local changed = pair.old_line and analysis.line_changes.old[pair.old_line]
			or pair.new_line and analysis.line_changes.new[pair.new_line]
		local row = {
			display_line = index,
			anchor_side = side,
			anchorable = line ~= nil,
			kind = line and (analysis.line_changes[side][line] and side or "context") or "filler",
			path = source.path,
			source_line = line or 0,
			text = record and record.text or "",
			terminator = record and record.terminator or "",
		}
		row[side .. "_line"], row[side .. "_path"] = line, source.path
		if line then
			value.by_source[side][line] = index
		end
		if changed then
			if not hunk then
				hunk = { first = index, last = index }
				value.hunks[#value.hunks + 1] = hunk
			end
			hunk.last, row.hunk_index = index, #value.hunks
		else
			hunk = nil
		end
		value.rows[#value.rows + 1] = row
	end
	if #value.rows == 0 then
		value.rows[1] = {
			display_line = 1,
			anchor_side = side,
			anchorable = false,
			kind = "empty",
			path = source.path,
			source_line = 0,
			text = "",
			terminator = "",
		}
		value.rows[1][side .. "_path"] = source.path
	end
	return value
end

local function bind_projected_scroll(state, presentation)
	presentation.scroll_sync_autocmd = vim.api.nvim_create_autocmd("WinScrolled", {
		callback = function(event)
			if state.presentation ~= presentation or presentation.syncing_scroll then
				return
			end
			local win = tonumber(event.match)
			local from = win == presentation.left.win and presentation.left
				or win == presentation.right.win and presentation.right
				or nil
			if not from then
				return
			end
			local to = from == presentation.left and presentation.right or presentation.left
			if
				not valid_win(from.win)
				or not valid_win(to.win)
				or vim.api.nvim_win_get_buf(from.win) ~= from.buf
				or vim.api.nvim_win_get_buf(to.win) ~= to.buf
			then
				return
			end
			local view = vim.api.nvim_win_call(from.win, vim.fn.winsaveview)
			presentation.syncing_scroll = true
			vim.api.nvim_win_call(to.win, function()
				local target = vim.fn.winsaveview()
				target.topline, target.topfill, target.leftcol = view.topline, view.topfill, view.leftcol
				target.lnum = math.max(view.topline, target.lnum)
				vim.fn.winrestview(target)
			end)
			presentation.syncing_scroll = false
		end,
	})
end

---Render one entry in the state's origin tab without creating a tab.
---@param state table
---@param entry table
---@param options? { layout?: "inline"|"split", context?: "hunks"|"full", side?: "old"|"new" }
---@return boolean?
---@return string? err
function M.show(state, entry, options)
	options = options or {}
	local layout = options.layout or "inline"
	local context = options.context or "hunks"
	if layout ~= "inline" and layout ~= "split" then
		return nil, "layout must be inline or split"
	end
	if context ~= "hunks" and context ~= "full" then
		return nil, "context must be hunks or full"
	end
	local preferred_side = options.side
	if preferred_side ~= nil and preferred_side ~= "old" and preferred_side ~= "new" then
		return nil, "side must be old or new"
	end
	local preferred_path = preferred_side == "old" and entry.old_path
		or preferred_side == "new" and entry.new_path
		or nil
	if preferred_side and not preferred_path then
		return nil, "preferred logical review side has no source path"
	end
	if not state.enabled then
		return nil, "review mode is not enabled"
	end
	local previous_inline_view = capture_inline_view(state, entry)
	local engine_result = options.engine_result or {}
	local structural = engine_result.origin_engine and engine_result.origin_engine.id ~= "main" and engine_result or nil
	local projection
	if layout == "inline" and not entry.metadata_only then
		local projection_err
		if structural then
			projection = structural.projection
		else
			projection, projection_err = review_projection.build(entry)
		end
		if not projection then
			return nil, "Could not build unified review projection: " .. tostring(projection_err)
		end
	end
	local intraline, intraline_err
	if structural then
		intraline = structural.intraline
	else
		intraline, intraline_err = review_diff.for_entry(state, entry)
	end
	if not intraline then
		return nil, "Could not refine review changes: " .. tostring(intraline_err)
	end
	local split_projections = structural
			and layout == "split"
			and {
				old = split_projection(structural, "old"),
				new = split_projection(structural, "new"),
			}
		or nil
	M.clear(state)
	if not valid_win(state.origin.win) or not vim.api.nvim_tabpage_is_valid(state.origin.tab) then
		return nil, "origin tab or window is no longer valid"
	end
	vim.api.nvim_set_current_tabpage(state.origin.tab)
	vim.api.nvim_set_current_win(state.origin.win)
	review_mode.capture_window(state, state.origin.win)
	presentation_generation = presentation_generation + 1
	local hunk_context = config.hunk_context
	local visibility_hunk_context = layout == "split" and math.max(1, hunk_context) or hunk_context
	local old_line_count = #text_lines(entry.old_text or "")
	local new_line_count = #text_lines(entry.new_text or "")
	local logical_old_line_count = entry.metadata_only and 0
		or structural and structural.projection.sources.old.line_count
		or source_line_count(entry.old_text or "")
	local logical_new_line_count = entry.metadata_only and 0
		or structural and structural.projection.sources.new.line_count
		or source_line_count(entry.new_text or "")
	local presentation = {
		cursor_guards = {},
		entry = entry,
		intraline = intraline,
		structural = structural,
		selected_engine = engine_result.selected_engine or "main",
		origin_engine = engine_result.origin_engine,
		fallback_reason = engine_result.fallback_reason,
		engine_result = engine_result,
		split_projections = split_projections,
		generation = presentation_generation,
		hunk_context = hunk_context,
		visibility_hunk_context = visibility_hunk_context,
		layout = layout,
		context = context,
		preferred_side = nil,
		projection = projection,
		source_line_counts = {
			old = logical_old_line_count,
			new = logical_new_line_count,
		},
		decorations = {},
		owned_buffers = {},
		symbol_candidates = {},
		symbol_labels = {},
		visibility = {
			old = split_projections and review_projection.sections(split_projections.old, visibility_hunk_context)
				or sections(entry, "old", old_line_count, visibility_hunk_context),
			new = split_projections and review_projection.sections(split_projections.new, visibility_hunk_context)
				or sections(entry, "new", new_line_count, visibility_hunk_context),
			unified = projection and review_projection.sections(projection, visibility_hunk_context) or nil,
		},
	}
	state.presentation = presentation
	state.clear_presentation = M.clear
	state.handlers.next_hunk = M.next_hunk
	state.handlers.prev_hunk = M.prev_hunk

	if layout == "inline" then
		local side = projection and "unified" or preferred_side or entry.new_path and "new" or "old"
		local buf = projection and unified_scratch(entry, projection, presentation.generation, state)
			or scratch(entry, side, state)
		presentation.inline = { win = state.origin.win, buf = buf, side = side, real = false }
		remember_owned(presentation, buf)
		put_buffer(state.origin.win, buf)
		prepare_review_window(state.origin.win, layout)
		if projection then
			configure_unified_gutter(presentation, state.origin.win, buf)
		end
		local decorated, decorate_err = decorate(state, entry, buf, state.origin.win, side, context, true)
		if not decorated then
			M.clear(state)
			return nil, decorate_err
		end
		set_review_winbar(state, presentation, presentation.inline)
		presentation.target = { entry = entry, side = side, win = state.origin.win, buf = buf }
		restore_inline_view(presentation.inline, previous_inline_view)
	else
		local left_buf = split_projections
				and unified_scratch(entry, split_projections.old, presentation.generation, state, "old")
			or side_buffer(state, entry, "old")
		presentation.left = {
			win = state.origin.win,
			buf = left_buf,
			side = "old",
			projection = split_projections and split_projections.old,
		}
		remember_owned(presentation, left_buf)
		put_buffer(state.origin.win, left_buf)
		if not entry.deleted then
			local right_buf, real
			if structural then
				right_buf, real =
					unified_scratch(entry, split_projections.new, presentation.generation, state, "new"), false
			else
				right_buf, real = side_buffer(state, entry, "new")
			end
			local right_win = create_split(state, right_buf)
			presentation.right = {
				win = right_win,
				buf = right_buf,
				side = "new",
				real = real,
				projection = split_projections and split_projections.new,
			}
			remember_owned(presentation, right_buf)
			local scrollopt = vim.o.scrollopt
			if structural then
				vim.wo[state.origin.win].scrollbind = false
				vim.wo[right_win].scrollbind = false
				vim.wo[state.origin.win].wrap = false
				vim.wo[right_win].wrap = false
			else
				enable_native_diff(state.origin.win, right_win)
			end
			presentation.scrollopt_added = added_options(scrollopt, vim.o.scrollopt)
			prepare_review_window(state.origin.win, layout)
			prepare_review_window(right_win, layout)
			if split_projections then
				configure_unified_gutter(presentation, state.origin.win, left_buf, split_projections.old)
				configure_unified_gutter(presentation, right_win, right_buf, split_projections.new)
			end
			local left_decorated, left_decorate_err =
				decorate(state, entry, left_buf, state.origin.win, "old", context, false)
			if not left_decorated then
				M.clear(state)
				return nil, left_decorate_err
			end
			local right_decorated, right_decorate_err =
				decorate(state, entry, right_buf, right_win, "new", context, false)
			if not right_decorated then
				M.clear(state)
				return nil, right_decorate_err
			end
			set_review_winbar(state, presentation, presentation.left)
			set_review_winbar(state, presentation, presentation.right)
			vim.api.nvim_set_current_win(right_win)
			presentation.target =
				{ entry = entry, side = "new", win = right_win, buf = right_buf, path = entry.new_path }
		else
			prepare_review_window(state.origin.win, layout)
			if split_projections then
				configure_unified_gutter(presentation, state.origin.win, left_buf, split_projections.old)
			end
			local decorated, decorate_err = decorate(state, entry, left_buf, state.origin.win, "old", context, false)
			if not decorated then
				M.clear(state)
				return nil, decorate_err
			end
			set_review_winbar(state, presentation, presentation.left)
			presentation.target =
				{ entry = entry, side = "old", win = state.origin.win, buf = left_buf, path = entry.old_path }
		end
	end
	if split_projections and presentation.right then
		bind_projected_scroll(state, presentation)
	end
	install_band_refresh(state, presentation)
	return true
end

local function restore_highlight_namespace(item)
	if not item.split_highlight_namespace or not valid_win(item.win) then
		return
	end
	item.split_highlight_namespace = false
	local ok, current = pcall(vim.api.nvim_get_hl_ns, { winid = item.win })
	if ok and current == item.namespace then
		pcall(vim.api.nvim_win_set_hl_ns, item.win, item.previous_hl_namespace)
	end
end

local function clear_decoration(item)
	restore_highlight_namespace(item)
	if valid_buf(item.buf) then
		pcall(vim.api.nvim_buf_clear_namespace, item.buf, item.namespace, 0, -1)
	end
	if item.scoped then
		unscope_namespace(item.win, item.namespace)
	end
end

local function adopt_right_window(state, presentation)
	local right = presentation.right
	if valid_win(state.origin.win) or not right or not valid_win(right.win) then
		return false
	end
	local previous_origin = state.origin.win
	local origin_snapshot = state.window_snapshots[previous_origin]
	local right_snapshot = state.window_snapshots[right.win]
	state.window_snapshots[previous_origin] = nil
	state.window_snapshots[right.win] = origin_snapshot or right_snapshot
	state.origin.win = right.win
	state.auxiliary.right = nil
	if origin_snapshot and vim.api.nvim_win_get_buf(right.win) == right.buf then
		put_buffer(right.win, origin_snapshot.buf)
	end
	review_mode.restore_window(state, right.win)
	if vim.api.nvim_tabpage_is_valid(state.origin.tab) then
		vim.api.nvim_set_current_tabpage(state.origin.tab)
	end
	vim.api.nvim_set_current_win(right.win)
	return true
end

---Clear presentation-owned buffers, windows, decoration, view, and options only.
---@param state table
function M.clear(state)
	local presentation = state and state.presentation
	if not presentation then
		return
	end
	if presentation.scroll_sync_autocmd then
		pcall(vim.api.nvim_del_autocmd, presentation.scroll_sync_autocmd)
	end
	if presentation.logical_cursor_autocmd then
		pcall(vim.api.nvim_del_autocmd, presentation.logical_cursor_autocmd)
		presentation.logical_cursor_autocmd = nil
	end
	presentation.logical_cursor = nil
	if presentation.band_refresh_autocmd then
		pcall(vim.api.nvim_del_autocmd, presentation.band_refresh_autocmd)
		presentation.band_refresh_autocmd = nil
	end
	presentation.band_refresh_pending = false
	presentation.band_refresh_force = false
	clear_cursor_guards(presentation)
	release_unified_gutter(presentation)
	state.presentation = nil
	state.clear_presentation = nil
	for _, item in ipairs(presentation.decorations) do
		clear_decoration(item)
	end
	for buf in pairs(presentation.owned_buffers) do
		if valid_buf(buf) and vim.b[buf].nvim_review_role == "unified" then
			review_lsp.clear(buf)
		end
	end
	for buf, owned in pairs(presentation.owned_buffers) do
		if owned then
			review_mode.release_transient(state, buf)
		end
	end
	local right = presentation.right
	local adopted_right = adopt_right_window(state, presentation)
	if not adopted_right and right and valid_win(right.win) and vim.api.nvim_win_get_buf(right.win) == right.buf then
		vim.api.nvim_win_close(right.win, true)
	elseif not adopted_right and right and valid_win(right.win) then
		review_mode.restore_window(state, right.win)
	end
	if right then
		state.window_snapshots[right.win] = nil
	end
	state.auxiliary.right = nil
	local origin = state.window_snapshots[state.origin.win]
	local current = valid_win(state.origin.win) and vim.api.nvim_win_get_buf(state.origin.win) or nil
	if origin and current and presentation.owned_buffers[current] ~= nil then
		put_buffer(state.origin.win, origin.buf)
	end
	review_mode.restore_window(state, state.origin.win)
	restore_scroll_options(presentation.scrollopt_added)
	for buf, owned in pairs(presentation.owned_buffers) do
		if owned and valid_buf(buf) and #vim.fn.win_findbuf(buf) == 0 then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
end

---@param state table
---@return boolean?
---@return string? err
function M.toggle_layout(state)
	if not state.presentation then
		return nil, "nothing is being presented"
	end
	local entry = state.presentation.entry
	local context = state.presentation.context
	local layout = state.presentation.layout == "inline" and "split" or "inline"
	local engine_result = state.presentation.engine_result
	return M.show(state, entry, {
		layout = layout,
		context = context,
		engine_result = engine_result,
	})
end

---@param state table
---@return boolean?
---@return string? err
function M.toggle_context(state)
	if not state.presentation then
		return nil, "nothing is being presented"
	end
	local entry = state.presentation.entry
	local layout = state.presentation.layout
	local context = state.presentation.context == "hunks" and "full" or "hunks"
	local engine_result = state.presentation.engine_result
	return M.show(state, entry, {
		layout = layout,
		context = context,
		engine_result = engine_result,
	})
end

local function active_projection(state, expected_generation, win, anchor_side)
	local presentation = state and state.presentation
	if not presentation then
		return nil, "no review projection is active"
	end
	local target = presentation.inline
	if presentation.split_projections then
		if anchor_side then
			target = anchor_side == "left" and presentation.left or presentation.right
		else
			local selected_win = win or vim.api.nvim_get_current_win()
			target = presentation.left and presentation.left.win == selected_win and presentation.left
				or presentation.right and presentation.right.win == selected_win and presentation.right
				or not win and (presentation.right or presentation.left)
		end
	end
	local projection = target and (target.projection or presentation.projection)
	if not projection then
		return nil, "no review projection is active"
	end
	if expected_generation and expected_generation ~= presentation.generation then
		return nil, "review projection generation changed"
	end
	if
		not valid_win(target.win)
		or not valid_buf(target.buf)
		or vim.api.nvim_win_get_buf(target.win) ~= target.buf
		or vim.b[target.buf].nvim_review_projection_generation ~= presentation.generation
	then
		return nil, "review projection is no longer current"
	end
	return presentation, target, projection
end

local function presenter_source(presentation, inline, source_ref)
	return {
		anchor_side = source_ref.side == "old" and "left" or "right",
		anchorable = source_ref.anchorable,
		buf = inline.buf,
		display_line = source_ref.display_line,
		entry = presentation.entry,
		generation = presentation.generation,
		kind = source_ref.kind,
		layer = presentation.entry.layer or "history",
		line = source_ref.source_line,
		new_line = source_ref.new_line,
		new_path = source_ref.new_path,
		old_line = source_ref.old_line,
		old_path = source_ref.old_path,
		path = source_ref.path,
		side = source_ref.side,
		source_line = source_ref.source_line,
		terminator = source_ref.terminator,
		win = inline.win,
	}
end

---Resolve one unified display row to its canonical OLD/NEW source reference.
---@param state table
---@param display_line integer
---@param expected_generation? integer
---@return table? source_ref
---@return string? err
function M.source_at(state, display_line, expected_generation, win)
	local presentation, inline_or_err, projection = active_projection(state, expected_generation, win)
	if not presentation then
		return nil, inline_or_err
	end
	local source_ref, source_err = review_projection.source_at(projection, display_line)
	if not source_ref then
		return nil, source_err
	end
	return presenter_source(presentation, inline_or_err, source_ref)
end

---Resolve one unified display selection to a single canonical source range.
---@param state table
---@param first integer
---@param last integer
---@param expected_generation? integer
---@param preferred_side? "old"|"new"|"left"|"right"
---@return table? source_range
---@return string? err
function M.resolve_range(state, first, last, expected_generation, preferred_side, win)
	local presentation, inline_or_err, projection = active_projection(state, expected_generation, win)
	if not presentation then
		return nil, inline_or_err
	end
	local source_range, range_err = review_projection.resolve_range(projection, first, last, preferred_side)
	if not source_range then
		return nil, range_err
	end
	source_range.anchor_side = source_range.side == "old" and "left" or "right"
	source_range.buf = inline_or_err.buf
	source_range.entry = presentation.entry
	source_range.generation = presentation.generation
	source_range.layer = presentation.entry.layer or "history"
	source_range.win = inline_or_err.win
	return source_range
end

local function merged_sections(sections_value)
	table.sort(sections_value, function(left, right)
		return left.first < right.first
	end)
	local merged = {}
	for _, section in ipairs(sections_value) do
		local previous = merged[#merged]
		if previous and section.first <= previous.last + 1 then
			previous.last = math.max(previous.last, section.last)
		else
			merged[#merged + 1] = { first = section.first, last = section.last }
		end
	end
	return merged
end

local function reveal_target_rows(state, presentation, target, rows)
	if state.presentation ~= presentation or not valid_win(target.win) or not valid_buf(target.buf) then
		return nil, "review presentation is no longer current"
	elseif vim.api.nvim_win_get_buf(target.win) ~= target.buf then
		return nil, "review source window changed"
	elseif type(rows) ~= "table" or #rows == 0 then
		return nil, "at least one source row is required"
	end
	local wanted = {}
	local line_count = vim.api.nvim_buf_line_count(target.buf)
	for _, row in ipairs(rows) do
		if not integer(row) or row < 1 or row > line_count then
			return nil, "source row is outside the review buffer"
		end
		wanted[row] = true
	end

	local changed = false
	for _, item in ipairs(presentation.decorations or {}) do
		if item.buf == target.buf and item.win == target.win and item.omitted then
			local retained = {}
			for _, hidden in ipairs(item.omitted) do
				local visible = {}
				for row = hidden.first, hidden.last do
					if wanted[row] then
						visible[#visible + 1] = row
					end
				end
				if #visible == 0 then
					retained[#retained + 1] = hidden
				else
					changed = true
					pcall(vim.api.nvim_buf_del_extmark, item.buf, item.namespace, hidden.id)
					local first = hidden.first
					for _, row in ipairs(visible) do
						if first < row then
							retained[#retained + 1] = conceal_range(item.buf, item.namespace, first, row - 1)
						end
						first = row + 1
					end
					if first <= hidden.last then
						retained[#retained + 1] = conceal_range(item.buf, item.namespace, first, hidden.last)
					end
				end
			end
			item.omitted = retained
		end
	end
	if changed then
		local guard = presentation.cursor_guards[target.win]
		if guard then
			local visible = vim.deepcopy(guard.sections)
			for row in pairs(wanted) do
				visible[#visible + 1] = { first = row, last = row }
			end
			guard.sections = merged_sections(visible)
		end
	end
	return true
end

---Reveal mapped display rows which are currently concealed by hunk-only context.
---@param state table
---@param rows integer[]
---@param expected_generation? integer
---@return boolean?
---@return string? err
function M.reveal_rows(state, rows, expected_generation, win)
	local presentation, inline_or_err, projection = active_projection(state, expected_generation, win)
	if not presentation then
		return nil, inline_or_err
	elseif type(rows) ~= "table" or #rows == 0 then
		return nil, "at least one display row is required"
	end
	for _, row in ipairs(rows) do
		if not integer(row) or row < 1 or row > #projection.rows then
			return nil, "display row is outside the unified projection"
		end
	end
	if presentation.split_projections then
		-- Both panes conceal the same display rows. Revealing a comment must
		-- preserve that geometry, including unanchorable rows on the other side.
		for _, pane in ipairs({ presentation.left, presentation.right }) do
			local revealed, err = reveal_target_rows(state, presentation, pane, rows)
			if not revealed then
				return nil, err
			end
		end
		return true
	end
	return reveal_target_rows(state, presentation, inline_or_err, rows)
end

local function first_source_line(projection, side)
	local first
	for line in pairs(projection.by_source[side] or {}) do
		first = first and math.min(first, line) or line
	end
	return first
end

---Reverse-map one canonical persisted anchor into the active unified projection.
---@param state table
---@param anchor table
---@param expected_generation? integer
---@return table? location
---@return string? err
function M.locate_anchor(state, anchor, expected_generation)
	local presentation, inline_or_err, projection =
		active_projection(state, expected_generation, nil, anchor and anchor.side)
	if not presentation then
		return nil, inline_or_err
	elseif type(anchor) ~= "table" or type(anchor.path) ~= "string" then
		return nil, "canonical file or range anchor is required"
	elseif anchor.layer and anchor.layer ~= (presentation.entry.layer or "history") then
		return nil, "anchor layer is not represented by this unified projection"
	end
	local side = anchor.side == "left" and "old" or anchor.side == "right" and "new" or nil
	if not side then
		return nil, "anchor side must be left or right"
	end
	local selected = projection.sources[side]
	local line = anchor.start_line or first_source_line(projection, side)
	local display_line
	local locate_err
	if line then
		display_line, locate_err = review_projection.locate(projection, side, line, anchor.path)
	else
		for index, row in ipairs(projection.rows) do
			if row.path == anchor.path and row.anchor_side == side then
				display_line = index
				break
			end
		end
		if not display_line and selected.path == anchor.path and projection.rows[1] then
			display_line = 1
		end
	end
	if not display_line then
		return nil, locate_err or "anchor is not represented by this unified projection"
	end
	local source_ref = assert(review_projection.source_at(projection, display_line))
	local location = presenter_source(presentation, inline_or_err, source_ref)
	local record = line and selected.lines[line] or nil
	location.anchor_side = side == "old" and "left" or "right"
	location.display_line = display_line
	location.line = line or 0
	location.path = selected.path
	location.side = side
	location.source_line = line or 0
	location.terminator = record and record.terminator or ""
	return location
end

---Locate and reveal a frozen NEW source line in either review layout.
---@param state table
---@param path string
---@param line integer
---@param expected_generation? integer
---@return table? location
---@return string? err
function M.reveal_new_location(state, path, line, expected_generation)
	local presentation = state and state.presentation
	if not presentation then
		return nil, "review presentation is unavailable"
	elseif expected_generation and presentation.generation ~= expected_generation then
		return nil, "review presentation generation changed"
	elseif presentation.entry.deleted or presentation.entry.metadata_only or presentation.entry.new_path ~= path then
		return nil, "NEW source is not represented by this review presentation"
	elseif not integer(line) or line < 1 or line > presentation.source_line_counts.new then
		return nil, "NEW source line is outside the review presentation"
	end

	if presentation.projection and presentation.inline or presentation.split_projections then
		local location, locate_err = M.locate_anchor(state, {
			kind = "range",
			path = path,
			side = "right",
			layer = presentation.entry.layer or "history",
			start_line = line,
			end_line = line,
		}, presentation.generation)
		if not location then
			return nil, locate_err
		end
		local revealed, reveal_err =
			M.reveal_rows(state, { location.display_line }, presentation.generation, location.win)
		if not revealed then
			return nil, reveal_err
		end
		return {
			buf = location.buf,
			line = location.display_line,
			source_line = line,
			win = location.win,
		}
	end

	local target = presentation.right
		or (presentation.inline and presentation.inline.side == "new" and presentation.inline or nil)
	if not target then
		return nil, "NEW review pane is unavailable"
	end
	local revealed, reveal_err = reveal_target_rows(state, presentation, target, { line })
	if not revealed then
		return nil, reveal_err
	end
	return { buf = target.buf, line = line, source_line = line, win = target.win }
end

---Return every active display row represented by a canonical persisted anchor.
---@param state table
---@param anchor table
---@param expected_generation? integer
---@return integer[]? rows
---@return string? err
function M.rows_for_anchor(state, anchor, expected_generation)
	local presentation, projection_err, projection =
		active_projection(state, expected_generation, nil, anchor and anchor.side)
	if not presentation then
		return nil, projection_err
	elseif type(anchor) ~= "table" or type(anchor.path) ~= "string" then
		return nil, "canonical file or range anchor is required"
	elseif anchor.layer and anchor.layer ~= (presentation.entry.layer or "history") then
		return nil, "anchor layer is not represented by this unified projection"
	elseif anchor.side ~= "left" and anchor.side ~= "right" then
		return nil, "anchor side must be left or right"
	end
	if anchor.kind ~= "range" or not anchor.start_line then
		local location, locate_err = M.locate_anchor(state, anchor, presentation.generation)
		return location and { location.display_line } or nil, locate_err
	end
	return review_projection.rows_for_range(
		projection,
		anchor.side,
		anchor.start_line,
		anchor.end_line or anchor.start_line,
		anchor.path
	)
end

local function logical_source_path(entry, side)
	if side == "old" then
		return entry.old_path
	elseif side == "new" then
		return entry.new_path
	end
	return nil
end

local function validate_logical_location(presentation, location)
	if type(location) ~= "table" then
		return nil, "logical review location is required"
	elseif type(location.entry_identity) ~= "string" or location.entry_identity == "" then
		return nil, "logical review entry identity is required"
	elseif location.entry_identity ~= presentation.entry.identity then
		return nil, "logical review entry is not currently presented"
	elseif type(location.layer) ~= "string" or location.layer == "" then
		return nil, "logical review layer is required"
	elseif location.layer ~= (presentation.entry.layer or "history") then
		return nil, "logical review layer is not currently presented"
	elseif location.side ~= "old" and location.side ~= "new" then
		return nil, "logical review side must be old or new"
	elseif type(location.path) ~= "string" or location.path == "" then
		return nil, "logical review path is required"
	elseif location.path ~= logical_source_path(presentation.entry, location.side) then
		return nil, "logical review path is not represented by this entry"
	elseif not integer(location.line) or location.line < 0 then
		return nil, "logical review line must be a non-negative integer"
	elseif not integer(location.col) or location.col < 1 then
		return nil, "logical review column must be a positive integer"
	elseif location.line == 0 and location.col ~= 1 then
		return nil, "logical file locations must use column one"
	end
	local line_count = presentation.source_line_counts[location.side]
	if location.line == 0 then
		if line_count ~= 0 then
			return nil, "logical file location is only valid for empty or metadata content"
		end
	elseif location.line > line_count then
		return nil, "logical review line is outside the represented source"
	end
	return true
end

local function matching_side(presentation, side)
	local expected = side == "old" and "old" or "new"
	for _, name in ipairs({ "inline", "left", "right" }) do
		local target = presentation[name]
		if target and target.side == expected then
			return target
		end
	end
	return nil
end

---Capture the current visual review cursor as one stable OLD/NEW source location.
---@param state table
---@return table? location
---@return string? err
function M.capture_location(state)
	local presentation = state and state.presentation
	if not presentation or type(presentation.entry) ~= "table" then
		return nil, "review presentation is unavailable"
	end
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local location
	if
		(
			presentation.projection
			and presentation.inline
			and presentation.inline.win == win
			and valid_buf(presentation.inline.buf)
			and vim.api.nvim_win_get_buf(win) == presentation.inline.buf
		) or presentation.split_projections ~= nil
	then
		local restored_cursor = presentation.logical_cursor
		local side
		local path
		local source_line
		if restored_cursor and restored_cursor.win == win and restored_cursor.display_line == cursor[1] then
			side = restored_cursor.side
			path = restored_cursor.path
			source_line = restored_cursor.source_line
		else
			presentation.logical_cursor = nil
			presentation.preferred_side = nil
			local source, source_err = M.source_at(state, cursor[1], presentation.generation, win)
			if not source then
				return nil, source_err
			end
			side = source.side
			path = source.path
			source_line = source.source_line
			if source.kind == "context" and presentation.preferred_side == "old" and source.old_path then
				side = "old"
				path = source.old_path
				source_line = source.old_line
			elseif source.kind == "context" and presentation.preferred_side == "new" and source.new_path then
				side = "new"
				path = source.new_path
				source_line = source.new_line
			elseif source.kind == "empty" and presentation.preferred_side == "old" and presentation.entry.old_path then
				side = "old"
				path = presentation.entry.old_path
				source_line = 0
			elseif source.kind == "empty" and presentation.preferred_side == "new" and presentation.entry.new_path then
				side = "new"
				path = presentation.entry.new_path
				source_line = 0
			end
		end
		location = {
			entry_identity = presentation.entry.identity,
			layer = presentation.entry.layer or "history",
			side = side,
			path = path,
			line = source_line,
			col = source_line == 0 and 1 or cursor[2] + 1,
		}
	else
		local target
		for _, name in ipairs({ "inline", "left", "right" }) do
			local candidate = presentation[name]
			if
				candidate
				and candidate.win == win
				and valid_buf(candidate.buf)
				and vim.api.nvim_win_get_buf(win) == candidate.buf
			then
				target = candidate
				break
			end
		end
		if not target or (target.side ~= "old" and target.side ~= "new") then
			return nil, "current window is not an OLD/NEW review source"
		end
		local line_count = presentation.source_line_counts[target.side]
		location = {
			entry_identity = presentation.entry.identity,
			layer = presentation.entry.layer or "history",
			side = target.side,
			path = logical_source_path(presentation.entry, target.side),
			line = line_count == 0 and 0 or cursor[1],
			col = line_count == 0 and 1 or cursor[2] + 1,
		}
	end
	local valid, validation_err = validate_logical_location(presentation, location)
	return valid and location or nil, validation_err
end

---Restore one stable OLD/NEW source location into the current presentation.
---@param state table
---@param location table
---@param expected_generation? integer
---@return boolean?
---@return string? err
function M.restore_location(state, location, expected_generation)
	local presentation = state and state.presentation
	if not presentation then
		return nil, "review presentation is unavailable"
	elseif expected_generation and presentation.generation ~= expected_generation then
		return nil, "review presentation generation changed"
	end
	local valid, validation_err = validate_logical_location(presentation, location)
	if not valid then
		return nil, validation_err
	end
	local generation = presentation.generation

	local target
	local target_line
	if presentation.projection and presentation.inline or presentation.split_projections then
		local anchor = {
			kind = location.line == 0 and "file" or "range",
			layer = location.layer,
			path = location.path,
			side = location.side == "old" and "left" or "right",
		}
		if location.line > 0 then
			anchor.start_line = location.line
			anchor.end_line = location.line
		end
		local resolved, resolve_err = M.locate_anchor(state, anchor, generation)
		if not resolved then
			return nil, resolve_err
		end
		local revealed, reveal_err = M.reveal_rows(state, { resolved.display_line }, generation, resolved.win)
		if not revealed then
			return nil, reveal_err
		end
		target = presentation.inline or matching_side(presentation, location.side)
		target_line = resolved.display_line
	else
		target = matching_side(presentation, location.side)
		if not target then
			return nil, "logical review side has no active pane"
		end
		target_line = location.line == 0 and 1 or location.line
		local revealed, reveal_err = reveal_target_rows(state, presentation, target, { target_line })
		if not revealed then
			return nil, reveal_err
		end
	end

	if
		state.presentation ~= presentation
		or presentation.generation ~= generation
		or not valid_win(target.win)
		or not valid_buf(target.buf)
		or vim.api.nvim_win_get_buf(target.win) ~= target.buf
	then
		return nil, "review presentation changed while restoring its logical location"
	end
	local line = vim.api.nvim_buf_get_lines(target.buf, target_line - 1, target_line, false)[1] or ""
	local column = math.max(0, math.min(location.col - 1, #line))
	vim.api.nvim_set_current_win(target.win)
	vim.api.nvim_win_set_cursor(target.win, { target_line, column })
	presentation.preferred_side = location.side
	if presentation.logical_cursor_autocmd then
		pcall(vim.api.nvim_del_autocmd, presentation.logical_cursor_autocmd)
	end
	presentation.logical_cursor = {
		win = target.win,
		display_line = target_line,
		side = location.side,
		path = location.path,
		source_line = location.line,
	}
	local logical_cursor_autocmd
	logical_cursor_autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = target.buf,
		callback = function()
			local logical_cursor = presentation.logical_cursor
			if
				state.presentation ~= presentation
				or not logical_cursor
				or not valid_win(logical_cursor.win)
				or vim.api.nvim_get_current_win() == logical_cursor.win
					and vim.api.nvim_win_get_cursor(logical_cursor.win)[1] ~= logical_cursor.display_line
			then
				if state.presentation == presentation then
					presentation.logical_cursor = nil
					presentation.logical_cursor_autocmd = nil
					presentation.preferred_side = nil
				end
				pcall(vim.api.nvim_del_autocmd, logical_cursor_autocmd)
			end
		end,
	})
	presentation.logical_cursor_autocmd = logical_cursor_autocmd
	return true
end

---@param state table
---@return table?
function M.current_target(state)
	local presentation = state and state.presentation
	if presentation and presentation.split_projections then
		local _, target = active_projection(state)
		if target and valid_win(target.win) then
			return M.source_at(state, vim.api.nvim_win_get_cursor(target.win)[1], presentation.generation, target.win)
		end
	end
	if presentation and presentation.projection and presentation.inline and valid_win(presentation.inline.win) then
		local display_line = vim.api.nvim_win_get_cursor(presentation.inline.win)[1]
		return M.source_at(state, display_line, presentation.generation)
	end
	return presentation and presentation.target or nil
end

local function navigate_hunk(state, direction)
	local presentation = state and state.presentation
	local _, pane, projection = active_projection(state)
	local hunks = projection and projection.hunks or presentation and presentation.entry.hunks

	if not presentation or #(hunks or {}) == 0 then
		return false
	end
	local win = projection and pane.win or vim.api.nvim_get_current_win()
	if not valid_win(win) then
		return false
	end
	local side = presentation.target.side
	if not projection and presentation.left and win == presentation.left.win then
		side = "old"
	elseif not projection and presentation.right and win == presentation.right.win then
		side = "new"
	end
	local current = vim.api.nvim_win_get_cursor(win)[1]
	local starts = {}
	for _, hunk in ipairs(hunks) do
		starts[#starts + 1] = projection and hunk.first or math.max(1, side == "old" and hunk[1] or hunk[3])
	end
	local target
	if direction > 0 then
		for _, value in ipairs(starts) do
			if value > current then
				target = value
				break
			end
		end
		target = target or starts[1]
	else
		for index = #starts, 1, -1 do
			if starts[index] < current then
				target = starts[index]
				break
			end
		end
		target = target or starts[#starts]
	end
	vim.api.nvim_win_set_cursor(
		win,
		{ math.min(target, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))), 0 }
	)
	return true
end

function M.next_hunk(state)
	return navigate_hunk(state, 1)
end

function M.prev_hunk(state)
	return navigate_hunk(state, -1)
end

return M
