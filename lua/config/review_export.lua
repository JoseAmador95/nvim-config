-- Deterministic Markdown export for native review sessions.
local M = {}

local review_lsp = require("config.review_lsp")
local review_store = require("config.review_store")

local PREVIEW_NAME = "review-export://markdown"
local SIDE_LABELS = { left = "OLD", right = "NEW" }
local preview_state

local function scope_fields(scope)
	if scope.kind == "working" then
		return {
			"HEAD: `" .. scope.head_oid .. "`",
			"Working fingerprint: `" .. scope.fingerprint .. "`",
		}
	elseif scope.kind == "commit" then
		return { "Commit: `" .. scope.commit_oid .. "`" }
	elseif scope.kind == "range" then
		return { "From: `" .. scope.from_oid .. "`", "To: `" .. scope.to_oid .. "`" }
	end
	return {
		"Base: `" .. scope.base_oid .. "`",
		"Merge base: `" .. scope.merge_base_oid .. "`",
		"Head: `" .. scope.head_oid .. "`",
	}
end

local function location(anchor)
	if not anchor.path then
		return "REVIEW"
	end
	local suffix = anchor.start_line and ":" .. anchor.start_line or ""
	if anchor.end_line and anchor.end_line ~= anchor.start_line then
		suffix = suffix .. "-" .. anchor.end_line
	end
	local side = SIDE_LABELS[anchor.side]
	return anchor.path .. suffix .. (side and " [" .. side .. "]" or "")
end

