-- Native, LSP-friendly code-review workspaces built on exact Diffview scopes.
local M = {}

local review_diffview = require("config.review_diffview")
local review_export = require("config.review_export")
local review_scope = require("config.review_scope")
local review_source = require("config.review_source")
local review_store = require("config.review_store")

local NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review")
local THREAD_RESTORE_ATTEMPTS = 500
local THREAD_RESTORE_INTERVAL_MS = 20
local REVIEW_TYPES = { "issue", "suggestion", "rationale", "question", "pedantic", "praise" }
local TYPE_SIGNS = {
	issue = { text = "●", highlight = "DiagnosticSignError" },
	suggestion = { text = "◆", highlight = "DiagnosticSignWarn" },
	rationale = { text = "R", highlight = "DiagnosticSignInfo" },
	question = { text = "?", highlight = "DiagnosticSignInfo" },
	pedantic = { text = "·", highlight = "DiagnosticSignHint" },
	praise = { text = "♥", highlight = "DiagnosticSignHint" },
}

local workspaces = {}
local suspended
local publishing_sessions = {}
local export_workspace
local review_threads

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Review" })
end

local function error_message(err)
	return type(err) == "table" and (err.message or err.code) or tostring(err)
end

local function valid_tab(tabpage)
	return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function buffer_in_root(root, buf)
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
		return false
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then
		return false
	end
	local repo = require("config.repo")
	if repo.contains(root, path) then
		return true
	end
	local canonical_root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
	local lexical = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	return lexical:sub(1, #canonical_root + 1) == canonical_root .. "/"
end

local function modified_buffer(root)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buf].modified and buffer_in_root(root, buf) then
			return vim.api.nvim_buf_get_name(buf)
		end
	end
	return nil
end

local function active_workspace()
	local workspace = review_diffview.workspace()
	if workspace then
		return workspace
	end
	local tabpage = vim.api.nvim_get_current_tabpage()
	local link = review_source.get(tabpage)
	workspace = link and link.workspace
	if not workspace or workspaces[workspace.root] ~= workspace then
		if link then
			review_source.clear(tabpage)
		end
		return nil
	end
	return workspace
end

local function publication_key(workspace)
	return workspace.root .. "\0" .. workspace.session.id
end

local function publication_active(workspace)
	return publishing_sessions[publication_key(workspace)] ~= nil
end

local function root_publication_active(root)
	for _, workspace in pairs(publishing_sessions) do
		if workspace.root == root then
			return true
		end
	end
	return false
end

local function allow_mutation(workspace)
	if publication_active(workspace) then
		notify("Wait for the current TUICR publication to finish", vim.log.levels.WARN)
		return false
	end
	if workspace.unsaved_error then
		notify("This review has an unsaved conflict; export it before reopening the saved session", vim.log.levels.WARN)
		return false
	end
	return true
end

local function allow_composer_mutation(workspace, interrupted)
	if interrupted then
		workspace.automatic_recovery = nil
		workspace.recovery_exported = nil
		return true
	end
	return allow_mutation(workspace)
end

local function composer_active()
	return require("config.review_editor").has_active()
end

local function suspend_review_threads()
	local loaded, trouble = pcall(require, "trouble")
	if not loaded or type(trouble.is_open) ~= "function" then
		review_threads = nil
		return nil
	end
	local owner = review_threads
	if not owner then
		return nil
	end
	if not valid_tab(owner.tabpage) then
		review_threads = nil
		return nil
	end
	local original_tab = vim.api.nvim_get_current_tabpage()
	local original_win = vim.api.nvim_get_current_win()
	local state = {
		owner = owner,
		focused = vim.bo.filetype == "trouble" and vim.api.nvim_get_current_tabpage() == owner.tabpage,
	}
	vim.api.nvim_set_current_tabpage(owner.tabpage)
	if not trouble.is_open({ mode = "review" }) then
		review_threads = nil
		if valid_tab(original_tab) then
			vim.api.nvim_set_current_tabpage(original_tab)
		end
		return nil
	end
	local closed, close_err = pcall(trouble.close, { mode = "review" })
	local remained_open = trouble.is_open({ mode = "review" })
	if valid_tab(original_tab) then
		vim.api.nvim_set_current_tabpage(original_tab)
		if vim.api.nvim_win_is_valid(original_win) then
			vim.api.nvim_set_current_win(original_win)
		end
	end
	if not closed then
		return nil, tostring(close_err)
	end
	if remained_open then
		return nil, "Trouble review view remained open"
	end
	review_threads = nil
	return state
end

local function restore_review_threads(state, attempts)
	if not state then
		return true
	end
	attempts = attempts or THREAD_RESTORE_ATTEMPTS
	local owner = state.owner
	local target = owner.review_host and owner.workspace.tabpage or owner.tabpage
	if not valid_tab(target) then
		if attempts > 1 then
			vim.defer_fn(function()
				restore_review_threads(state, attempts - 1)
			end, THREAD_RESTORE_INTERVAL_MS)
			return true
		end
		return false
	end
	local current_tab = vim.api.nvim_get_current_tabpage()
	local current_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_tabpage(target)
	local loaded, trouble = pcall(require, "trouble")
	owner.tabpage = target
	review_threads = owner
	local called = loaded and pcall(trouble.open, { mode = "review", focus = state.focused })
	local opened = called and trouble.is_open({ mode = "review" })
	if not state.focused and valid_tab(current_tab) then
		vim.api.nvim_set_current_tabpage(current_tab)
		if vim.api.nvim_win_is_valid(current_win) then
			vim.api.nvim_set_current_win(current_win)
		end
	end
	if not opened then
		review_threads = nil
	end
	return opened
end

local function close_review_threads(workspace)
	if not review_threads or review_threads.workspace ~= workspace then
		return
	end
	if review_threads.review_host and not valid_tab(review_threads.tabpage) then
		review_threads = nil
		return
	end
	local _, err = suspend_review_threads()
	if err then
		notify("Could not close review threads: " .. err, vim.log.levels.ERROR)
	end
end

local function thread_workspace()
	local workspace = review_threads and review_threads.workspace
	if workspace and workspaces[workspace.root] == workspace then
		return workspace
	end
	return nil
end

local function root_for_command()
	local workspace = active_workspace()
	if workspace then
		return workspace.root
	end
	return require("config.repo").current_root(0)
end

local function persist_unsaved_recovery(workspace)
	if not workspace.unsaved_error or #workspace.session.items == 0 then
		return true
	end
	if type(workspace.automatic_recovery) == "table" then
		local verified = review_store.verify_recovery(workspace.root, workspace.automatic_recovery)
		if verified then
			return workspace.automatic_recovery
		end
	end
	local markdown, render_err = review_export.render(workspace.session, true)
	if not markdown then
		return nil, render_err
	end
	local recovery, recovery_err = review_store.save_recovery(workspace.root, workspace.session, markdown)
	if not recovery then
		return nil, recovery_err
	end
	workspace.automatic_recovery = recovery
	return recovery
end

local function save_session(workspace, session)
	local saved, err = review_store.save(workspace.root, session)
	if not saved then
		workspace.session = session
		workspace.scope = session.scope
		workspace.unsaved_error = err
		local recovery, recovery_err = persist_unsaved_recovery(workspace)
		review_diffview.update_title(workspace)
		M.refresh_marks(workspace)
		local message = "Could not save review: " .. tostring(err)
		if type(recovery) == "table" then
			message = message .. "; complete recovery saved to " .. recovery.path
		elseif #session.items > 0 then
			message = message .. "; recovery failed: " .. tostring(recovery_err)
		end
		notify(message, vim.log.levels.ERROR)
		return nil, err
	end
	workspace.session = saved
	workspace.scope = saved.scope
	workspace.unsaved_error = nil
	workspace.recovery_exported = nil
	workspace.automatic_recovery = nil
	review_diffview.update_title(workspace)
	M.refresh_marks(workspace)
	local ok, trouble = pcall(require, "trouble")
	if ok then
		pcall(trouble.refresh, "review")
	end
	return true
