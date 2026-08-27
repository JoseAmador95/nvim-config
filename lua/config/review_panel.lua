-- Plugin-free three-pane floating panel for native review workspaces.
local M = {}

local review_lsp = require("config.review_lsp")
local review_store = require("config.review_store")

local PANEL_ORDER = { "files", "commits", "comments" }
local PANEL_TITLES = { files = " Files ", commits = " Commits ", comments = " Comments " }
local PANEL_NAMES = { files = "files", commits = "commits", comments = "comments" }
local COMMIT_NAMESPACE = vim.api.nvim_create_namespace("nvim_review_panel_commits")

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function pane_for_win(state, win)
	for name, pane in pairs(state.panes or {}) do
		if pane.win == win and valid_win(win) then
			return name
		end
	end
	return nil
end

local function valid_source_win(state, win)
	if not valid_win(win) or pane_for_win(state, win) then
		return false
	end
	local config = vim.api.nvim_win_get_config(win)
	if config.relative and config.relative ~= "" then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not valid_buf(buf) or vim.b[buf].nvim_review_role == "panel" or vim.b[buf].nvim_review_panel_role ~= nil then
		return false
	end
	if vim.bo[buf].buftype == "" then
		return true
	end
	return vim.b[buf].nvim_review_role == "old" or vim.b[buf].nvim_review_role == "snapshot"
end

local function resolve_source_win(state, preferred)
	if valid_source_win(state, preferred) then
		state.source_win = preferred
	end
	if valid_source_win(state, state.source_win) then
		return state.source_win
	end
	state.source_win = nil
	return nil
end

local function current_pane(state)
	return pane_for_win(state, vim.api.nvim_get_current_win())
end

local function safe_cursor(win)
	if not valid_win(win) then
		return { 1, 0 }
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	return { cursor[1], cursor[2] }
end

local function capture_pane(pane)
	if not valid_win(pane.win) then
		return
	end
	local cursor = safe_cursor(pane.win)
	pane.cursor = cursor
	pane.selected = pane.rows[cursor[1]] or pane.selected
	vim.api.nvim_win_call(pane.win, function()
		pane.view = vim.fn.winsaveview()
	end)
end

local function capture_all(state)
	for _, pane in pairs(state.panes) do
		capture_pane(pane)
	end
end

local function dimensions()
	local available_width = math.max(12, vim.o.columns - 4)
	local available_height = math.max(8, vim.o.lines - 4)
	local width = math.max(12, math.min(150, available_width))
	local height = math.max(8, math.min(48, available_height))
	local left = math.max(5, math.floor((width - 1) * 0.42))
	local right = math.max(6, width - left - 1)
	if left + right + 1 > width then
		left = math.max(5, width - right - 1)
	end
	local top = math.max(3, math.floor((height - 1) * 0.45))
	local bottom = math.max(4, height - top - 1)
	if top + bottom + 1 > height then
		top = math.max(3, height - bottom - 1)
	end
	local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))
	return {
		files = { row = row, col = col, width = left, height = height },
		commits = { row = row, col = col + left + 1, width = right, height = top },
		comments = { row = row + top + 1, col = col + left + 1, width = right, height = bottom },
	}
end

local function window_config(name, geometry)
	return {
		relative = "editor",
		row = geometry.row,
		col = geometry.col,
		width = geometry.width,
		height = geometry.height,
		style = "minimal",
		border = "rounded",
		title = PANEL_TITLES[name],
		title_pos = "center",
		zindex = 45,
	}
end

local function invoke(state, name, ...)
	local callback = state.callbacks[name]
	if type(callback) == "function" then
		return callback(...)
	end
end

local function selected_value(state, name)
	local pane = state.panes[name]
	if not pane or not valid_win(pane.win) then
		return nil
	end
	capture_pane(pane)
	return pane.rows[pane.cursor[1]]
end

