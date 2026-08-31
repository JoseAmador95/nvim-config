-- Repository/session-scoped standalone native reviews in ordinary Neovim tabs.
local M = {}

local repo = require("native_review.dependencies").get("repo")
local review_changes = require("native_review.changes")
local review_editor = require("native_review.editor")
local review_export = require("native_review.export")
local review_lsp = require("native_review.lsp")
local review_mode = require("native_review.mode")
local review_panel = require("native_review.panel")
local review_presenter = require("native_review.presenter")
local review_scope = require("native_review.scope")
local review_store = require("native_review.store")

local NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_comments")
local PREVIEW_NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_comment_preview")
local REVIEW_TYPES = { "issue", "suggestion", "rationale", "question", "pedantic", "praise" }
local COMMENT_SIGN_TYPES = { "issue", "suggestion", "question", "rationale", "pedantic", "praise" }
local TYPE_SIGNS = {
	issue = { text = "●", highlight = "NvimReviewCommentIssue" },
	suggestion = { text = "◆", highlight = "NvimReviewCommentSuggestion" },
	question = { text = "?", highlight = "NvimReviewCommentQuestion" },
	rationale = { text = "R", highlight = "NvimReviewCommentRationale" },
	pedantic = { text = "·", highlight = "NvimReviewCommentPedantic" },
	praise = { text = "♥", highlight = "NvimReviewCommentPraise" },
}
local TYPE_HIGHLIGHT_LINKS = {
	issue = "DiagnosticSignError",
	suggestion = "DiagnosticSignWarn",
	question = "DiagnosticSignInfo",
	rationale = "Special",
	pedantic = "DiagnosticSignHint",
	praise = "DiagnosticSignOk",
}

local function apply_comment_highlights()
	for _, item_type in ipairs(REVIEW_TYPES) do
		vim.api.nvim_set_hl(
			0,
			TYPE_SIGNS[item_type].highlight,
			{ default = true, link = TYPE_HIGHLIGHT_LINKS[item_type] }
		)
	end
end

apply_comment_highlights()
local comment_highlight_group = vim.api.nvim_create_augroup("NvimReviewCommentHighlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
	group = comment_highlight_group,
	callback = apply_comment_highlights,
})
local HELP_GROUPS = { common = "review", diff_line = "review_diff", file = "review_file" }
local MAPPINGS = {
	{ lhs = "<leader>rr", rhs = "<cmd>ReviewPanel<cr>", desc = "Toggle review panel", help = "common" },
	{ lhs = "<leader>ro", rhs = "<cmd>ReviewOpen<cr>", desc = "Open default review", help = "common" },
	{ lhs = "<leader>rm", rhs = "<cmd>ReviewMode<cr>", desc = "Toggle review mode", help = "common" },
	{ lhs = "<leader>rs", rhs = "<cmd>ReviewScope<cr>", desc = "Review scope/session", help = "common" },
	{ lhs = "<leader>rb", rhs = "<cmd>ReviewScopeBack<cr>", desc = "Return to parent review scope", help = "common" },
	{ lhs = "<leader>rf", rhs = "<cmd>ReviewFiles<cr>", desc = "Focus review files", help = "common" },
	{ lhs = "<leader>rh", rhs = "<cmd>ReviewCommits<cr>", desc = "Focus review commits", help = "common" },
	{ lhs = "<leader>rl", rhs = "<cmd>ReviewComments<cr>", desc = "Focus review comments", help = "common" },
	{ lhs = "<leader>rv", rhs = "<cmd>ReviewLayout<cr>", desc = "Toggle review layout", help = "common" },
	{ lhs = "<leader>rw", rhs = "<cmd>ReviewContext<cr>", desc = "Toggle review context", help = "common" },
	{ lhs = "<leader>ri", rhs = "<cmd>ReviewInlineComments<cr>", desc = "Toggle inline comments", help = "common" },
	{ lhs = "<leader>rg", rhs = "<cmd>ReviewCode<cr>", desc = "Focus reviewed code", help = "common" },
	{ lhs = "<leader>ra", rhs = "<cmd>ReviewComment<cr>", desc = "Add line/range comment", help = "diff_line" },
	{ lhs = "<leader>rA", rhs = "<cmd>ReviewFileComment<cr>", desc = "Add file comment", help = "file" },
	{ lhs = "<leader>rR", rhs = "<cmd>ReviewGeneralComment<cr>", desc = "Add review-level comment", help = "common" },
	{ lhs = "<leader>re", rhs = "<cmd>ReviewEdit<cr>", desc = "Edit review comment", help = "common" },
	{ lhs = "<leader>rc", rhs = "<cmd>ReviewChangeType<cr>", desc = "Change comment type", help = "diff_line" },
	{ lhs = "<leader>rd", rhs = "<cmd>ReviewDeleteDraft<cr>", desc = "Delete review comment", help = "diff_line" },
	{ lhs = "<leader>rp", rhs = "<cmd>ReviewReply<cr>", desc = "Reply to review comment", help = "common" },
	{ lhs = "<leader>rt", rhs = "<cmd>ReviewToggleResolve<cr>", desc = "Resolve or reopen comment", help = "common" },
	{ lhs = "<leader>rE", rhs = "<cmd>ReviewExport<cr>", desc = "Export review", help = "common" },
	{ lhs = "<leader>ru", rhs = "<cmd>ReviewRefresh<cr>", desc = "Refresh review", help = "common" },
	{ lhs = "<leader>rq", rhs = "<cmd>ReviewClose<cr>", desc = "Close review", help = "common" },
	{ lhs = "]r", rhs = "<cmd>ReviewNext<cr>", desc = "Next review comment", help = "common" },
	{ lhs = "[r", rhs = "<cmd>ReviewPrev<cr>", desc = "Previous review comment", help = "common" },
}

local workspaces = {}
local active
local suspended
local scope_history = {}
local setup_done = false
local inline_preview

local function notify(message, level)
	vim.notify(tostring(message), level or vim.log.levels.INFO, { title = "Review" })
end

local function message(err)
	return type(err) == "table" and (err.message or err.code or vim.inspect(err)) or tostring(err)
end

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
	return type(tab) == "number" and vim.api.nvim_tabpage_is_valid(tab)
end

local function clear_inline_preview()
	if inline_preview and valid_buf(inline_preview.buf) then
		pcall(vim.api.nvim_buf_clear_namespace, inline_preview.buf, PREVIEW_NAMESPACE, 0, -1)
	end
	inline_preview = nil
end

local function buffer_text(buf)
	local separator = ({ dos = "\r\n", mac = "\r" })[vim.bo[buf].fileformat] or "\n"
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), separator)
	return vim.bo[buf].endofline and text .. separator or text
end

local function null(value)
	return value == nil or value == vim.NIL
end

local function key(root, id)
	return root .. "\0" .. id
end

local function workspace_key(workspace)
	return key(workspace.root, workspace.session.id)
end

local function registered(workspace)
	return workspace and workspaces[workspace_key(workspace)] == workspace
end

local function current_workspace()
	if registered(active) then
		return active
	end
	active = nil
	return nil
end

local function unsaved_transition_error(action)
	local workspace = current_workspace()
	if not workspace or not workspace.unsaved_error then
		return nil
	end
	return "active review has unsaved in-memory changes; cannot "
		.. action
		.. ". Export it if needed, or use :ReviewClose! to discard it only after verified recovery"
end

local function composer_transition_error(action)
	if review_editor.has_active() then
		return "review composer has unsent text; cannot " .. action
	end
	return nil
end

local function clear_scope_history()
	for index = #scope_history, 1, -1 do
		table.remove(scope_history, index)
	end
end

local function workspace_for_key(expected)
	local workspace = workspaces[expected]
	return registered(workspace) and workspace or nil
end

local function active_for_key(expected, action)
	local workspace = current_workspace()
	if not workspace or workspace_key(workspace) ~= expected then
		notify("Active review changed while " .. action .. "; no changes were made", vim.log.levels.WARN)
		return nil
	end
	return workspace
end

local function find_item(session, id)
	for _, item in ipairs(session and session.items or {}) do
		if item.id == id then
			return item
		end
	end
	return nil
end

local function find_entry(workspace, identity)
	for _, entry in ipairs(workspace.model.entries or {}) do
		if entry.identity == identity then
			return entry
		end
	end
	return nil
end

local function status_side(workspace, entry)
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	if presentation and presentation.entry == entry then
		local current = vim.api.nvim_get_current_win()
		for _, name in ipairs({ "inline", "left", "right" }) do
			local side = presentation[name]
			if side and side.win == current then
				if side.side == "unified" then
					local display_line = vim.api.nvim_win_get_cursor(current)[1]
					local source_ref =
						review_presenter.source_at(workspace.mode_state, display_line, presentation.generation)
					return source_ref and source_ref.side or "new"
				end
				return side.side
			end
		end
		if presentation.target and presentation.target.side then
			return presentation.target.side
		end
	end
	return entry.deleted and "old" or "new"
end

function M.status()
	local workspace = current_workspace()
	if not workspace then
		return { active = false, mode_on = false }
	end
	local status = {
		active = true,
		mode_on = workspace.mode_on == true,
		scope_kind = workspace.scope and workspace.scope.kind or nil,
		scope_label = workspace.scope and workspace.scope.label or nil,
		layout = workspace.layout,
		context = workspace.context,
		inline_comments = workspace.inline_comments ~= false,
	}
	local entry = find_entry(workspace, workspace.entry_identity)
	if entry then
		local side = status_side(workspace, entry)
		status.entry = {
			identity = entry.identity,
			path = side == "old" and (entry.old_path or entry.path) or (entry.new_path or entry.path),
			layer = entry.layer or "history",
			side = side == "old" and "OLD" or "CURRENT",
		}
	end
	return status
end

local function emit_changed()
	vim.api.nvim_exec_autocmds("User", {
		pattern = "NvimConfigReviewChanged",
		data = vim.deepcopy(M.status()),
		modeline = false,
	})
end

local function root_for_command()
	local root = repo.current_root(0)
	local workspace = current_workspace()
	return root or (workspace and workspace.root)
end

local function buffer_in_root(root, buf)
	if not valid_buf(buf) or vim.bo[buf].buftype ~= "" then
		return false
	end
	local path = vim.api.nvim_buf_get_name(buf)
	return path ~= "" and repo.contains(root, path)
end

