-- Transient hunk/full-file presentation for review-owned Diffview windows.
local M = {}

local HIGHLIGHT = "NvimReviewHunkBand"
local HEADER_PRIORITY = 50
local FOOTER_PRIORITY = 200
local DIFFVIEW_INSERT_REPAINT_DELAY_MS = 150
local DIFFVIEW_RESIZE_REPAINT_DELAY_MS = 100
local REBUILD_SETTLE_MARGIN_MS = 25

local decorations = {}
local namespaces = {}
local warned = {}
local setup_done = false
local rebuild_pending = false
local rebuild_all = false
local rebuild_buffers = {}
local delayed_rebuild_token = 0
local delayed_rebuild_tokens = {}

local function notify_once(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	vim.notify(message, vim.log.levels.WARN, { title = "Review" })
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function scope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		return pcall(vim.api.nvim_win_add_ns, win, namespace)
	end
	if type(vim.api.nvim__ns_set) == "function" then
		return pcall(vim.api.nvim__ns_set, namespace, { wins = { win } })
	end
	return false
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

local function decorated_windows()
	local wins = {}
	for win in pairs(decorations) do
		wins[#wins + 1] = win
	end
	return wins
end

local function context_mode(workspace)
	return workspace and workspace.context_mode == "full" and "full" or "hunks"
end

local function text_width(win)
	local info = vim.fn.getwininfo(win)[1]
	local textoff = info and info.textoff or 0
	return math.max(1, vim.api.nvim_win_get_width(win) - textoff)
end

local function pad_band(text, width)
	local padding = width - vim.fn.strdisplaywidth(text)
	return padding > 0 and text .. string.rep(" ", padding) or text
end

local function valid_hunk(hunk)
	if type(hunk) ~= "table" or #hunk < 4 then
		return false
	end
	for index = 1, 4 do
		local value = hunk[index]
		if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
			return false
		end
	end
	return true
end

local function diff_context()
	for option in vim.o.diffopt:gmatch("[^,]+") do
		local value = option:match("^context:(%d+)$")
		if value then
			return tonumber(value)
		end
	end
	return 6
end

---Expand cached hunks into merged, inclusive new-side line sections.
---@param hunks table
---@param line_count integer
---@param context integer
---@return table[] sections
---@return boolean malformed
local function visible_sections(hunks, line_count, context)
	if type(hunks) ~= "table" or line_count < 1 then
		return {}, type(hunks) ~= "table"
	end
	context = math.max(0, context)
	local expanded = {}
	for _, hunk in ipairs(hunks) do
		if not valid_hunk(hunk) then
			return {}, true
		end
		local new_start, new_count = hunk[3], hunk[4]
		local first
		local last
		if new_count == 0 then
			first = new_start == 0 and 1 or math.min(math.max(new_start, 1), line_count)
			last = first
		else
			first = math.min(math.max(new_start, 1), line_count)
			last = math.min(math.max(new_start + new_count - 1, first), line_count)
		end
		expanded[#expanded + 1] = {
			first = math.max(1, first - context),
			last = math.min(line_count, last + context),
		}
	end
	table.sort(expanded, function(left, right)
		return left.first < right.first or (left.first == right.first and left.last < right.last)
	end)
	local merged = {}
	for _, section in ipairs(expanded) do
		local previous = merged[#merged]
		if previous and section.first <= previous.last + 1 then
			previous.last = math.max(previous.last, section.last)
		else
			merged[#merged + 1] = section
		end
	end
	return merged, false
end

local function complement(sections, line_count)
	local omitted = {}
	local first = 1
	for _, section in ipairs(sections) do
		if first < section.first then
			omitted[#omitted + 1] = { first = first, last = section.first - 1 }
		end
		first = section.last + 1
	end
	if first <= line_count then
		omitted[#omitted + 1] = { first = first, last = line_count }
	end
	return omitted
end

---Build deterministic review marks for cached inline hunks.
---@param hunks table
---@param line_count integer
---@param width integer
---@param context? integer
---@return table plan
---@return boolean malformed
local function build_plan(hunks, line_count, width, context)
	local sections, malformed = visible_sections(hunks, line_count, context or diff_context())
	if malformed or #sections == 0 then
		return { sections = {}, omitted = {}, bands = {} }, malformed
	end
	local omitted = complement(sections, line_count)
	local bands = {}
	if #omitted > 0 then
		for index, section in ipairs(sections) do
			bands[#bands + 1] = {
				row = section.first - 1,
				above = true,
				priority = HEADER_PRIORITY,
				right_gravity = false,
				text = pad_band(("HUNK %d/%d · L%d-%d"):format(index, #sections, section.first, section.last), width),
			}
			bands[#bands + 1] = {
				row = section.last - 1,
				above = false,
				priority = FOOTER_PRIORITY,
				right_gravity = true,
				text = pad_band(("END HUNK %d/%d"):format(index, #sections), width),
			}
		end
	end
	return { sections = sections, omitted = omitted, bands = bands }, false
end

local function edge_counts(hunks, bands, line_count)
	local plugin_bof = 0
	local plugin_eof = 0
	for _, hunk in ipairs(type(hunks) == "table" and hunks or {}) do
		if valid_hunk(hunk) then
			local old_count, new_start, new_count = hunk[2], hunk[3], hunk[4]
			if (new_count == 0 and new_start == 0) or (new_count > 0 and new_start == 1) then
				plugin_bof = plugin_bof + old_count
			end
			if new_count == 0 and new_start == line_count then
				plugin_eof = plugin_eof + old_count
			end
		end
	end

	local band_bof = 0
	local band_eof = 0
	for _, band in ipairs(bands) do
		if band.row == 0 and band.above then
			band_bof = band_bof + 1
		end
		if band.row == line_count - 1 and not band.above then
			band_eof = band_eof + 1
		end
	end
	return {
		bof_topfill = plugin_bof + band_bof,
		eof_below = plugin_eof + band_eof,
		plugin_bof_topfill = plugin_bof,
		plugin_eof_below = plugin_eof,
	}
end

-- Keep the pinned Diffview private seam isolated in this module.
local function cached_hunks(buf)
	local ok, inline_diff = pcall(require, "diffview.scene.inline_diff")
	if not ok or type(inline_diff.get_hunks) ~= "function" then
		return nil, "Diffview's pinned inline hunk seam is unavailable"
	end
	local read, hunks = pcall(inline_diff.get_hunks, buf)
	if not read then
		return nil, "Diffview's pinned inline hunk seam failed"
	end
	return hunks
end

local function clear_window(win, drop_namespace)
	local record = decorations[win]
	local namespace = namespaces[win]
	if record and namespace and valid_buf(record.buf) then
		pcall(vim.api.nvim_buf_clear_namespace, record.buf, namespace, 0, -1)
	end
	if record and valid_win(win) then
		vim.wo[win].conceallevel = record.conceallevel
		vim.wo[win].concealcursor = record.concealcursor
	end
	if namespace then
		unscope_namespace(win, namespace)
	end
	decorations[win] = nil
	if drop_namespace then
		namespaces[win] = nil
	end
end

local function with_saved_view(win, callback)
	if not valid_win(win) then
		return
	end
	vim.api.nvim_win_call(win, function()
		local view = vim.fn.winsaveview()
		local ok, err = xpcall(callback, debug.traceback)
		if valid_win(win) then
			vim.fn.winrestview(view)
		end
		if not ok then
			error(err)
		end
	end)
end

local function maintain_edge_visibility(win, record, plugin_only)
	if not record or not valid_win(win) or not valid_buf(record.buf) or vim.api.nvim_win_get_buf(win) ~= record.buf then
		return
	end
	local below = plugin_only and record.plugin_eof_below or record.eof_below
	local desired_topfill = plugin_only and record.plugin_bof_topfill or record.bof_topfill
	vim.api.nvim_win_call(win, function()
		local last_line = vim.api.nvim_buf_line_count(record.buf)
		local view = vim.fn.winsaveview()
		local changed = false
		if vim.api.nvim_win_get_cursor(win)[1] == last_line and below > 0 then
			local height = vim.api.nvim_win_get_height(win)
			local effective_below = math.min(below, math.max(height - 1, 0))
			local min_topline = math.min(last_line, math.max(1, last_line - (height - 1 - effective_below)))
			if view.topline < min_topline then
				view.topline = min_topline
				changed = true
			end
		end
		local topfill = view.topline == 1 and desired_topfill or 0
		if view.topfill ~= topfill then
			view.topfill = topfill
			changed = true
		end
		if changed then
			vim.fn.winrestview(view)
		end
	end)
end

local function render_bands(workspace, buf, win, dependencies)
	local previous = decorations[win]
	local conceallevel = previous and previous.conceallevel or vim.wo[win].conceallevel
	local concealcursor = previous and previous.concealcursor or vim.wo[win].concealcursor
	clear_window(win, true)
	local get_hunks = dependencies and dependencies.get_hunks or cached_hunks
	local hunks, seam_err = get_hunks(buf)
	if seam_err then
		notify_once("seam", seam_err)
		return vim.tbl_extend("force", { buf = buf }, edge_counts({}, {}, vim.api.nvim_buf_line_count(buf)))
	end
	if hunks == nil then
		return vim.tbl_extend("force", { buf = buf }, edge_counts({}, {}, vim.api.nvim_buf_line_count(buf)))
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	local plan, malformed = build_plan(hunks, line_count, text_width(win))
	local edges = edge_counts(hunks, plan.bands, line_count)
	if malformed then
		notify_once("malformed", "Diffview returned malformed cached inline hunks")
		return vim.tbl_extend("force", { buf = buf }, edge_counts({}, {}, line_count))
	end
	if #plan.omitted == 0 then
		return vim.tbl_extend("force", { buf = buf }, edges)
	end
	local namespace = namespaces[win]
	if not namespace then
		namespace = vim.api.nvim_create_namespace("nvim_review_hunk_bands_" .. win)
		namespaces[win] = namespace
	end
	local scoped = scope_namespace(win, namespace)
	if not scoped then
		notify_once("window_namespace", "Review hunk bands require Neovim window-scoped namespaces")
		return
	end
	for _, range in ipairs(plan.omitted) do
		vim.api.nvim_buf_set_extmark(buf, namespace, range.first - 1, 0, {
			conceal_lines = "",
			end_row = range.last - 1,
			end_col = 0,
		})
	end
	for _, band in ipairs(plan.bands) do
		vim.api.nvim_buf_set_extmark(buf, namespace, band.row, 0, {
			virt_lines = { { { band.text, HIGHLIGHT } } },
			virt_lines_above = band.above,
			priority = band.priority,
			right_gravity = band.right_gravity,
		})
	end
	local record = vim.tbl_extend("force", edges, {
		buf = buf,
		concealcursor = concealcursor,
		conceallevel = conceallevel,
		dependencies = dependencies,
		layout_name = "diff1_inline",
		workspace = workspace,
	})
	decorations[win] = record
	vim.wo[win].conceallevel = math.max(conceallevel, 2)
	vim.wo[win].concealcursor = ""
	return record
end

---Return the effective transient presentation mode.
---@param workspace table?
---@return "hunks"|"full"
function M.mode(workspace)
	return context_mode(workspace)
end

---Return the title-cased mode label.
---@param workspace table?
---@return "Hunks"|"Full"
function M.label(workspace)
	return context_mode(workspace) == "full" and "Full" or "Hunks"
end

---Return whether a layout supports the review context modes.
---@param layout_name string?
---@return boolean
function M.supports(layout_name)
	return type(layout_name) == "string"
		and (
			layout_name == "diff2_horizontal"
			or layout_name == "diff2_horizontal_pinned"
			or layout_name == "diff1_inline"
			or layout_name == "diff1_inline_pinned"
		)
end

---Apply one workspace's context mode to one owned diff window.
---@param workspace table
---@param buf integer
---@param win integer
---@param layout_name string
---@param dependencies? table
function M.apply_window(workspace, buf, win, layout_name, dependencies)
	if not valid_win(win) or not valid_buf(buf) or vim.api.nvim_win_get_buf(win) ~= buf then
		return
	end
	local edge_record
	local plugin_only = false
	with_saved_view(win, function()
		if layout_name == "diff2_horizontal" or layout_name == "diff2_horizontal_pinned" then
			clear_window(win, true)
			if context_mode(workspace) == "full" then
				vim.wo[win].foldenable = false
			else
				vim.wo[win].foldmethod = "diff"
				vim.wo[win].foldlevel = 0
				vim.wo[win].foldenable = true
			end
		elseif layout_name == "diff1_inline" or layout_name == "diff1_inline_pinned" then
			if context_mode(workspace) == "hunks" then
				edge_record = render_bands(workspace, buf, win, dependencies)
			else
				edge_record = decorations[win]
				plugin_only = true
				clear_window(win, true)
			end
		else
			clear_window(win, true)
		end
	end)
	maintain_edge_visibility(win, edge_record, plugin_only)
end

---Reapply presentation to every diff pane owned by one workspace.
---@param workspace table
---@param dependencies? table
function M.apply_workspace(workspace, dependencies)
	if not workspace or not valid_win(vim.api.nvim_get_current_win()) then
		return
	end
	local tabpage = workspace.tabpage
	if type(tabpage) ~= "number" or not vim.api.nvim_tabpage_is_valid(tabpage) then
		return
	end
	local previous_tab = vim.api.nvim_get_current_tabpage()
	local previous_win = vim.api.nvim_get_current_win()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if valid_win(win) and vim.w[win].nvim_review_diff_symbol then
			M.apply_window(
				workspace,
				vim.api.nvim_win_get_buf(win),
				win,
				vim.w[win].nvim_review_layout_name,
				dependencies
			)
		end
	end
	if vim.api.nvim_tabpage_is_valid(previous_tab) then
		vim.api.nvim_set_current_tabpage(previous_tab)
		if valid_win(previous_win) and vim.api.nvim_win_get_tabpage(previous_win) == previous_tab then
			vim.api.nvim_set_current_win(previous_win)
		end
	end
end

---Clear all presentation marks owned by one workspace during view teardown.
---@param workspace table?
function M.clear_workspace(workspace)
	for _, win in ipairs(decorated_windows()) do
		local record = decorations[win]
		if not workspace or record.workspace == workspace then
			clear_window(win, true)
		end
	end
end

local function rebuild_bands(filter_buf)
	for _, win in ipairs(decorated_windows()) do
		local record = decorations[win]
		if
			(not filter_buf or record.buf == filter_buf)
			and valid_win(win)
			and valid_buf(record.buf)
			and vim.api.nvim_win_get_buf(win) == record.buf
		then
			M.apply_window(record.workspace, record.buf, win, record.layout_name, record.dependencies)
		elseif not valid_win(win) or not valid_buf(record.buf) or vim.api.nvim_win_get_buf(win) ~= record.buf then
			clear_window(win, true)
		end
	end
end

local function schedule_rebuild(filter_buf)
	if filter_buf then
		rebuild_buffers[filter_buf] = true
	else
		rebuild_all = true
	end
	if rebuild_pending then
		return
	end
	rebuild_pending = true
	vim.schedule(function()
		rebuild_pending = false
		if rebuild_all then
			rebuild_bands()
		else
			for buf in pairs(rebuild_buffers) do
				rebuild_bands(buf)
			end
		end
		rebuild_all = false
		rebuild_buffers = {}
	end)
end

local function delayed_rebuild_key(filter_buf)
	return filter_buf or 0
end

local function cancel_delayed_rebuild(filter_buf)
	local key = delayed_rebuild_key(filter_buf)
	delayed_rebuild_tokens[key] = nil
end

local function schedule_delayed_rebuild(filter_buf, repaint_delay_ms)
	local key = delayed_rebuild_key(filter_buf)
	delayed_rebuild_token = delayed_rebuild_token + 1
	local token = delayed_rebuild_token
	delayed_rebuild_tokens[key] = token
	vim.defer_fn(function()
		if delayed_rebuild_tokens[key] ~= token then
			return
		end
		delayed_rebuild_tokens[key] = nil
		schedule_rebuild(filter_buf)
	end, repaint_delay_ms + REBUILD_SETTLE_MARGIN_MS)
end

local function define_highlight()
	vim.api.nvim_set_hl(0, HIGHLIGHT, { link = "StatusLine" })
end

---Install theme, repaint, resize, and teardown maintenance for review marks.
function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	define_highlight()
	local group = vim.api.nvim_create_augroup("NvimConfigReviewContext", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		desc = "Restore the review hunk band highlight",
		callback = define_highlight,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = group,
		desc = "Resize review hunk bands to their inline windows",
		callback = function()
			schedule_delayed_rebuild(nil, DIFFVIEW_RESIZE_REPAINT_DELAY_MS)
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
		group = group,
		desc = "Rebuild review context after Diffview repaints inline marks",
		callback = function(event)
			for _, record in pairs(decorations) do
				if record.buf == event.buf then
					if event.event == "TextChangedI" then
						schedule_delayed_rebuild(event.buf, DIFFVIEW_INSERT_REPAINT_DELAY_MS)
					else
						cancel_delayed_rebuild(event.buf)
						schedule_rebuild(event.buf)
					end
					return
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		desc = "Keep review hunk bands visible at file edges",
		callback = function(event)
			local win = vim.api.nvim_get_current_win()
			local record = decorations[win]
			if not record or record.buf ~= event.buf then
				return
			end
			vim.schedule(function()
				if decorations[win] == record then
					maintain_edge_visibility(win, record, false)
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		desc = "Discard review hunk bands for closed windows",
		callback = function(event)
			local win = tonumber(event.match)
			if win then
				clear_window(win, true)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		desc = "Discard review hunk bands for deleted buffers",
		callback = function(event)
			for _, win in ipairs(decorated_windows()) do
				local record = decorations[win]
				if record.buf == event.buf then
					clear_window(win, true)
				end
			end
		end,
	})
end

M._build_plan = build_plan
M._clear_window = clear_window
M._decorations = decorations
M._namespace = function(win)
	return namespaces[win]
end
M._rebuild_bands = rebuild_bands

return M
