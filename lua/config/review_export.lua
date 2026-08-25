-- Deterministic Markdown export for native review sessions.
local M = {}

local PREVIEW_NAME = "review-export://markdown"

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
		return "General"
	end
	local suffix = anchor.start_line and ":" .. anchor.start_line or ""
	if anchor.end_line and anchor.end_line ~= anchor.start_line then
		suffix = suffix .. "-" .. anchor.end_line
	end
	return anchor.path .. suffix
end

local function indented_context(context)
	local lines = {}
	for _, line in ipairs(vim.split(context, "\n", { plain = true })) do
		lines[#lines + 1] = "    " .. line
	end
	return lines
end

local function item_tags(item, force, session_stale)
	local tags = { item.type, item.status }
	if item.anchor.side then
		tags[#tags + 1] = item.anchor.side
	end
	if item.anchor.layer then
		tags[#tags + 1] = item.anchor.layer
	end
	if force and (session_stale or item.anchor.stale) then
		tags[#tags + 1] = "stale"
	end
	return table.concat(tags, ", ")
end

local function append_item(lines, item, force, session_stale, heading)
	lines[#lines + 1] = string.format("%s %s — %s", heading, item.type:upper(), location(item.anchor))
	lines[#lines + 1] = ""
	lines[#lines + 1] = "_" .. item_tags(item, force, session_stale) .. "_"
	lines[#lines + 1] = ""
	lines[#lines + 1] = item.body
	if item.anchor.context and item.anchor.context ~= "" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Context (`" .. item.anchor.context_hash .. "`):"
		lines[#lines + 1] = ""
		vim.list_extend(lines, indented_context(item.anchor.context))
	end
	lines[#lines + 1] = ""
end

local function selected_items(session, force)
	local by_id = {}
	local eligible = {}
	local displayed = {}
	for _, item in ipairs(session.items) do
		by_id[item.id] = item
		local include = force or (item.status ~= "resolved" and item.status ~= "exported")
		if include then
			eligible[item.id] = true
			displayed[item.id] = true
		end
	end
	for id in pairs(eligible) do
		local item = by_id[id]
		while item and item.reply_to ~= vim.NIL and item.reply_to ~= nil do
			displayed[item.reply_to] = true
			item = by_id[item.reply_to]
		end
	end
	local selected = {}
	for _, item in ipairs(session.items) do
		if displayed[item.id] then
			selected[#selected + 1] = item
		end
	end
	return selected, eligible
end

local function lockable_ids(session, included_ids)
	local lockable = {}
	local exported = {}
	for _, item in ipairs(session.items) do
		exported[item.id] = item.status == "exported"
	end
	for _, id in ipairs(included_ids) do
		if not exported[id] then
			lockable[#lockable + 1] = id
		end
	end
	return lockable
end

---Render one review session as self-contained Markdown.
---@param session table
---@param force? boolean
---@return string? markdown
---@return string[]|string ids_or_error
function M.render(session, force)
	local items, eligible = selected_items(session, force == true)
	if #items == 0 then
		return nil, "review has no comments eligible for export"
	end
	if not force then
		for _, item in ipairs(items) do
			if session.stale or item.anchor.stale then
				return nil, "review contains stale unresolved comments; use :ReviewExport! to include them"
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
			if eligible[reply.id] then
				ids[#ids + 1] = reply.id
			end
			append_replies(reply.id, depth + 1)
		end
	end
	for _, item in ipairs(items) do
		if item.reply_to == vim.NIL or item.reply_to == nil or not included[item.reply_to] then
			append_item(lines, item, force == true, session.stale, "##")
			if eligible[item.id] then
				ids[#ids + 1] = item.id
			end
			append_replies(item.id, 1)
		end
	end
	return table.concat(lines, "\n"), ids
end

local function preview(markdown)
	local buf = vim.fn.bufnr(PREVIEW_NAME)
	if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then
		local windows = vim.fn.win_findbuf(buf)
		if windows[1] and vim.api.nvim_win_is_valid(windows[1]) then
			vim.api.nvim_set_current_win(windows[1])
		else
			vim.cmd("tabnew")
			vim.api.nvim_win_set_buf(0, buf)
		end
	else
		vim.cmd("tabnew")
		buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_name(buf, PREVIEW_NAME)
	end
	require("config.tabs").mark_transient(vim.api.nvim_get_current_tabpage(), "Review export preview")
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
end

---Remove the Markdown preview while a normal editor session is serialized.
---@return table? state
---@return string? error_message
function M.suspend_preview()
	local buf = vim.fn.bufnr(PREVIEW_NAME)
	if buf < 0 or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local windows = vim.fn.win_findbuf(buf)
	if #windows == 0 then
		return nil
	end
	local current_tab = vim.api.nvim_get_current_tabpage()
	local preview_tab = vim.api.nvim_win_get_tabpage(windows[1])
	local state = {
		focused = current_tab == preview_tab,
		markdown = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
	}
	vim.api.nvim_set_current_tabpage(preview_tab)
	local ok, err
	if #vim.api.nvim_list_tabpages() > 1 then
		ok, err = pcall(vim.cmd, "tabclose!")
	else
		ok, err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	if not ok then
		return nil, tostring(err)
	end
	if not state.focused and vim.api.nvim_tabpage_is_valid(current_tab) then
		vim.api.nvim_set_current_tabpage(current_tab)
	end
	return state
end

---Restore a preview removed by `suspend_preview` without stealing normal focus.
---@param state table?
---@return boolean
function M.restore_preview(state)
	if not state then
		return true
	end
	if type(state.markdown) ~= "string" or type(state.focused) ~= "boolean" then
		return false
	end
	local current_tab = vim.api.nvim_get_current_tabpage()
	preview(state.markdown)
	if not state.focused and vim.api.nvim_tabpage_is_valid(current_tab) then
		vim.api.nvim_set_current_tabpage(current_tab)
	end
	return true
end

---Copy rendered Markdown, or preview it without locking drafts when unavailable.
---@param session table
---@param force? boolean
---@param dependencies? table
---@return table? result
---@return string? error_message
function M.deliver(session, force, dependencies)
	local markdown, ids_or_error = M.render(session, force)
	if not markdown then
		return nil, ids_or_error
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
	return { markdown = markdown, previewed = false, ids = lockable_ids(session, ids_or_error) }
end

return M