local function focus_next(state)
	local current = current_pane(state) or state.focused or "files"
	local index = vim.fn.index(PANEL_ORDER, current)
	return M.focus(state, PANEL_ORDER[(index + 1) % #PANEL_ORDER + 1])
end

local function comment_action(state, callback, ...)
	local id = selected_value(state, "comments")
	if id then
		invoke(state, callback, id, ...)
	end
end

local function choose_commit(state)
	local oid = selected_value(state, "commits")
	if not oid then
		return
	end
	if not state.commit_first or state.commit_second then
		state.commit_first = oid
		state.commit_second = nil
	elseif state.commit_first ~= oid then
		state.commit_second = oid
	end
	M.refresh(state)
	M.focus(state, "commits")
end

local function apply_commit(state)
	local oid = selected_value(state, "commits")
	if not oid then
		return
	end
	local first = state.commit_first or oid
	local second = state.commit_second
	invoke(state, "apply_commit", first, second)
end

local function install_common_maps(state, buf)
	for index, name in ipairs(PANEL_ORDER) do
		vim.keymap.set("n", tostring(index), function()
			M.focus(state, name)
		end, { buffer = buf, silent = true, desc = "Focus review " .. name })
	end
	vim.keymap.set("n", "<Tab>", function()
		focus_next(state)
	end, { buffer = buf, silent = true, desc = "Focus next review pane" })
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			M.hide(state)
		end, { buffer = buf, silent = true, desc = "Hide review panel" })
	end
end

local function install_pane_maps(state, name, buf)
	install_common_maps(state, buf)
	if name == "files" then
		vim.keymap.set("n", "<CR>", function()
			local identity = selected_value(state, "files")
			if identity then
				invoke(state, "select_entry", identity)
			end
		end, { buffer = buf, silent = true, desc = "Present exact review entry" })
		vim.keymap.set("n", "<leader>rA", function()
			local identity = selected_value(state, "files")
			if identity then
				invoke(state, "file_comment", identity)
			end
		end, { buffer = buf, silent = true, desc = "Comment selected review file" })
	elseif name == "commits" then
		vim.keymap.set("n", "<Space>", function()
			choose_commit(state)
		end, { buffer = buf, silent = true, desc = "Select commit endpoint" })
		vim.keymap.set("n", "c", function()
			state.commit_first = nil
			state.commit_second = nil
			M.refresh(state)
			M.focus(state, "commits")
		end, { buffer = buf, silent = true, desc = "Clear commit selection" })
		vim.keymap.set("n", "<CR>", function()
			apply_commit(state)
		end, { buffer = buf, silent = true, desc = "Open selected commit span" })
	else
		local actions = {
			["<CR>"] = "jump_comment",
			e = "edit_comment",
			d = "delete_comment",
			c = "change_type",
			r = "reply_comment",
			s = "toggle_resolution",
			m = "reanchor_comment",
		}
		for lhs, callback in pairs(actions) do
			local action = callback
			vim.keymap.set("n", lhs, function()
				if action == "reanchor_comment" then
					local source_win = resolve_source_win(state)
					if not source_win then
						vim.notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
						return
					end
					comment_action(state, action, source_win)
				else
					comment_action(state, action)
				end
			end, { buffer = buf, silent = true, desc = "Review comment action" })
		end
	end
end

local function new_buffer(state, name)
	local buf = vim.api.nvim_create_buf(false, true)
	review_lsp.mark(buf, "panel", { pane = name, workspace = state.workspace })
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "reviewpanel"
	vim.b[buf].nvim_review_panel_role = name
	pcall(vim.api.nvim_buf_set_name, buf, ("review-panel://%s/%s"):format(state.workspace.session.id, name))
	install_pane_maps(state, name, buf)
	return buf
end

local function ensure_windows(state)
	local geometry = dimensions()
	for _, name in ipairs(PANEL_ORDER) do
		local pane = state.panes[name]
		if not valid_buf(pane.buf) then
			pane.buf = new_buffer(state, name)
		end
		if not valid_win(pane.win) then
			pane.win = vim.api.nvim_open_win(pane.buf, false, window_config(name, geometry[name]))
		else
			vim.api.nvim_win_set_config(pane.win, window_config(name, geometry[name]))
		end
		vim.wo[pane.win].cursorline = true
		vim.wo[pane.win].wrap = false
		vim.wo[pane.win].signcolumn = "no"
		vim.wo[pane.win].winfixbuf = true
	end
end

local function short_text(value, maximum)
	value = tostring(value or ""):gsub("%s+", " ")
	if vim.fn.strdisplaywidth(value) <= maximum then
		return value
	end
	local suffix = "…"
	local budget = math.max(0, maximum - vim.fn.strdisplaywidth(suffix))
	local width = 0
	local parts = {}
	for index = 0, vim.fn.strchars(value) - 1 do
		local character = vim.fn.strcharpart(value, index, 1)
		local character_width = vim.fn.strdisplaywidth(character)
		if width + character_width > budget then
			break
		end
		parts[#parts + 1] = character
		width = width + character_width
	end
	return table.concat(parts) .. suffix
end

local function header(state)
	local workspace = state.workspace
	local root = vim.fs.basename(workspace.root) or workspace.root
	local scope = workspace.scope.label or workspace.scope.kind or workspace.session.id:sub(1, 8)
	return string.format(
		"Review · repo=%s · scope=%s · layout=%s · context=%s · comments=%d",
		root,
		scope,
		workspace.layout or "inline",
		workspace.context or "hunks",
		#(workspace.session.items or {})
	)
end

local function comment_counts(workspace)
	local counts = {}
	for _, item in ipairs(workspace.session.items or {}) do
		local path = item.anchor and item.anchor.path
		if path then
			counts[path] = (counts[path] or 0) + 1
		end
	end
	return counts
end

local function file_lines(state)
	local lines = { header(state), "Enter present · 1/2/3 or Tab focus · q hide", "" }
	local rows = {}
	local counts = comment_counts(state.workspace)
	for _, entry in ipairs(state.workspace.model.entries or {}) do
		local path = entry.path or entry.new_path or entry.old_path or "<unknown>"
		local layer = entry.layer or "history"
		local location = path
		if entry.renamed or (entry.old_path and entry.new_path and entry.old_path ~= entry.new_path) then
			location = (entry.old_path or "<none>") .. " -> " .. (entry.new_path or "<none>")
		end
		lines[#lines + 1] = string.format(
			"[%s][%s] %s  (%d)",
			entry.status or "?",
			layer,
			location,
			(counts[entry.old_path] or 0) + (entry.new_path ~= entry.old_path and (counts[entry.new_path] or 0) or 0)
		)
		rows[#lines] = entry.identity
	end
	if #(state.workspace.model.entries or {}) == 0 then
		lines[#lines + 1] = "No changed files"
	end
	return lines, rows
end

local function commit_date(commit)
	return commit.date or commit.author_date or commit.committed_at or ""
end

local function commit_lines(state)
	local lines = { "Space endpoints · Enter apply · c clear", "" }
	local rows = {}
	for _, commit in ipairs(state.workspace.model.commits or {}) do
		local marker = " "
		if commit.oid == state.commit_first then
			marker = "1"
		elseif commit.oid == state.commit_second then
			marker = "2"
		end
		local details = table.concat(
			vim.tbl_filter(function(value)
				return value ~= ""
			end, {
				commit_date(commit),
				commit.author or commit.author_name or "",
				commit.subject or commit.summary or "",
			}),
			" · "
		)
		lines[#lines + 1] =
			string.format("%s %s%s", marker, commit.oid:sub(1, 10), details ~= "" and " · " .. details or "")
		rows[#lines] = commit.oid
	end
	if #(state.workspace.model.commits or {}) == 0 then
		lines[#lines + 1] = "No commits for this scope"
	end
	return lines, rows
end

local function anchor_label(anchor)
	local kind = anchor.kind or (not anchor.path and "general" or anchor.start_line and "range" or "file")
	if kind == "general" then
		return "general"
	end
	local value = anchor.path
	if kind == "range" then
		local last = anchor.end_line or anchor.start_line
		value = value .. ":" .. tostring(anchor.start_line)
		if last ~= anchor.start_line then
			value = value .. "-" .. tostring(last)
		end
	end
	return kind .. " " .. value
end

local function comment_lines(state)
	local lines = { "Enter jump · e edit · d delete · c type · r reply · s resolve · m reanchor", "" }
	local rows = {}
	for _, item in ipairs(state.workspace.session.items or {}) do
		local body = short_text(item.body:match("[^\n]+") or item.body, 54)
		lines[#lines + 1] = string.format(
			"%02d [%s][%s] %s · %s",
			item.sequence,
			item.type,
			review_store.item_status(item),
			anchor_label(item.anchor),
			body
		)
		rows[#lines] = item.id
	end
	if #(state.workspace.session.items or {}) == 0 then
		lines[#lines + 1] = "No comments"
	end
	return lines, rows
end

local function set_lines(pane, lines, rows)
	if not valid_buf(pane.buf) then
		return
	end
	vim.bo[pane.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
	vim.bo[pane.buf].modifiable = false
	pane.rows = rows
end

local function restore_pane(pane)
	if not valid_win(pane.win) or not valid_buf(pane.buf) then
		return
	end
	local line = pane.cursor[1]
	if pane.selected then
		for candidate, value in pairs(pane.rows) do
			if value == pane.selected then
				line = candidate
				break
			end
		end
	end
	line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(pane.buf)))
	local view = vim.deepcopy(pane.view or {})
	view.lnum = line
	view.col = pane.cursor[2]
	vim.api.nvim_win_call(pane.win, function()
		vim.fn.winrestview(view)
	end)
	local content = vim.api.nvim_buf_get_lines(pane.buf, line - 1, line, false)[1] or ""
	vim.api.nvim_win_set_cursor(pane.win, { line, math.max(0, math.min(pane.cursor[2], #content)) })
end

local function commit_index(state, oid)
	for index, commit in ipairs(state.workspace.model.commits or {}) do
		if commit.oid == oid then
			return index
		end
	end
	return nil
end

local function decorate_commits(state)
	local pane = state.panes.commits
	if not valid_buf(pane.buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(pane.buf, COMMIT_NAMESPACE, 0, -1)
	local first = commit_index(state, state.commit_first)
	local second = commit_index(state, state.commit_second)
	if not first then
		state.commit_first = nil
		state.commit_second = nil
		return
	end
	second = second or first
	local low, high = math.min(first, second), math.max(first, second)
	for index = low, high do
		-- Commit rows begin after the two-line pane header.
		vim.api.nvim_buf_set_extmark(pane.buf, COMMIT_NAMESPACE, index + 1, 0, { line_hl_group = "Visual" })
	end
end

---Create persistent panel state for one repository/session workspace.
---@param workspace table
---@param callbacks? table
---@return table state
function M.new(workspace, callbacks)
	return {
		workspace = workspace,
		callbacks = callbacks or {},
		visible = false,
		focused = "files",
		source_win = nil,
		resize_autocmd = nil,
		commit_first = nil,
		commit_second = nil,
		panes = {
			files = { rows = {}, cursor = { 4, 0 }, view = {} },
			commits = { rows = {}, cursor = { 3, 0 }, view = {} },
			comments = { rows = {}, cursor = { 3, 0 }, view = {} },
		},
	}
end

---Refresh all pane contents while retaining stable selections and scroll positions.
---@param state table
---@param workspace? table
function M.refresh(state, workspace)
	state.workspace = workspace or state.workspace
	if not state.visible then
		return true
	end
	capture_all(state)
	ensure_windows(state)
	local files, file_rows = file_lines(state)
	local commits, commit_rows = commit_lines(state)
	local comments, comment_rows = comment_lines(state)
	set_lines(state.panes.files, files, file_rows)
	set_lines(state.panes.commits, commits, commit_rows)
	set_lines(state.panes.comments, comments, comment_rows)
	decorate_commits(state)
	for _, pane in pairs(state.panes) do
		restore_pane(pane)
	end
	return true
end

---Reflow all owned floats after a screen resize.
---@param state table
function M.reflow(state)
	if not state.visible then
		return
	end
	local geometry = dimensions()
	for _, name in ipairs(PANEL_ORDER) do
		local pane = state.panes[name]
		if valid_win(pane.win) then
			vim.api.nvim_win_set_config(pane.win, window_config(name, geometry[name]))
		end
	end
end

---Open all three panes without creating or switching tabs.
---@param state table
---@param focus? "files"|"commits"|"comments"
---@return boolean
function M.open(state, focus)
	local current = vim.api.nvim_get_current_win()
	resolve_source_win(state, current)
	state.visible = true
	ensure_windows(state)
	M.refresh(state)
	if not state.resize_autocmd then
		state.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
			callback = function()
				M.reflow(state)
			end,
		})
	end
	return M.focus(state, focus or state.focused or "files")
end

---Prefer a current presenter target while retaining an existing valid source as fallback.
---@param state table
---@param win? integer
---@return integer? source_win
function M.update_source(state, win)
	return resolve_source_win(state, win)
end

M.show = M.open

---Focus one pane, opening the complete panel if necessary.
---@param state table
---@param name "files"|"commits"|"comments"
---@return boolean
function M.focus(state, name)
	if not PANEL_NAMES[name] then
		return false
	end
	if not state.visible then
		return M.open(state, name)
	end
	local pane = state.panes[name]
	if not valid_win(pane.win) then
		ensure_windows(state)
		M.refresh(state)
	end
	if not valid_win(pane.win) then
		return false
	end
	state.focused = name
	vim.api.nvim_set_current_win(pane.win)
	return true
end

---Hide every owned float and restore the source focus captured on open.
---@param state table
---@return boolean
function M.hide(state)
	local has_window = false
	for _, pane in pairs(state.panes) do
		has_window = has_window or valid_win(pane.win)
	end
	if not state.visible and not has_window then
		return true
	end
	capture_all(state)
	state.visible = false
	if state.resize_autocmd then
		pcall(vim.api.nvim_del_autocmd, state.resize_autocmd)
		state.resize_autocmd = nil
	end
	for _, pane in pairs(state.panes) do
		if valid_win(pane.win) then
			pcall(vim.api.nvim_win_close, pane.win, true)
		end
		pane.win = nil
		pane.buf = nil -- bufhidden=wipe makes the buffer disposable; logical state remains above.
	end
	local source_win = resolve_source_win(state)
	if source_win then
		vim.api.nvim_set_current_win(source_win)
	end
	return true
end

---Toggle the complete panel.
---@param state table
---@param focus? "files"|"commits"|"comments"
function M.toggle(state, focus)
	if state.visible then
		return M.hide(state)
	end
	return M.open(state, focus)
end

---Destroy only panel-owned floats/buffers. Safe after partial manual teardown.
---@param state table
function M.close(state)
	M.hide(state)
	for _, pane in pairs(state.panes) do
		if valid_buf(pane.buf) then
			pcall(vim.api.nvim_buf_delete, pane.buf, { force = true })
		end
		pane.win = nil
		pane.buf = nil
	end
	return true
end

---Capture whether and where the panel was visible, then hide it.
---@param state table
---@return table snapshot
function M.suspend(state)
	local snapshot = { visible = state.visible, focused = current_pane(state) or state.focused }
	M.hide(state)
	return snapshot
end

---Restore a prior logical panel snapshot.
---@param state table
---@param snapshot table?
---@return boolean
function M.restore(state, snapshot)
	if not snapshot or not snapshot.visible then
		return true
	end
	return M.open(state, snapshot.focused)
end

function M.is_open(state)
	return state.visible == true
end

M._dimensions = dimensions
M._file_lines = file_lines
M._commit_lines = commit_lines
M._comment_lines = comment_lines

return M