local function update_panel(workspace)
	if workspace.panel then
		review_panel.refresh(workspace.panel, workspace)
	end
end

local function refresh_trouble()
	local ok, trouble = pcall(require, "trouble")
	if ok and type(trouble.refresh) == "function" then
		pcall(trouble.refresh, "review")
	end
end

local function save_verified_recovery(root, session, markdown)
	local receipt, save_err = review_store.save_recovery(root, session, markdown)
	if not receipt then
		return nil, save_err
	end
	local verified, verify_err = review_store.verify_recovery(root, receipt)
	if not verified then
		return nil, "recovery verification failed: " .. tostring(verify_err)
	end
	return receipt
end

local function recovery(workspace)
	if not workspace.unsaved_error then
		return true
	end
	local markdown, render_err = review_export.render_recovery(workspace.session)
	if not markdown then
		return nil, render_err
	end
	local receipt, err = save_verified_recovery(workspace.root, workspace.session, markdown)
	workspace.recovery = receipt
	return receipt, err
end

local function persistence_error(workspace, action, err)
	local detail = message(err)
	notify("Could not " .. action .. ": " .. detail .. "; live review was kept unchanged", vim.log.levels.ERROR)
	return nil, detail
end

local function matching_persisted_snapshot(workspace)
	local saved, load_err = review_store.load(workspace.root, workspace.session.id)
	if not saved then
		return nil, "could not load the persisted review: " .. tostring(load_err)
	end
	local live = workspace.session
	local saved_scope_id = type(saved) == "table" and type(saved.scope) == "table" and saved.scope.id or nil
	local live_scope_id = type(live.scope) == "table" and live.scope.id or nil
	if
		type(saved) ~= "table"
		or saved.id ~= live.id
		or saved.repo_root ~= workspace.root
		or saved_scope_id ~= live_scope_id
	then
		return nil, "persisted review identity does not match the live workspace"
	end
	if saved.revision ~= live.revision then
		return nil,
			("review changed in another Neovim (live revision %s, persisted revision %s)"):format(
				tostring(live.revision),
				tostring(saved.revision)
			)
	end
	if not vim.deep_equal(saved, live) then
		return nil, "persisted review content does not match the live revision"
	end
	return vim.deepcopy(saved)
end

local function verified_persisted_snapshot(workspace, action)
	local saved, err = matching_persisted_snapshot(workspace)
	if not saved then
		return persistence_error(workspace, action, err)
	end
	return saved
end

local function save_mutation(workspace, changed)
	local saved, err = review_store.save(workspace.root, changed)
	if not saved then
		workspace.session = changed
		workspace.scope = changed.scope
		workspace.unsaved_error = err
		local receipt, recovery_err = recovery(workspace)
		local suffix = type(receipt) == "table" and "; recovery saved to " .. receipt.path
			or "; recovery failed: " .. tostring(recovery_err)
		notify("Could not save review: " .. tostring(err) .. suffix, vim.log.levels.ERROR)
		update_panel(workspace)
		M.refresh_marks(workspace)
		refresh_trouble()
		return nil, err
	end
	workspace.session = saved
	workspace.scope = saved.scope
	workspace.unsaved_error = nil
	workspace.recovery = nil
	update_panel(workspace)
	M.refresh_marks(workspace)
	refresh_trouble()
	return true
end

local function stale_now(workspace)
	if workspace.scope.kind ~= "working" then
		return false
	end
	local drift, err = review_scope.detect_drift(workspace.scope)
	if not drift then
		return nil, message(err)
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if valid_buf(buf) and vim.bo[buf].modified and buffer_in_root(workspace.root, buf) then
			return true
		end
	end
	return drift.stale
end

local function session_has_stale_location(session)
	if session.stale then
		return true
	end
	for _, item in ipairs(session.items or {}) do
		if item.anchor and item.anchor.stale then
			return true
		end
	end
	return false
end

local function mark_stale(workspace)
	if workspace.session.stale then
		return true
	end
	local changed = vim.deepcopy(workspace.session)
	changed.stale = true
	return save_mutation(workspace, changed)
end

local function allow_mutation(workspace)
	if not registered(workspace) then
		notify("No active review", vim.log.levels.ERROR)
		return false
	end
	if workspace.unsaved_error then
		notify("Review has an unsaved conflict; reopen the exact session", vim.log.levels.ERROR)
		return false
	end
	local stale, err = stale_now(workspace)
	if stale == nil then
		notify("Could not check review drift: " .. err, vim.log.levels.ERROR)
		return false
	end
	if stale or workspace.session.stale then
		if stale then
			mark_stale(workspace)
		end
		notify("Working review is stale; open a new exact scope before changing comments", vim.log.levels.ERROR)
		return false
	end
	return true
end

local function first_identity(model, preferred)
	if preferred then
		for _, entry in ipairs(model.entries or {}) do
			if entry.identity == preferred then
				return preferred
			end
		end
	end
	return model.entries[1] and model.entries[1].identity or nil
end

local open_drilldown

local function panel_callbacks(expected)
	local function present(identity)
		local workspace = workspace_for_key(expected)
		local shown, err = M.present(identity, expected)
		if not shown then
			notify(err, vim.log.levels.ERROR)
			return nil
		end
		local target = review_presenter.current_target(workspace.mode_state)
		review_panel.hide(workspace.panel)
		if target and valid_win(target.win) then
			vim.api.nvim_set_current_win(target.win)
		end
		return workspace
	end
	return {
		select_entry = function(identity)
			present(identity)
		end,
		file_comment = function(identity)
			if present(identity) then
				M.file_comment()
			end
		end,
		general_comment = M.general_comment,
		apply_commit = function(first, second)
			local workspace = workspace_for_key(expected)
			if not workspace then
				return
			end
			local request, err = review_changes.selection_request(workspace.model, first, second)
			if request then
				open_drilldown(request, workspace)
			else
				notify(message(err), vim.log.levels.ERROR)
			end
		end,
		scope_back = function()
			return M.scope_back(expected)
		end,
		jump_comment = M.jump,
		edit_comment = M.edit,
		delete_comment = M.delete,
		change_type = M.change_type,
		reply_comment = M.reply,
		toggle_resolution = M.toggle_resolution,
	}
end

local function disable_ui(workspace)
	clear_inline_preview()
	if workspace.panel then
		review_panel.hide(workspace.panel)
	end
	if workspace.mode_state then
		review_mode.disable(workspace.mode_state)
	end
	workspace.mode_on = false
end

local function focus_snapshot(workspace)
	local win = vim.api.nvim_get_current_win()
	local value = {
		kind = "window",
		tab = vim.api.nvim_get_current_tabpage(),
		win = win,
		buf = vim.api.nvim_get_current_buf(),
	}
	vim.api.nvim_win_call(win, function()
		value.view = vim.fn.winsaveview()
	end)
	for name, pane in pairs(workspace and workspace.panel and workspace.panel.panes or {}) do
		if pane.win == win then
			value.kind = "panel"
			value.pane = name
			return value
		end
	end
	local presentation = workspace and workspace.mode_state and workspace.mode_state.presentation
	for _, name in ipairs({ "inline", "left", "right" }) do
		local side = presentation and presentation[name]
		if side and side.win == win then
			value.kind = "presentation"
			value.side = side.side
			return value
		end
	end
	return value
end

local function set_focus(win, snapshot, require_same_buffer)
	if not valid_win(win) then
		return false
	end
	local tab = vim.api.nvim_win_get_tabpage(win)
	if valid_tab(tab) then
		vim.api.nvim_set_current_tabpage(tab)
	end
	vim.api.nvim_set_current_win(win)
	if snapshot.view and (not require_same_buffer or vim.api.nvim_win_get_buf(win) == snapshot.buf) then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview(snapshot.view)
		end)
	end
	return true
end

local function restore_focus(workspace, snapshot)
	if not snapshot then
		return false
	end
	if snapshot.kind == "panel" and workspace and review_panel.is_open(workspace.panel) then
		return review_panel.focus(workspace.panel, snapshot.pane)
	elseif snapshot.kind == "presentation" and workspace then
		local presentation = workspace.mode_state.presentation
		for _, name in ipairs({ "inline", "left", "right" }) do
			local side = presentation and presentation[name]
			if side and side.side == snapshot.side and set_focus(side.win, snapshot, false) then
				return true
			end
		end
	elseif snapshot.kind == "window" and set_focus(snapshot.win, snapshot, true) then
		return true
	end
	local target = workspace and review_presenter.current_target(workspace.mode_state) or nil
	return target and set_focus(target.win, snapshot, false) or false
end

local function restore_activation_origin(workspace, snapshot)
	if snapshot.kind == "window" and set_focus(snapshot.win, snapshot, true) then
		return
	end
	if
		snapshot.kind == "panel"
		and workspace
		and workspace.panel
		and set_focus(workspace.panel.source_win, snapshot, true)
	then
		return
	end
	if workspace and workspace.mode_state then
		set_focus(workspace.mode_state.origin.win, snapshot, true)
	end
end

local function ui_snapshot(workspace)
	return {
		entry_identity = workspace.entry_identity,
		layout = workspace.layout,
		context = workspace.context,
		inline_comments = workspace.inline_comments ~= false,
		mode_on = workspace.mode_on == true,
		panel_visible = workspace.panel and review_panel.is_open(workspace.panel) or false,
		panel_focus = workspace.panel and workspace.panel.focused or "files",
		focus = focus_snapshot(workspace),
	}
end

local function restore_ui(workspace, snapshot)
	active = workspace
	workspace.entry_identity = snapshot.entry_identity
	workspace.layout = snapshot.layout
	workspace.context = snapshot.context
	workspace.inline_comments = snapshot.inline_comments
	if snapshot.mode_on then
		local enabled, enable_err = review_mode.enable(workspace.mode_state)
		if not enabled then
			return nil, enable_err
		end
		workspace.mode_on = true
		if workspace.entry_identity then
			local shown, show_err = M.present(workspace.entry_identity, workspace_key(workspace), { emit = false })
			if not shown then
				review_mode.disable(workspace.mode_state)
				workspace.mode_on = false
				return nil, show_err
			end
		end
	else
		workspace.mode_on = false
	end
	if snapshot.panel_visible and not review_panel.open(workspace.panel, snapshot.panel_focus) then
		return nil, "could not restore the review panel"
	end
	restore_focus(workspace, snapshot.focus)
	M.refresh_marks(workspace)
	return true
