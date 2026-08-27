-- Native ordinary-window presenter for exact review_changes entries.
local M = {}

local review_lsp = require("config.review_lsp")
local review_mode = require("config.review_mode")
local repo = require("config.repo")

local BAND_HIGHLIGHT = "NvimReviewHunkBand"
local INLINE_HUNK_CONTEXT = 0
local presentation_generation = 0

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
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

local function scratch(entry, side, state)
	local buf = vim.api.nvim_create_buf(false, true)
	local is_old = side == "old"
	local role = is_old and "old" or "snapshot"
	local path = is_old and entry.old_path or entry.new_path
	local metadata = {
		root = state.workspace.root,
		path = path,
		current_path = entry.new_path,
		side = side,
		entry = entry,
		bridge = not entry.metadata_only,
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
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
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

local function sections(entry, side, line_count, context)
	context = math.max(0, context or INLINE_HUNK_CONTEXT)
	local values = {}
	for _, hunk in ipairs(entry.hunks or {}) do
		local start = side == "old" and hunk[1] or hunk[3]
		local count = side == "old" and hunk[2] or hunk[4]
		local first = math.min(line_count, math.max(1, start))
		local last = count == 0 and first or math.min(line_count, math.max(first, start + count - 1))
		values[#values + 1] = {
			first = math.max(1, first - context),
			last = math.min(line_count, math.max(first, last) + context),
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
		else
			merged[#merged + 1] = value
		end
	end
	return merged
end

local function hide_context(buf, win, namespace, visible)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local omitted = {}
	local first = 1
	for _, section in ipairs(visible) do
		if first < section.first then
			omitted[#omitted + 1] = { first = first, last = section.first - 1 }
			vim.api.nvim_buf_set_extmark(buf, namespace, first - 1, 0, {
				conceal_lines = "",
				end_row = section.first - 2,
				end_col = 0,
			})
		end
		first = section.last + 1
	end
	if first <= line_count then
		omitted[#omitted + 1] = { first = first, last = line_count }
		vim.api.nvim_buf_set_extmark(buf, namespace, first - 1, 0, {
			conceal_lines = "",
			end_row = line_count - 1,
			end_col = 0,
		})
	end
	if type(vim.api.nvim_win_add_ns) == "function" then
		vim.api.nvim_win_add_ns(win, namespace)
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

local function clear_cursor_guard(presentation)
	local guard = presentation and presentation.cursor_guard
	if not guard then
		return
	end
	presentation.cursor_guard = nil
	guard.active = false
	for _, id in ipairs(guard.autocmds or {}) do
		pcall(vim.api.nvim_del_autocmd, id)
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
	presentation.cursor_guard = guard
	guard.autocmds[#guard.autocmds + 1] = vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		desc = "Keep the native review cursor inside visible hunks",
		callback = function(event)
			if
				event.buf ~= guard.buf
				or vim.api.nvim_get_current_win() ~= guard.win
				or state.presentation ~= presentation
				or presentation.cursor_guard ~= guard
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
			clear_cursor_guard(presentation)
		end,
	})
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
	local path = side == "old" and entry.old_path or entry.new_path
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
	if type(comments) == "boolean" then
		values[#values + 1] = "comments:" .. (comments and "on" or "off")
	end
	values[#values + 1] = side == "old" and "OLD" or "CURRENT"
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
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, { line_hl_group = group })
		end
	end
end

local function render_deleted_inline(buf, namespace, entry)
	for _, hunk in ipairs(entry.hunks or {}) do
		local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
		if old_count > 0 then
			local old_lines = text_lines(entry.old_text)
			local virtual = {}
			for index = old_start, old_start + old_count - 1 do
				virtual[#virtual + 1] = { { old_lines[index] or "", "DiffDelete" } }
			end
			local line_count = vim.api.nvim_buf_line_count(buf)
			local row = math.max(0, math.min(new_start, line_count) - 1)
			local above = new_count > 0 or new_start == 0
			vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
				virt_lines = virtual,
				virt_lines_above = above,
			})
		end
	end
end

local function decorate(state, entry, buf, win, side, context, inline)
	if entry.metadata_only then
		return
	end
	local namespace = vim.api.nvim_create_namespace(("nvim_review_native_%d_%d"):format(win, buf))
	state.presentation.decorations[#state.presentation.decorations + 1] = {
		buf = buf,
		win = win,
		namespace = namespace,
	}
	for _, hunk in ipairs(entry.hunks or {}) do
		if side == "old" then
			highlight_lines(buf, namespace, hunk[1], hunk[2], "DiffDelete")
		else
			highlight_lines(buf, namespace, hunk[3], hunk[4], "DiffAdd")
		end
	end
	if inline and side == "new" then
		render_deleted_inline(buf, namespace, entry)
	end
	if context == "hunks" and inline then
		local visible = sections(entry, side, vim.api.nvim_buf_line_count(buf), INLINE_HUNK_CONTEXT)
		if #visible == 0 then
			return
		end
		vim.wo[win].conceallevel = math.max(2, vim.wo[win].conceallevel)
		vim.wo[win].concealcursor = "nvic"
		local omitted = hide_context(buf, win, namespace, visible)
		for index, section in ipairs(visible) do
			vim.api.nvim_buf_set_extmark(buf, namespace, section.first - 1, 0, {
				virt_lines = { { { (" HUNK %d/%d "):format(index, #visible), BAND_HIGHLIGHT } } },
				virt_lines_above = true,
			})
			vim.api.nvim_buf_set_extmark(buf, namespace, section.last - 1, 0, {
				virt_lines = { { { (" END HUNK %d/%d "):format(index, #visible), BAND_HIGHLIGHT } } },
			})
		end
		install_cursor_guard(state, state.presentation, buf, win, visible, omitted)
	end
end

local function enable_native_diff(left_win, right_win, context)
	for _, win in ipairs({ left_win, right_win }) do
		vim.api.nvim_win_call(win, function()
			vim.cmd("diffthis")
		end)
		vim.wo[win].foldenable = context == "hunks"
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

---Render one entry in the state's origin tab without creating a tab.
---@param state table
---@param entry table
---@param options? { layout?: "inline"|"split", context?: "hunks"|"full" }
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
	if not state.enabled then
		return nil, "review mode is not enabled"
	end
	M.clear(state)
	if not valid_win(state.origin.win) or not vim.api.nvim_tabpage_is_valid(state.origin.tab) then
		return nil, "origin tab or window is no longer valid"
	end
	vim.api.nvim_set_current_tabpage(state.origin.tab)
	vim.api.nvim_set_current_win(state.origin.win)
	review_mode.capture_window(state, state.origin.win)
	vim.api.nvim_set_hl(0, BAND_HIGHLIGHT, { default = true, link = "Comment" })
	presentation_generation = presentation_generation + 1
	local presentation = {
		entry = entry,
		generation = presentation_generation,
		layout = layout,
		context = context,
		decorations = {},
		owned_buffers = {},
	}
	state.presentation = presentation
	state.clear_presentation = M.clear
	state.handlers.next_hunk = M.next_hunk
	state.handlers.prev_hunk = M.prev_hunk

	if layout == "inline" then
		local side = entry.deleted and "old" or "new"
		local buf, real = side_buffer(state, entry, side)
		presentation.inline = { win = state.origin.win, buf = buf, side = side, real = real }
		remember_owned(presentation, buf)
		put_buffer(state.origin.win, buf)
		vim.wo[state.origin.win].foldenable = false
		decorate(state, entry, buf, state.origin.win, side, context, true)
		set_review_winbar(state, presentation, presentation.inline)
		presentation.target = { entry = entry, side = side, win = state.origin.win, buf = buf, path = entry.path }
	else
		local left_buf = side_buffer(state, entry, "old")
		presentation.left = { win = state.origin.win, buf = left_buf, side = "old" }
		remember_owned(presentation, left_buf)
		put_buffer(state.origin.win, left_buf)
		decorate(state, entry, left_buf, state.origin.win, "old", context, false)
		if not entry.deleted then
			local right_buf, real = side_buffer(state, entry, "new")
			local right_win = create_split(state, right_buf)
			presentation.right = { win = right_win, buf = right_buf, side = "new", real = real }
			remember_owned(presentation, right_buf)
			decorate(state, entry, right_buf, right_win, "new", context, false)
			set_review_winbar(state, presentation, presentation.left)
			set_review_winbar(state, presentation, presentation.right)
			local scrollopt = vim.o.scrollopt
			enable_native_diff(state.origin.win, right_win, context)
			presentation.scrollopt_added = added_options(scrollopt, vim.o.scrollopt)
			vim.api.nvim_set_current_win(right_win)
			presentation.target =
				{ entry = entry, side = "new", win = right_win, buf = right_buf, path = entry.new_path }
		else
			set_review_winbar(state, presentation, presentation.left)
			presentation.target =
				{ entry = entry, side = "old", win = state.origin.win, buf = left_buf, path = entry.old_path }
		end
	end
	return true
end

local function clear_decoration(item)
	if valid_buf(item.buf) then
		pcall(vim.api.nvim_buf_clear_namespace, item.buf, item.namespace, 0, -1)
	end
	if valid_win(item.win) and type(vim.api.nvim_win_remove_ns) == "function" then
		pcall(vim.api.nvim_win_remove_ns, item.win, item.namespace)
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
	clear_cursor_guard(presentation)
	state.presentation = nil
	state.clear_presentation = nil
	for _, item in ipairs(presentation.decorations) do
		clear_decoration(item)
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
	return M.show(state, entry, { layout = layout, context = context })
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
	return M.show(state, entry, { layout = layout, context = context })
end

---@param state table
---@return table?
function M.current_target(state)
	return state and state.presentation and state.presentation.target or nil
end

local function navigate_hunk(state, direction)
	local presentation = state and state.presentation
	if not presentation or #(presentation.entry.hunks or {}) == 0 then
		return false
	end
	local win = vim.api.nvim_get_current_win()
	local side = presentation.target.side
	if presentation.left and win == presentation.left.win then
		side = "old"
	elseif presentation.right and win == presentation.right.win then
		side = "new"
	end
	local current = vim.api.nvim_win_get_cursor(win)[1]
	local starts = {}
	for _, hunk in ipairs(presentation.entry.hunks) do
		starts[#starts + 1] = math.max(1, side == "old" and hunk[1] or hunk[3])
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