end

local function load_or_create(root, scope)
	local session, err = review_store.load(root, scope.id)
	if session then
		return session
	end
	if err and not tostring(err):find("missing", 1, true) then
		return nil, err
	end
	return review_store.new(root, scope)
end

local function update_drift(session)
	local drift, err = review_scope.detect_drift(session.scope)
	if not drift then
		return nil, err.message or err
	end
	local updated = vim.deepcopy(session)
	updated.stale = drift.stale or (session.scope.kind == "working" and modified_buffer(session.repo_root) ~= nil)
	return updated
end

local function composer_session(workspace, interrupted, stale_message)
	local current, drift_err = update_drift(workspace.session)
	if not current then
		if not interrupted then
			notify("Could not check review drift: " .. error_message(drift_err), vim.log.levels.ERROR)
			return nil
		end
		current = vim.deepcopy(workspace.session)
		current.stale = true
	end
	if current.stale and not interrupted then
		if not workspace.session.stale then
			save_session(workspace, current)
		end
		notify(stale_message, vim.log.levels.ERROR)
		return nil
	end
	return current
end

local function open_workspace_view(workspace, mode, path, target)
	local thread_state
	if
		valid_tab(workspace.tabpage)
		and workspace.view_mode ~= mode
		and review_threads
		and review_threads.workspace == workspace
	then
		local close_err
		thread_state, close_err = suspend_review_threads()
		if close_err then
			return nil, "could not suspend review threads: " .. close_err
		end
		workspace.pending_threads = thread_state
	end
	local opened, err = review_diffview.open(workspace, mode, path, nil, target)
	if not opened and thread_state then
		workspace.pending_threads = nil
		restore_review_threads(thread_state)
	end
	return opened, err
end

local function start_workspace(root, session, mode, origin)
	local workspace = {
		root = root,
		scope = session.scope,
		session = session,
		origin = origin,
		view_mode = mode or "files",
	}
	workspaces[root] = workspace
	local opened, err = review_diffview.open(workspace, workspace.view_mode)
	if not opened then
		workspaces[root] = nil
		if origin and valid_tab(origin.tabpage) then
			vim.api.nvim_set_current_tabpage(origin.tabpage)
			if vim.api.nvim_win_is_valid(origin.winid) then
				vim.api.nvim_set_current_win(origin.winid)
			end
		end
		return nil, err
	end
	return workspace
end

local function replace_workspace(root, session, mode)
	if root_publication_active(root) then
		return nil, "TUICR publication is still in progress for this repository"
	end
	if composer_active() then
		return nil, "review composer has unsent text; save or cancel it first"
	end
	local existing = workspaces[root]
	if existing and existing.unsaved_error then
		return nil, "current review has unsaved comments; export them before replacing it"
	end
	if existing and existing.session.id == session.id and valid_tab(existing.tabpage) then
		vim.api.nvim_set_current_tabpage(existing.tabpage)
		local opened, err = open_workspace_view(existing, mode or existing.view_mode)
		if not opened then
			return nil, err
		end
		return existing
	end
	local origin = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		winid = vim.api.nvim_get_current_win(),
	}
	local thread_state
	if existing and review_threads and review_threads.workspace == existing then
		local thread_err
		thread_state, thread_err = suspend_review_threads()
		if thread_err then
			return nil, "could not suspend review threads: " .. thread_err
		end
	end
	if existing and valid_tab(existing.tabpage) then
		existing.replacing = true
		vim.api.nvim_set_current_tabpage(existing.tabpage)
		local closed, err = review_diffview.close()
		if not closed then
			existing.replacing = nil
			if thread_state then
				restore_review_threads(thread_state)
			end
			if valid_tab(origin.tabpage) then
				vim.api.nvim_set_current_tabpage(origin.tabpage)
				if vim.api.nvim_win_is_valid(origin.winid) then
					vim.api.nvim_set_current_win(origin.winid)
				end
			end
			return nil, err
		end
	end
	local replacement, start_err = start_workspace(root, session, mode, origin)
	if not replacement then
		if existing then
			review_source.clear_workspace(existing)
		end
		return nil, start_err
	end
	if existing then
		review_source.migrate(existing, replacement)
	end
	if thread_state then
		thread_state.owner.workspace = replacement
		if not restore_review_threads(thread_state) then
			notify("Could not restore review threads after changing scope", vim.log.levels.ERROR)
		end
	end
	return replacement
end

local function open_session(root, session, mode)
	if publishing_sessions[root .. "\0" .. session.id] then
		return nil, "TUICR publication is still in progress for this review"
	end
	local checked, drift_err = update_drift(session)
	if not checked then
		return nil, drift_err
	end
	if checked.scope.kind == "working" and checked.stale then
		return nil,
			"working-tree review is stale or has unsaved buffers; save changes and open a new working scope",
			checked
	end
	local saved, save_err = review_store.save(root, checked)
	if not saved then
		return nil, save_err
	end
	return replace_workspace(root, saved, mode)
end

local function open_request(root, request, mode)
	local scope, scope_err = review_scope.resolve(root, request)
	if not scope then
		return nil, scope_err.message or scope_err
	end
	local session, session_err = load_or_create(root, scope)
	if not session then
		return nil, session_err
	end
	return open_session(root, session, mode)
end

local function report_open(root, request, mode)
	local workspace, err = open_request(root, request, mode)
	if not workspace then
		notify("Could not open review: " .. tostring(err), vim.log.levels.ERROR)
	end
	return workspace
end

local function item_label(item)
	local anchor = item.anchor
	local location = anchor.path or "General"
	if anchor.start_line then
		location = location .. ":" .. anchor.start_line
	end
	local first_line = item.body:match("[^\n]+") or item.body
	return string.format("%02d  %-10s  %-9s  %s  %s", item.sequence, item.type, item.status, location, first_line)
end