end

local function activate(root, session, model, options)
	local blocked = unsaved_transition_error("replace it") or composer_transition_error("replace the active review")
	if blocked then
		return nil, blocked
	end
	local expected = key(root, session.id)
	local existing = workspaces[expected]
	local previous = current_workspace()
	local opening_focus = focus_snapshot(previous)
	local previous_ui = previous and ui_snapshot(previous) or nil
	if previous then
		disable_ui(previous)
	end
	restore_activation_origin(previous, opening_focus)
	local preferences = options and options.preferences or nil
	local inline_comments = preferences and preferences.inline_comments
	if inline_comments == nil then
		inline_comments = not existing or existing.inline_comments ~= false
	end
	local workspace = {
		root = root,
		layout = preferences and preferences.layout or (existing and existing.layout or "inline"),
		context = preferences and preferences.context or (existing and existing.context or "hunks"),
		inline_comments = inline_comments,
		scope = session.scope,
		session = session,
		model = model,
		entry_identity = first_identity(model, existing and existing.entry_identity),
	}
	workspace.mode_state = review_mode.new(workspace)
	workspace.mode_on = true
	workspace.panel = review_panel.new(workspace, panel_callbacks(expected))
	workspaces[expected] = workspace
	active = workspace

	local function rollback(err)
		review_panel.close(workspace.panel)
		review_mode.disable(workspace.mode_state)
		workspaces[expected] = existing
		active = previous
		if previous then
			local restored, restore_err = restore_ui(previous, previous_ui)
			if not restored then
				disable_ui(previous)
				return nil, tostring(err) .. "; previous review could not be restored: " .. tostring(restore_err)
			end
		else
			M.refresh_marks(nil)
		end
		return nil, err
	end

	local enabled, enable_err = review_mode.enable(workspace.mode_state)
	if not enabled then
		return rollback(enable_err)
	end
	if workspace.entry_identity then
		local shown, show_err = M.present(workspace.entry_identity, expected, { emit = false })
		if not shown then
			return rollback(show_err)
		end
	end
	if not review_panel.open(workspace.panel, "files") then
		return rollback("could not open the review panel")
	end
	M.refresh_marks(workspace)
	return workspace
end

local function open_resolved(root, scope, supplied, options)
	local blocked = unsaved_transition_error("open another review") or composer_transition_error("open another review")
	if blocked then
		return nil, blocked
	end
	local session = supplied
	local created = false
	if not session then
		local load_err
		session, load_err = review_store.load(root, scope.id)
		if not session and load_err and not tostring(load_err):find("missing", 1, true) then
			return nil, load_err
		end
		if not session then
			session, load_err = review_store.new(root, scope)
			created = true
		end
		if not session then
			return nil, load_err
		end
	end
	if session.scope.kind == "working" and session.stale then
		return nil, "saved working review is stale; use :ReviewOpen working for a new exact scope"
	end
	local model, model_err = review_changes.build(root, scope)
	if not model then
		return nil, message(model_err)
	end
	if created then
		local saved, save_err = review_store.save(root, session)
		if not saved then
			return nil, save_err
		end
		session = saved
	end
	return activate(root, session, model, options)
end

local function open_request(request, root, options)
	local blocked = unsaved_transition_error("open another review") or composer_transition_error("open another review")
	if blocked then
		notify("Could not open review: " .. blocked, vim.log.levels.ERROR)
		return nil, blocked
	end
	root = root or root_for_command()
	if not root then
		notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		return nil
	end
	local scope, scope_err = review_scope.resolve(root, request or { kind = "branch" })
	if not scope then
		notify("Could not resolve review scope: " .. message(scope_err), vim.log.levels.ERROR)
		return nil
	end
	local workspace, err = open_resolved(root, scope, nil, options)
	if not workspace then
		notify("Could not open review: " .. tostring(err), vim.log.levels.ERROR)
	end
	return workspace, err
end

function M.open(request, root)
	local workspace, err = open_request(request, root)
	if workspace then
		clear_scope_history()
		emit_changed()
	end
	return workspace, err
end

