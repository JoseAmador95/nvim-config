-- Transient hunk/full-file presentation for review-owned Diffview windows.
local M = {}

local HIGHLIGHT = "NvimReviewHunkBand"
local HEADER_PRIORITY = 50
local FOOTER_PRIORITY = 200

local decorations = {}
local namespaces = {}
local warned = {}
local setup_done = false

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

---Build deterministic extmark descriptions for cached inline hunks.
---@param hunks table
---@param line_count integer
---@param width integer
---@return table[] bands
---@return boolean malformed
local function build_bands(hunks, line_count, width)
	if type(hunks) ~= "table" or line_count < 1 then
		return {}, type(hunks) ~= "table"
	end
	local bands = {}
	local total = #hunks
	local malformed = false
	for index, hunk in ipairs(hunks) do
		if valid_hunk(hunk) then
			local old_start, old_count, new_start, new_count = unpack(hunk)
			local header = ("HUNK %d/%d · -%d,%d +%d,%d"):format(
				index,
				total,
				old_start,
				old_count,
				new_start,
				new_count
			)
			local footer = ("END HUNK %d/%d"):format(index, total)
			local header_row
			local footer_row
			local above
			if new_count > 0 then
				header_row = new_start - 1
				footer_row = new_start + new_count - 2
				above = true
			else
				header_row = new_start == 0 and 0 or new_start - 1
				footer_row = header_row
				above = new_start == 0
			end
			header_row = math.max(0, math.min(header_row, line_count - 1))
			footer_row = math.max(0, math.min(footer_row, line_count - 1))
			bands[#bands + 1] = {
				row = header_row,
				above = above,
				priority = HEADER_PRIORITY,
				right_gravity = false,
				text = pad_band(header, width),
			}
			bands[#bands + 1] = {
				row = footer_row,
				above = new_count == 0 and above or false,
				priority = FOOTER_PRIORITY,
				right_gravity = true,
				text = pad_band(footer, width),
			}
		else
			malformed = true
		end
	end
	return bands, malformed
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
	local bands, malformed = build_bands(hunks, line_count, text_width(win))
	local edges = edge_counts(hunks, bands, line_count)
	if malformed then
		notify_once("malformed", "Diffview returned malformed cached inline hunks")
	end
	if #bands == 0 then
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
	for _, band in ipairs(bands) do
		vim.api.nvim_buf_set_extmark(buf, namespace, band.row, 0, {
			virt_lines = { { { band.text, HIGHLIGHT } } },
			virt_lines_above = band.above,
			priority = band.priority,
			right_gravity = band.right_gravity,
		})
	end
	local record = vim.tbl_extend("force", edges, {
		buf = buf,
		dependencies = dependencies,
		layout_name = "diff1_inline",
		workspace = workspace,
	})
	decorations[win] = record
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

---Clear all bands owned by one workspace during view teardown.
---@param workspace table?
function M.clear_workspace(workspace)
	for _, win in ipairs(decorated_windows()) do
		local record = decorations[win]
		if not workspace or record.workspace == workspace then
			clear_window(win, true)
		end
	end
end

local function rebuild_bands()
	for _, win in ipairs(decorated_windows()) do
		local record = decorations[win]
		if valid_win(win) and valid_buf(record.buf) and vim.api.nvim_win_get_buf(win) == record.buf then
			M.apply_window(record.workspace, record.buf, win, record.layout_name, record.dependencies)
		else
			clear_window(win, true)
		end
	end
end

local function define_highlight()
	vim.api.nvim_set_hl(0, HIGHLIGHT, { link = "StatusLine" })
end

---Install theme, resize, and teardown maintenance for persistent bands.
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
		callback = rebuild_bands,
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

M._build_bands = build_bands
M._clear_window = clear_window
M._decorations = decorations
M._namespace = function(win)
	return namespaces[win]
end
M._rebuild_bands = rebuild_bands

return M