local function item_status(item, force, session_stale)
	local tags = { review_store.item_status(item) }
	if force and (session_stale or item.anchor.stale) then
		tags[#tags + 1] = "stale"
	end
	return table.concat(tags, ", ")
end

local function append_item(lines, item, force, session_stale, heading)
	lines[#lines + 1] = string.format("%s %s — %s", heading, item.type:upper(), location(item.anchor))
	lines[#lines + 1] = ""
	lines[#lines + 1] = "_" .. item_status(item, force, session_stale) .. "_"
	lines[#lines + 1] = ""
	lines[#lines + 1] = item.body
	lines[#lines + 1] = ""
end

local function render(session, force, allow_empty)
	local items = session.items
	if #items == 0 and not allow_empty then
		return nil, "review has no comments to export"
	end
	if not force then
		for _, item in ipairs(items) do
			if session.stale or item.anchor.stale then
				return nil, "review contains stale comments; use :ReviewExport! to include them"
			end
		end
	end

	local lines = {
		"# Code review",
		"",
		"- Repository: `" .. session.repo_root .. "`",
		"- Scope: " .. session.scope.label .. " (`" .. session.scope.kind .. "`)",
	}
	for _, field in ipairs(scope_fields(session.scope)) do
		lines[#lines + 1] = "- " .. field
	end
	lines[#lines + 1] = ""
	if #items == 0 then
		lines[#lines + 1] = "## Empty live review state"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "The last local mutation removed every comment but could not be persisted."
		return table.concat(lines, "\n"), {}
	end

	local included = {}
	local children = {}
	for _, item in ipairs(items) do
		included[item.id] = true
		if item.reply_to ~= vim.NIL and item.reply_to ~= nil then
			children[item.reply_to] = children[item.reply_to] or {}
			children[item.reply_to][#children[item.reply_to] + 1] = item
		end
	end
	local ids = {}
	local function append_replies(parent_id, depth)
		for _, reply in ipairs(children[parent_id] or {}) do
			local level = math.min(6, depth + 2)
			append_item(lines, reply, force == true, session.stale, string.rep("#", level) .. " Reply:")
			ids[#ids + 1] = reply.id
			append_replies(reply.id, depth + 1)
		end
	end
	for _, item in ipairs(items) do
		if item.reply_to == vim.NIL or item.reply_to == nil or not included[item.reply_to] then
			append_item(lines, item, force == true, session.stale, "##")
			ids[#ids + 1] = item.id
			append_replies(item.id, 1)
		end
	end
	return table.concat(lines, "\n"), ids
end

---Render one review session as self-contained Markdown.
---@param session table
---@param force? boolean
---@return string? markdown
---@return string[]|string ids_or_error
function M.render(session, force)
	return render(session, force, false)
end

---Render an unsaved session recovery, including an intentionally empty live state.
---@param session table
---@return string markdown
---@return string[] ids
function M.render_recovery(session)
	return render(session, true, true)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function window_view(win)
	local view
	vim.api.nvim_win_call(win, function()
		view = vim.fn.winsaveview()
	end)
	return view
end

local function source_snapshot(win)
	if not valid_win(win) then
		return nil
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return {
		win = win,
		buf = buf,
		name = vim.api.nvim_buf_get_name(buf),
		view = window_view(win),
	}
end

local function source_matches(snapshot, win)
	if not snapshot or not valid_win(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if type(snapshot.buf) == "number" and vim.api.nvim_buf_is_valid(snapshot.buf) and buf == snapshot.buf then
		return true
	end
	return snapshot.name ~= "" and vim.api.nvim_buf_get_name(buf) == snapshot.name
end

local function resolve_source_win(snapshot, fallback)
	if source_matches(snapshot, snapshot and snapshot.win) then
		return snapshot.win
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if source_matches(snapshot, win) then
			return win
		end
	end
	return valid_win(fallback) and fallback or nil
end

local function restore_source_focus(snapshot, fallback)
	local win = resolve_source_win(snapshot, fallback)
	if not win then
		return false
	end
	vim.api.nvim_set_current_win(win)
	if snapshot and snapshot.view then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview(snapshot.view)
		end)
	end
	return true
end

local function close_preview(restore_focus, preserve_buffer)
	local state = preview_state
	if not state then
		return
	end
	if preserve_buffer and vim.api.nvim_buf_is_valid(state.buf) then
		vim.bo[state.buf].bufhidden = "hide"
	end
	if valid_win(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	preview_state = nil
	if restore_focus then
		restore_source_focus(state.source)
	end
end

local function create_preview_buffer(markdown)
	local buf = vim.api.nvim_create_buf(false, true)
	review_lsp.mark(buf, "panel", { preview = true })
	vim.api.nvim_buf_set_name(buf, PREVIEW_NAME)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(markdown, "\n", { plain = true }))
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.bo[buf].readonly = true
	return buf
end

local function open_preview(buf, source, enter, view)
	local width = math.max(20, math.min(100, vim.o.columns - 4))
	local height = math.max(6, math.min(36, vim.o.lines - 4))
	local win = vim.api.nvim_open_win(buf, enter, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Review export ",
		title_pos = "center",
	})
	vim.bo[buf].bufhidden = "wipe"
	preview_state = { buf = buf, win = win, source = source }
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	if view then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview(view)
		end)
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			close_preview(true)
		end, { buffer = buf, silent = true, desc = "Close review export preview" })
	end
	return win
end

local function preview(markdown)
	close_preview(false)
	local source = source_snapshot(vim.api.nvim_get_current_win())
	local buf = create_preview_buffer(markdown)
	open_preview(buf, source, true)
end

---Remove the Markdown float while retaining its unlisted buffer and exact visible state.
---The float window handle intentionally cannot survive session serialization.
---@return table? state
---@return string? error_message
function M.suspend_preview()
	local current = preview_state
	if not current or not valid_win(current.win) or not vim.api.nvim_buf_is_valid(current.buf) then
		preview_state = nil
		return nil
	end
	local state = {
		focused = vim.api.nvim_get_current_win() == current.win,
		markdown = table.concat(vim.api.nvim_buf_get_lines(current.buf, 0, -1, false), "\n"),
		buf = current.buf,
		source = vim.deepcopy(current.source),
		view = window_view(current.win),
	}
	local ok, err = pcall(close_preview, false, true)
	if not ok then
		if vim.api.nvim_buf_is_valid(current.buf) then
			vim.bo[current.buf].bufhidden = "wipe"
		end
		preview_state = current
		return nil, tostring(err)
	end
	return state
end

---Recreate a suspended float with the same buffer, Markdown view, and logical focus.
---@param state table?
---@param fallback_source_win? integer
---@return boolean
function M.restore_preview(state, fallback_source_win)
	if not state then
		return true
	end
	if type(state.markdown) ~= "string" or type(state.focused) ~= "boolean" then
		return false
	end
	local current_win = vim.api.nvim_get_current_win()
	local source_win = resolve_source_win(state.source, fallback_source_win) or current_win
	local source = source_matches(state.source, source_win) and vim.deepcopy(state.source)
		or source_snapshot(source_win)
	if source then
		source.win = source_win
	end
	local buf = state.buf
	if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= PREVIEW_NAME then
		buf = create_preview_buffer(state.markdown)
	end
	local ok = pcall(open_preview, buf, source, state.focused, state.view)
	if not ok then
		return false
	end
	if not state.focused and valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
	return true
end

---Copy the complete Markdown snapshot, or preview it when unavailable.
---@param session table
---@param force? boolean
---@param dependencies? table
---@return table? result
---@return string? error_message
function M.deliver(session, force, dependencies)
	local markdown, render_error = M.render(session, force)
	if not markdown then
		return nil, render_error
	end
	local deps = dependencies or {}
	local has_clipboard = deps.has_clipboard
	if has_clipboard == nil then
		has_clipboard = vim.fn.has("clipboard") == 1
	end
	local copied = false
	if has_clipboard then
		local called, result = pcall(deps.setreg or vim.fn.setreg, "+", markdown)
		copied = called and (type(result) ~= "number" or result == 0)
	end
	if not copied then
		local show_preview = deps.preview or preview
		show_preview(markdown)
		return { markdown = markdown, previewed = true, ids = {} }
	end
	return { markdown = markdown, previewed = false, ids = {} }
end

return M