local function select_item(workspace, prompt, predicate, callback)
	local items = {}
	for _, item in ipairs(workspace.session.items) do
		if not predicate or predicate(item) then
			items[#items + 1] = item
		end
	end
	if #items == 0 then
		notify("No matching review comments", vim.log.levels.INFO)
		return
	end
	vim.ui.select(items, {
		prompt = prompt,
		format_item = item_label,
	}, callback)
end

local function find_session_item(session, id)
	for _, item in ipairs(session.items) do
		if item.id == id then
			return item
		end
	end
	return nil
end

local function find_item(workspace, id)
	return find_session_item(workspace.session, id)
end

local function with_item(workspace, id, prompt, predicate, callback)
	if id and id ~= "" then
		local item = find_item(workspace, id)
		if not item or (predicate and not predicate(item)) then
			notify("Review comment is unavailable for this action", vim.log.levels.ERROR)
			return
		end
		callback(item)
		return
	end
	select_item(workspace, prompt, predicate, function(item)
		if item then
			callback(item)
		end
	end)
end

local function context_for_buffer(buf, first, last)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local context_first = math.max(1, first - 3)
	local context_last = math.min(line_count, last + 3)
	local lines = vim.api.nvim_buf_get_lines(buf, context_first - 1, context_last, false)
	local context = table.concat(lines, "\n")
	if context == "" then
		return "\n"
	end
	local limit = review_store.max_anchor_context
	if #context <= limit then
		return context
	end
	local selected = {}
	for index = first - context_first + 1, last - context_first + 1 do
		selected[#selected + 1] = lines[index]
	end
	context = table.concat(selected, "\n")
	if context == "" then
		return "\n"
	end
	local boundary = math.min(#context, limit)
	while boundary > 0 do
		local byte = context:byte(boundary + 1)
		if not byte or byte < 128 or byte > 191 then
			break
		end
		boundary = boundary - 1
	end
	return context:sub(1, boundary)
end

local function current_anchor(workspace, first, last)
	if workspace.view_mode == "history" then
		return nil, "Commit history is browse-only; use :ReviewFiles before commenting"
	end
	local target, err = review_diffview.current_target()
	if not target then
		return nil, err
	end
	local line_count = vim.api.nvim_buf_line_count(target.bufnr)
	first = math.max(1, math.min(first, line_count))
	last = math.max(first, math.min(last, line_count))
	local context = context_for_buffer(target.bufnr, first, last)
	return {
		path = target.path,
		side = target.side,
		layer = target.layer,
		start_line = first,
		end_line = last,
		context = context,
		context_hash = vim.fn.sha256(context):lower(),
		stale = workspace.session.stale,
	}
end

local function choose_type(callback)
	vim.ui.select(REVIEW_TYPES, {
		prompt = "Review comment type",
		format_item = function(value)
			return value:sub(1, 1):upper() .. value:sub(2)
		end,
	}, callback)
end

local function anchor_location(item)
	local anchor = item.anchor
	if type(anchor) ~= "table" then
		return nil
	end
	return {
		path = anchor.path,
		side = anchor.side,
		layer = anchor.layer,
		line = anchor.start_line,
	}
end

local function same_location(left, right)
	return left
		and right
		and left.path == right.path
		and left.side == right.side
		and left.layer == right.layer
		and left.line == right.line
end

local function navigable_item(workspace, item)
	local location = anchor_location(item)
	return location ~= nil
		and not workspace.session.stale
		and not item.anchor.stale
		and type(location.path) == "string"
		and location.path ~= ""
		and type(location.side) == "string"
		and type(location.layer) == "string"
		and type(location.line) == "number"
end

local function current_line_item(workspace, session, predicate)
	if workspace.view_mode == "history" then
		return nil, nil, "Commit history is browse-only; use :ReviewFiles before changing comments"
	end
	if session.stale then
		return nil, nil, "Review is stale; open a new scope before changing comments"
	end
	local target, target_err = review_diffview.current_target()
	if not target then
		return nil, nil, target_err
	end
	local location = {
		path = target.path,
		side = target.side,
		layer = target.layer,
		line = vim.api.nvim_win_get_cursor(target.winid)[1],
	}
	local matches = {}
	local eligible = {}
	for _, item in ipairs(session.items) do
		if same_location(anchor_location(item), location) then
			matches[#matches + 1] = item
			if not item.anchor.stale and (not predicate or predicate(item)) then
				eligible[#eligible + 1] = item
			end
		end
	end
	if #matches == 0 then
		return nil, nil, "No review comment on the current line"
	end
	if #eligible == 0 then
		return nil, nil, "The review comment on the current line is unavailable for this action"
	end
	if #eligible > 1 then
		return nil, nil, "Multiple review comments are anchored on the current line"
	end
	return eligible[1], location
end

local function composer_recovery(workspace, title, body, anchor)
	local rendered = review_export.render(workspace.session, true)
	local lines = rendered and { rendered }
		or {
			"# Code review recovery",
			"",
			"- Repository: `" .. workspace.root .. "`",
			"- Scope: " .. workspace.scope.label,
		}
	vim.list_extend(lines, { "", "## Interrupted composer", "", "- Action: " .. title })
	if anchor and anchor.path then
		local location = anchor.path .. (anchor.start_line and ":" .. anchor.start_line or "")
		lines[#lines + 1] = "- Location: `" .. location .. "`"
	end
	vim.list_extend(lines, { "", body })
	if anchor and anchor.context and anchor.context ~= "" then
		vim.list_extend(lines, { "", "Context:", "" })
		for _, line in ipairs(vim.split(anchor.context, "\n", { plain = true })) do
			lines[#lines + 1] = "    " .. line
		end
	end
	local recovery, err = review_store.save_recovery(workspace.root, workspace.session, table.concat(lines, "\n"))
	if not recovery then
		notify("Could not save interrupted review comment: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	workspace.automatic_recovery = recovery
	notify("Interrupted review comment saved to " .. recovery.path, vim.log.levels.WARN)
	return true
end

local function compose(workspace, title, body, anchor, callback)
	require("config.review_editor").compose({
		title = title,
		body = body,
		recover = function(draft)
			return composer_recovery(workspace, title, draft, anchor)
		end,
	}, callback)
end

local function refresh_current_diff()
	local ok, actions = pcall(require, "diffview.actions")
	if ok and type(actions.refresh_files) == "function" then
		actions.refresh_files()
	end
end

local function focus_item(workspace, item)
	if workspace.session.stale or item.anchor.stale or not valid_tab(workspace.tabpage) or not item.anchor.path then
		return false
	end
	vim.api.nvim_set_current_tabpage(workspace.tabpage)
	local target = {
		current_path = item.anchor.path,
		layer = item.anchor.layer,
		side = item.anchor.side,
		line = item.anchor.start_line,
		column = (item.anchor.start_column or 1) - 1,
	}
	if workspace.view_mode == "history" then
		local opened = open_workspace_view(workspace, "files", item.anchor.path, target)
		return opened == true
	end
	return review_diffview.select_file(item.anchor.path, item.anchor.layer, target)
end

local function source_workspace()
	local existing = active_workspace()
	if existing then
		return existing
	end
	local root = require("config.repo").current_root(0)
	return root and workspaces[root] or nil
end

local function open_scope_picker(root)
	local choices = {
		{ label = "Branch · default branch…HEAD", action = "branch" },
		{ label = "Working tree · staged / unstaged / untracked", action = "working" },
		{ label = "Commit…", action = "commit" },
		{ label = "Range…", action = "range" },
		{ label = "Saved review session…", action = "sessions" },
		{ label = "TUICR round…", action = "tuicr" },
	}
	vim.ui.select(choices, {
		prompt = "Review scope",
		format_item = function(choice)
			return choice.label
		end,
	}, function(choice)
		if not choice then
			return
		elseif choice.action == "branch" or choice.action == "working" then
			report_open(root, { kind = choice.action })
		elseif choice.action == "sessions" then
			M.sessions(root)
		elseif choice.action == "tuicr" then
			M.link_tuicr(nil, root)
		elseif choice.action == "commit" then
			vim.ui.input({ prompt = "Commit revision: ", default = "HEAD" }, function(revision)
				if revision and revision ~= "" then
					report_open(root, { kind = "commit", rev = revision })
				end
			end)
		else
			vim.ui.input({ prompt = "Range start: " }, function(from)
				if not from or from == "" then
					return
				end
				vim.ui.input({ prompt = "Range end: ", default = "HEAD" }, function(to)
					if to and to ~= "" then
						report_open(root, { kind = "range", from = from, to = to })
					end
				end)
			end)
		end
	end)
end

---Open a saved session picker for one repository.
---@param root? string
function M.sessions(root)
	root = root or root_for_command()
	if not root then
		notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		return
	end
	local sessions, err = review_store.list(root)
	if not sessions then
		notify("Could not list reviews: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	if #sessions == 0 then
		notify("No saved review sessions for this repository")
		return
	end
	vim.ui.select(sessions, {
		prompt = "Saved review sessions",
		format_item = function(session)
			local stale = session.stale and " [stale]" or ""
			return session.scope.label .. stale .. " · " .. #session.items .. " comments"
		end,
	}, function(session)
		if session then
			local workspace, open_err, checked = open_session(root, session)
			if workspace then
				return
			end
			checked = checked or update_drift(session)
			if checked and checked.scope.kind == "working" and checked.stale then
				local stale_workspace = { root = root, scope = checked.scope, session = checked }
				if not save_session(stale_workspace, checked) then
					return
				end
				vim.ui.select({ "Export stale review with saved context" }, {
					prompt = "The exact working diff is no longer available",
				}, function(choice)
					if choice then
						export_workspace(stale_workspace, true)
					end
				end)
				return
			end
			notify("Could not open saved review: " .. tostring(open_err), vim.log.levels.ERROR)
		end
	end)
end

---Add a typed comment at the current review selection or cursor line.
---@param first integer
---@param last integer
---@param requested_type? string
function M.comment(first, last, requested_type)
	local workspace = review_diffview.workspace()
	if not workspace then
		notify("Open and focus a review diff before adding a comment", vim.log.levels.ERROR)
		return
	end
	if not allow_mutation(workspace) then
		return
	end
	local checked, drift_err = update_drift(workspace.session)
	if not checked then
		return notify("Could not check review drift: " .. error_message(drift_err), vim.log.levels.ERROR)
	end
	if checked.stale then
		save_session(workspace, checked)
		return notify("Review is stale; open a new scope before adding comments", vim.log.levels.ERROR)
	end
	local anchor, anchor_err = current_anchor(workspace, first, last)
	if not anchor then
		notify(anchor_err, vim.log.levels.ERROR)
		return
	end
	local function create(item_type)
		if not item_type then
			return
		end
		compose(workspace, "New " .. item_type, nil, anchor, function(body, interrupted)
			if not body then
				return true
			end
			if not allow_composer_mutation(workspace, interrupted) then
				return false
			end
			local current =
				composer_session(workspace, interrupted, "Review changed while composing; the editor remains open")
			if not current then
				return false
			end
			if current.stale then
				anchor = vim.tbl_extend("force", anchor, { stale = true })
			end
			local session, err = review_store.add(current, {
				type = item_type,
				body = body,
				anchor = anchor,
			})
			if not session then
				notify("Could not add review comment: " .. tostring(err), vim.log.levels.ERROR)
				return false
			end
			if not save_session(workspace, session) then
				return workspace.automatic_recovery ~= nil
			end
			notify("Review comment saved")
			return true
		end)
	end
	if requested_type and vim.tbl_contains(REVIEW_TYPES, requested_type) then
		create(requested_type)
	else
		choose_type(create)
	end
end

---Edit a local, not-yet-exported review comment.
---@param id? string
function M.edit(id)
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	if not allow_mutation(workspace) then
		return
	end
	if not composer_session(workspace, false, "Review is stale; open a new scope before editing comments") then
		return
	end
	with_item(workspace, id, "Edit review draft", function(item)
		return item.status ~= "exported"
	end, function(item)
		compose(workspace, "Edit " .. item.type, item.body, item.anchor, function(body, interrupted)
			if not body then
				return true
			end
			if not allow_composer_mutation(workspace, interrupted) then
				return false
			end
			local current =
				composer_session(workspace, interrupted, "Review changed while composing; the editor remains open")
			if not current then
				return false
			end
			local session, err = review_store.edit(current, item.id, { body = body })
			if not session then
				notify("Could not edit comment: " .. tostring(err), vim.log.levels.ERROR)
				return false
			end
			return save_session(workspace, session) == true or workspace.automatic_recovery ~= nil
		end)
	end)
end

---Delete one local draft by ID or at the exact current review line.
---@param id? string
function M.delete(id)
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	if not allow_mutation(workspace) then
		return
	end
	if not id or id == "" then
		local current = composer_session(workspace, false, "Review is stale; open a new scope before deleting comments")
		if not current then
			return
		end
		local item, _, item_err = current_line_item(workspace, current, function(candidate)
			return candidate.status ~= "exported"
		end)
		if not item then
			return notify(item_err, vim.log.levels.WARN)
		end
		local session, err = review_store.delete(current, item.id)
		if not session then
			return notify("Could not delete comment: " .. tostring(err), vim.log.levels.ERROR)
		end
		save_session(workspace, session)
		return
	end
	with_item(workspace, id, "Delete review draft", function(item)
		return item.status ~= "exported"
	end, function(item)
		if not allow_mutation(workspace) then
			return
		end
		local session, err = review_store.delete(workspace.session, item.id)
		if not session then
			notify("Could not delete comment: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		save_session(workspace, session)
	end)
end

---Change the type of the comment at the exact current review line.
function M.change_type()
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	if not allow_mutation(workspace) then
		return
	end
	local current = composer_session(workspace, false, "Review is stale; open a new scope before changing comments")
	if not current then
		return
	end
	local item, _, item_err = current_line_item(workspace, current, function(candidate)
		return candidate.status ~= "exported"
	end)
	if not item then
		return notify(item_err, vim.log.levels.WARN)
	end
	local id = item.id
	choose_type(function(item_type)
		if not item_type or not allow_mutation(workspace) then
			return
		end
		local latest = composer_session(workspace, false, "Review is stale; open a new scope before changing comments")
		if not latest then
			return
		end
		local resolved, _, resolved_err = current_line_item(workspace, latest, function(candidate)
			return candidate.status ~= "exported"
		end)
		if not resolved then
			return notify(resolved_err, vim.log.levels.WARN)
		end
		if resolved.id ~= id then
			return notify("The review comment on the current line is unavailable for this action", vim.log.levels.WARN)
		end
		local session, err = review_store.set_type(latest, id, item_type)
		if not session then
			return notify("Could not change comment type: " .. tostring(err), vim.log.levels.ERROR)
		end
		save_session(workspace, session)
	end)
end

---Reply to an existing local or exported comment.
---@param id? string
function M.reply(id)
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	if not allow_mutation(workspace) then
		return
	end
	if not composer_session(workspace, false, "Review is stale; open a new scope before replying") then
		return
	end
	with_item(workspace, id, "Reply to review comment", nil, function(item)
		compose(workspace, "Reply to " .. item.type, nil, item.anchor, function(body, interrupted)
			if not body then
				return true
			end
			if not allow_composer_mutation(workspace, interrupted) then
				return false
			end
			local current =
				composer_session(workspace, interrupted, "Review changed while composing; the editor remains open")
			if not current then
				return false
			end
			local session, err = review_store.reply(current, item.id, { body = body })
			if not session then
				notify("Could not save reply: " .. tostring(err), vim.log.levels.ERROR)
				return false
			end
			return save_session(workspace, session) == true or workspace.automatic_recovery ~= nil
		end)
	end)
end

local function set_item_status(id, status)
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	if not allow_mutation(workspace) then
		return
	end
	with_item(
		workspace,
		id,
		status == "resolved" and "Resolve review comment" or "Reopen review comment",
		function(item)
			return item.status ~= "exported"
		end,
		function(item)
			if not allow_mutation(workspace) then
				return
			end
			local target = status
			if status ~= "resolved" then
				target = (item.reply_to == vim.NIL or item.reply_to == nil) and "draft" or "reply"
			end
			local session, err = review_store.set_status(workspace.session, item.id, target)
			if not session then
				notify("Could not update comment: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			save_session(workspace, session)
		end
	)
end

---Toggle between the exact historical diff and the current source buffer.
function M.code()
	local workspace = review_diffview.workspace()
	if workspace then
		local target, err = review_diffview.current_target({ allow_panel = true })
		if not target then
			return notify(err, vim.log.levels.ERROR)
		end
		local relative = target.current_path
		local lexical, path_err = require("config.repo").resolve_relative(workspace.root, relative)
		if not lexical then
			return notify("Current source is unavailable: " .. tostring(path_err), vim.log.levels.ERROR)
		end
		local cursor = target.from_panel and { 1, 0 } or vim.api.nvim_win_get_cursor(target.winid)
		local saved_target = {
			current_path = target.current_path,
			layer = target.layer,
			revision = target.revision,
			side = target.side,
			line = cursor[1],
			column = cursor[2],
		}
		require("config.editor").open_file_in_tab(lexical, { lnum = cursor[1], col = cursor[2] + 1 })
		review_source.set(vim.api.nvim_get_current_tabpage(), workspace, saved_target)
		return
	end

	local source_tab = vim.api.nvim_get_current_tabpage()
	local link = review_source.get(source_tab)
	workspace = source_workspace()
	if not workspace or not valid_tab(workspace.tabpage) then
		return notify("No review workspace is linked to this source tab", vim.log.levels.ERROR)
	end
	if link and link.workspace ~= workspace then
		link = nil
	end
	local target = link and link.target or nil
	local relative = target and target.current_path or nil
	if not relative then
		local relative_err
		relative, relative_err = require("config.repo").relative_existing(workspace.root, vim.api.nvim_buf_get_name(0))
		if not relative then
			return notify("Could not return to review location: " .. tostring(relative_err), vim.log.levels.ERROR)
		end
	end
	vim.api.nvim_set_current_tabpage(workspace.tabpage)
	local layer = target and target.layer or nil
	if not review_diffview.select_file(relative, layer, target) then
		notify("The exact review file and layer are no longer available", vim.log.levels.ERROR)
	end
end

---Open the dedicated Trouble panel for review threads.
function M.threads()
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	local previous = thread_workspace()
	if review_threads then
		local closed, close_err = suspend_review_threads()
		if close_err then
			return notify("Could not close review threads: " .. close_err, vim.log.levels.ERROR)
		end
		if closed and previous == workspace then
			return
		end
	end
	local tabpage = vim.api.nvim_get_current_tabpage()
	local trouble = require("trouble")
	review_threads = {
		workspace = workspace,
		tabpage = tabpage,
		review_host = review_diffview.workspace(tabpage) == workspace,
	}
	local opened, open_err = pcall(trouble.open, { mode = "review" })
	if not opened or not trouble.is_open({ mode = "review" }) then
		review_threads = nil
		notify("Could not open review threads: " .. tostring(open_err or "no review comments"), vim.log.levels.WARN)
	end
end

---Return anchored items for the custom Trouble source.
---@return table[]
function M.items()
	local workspace = active_workspace()
	return workspace and vim.deepcopy(workspace.session.items) or {}
end

---Return the active repository and comments for external read-only views.
---@param owned_threads? boolean
---@return table?
function M.snapshot(owned_threads)
	local workspace
	if owned_threads then
		workspace = thread_workspace()
	else
		workspace = active_workspace()
	end
	if not workspace then
		return nil
	end
	return {
		root = workspace.root,
		stale = workspace.session.stale,
		items = vim.deepcopy(workspace.session.items),
	}
end

---Jump from a Trouble review item back into the exact diff.
---@param id string
---@param owned_threads? boolean
function M.jump(id, owned_threads)
	local workspace
	if owned_threads then
		workspace = thread_workspace()
	else
		workspace = active_workspace()
	end
	local item = workspace and find_item(workspace, id)
	if not item or not focus_item(workspace, item) then
		notify("Review location is unavailable", vim.log.levels.ERROR)
	end
end

---Choose an anchored review comment and jump to its exact diff location.
function M.comments()
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	select_item(workspace, "Review comments", function(item)
		return navigable_item(workspace, item)
	end, function(selected)
		if not selected then
			return
		end
		local item = find_item(workspace, selected.id)
		if not item or not navigable_item(workspace, item) or not focus_item(workspace, item) then
			notify("Review location is unavailable", vim.log.levels.ERROR)
		end
	end)
end

local function navigate(direction)
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	local anchored = {}
	for _, item in ipairs(workspace.session.items) do
		if not workspace.session.stale and not item.anchor.stale and item.anchor.path and item.anchor.start_line then
			anchored[#anchored + 1] = item
		end
	end
	if #anchored == 0 then
		return notify("Review has no anchored comments")
	end
	local index = workspace.navigation_index or (direction > 0 and 0 or 1)
	index = ((index - 1 + direction) % #anchored) + 1
	workspace.navigation_index = index
	focus_item(workspace, anchored[index])
end

local function remote_comment_id(item)
	if type(item.export_id) ~= "string" then
		return nil
	end
	return item.export_id:match("^tuicr:(.+)$")
end

local function publish_tuicr(workspace, force)
	if publication_active(workspace) then
		notify("TUICR publication is already in progress", vim.log.levels.WARN)
		return
	end
	local _, ids_or_error = review_export.render(workspace.session, force)
	if type(ids_or_error) ~= "table" then
		notify(ids_or_error, vim.log.levels.ERROR)
		return
	end
	local wanted = {}
	for _, id in ipairs(ids_or_error) do
		wanted[id] = true
	end
	local function include_ancestors(item)
		if not item or item.status == "exported" then
			return
		end
		wanted[item.id] = true
		if item.reply_to ~= vim.NIL and item.reply_to ~= nil then
			include_ancestors(find_item(workspace, item.reply_to))
		end
	end
	for _, id in ipairs(ids_or_error) do
		local item = find_item(workspace, id)
		if item and item.reply_to ~= vim.NIL and item.reply_to ~= nil then
			include_ancestors(find_item(workspace, item.reply_to))
		end
	end
	local queue = {}
	for _, item in ipairs(workspace.session.items) do
		if wanted[item.id] and item.status ~= "exported" then
			queue[#queue + 1] = item.id
		end
	end
	if #queue == 0 then
		local all_received = #workspace.session.items > 0
		for _, item in ipairs(workspace.session.items) do
			if item.status ~= "exported" or type(item.export_id) ~= "string" or not item.export_id:match("^tuicr:") then
				all_received = false
				break
			end
		end
		if force and workspace.unsaved_error and all_received then
			workspace.recovery_exported = true
			notify("All review comments have TUICR receipts; :ReviewClose! is now available")
			return
		end
		notify("All eligible comments were already published")
		return
	end

	local adapter = require("config.review_tuicr")
	local round = workspace.session.bridge.round
	local key = publication_key(workspace)
	publishing_sessions[key] = workspace
	local recovery_mode = false
	local recovery_error
	local function finish(message, level)
		if publishing_sessions[key] == workspace then
			publishing_sessions[key] = nil
		end
		if message then
			notify(message, level)
		end
	end
	local index = 0
	local function publish_next()
		index = index + 1
		local id = queue[index]
		if not id then
			if recovery_mode then
				if force then
					workspace.recovery_exported = true
				end
				local next_step = force and ":ReviewClose! is now available"
					or "run :ReviewExport! before forcing close"
				finish(
					string.format(
						"Published %d review comments, but receipts remain unsaved (%s); %s",
						#queue,
						error_message(recovery_error),
						next_step
					),
					vim.log.levels.WARN
				)
				return
			end
			finish(string.format("Published %d review comments to TUICR", #queue))
			return
		end
		local item = find_item(workspace, id)
		if not item then
			return finish("Review changed while publishing; stopped before duplicate delivery", vim.log.levels.ERROR)
		end
		local values = {
			type = item.type,
			body = item.body,
			delivery_key = item.id,
			anchor = {
				path = item.anchor.path,
				side = item.anchor.side,
				start_line = item.anchor.start_line,
				end_line = item.anchor.end_line,
			},
		}
		local operation = adapter.add
		if item.reply_to ~= vim.NIL and item.reply_to ~= nil then
			local parent = find_item(workspace, item.reply_to)
			local reply_to = parent and remote_comment_id(parent)
			if not reply_to then
				return finish("Reply parent has not been published to TUICR", vim.log.levels.ERROR)
			end
			values.reply_to = reply_to
			operation = adapter.respond
		end
		local ok, operation_err = pcall(operation, workspace.root, round, values, function(result, err)
			if not result or type(result.id) ~= "string" or result.id == "" then
				return finish(
					"TUICR publish stopped: " .. error_message(err or "missing comment id"),
					vim.log.levels.ERROR
				)
			end
			local updated, mark_err = review_store.mark_exported(workspace.session, id, "tuicr:" .. result.id)
			if not updated then
				return finish(
					"TUICR accepted a comment, but its receipt could not be retained: " .. error_message(mark_err),
					vim.log.levels.ERROR
				)
			end
			if recovery_mode then
				workspace.session = updated
				workspace.scope = updated.scope
				review_diffview.update_title(workspace)
				M.refresh_marks(workspace)
			else
				local saved, save_err = save_session(workspace, updated)
				if not saved then
					recovery_mode = true
					recovery_error = save_err
				end
			end
			publish_next()
		end)
		if not ok then
			finish("Could not start TUICR publication: " .. tostring(operation_err), vim.log.levels.ERROR)
		end
	end
	publish_next()
end

---Move to the next review comment.
function M.next()
	navigate(1)
end

---Move to the previous review comment.
function M.prev()
	navigate(-1)
end

export_workspace = function(workspace, force)
	if composer_active() then
		return notify("Save or cancel the open review comment before exporting", vim.log.levels.WARN)
	end
	if publication_active(workspace) then
		return notify("TUICR publication is already in progress", vim.log.levels.WARN)
	end
	local checked, drift_err = update_drift(workspace.session)
	if not checked then
		return notify("Could not check review drift: " .. error_message(drift_err), vim.log.levels.ERROR)
	end
	if checked.stale ~= workspace.session.stale then
		if workspace.unsaved_error then
			workspace.session = checked
			review_diffview.update_title(workspace)
		elseif not save_session(workspace, checked) then
			return
		end
	end
	if workspace.session.bridge then
		publish_tuicr(workspace, force)
		return
	end
	local result, err = review_export.deliver(workspace.session, force)
	if not result then
		return notify(err, vim.log.levels.ERROR)
	end
	local recovery
	if force then
		local recovery_err
		recovery, recovery_err = review_store.save_recovery(workspace.root, workspace.session, result.markdown)
		if not recovery then
			return notify(
				"Could not persist complete review recovery: " .. tostring(recovery_err),
				vim.log.levels.ERROR
			)
		end
		workspace.recovery_exported = recovery
	end
	if result.previewed then
		if force then
			notify(
				"Clipboard unavailable; opened a preview and saved complete recovery to " .. recovery.path,
				vim.log.levels.WARN
			)
		else
			notify("Clipboard unavailable; opened a preview and kept drafts editable", vim.log.levels.WARN)
		end
		return
	end
	local session = workspace.session
	local export_id = "clipboard:" .. os.date("!%Y%m%dT%H%M%SZ")
	for _, id in ipairs(result.ids) do
		local updated, mark_err = review_store.mark_exported(session, id, export_id)
		if not updated then
			return notify("Copied review, but could not lock drafts: " .. tostring(mark_err), vim.log.levels.ERROR)
		end
		session = updated
	end
	if save_session(workspace, session) then
		notify("Review copied to the clipboard")
	end
end

---Render and deliver unresolved comments, locking only successful clipboard exports.
---@param force? boolean
function M.export(force)
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	return export_workspace(workspace, force)
end

---Recompute working-tree drift and refresh the current exact view.
function M.refresh()
	local workspace = active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	local environment_safe, environment_err = review_diffview.environment_safe()
	if not environment_safe then
		return notify(environment_err, vim.log.levels.ERROR)
	end
	local session, err = update_drift(workspace.session)
	if not session then
		return notify("Could not refresh review: " .. tostring(err), vim.log.levels.ERROR)
	end
	if save_session(workspace, session) then
		if session.stale then
			notify("Review is stale; open a new scope to review current changes", vim.log.levels.WARN)
		else
			refresh_current_diff()
		end
	end
end

---Place review signs in a Diffview buffer without touching diagnostics.
---@param workspace table
---@param buf integer
function M.decorate_buffer(workspace, buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
	if workspace.session.stale or workspace.view_mode == "history" then
		return
	end
	local target = review_diffview.current_target()
	if not target or target.bufnr ~= buf then
		return
	end
	for _, item in ipairs(workspace.session.items) do
		local anchor = item.anchor
		if
			not anchor.stale
			and anchor.path == target.path
			and anchor.side == target.side
			and anchor.layer == target.layer
			and anchor.start_line
		then
			local sign = TYPE_SIGNS[item.type]
			local line = math.max(0, math.min(anchor.start_line - 1, vim.api.nvim_buf_line_count(buf) - 1))
			vim.api.nvim_buf_set_extmark(buf, NAMESPACE, line, 0, {
				sign_text = sign.text,
				sign_hl_group = sign.highlight,
				priority = 20,
			})
		end
	end
end

---Refresh signs in every visible pane of one review workspace.
---@param workspace? table
function M.refresh_marks(workspace)
	workspace = workspace or active_workspace()
	if not workspace or not valid_tab(workspace.tabpage) then
		return
	end
	local current_tab = vim.api.nvim_get_current_tabpage()
	local current_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_tabpage(workspace.tabpage)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(workspace.tabpage)) do
		if vim.api.nvim_win_is_valid(win) and vim.w[win].nvim_review_diff_symbol then
			vim.api.nvim_set_current_win(win)
			M.decorate_buffer(workspace, vim.api.nvim_win_get_buf(win))
		end
	end
	if valid_tab(current_tab) then
		vim.api.nvim_set_current_tabpage(current_tab)
		if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_tabpage(current_win) == current_tab then
			vim.api.nvim_set_current_win(current_win)
		end
	end
end

local function round_id(value)
	return type(value) == "string" and value or type(value) == "table" and (value.round or value.id) or nil
end

local function persist_round(workspace, round)
	if not allow_mutation(workspace) then
		return
	end
	local linked, err = review_store.link_tuicr(workspace.session, round)
	if not linked then
		notify("Could not link TUICR round: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	if not save_session(workspace, linked) then
		return
	end
	notify("Linked TUICR round " .. round)
end

---Link the current exact scope to a selected TUICR round without opening its TUI.
---@param requested_round? string
---@param requested_root? string
function M.link_tuicr(requested_round, requested_root)
	local root = requested_root or root_for_command()
	if not root then
		return notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
	end
	local function link(value)
		local round = round_id(value)
		if not round then
			return
		end
		local workspace = workspaces[root] or report_open(root, { kind = "branch" })
		if workspace then
			persist_round(workspace, round)
		end
	end
	require("config.review_tuicr").list_rounds(root, function(rounds, err)
		if not rounds then
			return notify("Could not list TUICR rounds: " .. tostring(err), vim.log.levels.ERROR)
		end
		if requested_round and requested_round ~= "" then
			for _, value in ipairs(rounds) do
				if round_id(value) == requested_round then
					link(value)
					return
				end
			end
			return notify("TUICR round is not open for this repository", vim.log.levels.ERROR)
		end
		if #rounds == 0 then
			return notify("No open TUICR rounds for this repository")
		end
		vim.ui.select(rounds, {
			prompt = "TUICR round",
			format_item = function(value)
				return round_id(value) or "Invalid round"
			end,
		}, link)
	end)
end

---Close all transient review tabs while auto-session serializes normal tabs.
function M.suspend_for_session()
	if suspended then
		return nil, "review tabs are already suspended"
	end
	if next(publishing_sessions) ~= nil then
		return nil, "TUICR publication is still in progress"
	end
	if composer_active() then
		return nil, "review composer has unsent text; save or cancel it first"
	end
	for _, workspace in pairs(workspaces) do
		if workspace.unsaved_error then
			return nil, "review comments are still unsaved after a concurrent edit"
		end
	end
	local original = vim.api.nvim_get_current_tabpage()
	local original_win = vim.api.nvim_get_current_win()
	local focus = {
		tabpage = original,
		winid = original_win,
		workspace = review_diffview.workspace(original),
	}
	local threads, threads_err = suspend_review_threads()
	if threads_err then
		return nil, "could not close review threads: " .. threads_err
	end
	local preview, preview_err = review_export.suspend_preview()
	if preview_err then
		restore_review_threads(threads)
		return nil, "could not close review export preview: " .. preview_err
	end
	local entries = {}
	for _, workspace in pairs(workspaces) do
		if valid_tab(workspace.tabpage) then
			vim.api.nvim_set_current_tabpage(workspace.tabpage)
			local target = review_diffview.current_target({ allow_panel = true })
			if target then
				local cursor = target.from_panel and { 1, 0 } or vim.api.nvim_win_get_cursor(target.winid)
				target.line = cursor[1]
				target.column = cursor[2]
				target.focus = focus.workspace == workspace
			end
			local entry = { workspace = workspace, mode = workspace.view_mode, target = target }
			workspace.suspending = true
			local closed, err = review_diffview.close()
			if not closed then
				workspace.suspending = nil
				suspended = { entries = entries, focus = focus, preview = preview, threads = threads }
				local _, restore_err = M.restore_after_session()
				return nil, "could not close review tab: " .. tostring(err or restore_err)
			end
			entries[#entries + 1] = entry
		end
	end
	suspended = { entries = entries, focus = focus, preview = preview, threads = threads }
	if valid_tab(original) then
		vim.api.nvim_set_current_tabpage(original)
		if vim.api.nvim_win_is_valid(original_win) then
			vim.api.nvim_set_current_win(original_win)
		end
	end
	return true
end

---Restore review tabs after synchronous session serialization has finished.
function M.restore_after_session()
	local state = suspended
	if not state then
		return true
	end
	suspended = nil
	local errors = {}
	for _, value in ipairs(state.entries) do
		local workspace = value.workspace
		workspace.suspending = nil
		local target = value.target
		local opened, err = review_diffview.open(
			workspace,
			value.mode,
			value.mode ~= "history" and target and target.current_path or nil,
			nil,
			target
		)
		if not opened then
			errors[#errors + 1] = tostring(err)
		end
	end
	local focus = state.focus
	local target = focus.workspace and focus.workspace.tabpage or focus.tabpage
	if valid_tab(target) then
		vim.api.nvim_set_current_tabpage(target)
		if not focus.workspace and vim.api.nvim_win_is_valid(focus.winid) then
			vim.api.nvim_set_current_win(focus.winid)
		end
	end
	if not review_export.restore_preview(state.preview) then
		errors[#errors + 1] = "could not restore review export preview"
	end
	if not restore_review_threads(state.threads) then
		errors[#errors + 1] = "could not restore review threads"
	end
	if #errors > 0 then
		return nil, "could not restore review tab: " .. table.concat(errors, "; ")
	end
	return true
end

local function close_workspace(force, requested_tab)
	local workspace = requested_tab and review_diffview.workspace(requested_tab) or active_workspace()
	if not workspace then
		return notify("No active review", vim.log.levels.ERROR)
	end
	if publication_active(workspace) then
		return notify("Wait for the current TUICR publication to finish", vim.log.levels.WARN)
	end
	if composer_active() then
		return notify("Save or cancel the open review comment before closing", vim.log.levels.WARN)
	end
	if workspace.unsaved_error then
		if not force then
			return notify(
				"Use :ReviewExport! and then :ReviewClose! to discard the recovered local copy",
				vim.log.levels.WARN
			)
		end
		if type(workspace.recovery_exported) == "table" then
			local verified, verify_err = review_store.verify_recovery(workspace.root, workspace.recovery_exported)
			if not verified then
				return notify("Recovery export is unavailable: " .. tostring(verify_err), vim.log.levels.ERROR)
			end
		elseif not workspace.recovery_exported and #workspace.session.items > 0 then
			return notify("Export the unsaved review before forcing it closed", vim.log.levels.ERROR)
		end
	end
	if valid_tab(workspace.tabpage) then
		local original_tab = vim.api.nvim_get_current_tabpage()
		vim.api.nvim_set_current_tabpage(workspace.tabpage)
		local closed, err = review_diffview.close()
		if not closed then
			notify("Could not close review: " .. tostring(err), vim.log.levels.ERROR)
			if valid_tab(original_tab) then
				vim.api.nvim_set_current_tabpage(original_tab)
			end
			return false
		end
		if valid_tab(original_tab) then
			vim.api.nvim_set_current_tabpage(original_tab)
		end
	end
	return true
end

---Close a review-owned tab through the same recovery and composer guards.
---@param tabpage integer
---@return boolean
function M.close_tab(tabpage)
	return close_workspace(false, tabpage) == true
end

local function parse_open(arguments)
	local kind = arguments[1] or "branch"
	if kind == "working" and #arguments == 1 then
		return { kind = kind }
	elseif kind == "commit" and #arguments <= 2 then
		return { kind = kind, rev = arguments[2] or "HEAD" }
	elseif kind == "range" and #arguments == 3 then
		return { kind = kind, from = arguments[2], to = arguments[3] }
	elseif kind == "branch" and #arguments <= 3 then
		return { kind = kind, base = arguments[2], head = arguments[3] }
	elseif kind == "tuicr" and #arguments <= 2 then
		return { kind = kind, round = arguments[2] }
	end
	return nil
end

local function setup_commands()
	vim.api.nvim_create_user_command("ReviewOpen", function(command)
		local root = root_for_command()
		if not root then
			return notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		end
		local arguments = vim.split(command.args, "%s+", { trimempty = true })
		local request = parse_open(arguments)
		if not request then
			return notify(
				"Usage: ReviewOpen [working|commit [REV]|range FROM TO|branch [BASE [HEAD]]|tuicr [UUID]]",
				vim.log.levels.ERROR
			)
		end
		if request.kind == "tuicr" then
			M.link_tuicr(request.round, root)
			return
		end
		report_open(root, request)
	end, {
		nargs = "*",
		complete = function()
			return { "working", "commit", "range", "branch", "tuicr" }
		end,
		desc = "Open an exact native code-review workspace",
	})
	vim.api.nvim_create_user_command("ReviewScope", function()
		local root = root_for_command()
		if root then
			open_scope_picker(root)
		else
			notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		end
	end, { desc = "Choose a review scope or saved session" })
	vim.api.nvim_create_user_command("ReviewSessions", function()
		M.sessions()
	end, { desc = "Open a saved review session" })
	vim.api.nvim_create_user_command("ReviewFiles", function()
		local workspace = active_workspace()
		if workspace and not composer_active() then
			open_workspace_view(workspace, "files")
		elseif workspace then
			notify("Save or cancel the open review comment before changing review views", vim.log.levels.WARN)
		end
	end, { desc = "Show the review file aggregate" })
	vim.api.nvim_create_user_command("ReviewCommits", function()
		local workspace = active_workspace()
		if workspace then
			if composer_active() then
				return notify(
					"Save or cancel the open review comment before changing review views",
					vim.log.levels.WARN
				)
			end
			local opened, err = open_workspace_view(workspace, "history")
			if not opened then
				notify(err, vim.log.levels.WARN)
			end
		end
	end, { desc = "Show commits in the review scope" })
	vim.api.nvim_create_user_command("ReviewCode", M.code, { desc = "Toggle current source and exact review diff" })
	vim.api.nvim_create_user_command("ReviewLayout", function()
		local changed, err = review_diffview.layout()
		if not changed then
			notify(err, vim.log.levels.WARN)
		end
	end, { desc = "Toggle side-by-side and unified inline review layouts" })
	vim.api.nvim_create_user_command("ReviewComment", function(command)
		M.comment(command.line1, command.line2, command.args ~= "" and command.args or nil)
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return vim.deepcopy(REVIEW_TYPES)
		end,
		desc = "Add a typed review comment",
	})
	vim.api.nvim_create_user_command("ReviewThreads", M.threads, { desc = "Toggle review threads in Trouble" })
	vim.api.nvim_create_user_command("ReviewComments", M.comments, { desc = "Choose and jump to a review comment" })
	vim.api.nvim_create_user_command("ReviewReply", function(command)
		M.reply(command.args)
	end, { nargs = "?", desc = "Reply to a review comment" })
	vim.api.nvim_create_user_command("ReviewEdit", function(command)
		M.edit(command.args)
	end, { nargs = "?", desc = "Edit a review draft" })
	vim.api.nvim_create_user_command("ReviewDeleteDraft", function(command)
		M.delete(command.args)
	end, { nargs = "?", desc = "Delete a review comment at the current line or by ID" })
	vim.api.nvim_create_user_command("ReviewChangeType", M.change_type, {
		desc = "Change the review comment type at the current line",
	})
	vim.api.nvim_create_user_command("ReviewResolve", function(command)
		set_item_status(command.args, "resolved")
	end, { nargs = "?", desc = "Resolve a review comment" })
	vim.api.nvim_create_user_command("ReviewReopen", function(command)
		set_item_status(command.args, "open")
	end, { nargs = "?", desc = "Reopen a resolved review comment" })
	vim.api.nvim_create_user_command("ReviewNext", M.next, { desc = "Go to next review comment" })
	vim.api.nvim_create_user_command("ReviewPrev", M.prev, { desc = "Go to previous review comment" })
	vim.api.nvim_create_user_command("ReviewRefresh", M.refresh, { desc = "Refresh review drift and files" })
	vim.api.nvim_create_user_command("ReviewExport", function(command)
		M.export(command.bang)
	end, { bang = true, desc = "Export review to clipboard" })
	vim.api.nvim_create_user_command("ReviewLinkTuicr", function(command)
		M.link_tuicr(command.args ~= "" and command.args or nil)
	end, { nargs = "?", desc = "Link current review to a TUICR round" })
	vim.api.nvim_create_user_command("ReviewClose", function(command)
		close_workspace(command.bang)
	end, { bang = true, desc = "Close the current review workspace" })
end

local function setup_mappings()
	local mappings = {
		{ "<leader>Ro", "<cmd>ReviewOpen<cr>", "Open default review" },
		{ "<leader>Rs", "<cmd>ReviewScope<cr>", "Review scope/session" },
		{ "<leader>Rf", "<cmd>ReviewFiles<cr>", "Review files" },
		{ "<leader>Rh", "<cmd>ReviewCommits<cr>", "Review commits/history" },
		{ "<leader>Rg", "<cmd>ReviewCode<cr>", "Toggle review code/diff" },
		{ "<leader>Rv", "<cmd>ReviewLayout<cr>", "Toggle review layout" },
		{ "<leader>Rl", "<cmd>ReviewComments<cr>", "List review comments" },
		{ "<leader>Ra", "<cmd>ReviewComment<cr>", "Add review comment" },
		{ "<leader>Rc", "<cmd>ReviewChangeType<cr>", "Change review comment type" },
		{ "<leader>Rd", "<cmd>ReviewDeleteDraft<cr>", "Delete comment on current line" },
		{ "<leader>Rt", "<cmd>ReviewThreads<cr>", "Review threads" },
		{ "<leader>Re", "<cmd>ReviewExport<cr>", "Export review" },
		{ "<leader>Rr", "<cmd>ReviewRefresh<cr>", "Refresh review" },
		{ "<leader>Rq", "<cmd>ReviewClose<cr>", "Close review" },
		{ "]r", "<cmd>ReviewNext<cr>", "Next review comment" },
		{ "[r", "<cmd>ReviewPrev<cr>", "Previous review comment" },
	}
	for _, mapping in ipairs(mappings) do
		vim.keymap.set("n", mapping[1], mapping[2], { silent = true, desc = mapping[3] })
	end
end

local function setup_drift_tracking()
	local group = vim.api.nvim_create_augroup("NvimConfigCodeReview", { clear = true })
	vim.api.nvim_create_autocmd("BufModifiedSet", {
		group = group,
		desc = "Mark working reviews stale when an in-memory source diverges",
		callback = function(event)
			if not vim.bo[event.buf].modified then
				return
			end
			for root, workspace in pairs(workspaces) do
				if
					workspace.scope.kind == "working"
					and not workspace.session.stale
					and buffer_in_root(root, event.buf)
				then
					local session = vim.deepcopy(workspace.session)
					session.stale = true
					save_session(workspace, session)
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		desc = "Persist review state before global Neovim teardown",
		callback = function()
			local editor = require("config.review_editor")
			local saved, composer_err = pcall(editor.persist_active)
			if not saved or composer_err ~= true then
				notify("Could not persist the open review comment before exit", vim.log.levels.ERROR)
			end
			for _, workspace in pairs(workspaces) do
				if workspace.unsaved_error then
					local recovery, recovery_err = persist_unsaved_recovery(workspace)
					if not recovery and #workspace.session.items > 0 then
						notify(
							"Could not persist review recovery before exit: " .. tostring(recovery_err),
							vim.log.levels.ERROR
						)
					end
				end
			end
		end,
	})
end

---Register review commands, mappings, and Diffview callbacks.
function M.setup()
	review_diffview.set_controller({
		code = M.code,
		close = close_workspace,
		refresh = M.refresh,
		decorate_buffer = M.decorate_buffer,
		clear_buffers = function(_, buffers)
			for _, buf in ipairs(buffers or {}) do
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
				end
			end
		end,
		view_opened = function(workspace)
			M.refresh_marks(workspace)
			local threads = workspace.pending_threads
			workspace.pending_threads = nil
			if threads and not restore_review_threads(threads) then
				notify("Could not restore review threads after changing views", vim.log.levels.ERROR)
			end
		end,
		view_enter = function(workspace)
			local checked, err = update_drift(workspace.session)
			if not checked then
				notify("Could not check review drift: " .. error_message(err), vim.log.levels.ERROR)
			elseif checked.stale ~= workspace.session.stale then
				save_session(workspace, checked)
			else
				M.refresh_marks(workspace)
			end
		end,
		view_closed = function(workspace)
			if workspace.suspending or workspace.replacing then
				workspace.replacing = nil
				return
			end
			if workspaces[workspace.root] == workspace then
				workspaces[workspace.root] = nil
			end
			if workspace.unsaved_error then
				local recovery, err = persist_unsaved_recovery(workspace)
				if type(recovery) == "table" then
					notify("Review tab closed; complete recovery remains at " .. recovery.path, vim.log.levels.WARN)
				elseif #workspace.session.items > 0 then
					notify("Review tab closed and recovery failed: " .. tostring(err), vim.log.levels.ERROR)
				end
			end
			review_source.clear_workspace(workspace)
			close_review_threads(workspace)
		end,
	})
	setup_commands()
	setup_mappings()
	setup_drift_tracking()
end

M._parse_open = parse_open
M._workspaces = workspaces

return M