open_drilldown = function(request, parent)
	if not registered(parent) or parent ~= current_workspace() then
		return nil, "review session is no longer active"
	end
	local blocked = unsaved_transition_error("open a nested review scope")
		or composer_transition_error("open a nested review scope")
	if blocked then
		notify("Could not open review: " .. blocked, vim.log.levels.ERROR)
		return nil, blocked
	end
	local parent_ui = ui_snapshot(parent)
	local workspace, err = open_request(request, parent.root, {
		preferences = {
			layout = parent.layout,
			context = parent.context,
			inline_comments = parent.inline_comments ~= false,
		},
	})
	if not workspace then
		return nil, err
	end
	if workspace_key(workspace) ~= workspace_key(parent) then
		scope_history[#scope_history + 1] = { workspace = parent, ui_snapshot = parent_ui }
	end
	emit_changed()
	return workspace
end

function M.scope_back(expected)
	local frame = scope_history[#scope_history]
	if not frame then
		notify("Already at full review scope")
		return false
	end
	local child = current_workspace()
	if expected and (not child or workspace_key(child) ~= expected) then
		notify("Active review changed while returning to the parent scope; no changes were made", vim.log.levels.WARN)
		return false
	end
	local blocked = unsaved_transition_error("return to the parent review scope")
		or composer_transition_error("return to the parent review scope")
	if blocked then
		notify("Could not return to parent review scope: " .. blocked, vim.log.levels.ERROR)
		return nil, blocked
	end
	if not child then
		return nil, "review session is no longer active"
	end

	local child_ui = ui_snapshot(child)
	disable_ui(child)
	restore_activation_origin(child, child_ui.focus)
	local parent = frame.workspace
	local restored, restore_err
	if registered(parent) then
		restored, restore_err = restore_ui(parent, frame.ui_snapshot)
	else
		restore_err = "parent review session is no longer registered"
	end
	if not restored then
		if registered(parent) then
			disable_ui(parent)
		end
		active = child
		local rolled_back, rollback_err = restore_ui(child, child_ui)
		if not rolled_back then
			disable_ui(child)
			return nil,
				("could not restore parent review scope: %s; child review could not be restored: %s"):format(
					tostring(restore_err),
					tostring(rollback_err)
				)
		end
		return nil, "could not restore parent review scope: " .. tostring(restore_err)
	end
	table.remove(scope_history)
	emit_changed()
	return true
end

function M.present(identity, expected, options)
	clear_inline_preview()
	local workspace = expected and workspace_for_key(expected) or current_workspace()
	if not workspace or workspace ~= current_workspace() then
		return nil, "review session is no longer active"
	end
	local entry = find_entry(workspace, identity)
	if not entry then
		return nil, "review entry is no longer part of the exact model"
	end
	local enabled_for_present = false
	if not workspace.mode_on then
		local enabled, err = review_mode.enable(workspace.mode_state)
		if not enabled then
			return nil, err
		end
		workspace.mode_on = true
		enabled_for_present = true
	end
	local shown, err = review_presenter.show(workspace.mode_state, entry, {
		layout = workspace.layout,
		context = workspace.context,
	})
	if not shown then
		if enabled_for_present then
			review_mode.disable(workspace.mode_state)
			workspace.mode_on = false
		end
		return nil, err
	end
	local target = review_presenter.current_target(workspace.mode_state)
	review_panel.update_source(workspace.panel, target and target.win or nil)
	workspace.entry_identity = identity
	update_panel(workspace)
	M.refresh_marks(workspace)
	if not options or options.emit ~= false then
		emit_changed()
	end
	return true
end

function M.mode(value)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	value = value or "toggle"
	if value == "toggle" then
		value = workspace.mode_on and "off" or "on"
	end
	if value == "off" then
		clear_inline_preview()
		if workspace.mode_on then
			review_mode.disable(workspace.mode_state)
			workspace.mode_on = false
		end
		emit_changed()
		return true
	elseif value ~= "on" then
		notify("Usage: ReviewMode [on|off|toggle]", vim.log.levels.ERROR)
		return nil
	end
	local enabled_for_mode = false
	if not workspace.mode_on then
		local enabled, err = review_mode.enable(workspace.mode_state)
		if not enabled then
			notify(err, vim.log.levels.ERROR)
			return nil
		end
		workspace.mode_on = true
		enabled_for_mode = true
	end
	if workspace.entry_identity then
		local shown, err = M.present(workspace.entry_identity, nil, { emit = false })
		if not shown then
			if enabled_for_mode then
				review_mode.disable(workspace.mode_state)
				workspace.mode_on = false
			end
			notify(err, vim.log.levels.ERROR)
			return nil
		end
	end
	emit_changed()
	return true
end

function M.panel(action)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return false
	end
	action = action or "toggle"
	if action == "toggle" then
		return review_panel.toggle(workspace.panel)
	elseif action == "open" then
		return review_panel.open(workspace.panel)
	elseif action == "close" then
		return review_panel.hide(workspace.panel)
	elseif action == "files" or action == "commits" or action == "comments" then
		return review_panel.focus(workspace.panel, action)
	end
	notify("Usage: ReviewPanel [toggle|open|close|files|commits|comments]", vim.log.levels.ERROR)
	return false
end

function M.files()
	return M.panel("files")
end

function M.commits()
	return M.panel("commits")
end

function M.comments()
	return M.panel("comments")
end

M.threads = M.comments

local function presentation_option(name, value, allowed)
	local workspace = current_workspace()
	if not workspace then
		return nil, "No active review"
	end
	if not value or value == "" then
		value = workspace[name] == allowed[1] and allowed[2] or allowed[1]
	end
	if value ~= allowed[1] and value ~= allowed[2] then
		return nil, name .. " must be " .. allowed[1] .. " or " .. allowed[2]
	end
	local previous = workspace[name]
	workspace[name] = value
	if workspace.mode_on and workspace.entry_identity then
		local shown, err = M.present(workspace.entry_identity, nil, { emit = false })
		if not shown then
			workspace[name] = previous
			return nil, err
		end
	end
	update_panel(workspace)
	emit_changed()
	return true
end

function M.layout(value)
	local ok, err = presentation_option("layout", value, { "inline", "split" })
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
	return ok, err
end

function M.context(value)
	local ok, err = presentation_option("context", value, { "hunks", "full" })
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
	return ok, err
end

function M.inline_comments(value)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	value = value and value ~= "" and value or "toggle"
	if value == "toggle" then
		value = workspace.inline_comments == false and "on" or "off"
	end
	if value ~= "on" and value ~= "off" then
		notify("Usage: ReviewInlineComments [on|off|toggle]", vim.log.levels.ERROR)
		return nil
	end
	workspace.inline_comments = value == "on"
	clear_inline_preview()
	review_presenter.refresh_winbars(workspace.mode_state)
	emit_changed()
	return true
end

function M.code()
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return
	end
	local target = review_presenter.current_target(workspace.mode_state)
	if target and valid_win(target.win) then
		vim.api.nvim_set_current_win(target.win)
	elseif workspace.entry_identity then
		local shown, err = M.present(workspace.entry_identity)
		if not shown then
			notify(err, vim.log.levels.ERROR)
		end
	end
end

local function presentation_target(workspace, win)
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	if not presentation then
		return nil
	end
	win = win or vim.api.nvim_get_current_win()
	for _, name in ipairs({ "left", "right", "inline" }) do
		local side = presentation[name]
		if side and side.win == win then
			if side.side == "unified" and presentation.projection then
				return {
					entry = presentation.entry,
					buf = side.buf,
					win = side.win,
					generation = presentation.generation,
					layer = presentation.entry.layer or "history",
					unified = true,
				}
			end
			local old = side.side == "old"
			return {
				entry = presentation.entry,
				buf = side.buf,
				win = side.win,
				path = old and presentation.entry.old_path or presentation.entry.new_path,
				side = old and "left" or "right",
				layer = presentation.entry.layer or "history",
			}
		end
	end
	return nil
end

local function relative_path(workspace, buf)
	if not valid_buf(buf) or vim.bo[buf].buftype ~= "" then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(buf)
	return name ~= "" and repo.relative_existing(workspace.root, name) or nil
end

local function normal_targets(workspace, buf, win)
	local path = relative_path(workspace, buf)
	local targets = {}
	if not path then
		return targets
	end
	if vim.bo[buf].modified then
		return targets
	end
	local contents = buffer_text(buf)
	for _, entry in ipairs(workspace.model.entries or {}) do
		if
			entry.new_path == path
			and not entry.deleted
			and type(entry.new_text) == "string"
			and contents == entry.new_text
		then
			targets[#targets + 1] = {
				entry = entry,
				buf = buf,
				win = win,
				path = path,
				side = "right",
				layer = entry.layer or "history",
			}
		elseif
			entry.old_path == path
			and entry.deleted
			and type(entry.old_text) == "string"
			and contents == entry.old_text
		then
			targets[#targets + 1] = {
				entry = entry,
				buf = buf,
				win = win,
				path = path,
				side = "left",
				layer = entry.layer or "history",
			}
		end
	end
	return targets
end

local function choose_target(workspace, captured, callback)
	if not valid_buf(captured.buf) then
		callback(nil, "review target changed before it could be captured")
		return
	end
	local captured_visible = valid_win(captured.win) and vim.api.nvim_win_get_buf(captured.win) == captured.buf
	local target = captured_visible and presentation_target(workspace, captured.win) or nil
	if target and target.buf == captured.buf then
		callback(target)
		return
	end
	local targets = normal_targets(workspace, captured.buf, captured.win)
	if #targets == 0 then
		callback(nil, "current buffer is not represented in the active review")
	elseif #targets == 1 then
		callback(targets[1])
	else
		vim.ui.select(targets, {
			prompt = "Review layer",
			format_item = function(value)
				return string.format("[%s] %s", value.layer, value.path)
			end,
		}, function(selected)
			callback(selected, selected and nil or "review layer selection was cancelled")
		end)
	end
end

local function source_lines(entry, side)
	local text = side == "left" and entry.old_text or entry.new_text
	if type(text) ~= "string" or text == "" then
		return {}
	end
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	if text:sub(-1) == "\n" then
		text = text:sub(1, -2)
	end
	return vim.split(text, "\n", { plain = true })
end

local function context_for_entry(entry, side, first, last)
	local lines = source_lines(entry, side)
	local count = #lines
	local context_first = math.max(1, first - 3)
	local context_last = math.min(count, last + 3)
	local context = table.concat(vim.list_slice(lines, context_first, context_last), "\n")
	if context == "" then
		context = "\n"
	end
	if #context > review_store.max_anchor_context then
		context = table.concat(vim.list_slice(lines, first, last), "\n")
		local truncated, truncate_err = review_store.truncate_utf8(context, review_store.max_anchor_context)
		if not truncated then
			return nil, "could not capture valid UTF-8 review context: " .. tostring(truncate_err)
		end
		context = truncated ~= "" and truncated or "\n"
	end
	return context
end

local function unified_file_source(workspace, target, display_line, preferred_side)
	local source_ref, source_err = review_presenter.source_at(workspace.mode_state, display_line, target.generation)
	if not source_ref then
		return nil, source_err
	end
	local preferred = preferred_side == "left" and "old" or preferred_side == "right" and "new" or nil
	local side
	if source_ref.old_path and not source_ref.new_path then
		side = "old"
	elseif source_ref.new_path and not source_ref.old_path then
		side = "new"
	elseif preferred and source_ref[preferred .. "_path"] then
		side = preferred
	else
		side = "new"
	end
	local path = source_ref[side .. "_path"]
	if not path then
		return nil, "display row has no file on the selected source side"
	end
	return {
		display_first = display_line,
		display_last = display_line,
		entry = source_ref.entry,
		layer = source_ref.layer,
		path = path,
		side = side,
	}
end

local function resolve_capture(workspace, target, kind, first, last, preferred_side)
	first, last = math.min(first, last), math.max(first, last)
	if target.unified then
		local resolved, resolve_err
		if kind == "file" then
			resolved, resolve_err = unified_file_source(workspace, target, first, preferred_side)
		else
			resolved, resolve_err =
				review_presenter.resolve_range(workspace.mode_state, first, last, target.generation, preferred_side)
		end
		if not resolved then
			return nil, resolve_err
		end
		resolved.anchor_side = resolved.anchor_side or (resolved.side == "old" and "left" or "right")
		resolved.entry = resolved.entry or target.entry
		return resolved
	end

	local lines = source_lines(target.entry, target.side)
	if #lines == 0 and kind == "range" then
		return nil, "empty review content has no line anchor; use a file comment"
	end
	local resolved_first = math.max(1, math.min(first, math.max(1, #lines)))
	local resolved_last = math.max(resolved_first, math.min(last, math.max(1, #lines)))
	return {
		anchor_side = target.side,
		display_first = resolved_first,
		display_last = resolved_last,
		end_line = resolved_last,
		entry = target.entry,
		layer = target.layer,
		path = target.path,
		start_line = resolved_first,
	}
end

local function make_anchor(workspace, target, kind, first, last, preferred_side)
	local resolved, resolve_err = resolve_capture(workspace, target, kind, first, last, preferred_side)
	if not resolved then
		return nil, resolve_err
	end
	local anchor = {
		kind = kind,
		path = resolved.path,
		side = resolved.anchor_side,
		layer = resolved.layer,
		stale = workspace.session.stale,
	}
	if kind == "range" then
		anchor.start_line = resolved.start_line
		anchor.end_line = resolved.end_line
		local context, context_err = context_for_entry(resolved.entry, anchor.side, anchor.start_line, anchor.end_line)
		if not context then
			return nil, context_err
		end
		anchor.context = context
		anchor.context_hash = vim.fn.sha256(anchor.context):lower()
	end
	return anchor, nil, {
		first = resolved.display_first,
		last = resolved.display_last,
	}
end

local function displayed_anchor(workspace, anchor)
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	if not presentation then
		return nil, "review presentation is unavailable"
	end
	if presentation.projection and presentation.inline then
		local rows, rows_err = review_presenter.rows_for_anchor(workspace.mode_state, anchor, presentation.generation)
		if not rows then
			return nil, rows_err
		end
		local revealed, reveal_err = review_presenter.reveal_rows(workspace.mode_state, rows, presentation.generation)
		if not revealed then
			return nil, reveal_err
		end
		return {
			buf = presentation.inline.buf,
			first = rows[1],
			last = rows[#rows],
			rows = rows,
			win = presentation.inline.win,
		}
	end
	local side = anchor.side == "left" and presentation.left or presentation.right or presentation.inline
	if not side or not valid_win(side.win) or not valid_buf(side.buf) then
		return nil, "comment side is unavailable"
	end
	local first = anchor.kind == "range" and anchor.start_line or 1
	local last = anchor.kind == "range" and (anchor.end_line or first) or first
	return { buf = side.buf, first = first, last = last, win = side.win }
end

local function capture(first, last)
	return {
		win = vim.api.nvim_get_current_win(),
		buf = vim.api.nvim_get_current_buf(),
		first = first,
		last = last,
	}
end

local function composer_recovery(workspace, title, body, anchor)
	local markdown = review_export.render(workspace.session, true) or "# Code review recovery"
	local text = table.concat({ markdown, "", "## Interrupted composer", "", title, "", body }, "\n")
	local receipt, err = save_verified_recovery(workspace.root, workspace.session, text)
	if not receipt then
		notify("Could not save interrupted review comment: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	workspace.recovery = receipt
	return true
end

local function compose(workspace, options, callback)
	clear_inline_preview()
	options.recover = function(body, selected_type)
		return composer_recovery(workspace, options.title .. " " .. tostring(selected_type or ""), body, options.anchor)
	end
	return review_editor.compose(options, callback)
end

local editor_source

local function valid_type(value)
	return value == nil or vim.tbl_contains(REVIEW_TYPES, value)
end

local function add_from_capture(workspace, captured, requested_type, kind)
	if not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	choose_target(workspace, captured, function(target, target_err)
		workspace = active_for_key(expected, "selecting a review target")
		if not workspace then
			return
		end
		if not target then
			notify(target_err, vim.log.levels.ERROR)
			return
		end
		local anchor, anchor_err, display = make_anchor(workspace, target, kind, captured.first, captured.last)
		if not anchor then
			notify(anchor_err, vim.log.levels.ERROR)
			return
		end
		local target_visible = valid_win(target.win) and vim.api.nvim_win_get_buf(target.win) == target.buf
		if not target_visible or review_panel.is_open(workspace.panel) then
			local shown, show_err = M.present(target.entry.identity, expected)
			if not shown then
				notify(show_err, vim.log.levels.ERROR)
				return
			end
			local presented, display_err = displayed_anchor(workspace, anchor)
			review_panel.hide(workspace.panel)
			if not presented then
				notify(display_err, vim.log.levels.ERROR)
				return
			end
			target = presented
			display = { first = presented.first, last = presented.last }
		end
		if
			not valid_win(target.win)
			or not valid_buf(target.buf)
			or vim.api.nvim_win_get_buf(target.win) ~= target.buf
		then
			notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
			return
		end
		vim.api.nvim_set_current_win(target.win)
		vim.api.nvim_win_set_cursor(target.win, { display.last, 0 })
		compose(workspace, {
			title = anchor.kind == "file" and "New file comment" or "New",
			type_cycle = REVIEW_TYPES,
			selected_type = requested_type or REVIEW_TYPES[1],
			source_win = target.win,
			anchor_line = anchor.kind == "range" and display.last or nil,
			anchor_range = anchor.kind == "range" and { first = display.first, last = display.last } or nil,
			anchor = anchor,
		}, function(body, interrupted, selected_type)
			if not body then
				return true
			end
			local current = active_for_key(expected, "composing a review comment")
			if not current or (not interrupted and not allow_mutation(current)) then
				return false
			end
			local changed, err = review_store.add(current.session, {
				type = selected_type or requested_type or REVIEW_TYPES[1],
				body = body,
				anchor = anchor,
			})
			if not changed then
				notify(err, vim.log.levels.ERROR)
				return false
			end
			return save_mutation(current, changed) == true
		end)
	end)
end

local function choose_saved(root, callback)
	local sessions, err = review_store.list(root)
	if not sessions then
		notify("Could not list review sessions: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.ui.select(sessions, {
		prompt = "Saved review session",
		format_item = function(session)
			return string.format("%s · %d comments", session.scope.label, #session.items)
		end,
	}, function(session)
		if not session then
			return
		end
		local workspace, open_err = open_resolved(root, session.scope, session)
		if not workspace then
			notify("Could not open saved review: " .. tostring(open_err), vim.log.levels.ERROR)
		else
			clear_scope_history()
			emit_changed()
			if callback then
				callback(workspace)
			end
		end
	end)
end

local function user_input(prompt, callback)
	vim.ui.input({ prompt = prompt }, function(value)
		if value and vim.trim(value) ~= "" then
			callback(vim.trim(value))
		end
	end)
end

local function scope_picker(root, callback)
	local choices = {
		{ label = "Branch · default branch…HEAD", action = "branch" },
		{ label = "Working tree · staged / unstaged / untracked", action = "working" },
		{ label = "Commit…", action = "commit" },
		{ label = "Range…", action = "range" },
		{ label = "Saved review session…", action = "saved" },
	}
	local function opened(request)
		local workspace = M.open(request, root)
		if workspace and callback then
			callback(workspace)
		end
	end
	vim.ui.select(choices, {
		prompt = "Review scope",
		format_item = function(value)
			return value.label
		end,
	}, function(choice)
		if not choice then
			return
		elseif choice.action == "branch" or choice.action == "working" then
			opened({ kind = choice.action })
		elseif choice.action == "commit" then
			user_input("Commit: ", function(revision)
				opened({ kind = "commit", rev = revision })
			end)
		elseif choice.action == "range" then
			user_input("Range from: ", function(from)
				user_input("Range to: ", function(to)
					opened({ kind = "range", from = from, to = to })
				end)
			end)
		else
			choose_saved(root, callback)
		end
	end)
end

function M.comment(first, last, requested_type)
	if not valid_type(requested_type) then
		notify("Usage: ReviewComment [" .. table.concat(REVIEW_TYPES, "|") .. "]", vim.log.levels.ERROR)
		return
	end
	first = first or vim.fn.line(".")
	local captured = capture(first, last or first)
	local workspace = current_workspace()
	if workspace then
		add_from_capture(workspace, captured, requested_type, "range")
		return
	end
	local root = repo.current_root(captured.buf)
	if not root then
		notify("No active review and current buffer is not in a Git repository", vim.log.levels.ERROR)
		return
	end
	-- Location is captured before the asynchronous scope/session picker opens.
	scope_picker(root, function(opened)
		add_from_capture(opened, captured, requested_type, "range")
	end)
end

function M.file_comment(requested_type)
	if not valid_type(requested_type) then
		notify("Usage: ReviewFileComment [" .. table.concat(REVIEW_TYPES, "|") .. "]", vim.log.levels.ERROR)
		return
	end
	local line = vim.fn.line(".")
	local captured = capture(line, line)
	local workspace = current_workspace()
	if workspace then
		add_from_capture(workspace, captured, requested_type, "file")
		return
	end
	local root = repo.current_root(captured.buf)
	if root then
		scope_picker(root, function(opened)
			add_from_capture(opened, captured, requested_type, "file")
		end)
	else
		notify("No active review and current buffer is not in a Git repository", vim.log.levels.ERROR)
	end
end

function M.general_comment(requested_type)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	local anchor = { kind = "general", stale = workspace.session.stale }
	local source = editor_source(workspace)
	if not source then
		notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
		return
	end
	if review_panel.is_open(workspace.panel) then
		review_panel.hide(workspace.panel)
	end
	vim.api.nvim_set_current_win(source.win)
	compose(workspace, {
		title = "New review-level comment",
		type_cycle = REVIEW_TYPES,
		selected_type = requested_type or REVIEW_TYPES[1],
		source_win = source.win,
		anchor = anchor,
	}, function(body, interrupted, selected_type)
		if not body then
			return true
		end
		local current = active_for_key(expected, "composing a review-level comment")
		if not current or (not interrupted and not allow_mutation(current)) then
			return false
		end
		local changed, err = review_store.add(current.session, {
			type = selected_type or REVIEW_TYPES[1],
			body = body,
			anchor = anchor,
		})
		if not changed then
			notify(err, vim.log.levels.ERROR)
			return false
		end
		return save_mutation(current, changed) == true
	end)
end

local function current_location(workspace)
	local target = presentation_target(workspace)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	if not target or target.buf ~= buf then
		local targets = normal_targets(workspace, buf, win)
		target = #targets == 1 and targets[1] or nil
	end
	if not target then
		return nil
	end
	local display_line = vim.api.nvim_win_get_cursor(target.win)[1]
	if target.unified then
		local source_ref = review_presenter.source_at(workspace.mode_state, display_line, target.generation)
		if not source_ref then
			return nil
		end
		local refs = {}
		if source_ref.old_path and source_ref.old_line then
			refs[#refs + 1] = {
				path = source_ref.old_path,
				side = "left",
				layer = source_ref.layer,
				line = source_ref.old_line,
			}
		end
		if source_ref.new_path and source_ref.new_line then
			refs[#refs + 1] = {
				path = source_ref.new_path,
				side = "right",
				layer = source_ref.layer,
				line = source_ref.new_line,
			}
		end
		return {
			path = source_ref.path,
			side = source_ref.anchor_side,
			layer = source_ref.layer,
			line = source_ref.source_line,
			display_line = display_line,
			refs = refs,
			win = target.win,
			buf = target.buf,
			unified = true,
		}
	end
	return {
		path = target.path,
		side = target.side,
		layer = target.layer,
		line = display_line,
		display_line = display_line,
		win = target.win,
		buf = target.buf,
	}
end

editor_source = function(workspace)
	local location = current_location(workspace)
	if location then
		return location
	end
	local target = review_presenter.current_target(workspace.mode_state)
	local win = target and target.win or nil
	if not valid_win(win) or (target.buf and vim.api.nvim_win_get_buf(win) ~= target.buf) then
		win = review_panel.update_source(workspace.panel, win)
	end
	if not valid_win(win) then
		return nil
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not valid_buf(buf) or vim.b[buf].nvim_review_role == "panel" or vim.b[buf].nvim_review_panel_role then
		return nil
	end
	return {
		win = win,
		buf = buf,
		line = vim.api.nvim_win_get_cursor(win)[1],
	}
end

local function contains_line(anchor, location)
	if not anchor or anchor.kind ~= "range" or not location then
		return false
	end
	local last = anchor.end_line or anchor.start_line
	for _, candidate in ipairs(location.refs or { location }) do
		if
			anchor.path == candidate.path
			and anchor.side == candidate.side
			and anchor.layer == candidate.layer
			and anchor.start_line <= candidate.line
			and candidate.line <= last
		then
			return true
		end
	end
	return false
end

local function location_targets_anchor(anchor, location)
	if not anchor or not location then
		return false
	end
	for _, candidate in ipairs(location.refs or { location }) do
		if anchor.path == candidate.path and anchor.side == candidate.side and anchor.layer == candidate.layer then
			return anchor.kind ~= "range" or contains_line(anchor, location)
		end
	end
	return false
end

local function mapped_anchor_rows(workspace, anchor, buf)
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	if presentation and presentation.projection and presentation.inline and presentation.inline.buf == buf then
		return review_presenter.rows_for_anchor(workspace.mode_state, anchor, presentation.generation)
	end
	if anchor.kind ~= "range" or not anchor.start_line then
		return { 1 }
	end
	local rows = {}
	for line = anchor.start_line, anchor.end_line or anchor.start_line do
		rows[#rows + 1] = line
	end
	return rows
end

local function first_body_line(body)
	local lines = vim.split(tostring(body or ""), "\n", { plain = true })
	for _, line in ipairs(lines) do
		if not line:match("^%s*$") then
			return vim.trim(line):gsub("%s+", " "), #lines > 1
		end
	end
	return "", #lines > 1
end

local function display_excerpt(value, maximum, force_ellipsis)
	maximum = math.max(1, maximum)
	local ellipsis = "…"
	local ellipsis_width = vim.fn.strdisplaywidth(ellipsis)
	local truncated = vim.fn.strdisplaywidth(value) > maximum
	local append = force_ellipsis or truncated
	if not append then
		return value
	end
	local budget = math.max(0, maximum - ellipsis_width)
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
	return table.concat(parts) .. ellipsis
end

local function inline_preview_text(item, maximum)
	local anchor = item.anchor
	local last = anchor.end_line or anchor.start_line
	local range = anchor.start_line == last and ("L%d"):format(anchor.start_line)
		or ("L%d-%d"):format(anchor.start_line, last)
	local prefix = ("  [%s][%s] %s · "):format(item.type, review_store.item_status(item), range)
	local body, multiline = first_body_line(item.body)
	return prefix .. display_excerpt(body, maximum - vim.fn.strdisplaywidth(prefix), multiline)
end

local function inline_preview_width(win)
	local info = vim.fn.getwininfo(win)[1] or {}
	return math.max(1, vim.api.nvim_win_get_width(win) - (tonumber(info.textoff) or 0) - 1)
end

local function show_inline_preview()
	clear_inline_preview()
	local workspace = current_workspace()
	if not workspace or not workspace.mode_on or workspace.inline_comments == false or review_editor.has_active() then
		return false
	end
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	if
		not valid_win(win)
		or not valid_buf(buf)
		or vim.b[buf].nvim_review_role == "panel"
		or vim.b[buf].nvim_review_panel_role
	then
		return false
	end
	local location = current_location(workspace)
	if not location or location.win ~= win or location.buf ~= buf then
		return false
	end

	local items = {}
	for _, item in ipairs(workspace.session.items or {}) do
		if contains_line(item.anchor, location) then
			items[#items + 1] = item
		end
	end
	table.sort(items, function(left, right)
		local left_last = left.anchor.end_line or left.anchor.start_line
		local right_last = right.anchor.end_line or right.anchor.start_line
		if left_last ~= right_last then
			return left_last < right_last
		end
		if (left.sequence or math.huge) ~= (right.sequence or math.huge) then
			return (left.sequence or math.huge) < (right.sequence or math.huge)
		end
		return tostring(left.id or "") < tostring(right.id or "")
	end)
	if #items == 0 then
		return false
	end

	local count = vim.api.nvim_buf_line_count(buf)
	local grouped = {}
	local rows = {}
	for _, item in ipairs(items) do
		local mapped = mapped_anchor_rows(workspace, item.anchor, buf)
		local row = mapped and mapped[#mapped] or nil
		row = row and math.max(1, math.min(row, count)) or nil
		if row then
			if not grouped[row] then
				grouped[row] = {}
				rows[#rows + 1] = row
			end
			grouped[row][#grouped[row] + 1] = item
		end
	end
	table.sort(rows)
	local maximum = inline_preview_width(win)
	for _, row in ipairs(rows) do
		local virtual = {}
		for _, item in ipairs(grouped[row]) do
			virtual[#virtual + 1] = { { inline_preview_text(item, maximum), "Comment" } }
		end
		vim.api.nvim_buf_set_extmark(buf, PREVIEW_NAMESPACE, row - 1, 0, {
			virt_lines = virtual,
			priority = 70,
		})
	end
	inline_preview = { buf = buf, win = win }
	return true
end

local function item_label(item)
	local anchor = item.anchor
	local location = anchor.kind == "general" and "review" or anchor.path
	if anchor.kind == "range" then
		location = location .. ":" .. anchor.start_line .. "-" .. (anchor.end_line or anchor.start_line)
	elseif anchor.kind == "file" then
		location = location .. " [file]"
	end
	local side = review_panel.anchor_side_label(anchor)
	if side then
		location = "[" .. side .. "] " .. location
	end
	local preview = (item.body:match("[^\n]+") or item.body):gsub("%s+", " ")
	return string.format(
		"%02d %-10s %-14s %s %s",
		item.sequence,
		item.type,
		review_store.item_status(item),
		location,
		preview
	)
end

local function delete_prompt(item)
	local anchor = item.anchor
	local location = anchor.kind == "general" and "review" or anchor.path
	if anchor.kind == "range" then
		local last = anchor.end_line or anchor.start_line
		location = location .. ":" .. anchor.start_line .. (last ~= anchor.start_line and "-" .. last or "")
	elseif anchor.kind == "file" then
		location = location .. " [file]"
	end
	local side = review_panel.anchor_side_label(anchor)
	if side then
		location = "[" .. side .. "] " .. location
	end
	local excerpt, multiline = first_body_line(item.body)
	excerpt = display_excerpt(excerpt, 48, multiline)
	return string.format("Delete #%02d [%s] %s · %s?", item.sequence, item.type, location, excerpt)
end

local function choose_item(workspace, id, prompt, callback)
	if id and id ~= "" then
		local item = find_item(workspace.session, id)
		if item then
			callback(item)
		else
			notify("Review comment does not exist", vim.log.levels.ERROR)
		end
		return
	end
	local candidates = {}
	local location = current_location(workspace)
	if location then
		for _, item in ipairs(workspace.session.items) do
			if contains_line(item.anchor, location) then
				candidates[#candidates + 1] = item
			end
		end
	end
	if #candidates == 0 then
		candidates = vim.deepcopy(workspace.session.items)
	end
	if #candidates == 0 then
		notify("No matching review comments", vim.log.levels.INFO)
	elseif #candidates == 1 then
		callback(candidates[1])
	else
		vim.ui.select(candidates, { prompt = prompt, format_item = item_label }, callback)
	end
end

local function item_editor_source(workspace, item)
	local panel_open = review_panel.is_open(workspace.panel)
	local anchor = item.anchor
	if anchor.kind == "general" then
		local source = editor_source(workspace)
		if not source then
			notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
			return nil
		end
		if panel_open then
			review_panel.hide(workspace.panel)
		end
		vim.api.nvim_set_current_win(source.win)
		return source
	end

	local location = current_location(workspace)
	local exact = location_targets_anchor(anchor, location)
	if panel_open or not exact then
		if not M.jump(item.id) then
			return nil
		end
		location = current_location(workspace)
	end
	if
		not location
		or not valid_win(location.win)
		or not valid_buf(location.buf)
		or vim.api.nvim_win_get_buf(location.win) ~= location.buf
	then
		notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
		return nil
	end
	if panel_open then
		review_panel.hide(workspace.panel)
	end
	vim.api.nvim_set_current_win(location.win)
	return location
end

local function compose_item(workspace, item, action)
	local expected = workspace_key(workspace)
	local edit = action == "edit"
	local title = edit and "Edit" or "Reply"
	if item.anchor.kind == "file" or item.anchor.kind == "general" then
		local scope = item.anchor.kind == "file" and "file" or "review-level"
		title = edit and ("Edit " .. scope .. " comment") or ("Reply to " .. scope .. " comment")
	end
	local location = item_editor_source(workspace, item)
	if not location then
		return false
	end
	local display
	if item.anchor.kind == "range" then
		local display_err
		display, display_err = displayed_anchor(workspace, item.anchor)
		if not display then
			notify(display_err, vim.log.levels.ERROR)
			return false
		end
	end
	compose(workspace, {
		title = title,
		body = edit and item.body or "",
		type_cycle = edit and REVIEW_TYPES or nil,
		selected_type = (edit or item.anchor.kind == "file" or item.anchor.kind == "general") and item.type or nil,
		source_win = location.win,
		anchor_line = display and display.last or nil,
		anchor_range = display and { first = display.first, last = display.last } or nil,
		anchor = item.anchor,
	}, function(body, interrupted, selected_type)
		if not body then
			return true
		end
		local current = active_for_key(expected, "composing a review comment")
		if not current or (not interrupted and not allow_mutation(current)) then
			return false
		end
		local stable = find_item(current.session, item.id)
		if not stable then
			notify("Review comment changed while the composer was open", vim.log.levels.ERROR)
			return false
		end
		local values = { type = selected_type or stable.type, body = body, anchor = stable.anchor }
		local changed, err = edit and review_store.edit(current.session, stable.id, values)
			or review_store.reply(current.session, stable.id, values)
		if not changed then
			notify(err, vim.log.levels.ERROR)
			return false
		end
		return save_mutation(current, changed) == true
	end)
end

function M.edit(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	choose_item(workspace, id, "Edit review comment", function(selected)
		local current = active_for_key(expected, "selecting a review comment")
		local stable = current and find_item(current.session, selected.id)
		if stable then
			compose_item(current, stable, "edit")
		end
	end)
end

function M.reply(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	choose_item(workspace, id, "Reply to review comment", function(selected)
		local current = active_for_key(expected, "selecting a reply target")
		local stable = current and find_item(current.session, selected.id)
		if stable then
			compose_item(current, stable, "reply")
		end
	end)
end

local function direct_mutation(id, prompt, mutator)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	choose_item(workspace, id, prompt, function(selected)
		local current = active_for_key(expected, "selecting a review comment")
		local stable = current and find_item(current.session, selected.id)
		if not stable or not allow_mutation(current) then
			return
		end
		local changed, err = mutator(current, stable)
		if changed then
			save_mutation(current, changed)
		else
			notify(err, vim.log.levels.ERROR)
		end
	end)
end

function M.delete(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	choose_item(workspace, id, "Delete review comment", function(selected)
		if not selected then
			return
		end
		local selected_id = selected.id
		vim.ui.select({ "Cancel", "Delete" }, { prompt = delete_prompt(selected) }, function(choice)
			if choice ~= "Delete" then
				return
			end
			local current = active_for_key(expected, "deleting a review comment")
			local stable = current and find_item(current.session, selected_id)
			if not stable then
				if current then
					notify("Review comment changed before it could be deleted", vim.log.levels.ERROR)
				end
				return
			end
			if not allow_mutation(current) then
				return
			end
			local changed, err = review_store.delete(current.session, stable.id)
			if changed then
				save_mutation(current, changed)
			else
				notify(err, vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.change_type(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	choose_item(workspace, id, "Change review comment type", function(selected)
		vim.ui.select(REVIEW_TYPES, { prompt = "Review comment type" }, function(item_type)
			local current = item_type and active_for_key(expected, "changing a review comment type") or nil
			local stable = current and find_item(current.session, selected.id)
			if not stable or not allow_mutation(current) then
				return
			end
			local changed, err = review_store.set_type(current.session, stable.id, item_type)
			if changed then
				save_mutation(current, changed)
			else
				notify(err, vim.log.levels.ERROR)
			end
		end)
	end)
end

local function set_resolution(id, resolution)
	direct_mutation(
		id,
		resolution == "resolved" and "Resolve review comment" or "Reopen review comment",
		function(workspace, item)
			return review_store.set_resolution(workspace.session, item.id, resolution)
		end
	)
end

function M.resolve(id)
	set_resolution(id, "resolved")
end

function M.reopen(id)
	set_resolution(id, "open")
end

function M.toggle_resolution(id)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return
	end
	choose_item(workspace, id, "Resolve or reopen review comment", function(item)
		set_resolution(item.id, item.resolution == "resolved" and "open" or "resolved")
	end)
end

function M.reanchor(id, source_win)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local captured
	if source_win ~= nil then
		if not valid_win(source_win) then
			notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
			return
		end
		local line = vim.api.nvim_win_get_cursor(source_win)[1]
		captured = { win = source_win, buf = vim.api.nvim_win_get_buf(source_win), first = line, last = line }
	else
		captured = capture(vim.fn.line("."), vim.fn.line("."))
	end
	local expected = workspace_key(workspace)
	choose_item(workspace, id, "Reanchor review comment", function(selected)
		local current = active_for_key(expected, "selecting a review comment")
		if not current or not allow_mutation(current) then
			return
		end
		if selected.anchor.kind == "general" then
			notify("Review-level comments do not have a location to reanchor", vim.log.levels.INFO)
			return
		end
		choose_target(current, captured, function(target, target_err)
			current = active_for_key(expected, "reanchoring a review comment")
			local item = current and find_item(current.session, selected.id)
			if not current or not item or not allow_mutation(current) then
				return
			end
			if not target then
				notify(target_err, vim.log.levels.ERROR)
				return
			end
			local anchor, anchor_err
			if item.anchor.kind == "general" then
				anchor = { kind = "general", stale = false }
			elseif item.anchor.kind == "file" then
				anchor, anchor_err =
					make_anchor(current, target, "file", captured.first, captured.first, item.anchor.side)
			else
				local length = (item.anchor.end_line or item.anchor.start_line) - item.anchor.start_line
				local first = vim.api.nvim_win_get_cursor(target.win)[1]
				if target.unified then
					local resolved
					resolved, anchor_err = review_presenter.resolve_range(
						current.mode_state,
						first,
						first,
						target.generation,
						item.anchor.side
					)
					if resolved then
						local canonical = {
							entry = target.entry,
							buf = target.buf,
							win = target.win,
							path = resolved.path,
							side = resolved.anchor_side,
							layer = resolved.layer,
						}
						anchor, anchor_err =
							make_anchor(current, canonical, "range", resolved.start_line, resolved.start_line + length)
					end
				else
					anchor, anchor_err = make_anchor(current, target, "range", first, first + length)
				end
			end
			if not anchor then
				notify(anchor_err, vim.log.levels.ERROR)
				return
			end
			anchor.stale = false
			local changed, err = review_store.edit(current.session, item.id, {
				type = item.type,
				body = item.body,
				anchor = anchor,
			})
			if changed then
				save_mutation(current, changed)
			else
				notify(err, vim.log.levels.ERROR)
			end
		end)
	end)
end

local function entry_for_anchor(workspace, anchor)
	local layer = anchor.layer ~= "history" and anchor.layer or nil
	local entry = review_changes.find(workspace.model, anchor.path, layer)
	if entry then
		return entry
	end
	for _, candidate in ipairs(workspace.model.entries or {}) do
		if candidate.old_path == anchor.path or candidate.new_path == anchor.path then
			return candidate
		end
	end
	return nil
end

function M.jump(id)
	local workspace = current_workspace()
	local item = workspace and find_item(workspace.session, id)
	if not item then
		notify("Review comment does not exist", vim.log.levels.ERROR)
		return false
	end
	local anchor = item.anchor
	if anchor.kind == "general" then
		return review_panel.focus(workspace.panel, "comments")
	end
	if workspace.session.stale or anchor.stale then
		notify("Stale review locations cannot be opened", vim.log.levels.WARN)
		return false
	end
	local entry = entry_for_anchor(workspace, anchor)
	if not entry then
		notify("Comment path is not represented in the exact review model", vim.log.levels.ERROR)
		return false
	end
	local shown, err = M.present(entry.identity)
	if not shown then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	local presentation = workspace.mode_state.presentation
	local target
	local line
	if presentation.projection then
		local display_err
		target, display_err = displayed_anchor(workspace, anchor)
		if not target then
			notify(display_err, vim.log.levels.ERROR)
			return false
		end
		line = target.first
	else
		target = anchor.side == "left" and presentation.left or presentation.right or presentation.inline
		line = anchor.start_line or 1
	end
	if not target or not valid_win(target.win) then
		notify("Comment side is unavailable", vim.log.levels.ERROR)
		return false
	end
	vim.api.nvim_set_current_win(target.win)
	line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(target.buf)))
	vim.api.nvim_win_set_cursor(target.win, { line, math.max(0, (anchor.start_column or 1) - 1) })
	return true
end

local function navigate(direction)
	local workspace = current_workspace()
	if not workspace or #workspace.session.items == 0 then
		notify("No review comments", vim.log.levels.INFO)
		return
	end
	local items = vim.deepcopy(workspace.session.items)
	table.sort(items, function(left, right)
		local lp, rp = left.anchor.path or "", right.anchor.path or ""
		local ll, rl = left.anchor.start_line or 0, right.anchor.start_line or 0
		return lp == rp and (ll == rl and left.sequence < right.sequence or ll < rl) or lp < rp
	end)
	local location = current_location(workspace)
	local current_index
	for index, item in ipairs(items) do
		if contains_line(item.anchor, location) then
			current_index = index
			break
		end
	end
	local index = current_index and ((current_index - 1 + direction) % #items + 1) or (direction > 0 and 1 or #items)
	M.jump(items[index].id)
end

function M.next()
	navigate(1)
end

function M.prev()
	navigate(-1)
end

function M.refresh()
	clear_inline_preview()
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	local blocked = unsaved_transition_error("refresh it")
	if blocked then
		notify("Could not refresh review: " .. blocked, vim.log.levels.ERROR)
		return nil, blocked
	end
	local stale, stale_err = stale_now(workspace)
	if stale == nil then
		notify("Could not refresh review: " .. stale_err, vim.log.levels.ERROR)
		return nil
	end
	if stale then
		mark_stale(workspace)
		notify("Working review became stale; open a new exact working scope", vim.log.levels.ERROR)
		return nil
	end
	local loaded, load_err = review_store.load(workspace.root, workspace.session.id)
	if not loaded then
		notify("Could not reload review: " .. tostring(load_err), vim.log.levels.ERROR)
		return nil
	end
	local model, model_err = review_changes.build(workspace.root, loaded.scope)
	if not model then
		notify("Could not rebuild exact review: " .. message(model_err), vim.log.levels.ERROR)
		return nil
	end
	local identity = first_identity(model, workspace.entry_identity)
	-- Nothing becomes visible until both persistence and exact model construction succeed.
	workspace.session = loaded
	workspace.scope = loaded.scope
	workspace.model = model
	workspace.entry_identity = identity
	if workspace.mode_on and identity then
		local shown, show_err = M.present(identity, nil, { emit = false })
		if not shown then
			notify("Model refreshed but presentation failed: " .. tostring(show_err), vim.log.levels.ERROR)
			return nil
		end
	end
	update_panel(workspace)
	M.refresh_marks(workspace)
	emit_changed()
	return true
end

function M.export(force)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	local snapshot
	local recovery_receipt
	if workspace.unsaved_error then
		local recovery_err
		recovery_receipt, recovery_err = recovery(workspace)
		if not recovery_receipt then
			notify("Could not verify live review recovery: " .. tostring(recovery_err), vim.log.levels.ERROR)
			return nil
		end
		snapshot = vim.deepcopy(workspace.session)
	else
		snapshot = verified_persisted_snapshot(workspace, "export review")
		if not snapshot then
			return nil
		end
	end
	local stale, stale_err = stale_now(workspace)
	if stale == nil then
		notify("Could not check review drift: " .. stale_err, vim.log.levels.ERROR)
		return nil
	end
	local is_stale = stale or session_has_stale_location(snapshot)
	if is_stale and not force then
		notify("Review is stale; use :ReviewExport! to export the saved exact snapshot", vim.log.levels.ERROR)
		return nil
	end
	if stale then
		snapshot.stale = true
	end
	if is_stale then
		local markdown, render_err = review_export.render(snapshot, true)
		if not markdown then
			notify(render_err, vim.log.levels.ERROR)
			return nil
		end
		local recovery_err
		recovery_receipt, recovery_err = save_verified_recovery(workspace.root, snapshot, markdown)
		if not recovery_receipt then
			notify("Could not save exact review recovery: " .. tostring(recovery_err), vim.log.levels.ERROR)
			return nil
		end
	end
	local result, err = review_export.deliver(snapshot, force == true)
	if not result then
		notify(err, vim.log.levels.ERROR)
		return nil
	end
	result.recovery = recovery_receipt
	notify(result.previewed and "Review opened in Markdown preview" or "Complete review copied to clipboard")
	return result
end

local function anchor_rows_for_buffer(workspace, anchor, buf)
	if anchor.kind == "general" then
		return nil
	end
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	if presentation and presentation.projection and presentation.inline and presentation.inline.buf == buf then
		return review_presenter.rows_for_anchor(workspace.mode_state, anchor, presentation.generation)
	end
	if vim.b[buf].nvim_review_path == anchor.path then
		if vim.b[buf].nvim_review_side == anchor.side and vim.b[buf].nvim_review_layer == anchor.layer then
			return mapped_anchor_rows(workspace, anchor, buf)
		end
		return nil
	end
	for _, target in ipairs(normal_targets(workspace, buf, 0)) do
		if target.path == anchor.path and target.side == anchor.side and target.layer == anchor.layer then
			return mapped_anchor_rows(workspace, anchor, buf)
		end
	end
	return nil
end

local function aggregate_connector(mark)
	if mark.starts and not mark.ends and not mark.middle then
		return "╭"
	elseif mark.ends and not mark.starts and not mark.middle then
		return "╰"
	end
	return "│"
end

local function aggregate_sign_text(item_type, mark)
	local icon = TYPE_SIGNS[item_type].text
	local shows_badge = mark.single or mark.starts
	if not shows_badge then
		return aggregate_connector(mark)
	elseif mark.count > 1 and mark.count < 10 then
		return tostring(mark.count)
	elseif mark.count >= 10 then
		return "9+"
	elseif not mark.multiline then
		return icon
	elseif mark.starts then
		return aggregate_connector(mark) .. icon
	end
	return aggregate_connector(mark)
end

local function file_comment_virtual_line(item)
	local side = item.anchor.side == "left" and "OLD" or "NEW"
	local prefix = ("0 │ [%s][%s][%s] "):format(side, item.type, review_store.item_status(item))
	local body, multiline = first_body_line(item.body)
	local excerpt = display_excerpt(body, math.max(1, 88 - vim.fn.strdisplaywidth(prefix)), multiline)
	local sign = TYPE_SIGNS[item.type] or TYPE_SIGNS.question
	return {
		{ "0 │ ", "LineNr" },
		{ ("[%s][%s][%s] "):format(side, item.type, review_store.item_status(item)), sign.highlight },
		{ excerpt, "Comment" },
	}
end

function M.decorate_buffer(workspace, buf)
	workspace = workspace or current_workspace()
	if not workspace or not valid_buf(buf) or vim.b[buf].nvim_review_role == "panel" then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
	local count = vim.api.nvim_buf_line_count(buf)
	local marks = {}
	local file_comments = {}
	for _, item in ipairs(workspace.session.items or {}) do
		local anchor = item.anchor
		local anchor_rows = anchor_rows_for_buffer(workspace, anchor, buf)
		if anchor.kind == "file" and anchor_rows then
			file_comments[#file_comments + 1] = file_comment_virtual_line(item)
		elseif anchor.kind == "range" and anchor_rows then
			local rendered_rows = vim.tbl_filter(function(line)
				return line >= 1 and line <= count
			end, anchor_rows)
			local item_type = TYPE_SIGNS[item.type] and item.type or "question"
			for index, line in ipairs(rendered_rows) do
				marks[line] = marks[line] or {}
				local mark = marks[line][item_type]
				if not mark then
					mark = {
						count = 0,
						ends = false,
						middle = false,
						multiline = false,
						single = false,
						starts = false,
					}
					marks[line][item_type] = mark
				end
				mark.count = mark.count + 1
				if #rendered_rows > 1 then
					mark.multiline = true
					if index == 1 then
						mark.starts = true
					elseif index == #rendered_rows then
						mark.ends = true
					else
						mark.middle = true
					end
				else
					mark.single = true
				end
			end
		end
	end
	if #file_comments > 0 then
		vim.api.nvim_buf_set_extmark(buf, NAMESPACE, 0, 0, {
			priority = 70,
			virt_lines = file_comments,
			virt_lines_above = true,
			virt_lines_leftcol = true,
		})
	end
	for line, line_marks in pairs(marks) do
		for type_index, item_type in ipairs(COMMENT_SIGN_TYPES) do
			local mark = line_marks[item_type]
			if mark then
				vim.api.nvim_buf_set_extmark(buf, NAMESPACE, line - 1, 0, {
					priority = 90 - type_index,
					sign_hl_group = TYPE_SIGNS[item_type].highlight,
					sign_text = aggregate_sign_text(item_type, mark),
				})
			end
		end
	end
end

function M.refresh_marks(workspace)
	clear_inline_preview()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if valid_buf(buf) then
			vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
		end
	end
	workspace = workspace or current_workspace()
	if not workspace then
		return
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if
			valid_buf(buf)
			and (
				buffer_in_root(workspace.root, buf)
				or vim.b[buf].nvim_review_path
				or vim.b[buf].nvim_review_role == "unified"
			)
		then
			M.decorate_buffer(workspace, buf)
		end
	end
	review_presenter.refresh_bands(workspace.mode_state)
end

function M.snapshot()
	local workspace = current_workspace()
	if not workspace then
		return nil
	end
	local items = {}
	for _, item in ipairs(workspace.session.items) do
		items[#items + 1] = {
			id = item.id,
			sequence = item.sequence,
			type = item.type,
			status = review_store.item_status(item),
			resolution = item.resolution,
			body = item.body,
			anchor = vim.deepcopy(item.anchor),
			reply_to = item.reply_to,
		}
	end
	return {
		root = workspace.root,
		scope = vim.deepcopy(workspace.scope),
		stale = workspace.session.stale,
		items = items,
	}
end

function M.items()
	local value = M.snapshot()
	return value and value.items or {}
end

function M.suspend_for_session()
	clear_inline_preview()
	if suspended then
		return nil, "review UI is already suspended"
	elseif review_editor.has_active() then
		return nil, "review composer has unsent text; save or cancel it first"
	end
	local workspace = current_workspace()
	local state = {
		focus = focus_snapshot(workspace),
		key = workspace and workspace_key(workspace) or nil,
	}
	local preview, preview_err = review_export.suspend_preview()
	if preview_err then
		return nil, "could not suspend review export preview: " .. tostring(preview_err)
	end
	state.preview = preview
	if workspace then
		state.mode_on = workspace.mode_on
		state.entry = workspace.entry_identity
		state.layout = workspace.layout
		state.context = workspace.context
		state.inline_comments = workspace.inline_comments ~= false
		state.panel = review_panel.suspend(workspace.panel)
		if workspace.mode_state.presentation then
			review_presenter.clear(workspace.mode_state)
		end
		state.mode = review_mode.suspend(workspace.mode_state)
		workspace.mode_on = false
	end
	suspended = state
	emit_changed()
	return true
end

function M.restore_after_session()
	local state = suspended
	if not state then
		return true
	end
	suspended = nil
	local workspace = state.key and workspace_for_key(state.key) or nil
	local function finish(ok, err, preview_restored)
		if not (preview_restored and state.preview and state.preview.focused) then
			pcall(restore_focus, workspace, state.focus)
		end
		return ok, err
	end
	if state.key and not workspace then
		return finish(nil, "review session disappeared while UI was suspended", false)
	end
	if workspace then
		workspace.layout = state.layout
		workspace.context = state.context
		workspace.inline_comments = state.inline_comments
		workspace.entry_identity = first_identity(workspace.model, state.entry)
		local restored, restore_err = review_mode.restore(workspace.mode_state, state.mode)
		if not restored then
			review_mode.disable(workspace.mode_state)
			review_panel.hide(workspace.panel)
			return finish(nil, "could not restore review mode: " .. tostring(restore_err), false)
		end
		workspace.mode_on = state.mode_on == true
		if workspace.mode_on and workspace.entry_identity then
			local shown, show_err = M.present(workspace.entry_identity, state.key, { emit = false })
			if not shown then
				review_mode.disable(workspace.mode_state)
				workspace.mode_on = false
				review_panel.hide(workspace.panel)
				return finish(nil, "could not restore review presentation: " .. tostring(show_err), false)
			end
		end
		if not review_panel.restore(workspace.panel, state.panel) then
			review_mode.disable(workspace.mode_state)
			workspace.mode_on = false
			return finish(nil, "could not restore review panel", false)
		end
	end
	local preview_target = workspace and review_presenter.current_target(workspace.mode_state) or nil
	if not review_export.restore_preview(state.preview, preview_target and preview_target.win) then
		if workspace then
			review_mode.disable(workspace.mode_state)
			workspace.mode_on = false
			review_panel.hide(workspace.panel)
		end
		return finish(nil, "could not restore review export preview", false)
	end
	local ok, err = finish(true, nil, true)
	emit_changed()
	return ok, err
end

function M.close(force)
	clear_inline_preview()
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return false
	end
	local expected = workspace_key(workspace)
	if review_editor.has_active() then
		notify("Save or cancel the review composer before closing", vim.log.levels.WARN)
		return false
	end
	if workspace.unsaved_error then
		local receipt, recovery_err = recovery(workspace)
		if not receipt then
			notify("Could not close review because recovery failed: " .. tostring(recovery_err), vim.log.levels.ERROR)
			return false
		end
		if not force then
			local suffix = type(receipt) == "table" and "; recovery saved to " .. receipt.path or ""
			notify(
				"Review has unsaved changes" .. suffix .. "; use :ReviewClose! to discard the live state",
				vim.log.levels.ERROR
			)
			return false
		end
	end
	review_panel.close(workspace.panel)
	review_mode.disable(workspace.mode_state)
	workspaces[expected] = nil
	active = nil
	clear_scope_history()
	M.refresh_marks(nil)
	refresh_trouble()
	emit_changed()
	return true
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
	end
	return nil
end

function M.mapping_specs()
	return vim.deepcopy(MAPPINGS)
end

function M.help_groups()
	return vim.deepcopy(HELP_GROUPS)
end

function M.help_mappings(group)
	local values = {}
	for _, mapping in ipairs(MAPPINGS) do
		if mapping.help == group then
			values[#values + 1] = { "n", mapping.lhs, mapping.rhs, { desc = mapping.desc } }
		end
	end
	return values
end

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("NvimConfigCodeReview", { clear = true })
	vim.api.nvim_create_autocmd("CursorHold", {
		group = group,
		callback = function()
			show_inline_preview()
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave", "WinLeave", "TabLeave", "WinScrolled" }, {
		group = group,
		callback = clear_inline_preview,
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = group,
		callback = function(event)
			local workspace = current_workspace()
			if workspace then
				if workspace.mode_on then
					local enrolled, enroll_err = review_mode.enroll_affected_buffer(workspace.mode_state, event.buf)
					if enrolled == nil then
						notify("Could not enroll review buffer: " .. tostring(enroll_err), vim.log.levels.ERROR)
					end
				end
				M.decorate_buffer(workspace, event.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufModifiedSet", {
		group = group,
		callback = function(event)
			local workspace = current_workspace()
			if
				workspace
				and workspace.scope.kind == "working"
				and vim.bo[event.buf].modified
				and buffer_in_root(workspace.root, event.buf)
			then
				mark_stale(workspace)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if review_editor.persist_active() ~= true then
				notify("Could not persist the open review comment before exit", vim.log.levels.ERROR)
			end
			for _, workspace in pairs(workspaces) do
				recovery(workspace)
			end
		end,
	})
end

function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	review_lsp.setup()
	setup_autocmds()
end

M._parse_open = parse_open
M._workspaces = workspaces
M._scope_history = scope_history
M._active_workspace = current_workspace
M._open_scope_picker = scope_picker
M._choose_saved = choose_saved
M._root_for_command = root_for_command
M._contains_line = contains_line
M._inline_preview_text = inline_preview_text
M._show_inline_preview = show_inline_preview
M._clear_inline_preview = clear_inline_preview
M._preview_namespace = PREVIEW_NAMESPACE

return M
