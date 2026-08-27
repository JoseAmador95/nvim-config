-- Repository/session-scoped native reviews in ordinary Neovim tabs.
local M = {}

local repo = require("config.repo")
local review_changes = require("config.review_changes")
local review_editor = require("config.review_editor")
local review_export = require("config.review_export")
local review_lsp = require("config.review_lsp")
local review_mode = require("config.review_mode")
local review_panel = require("config.review_panel")
local review_presenter = require("config.review_presenter")
local review_scope = require("config.review_scope")
local review_store = require("config.review_store")
local review_tuicr = require("config.review_tuicr")

local NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_comments")
local REVIEW_TYPES = { "issue", "suggestion", "rationale", "question", "pedantic", "praise" }
local TYPE_SIGNS = {
	issue = { text = "●", highlight = "DiagnosticSignError" },
	suggestion = { text = "◆", highlight = "DiagnosticSignWarn" },
	rationale = { text = "R", highlight = "DiagnosticSignInfo" },
	question = { text = "?", highlight = "DiagnosticSignInfo" },
	pedantic = { text = "·", highlight = "DiagnosticSignHint" },
	praise = { text = "♥", highlight = "DiagnosticSignHint" },
}
local HELP_GROUPS = { common = "review", diff_line = "review_diff", file = "review_file" }
local MAPPINGS = {
	{ lhs = "<leader>rr", rhs = "<cmd>ReviewPanel<cr>", desc = "Toggle review panel", help = "common" },
	{ lhs = "<leader>ro", rhs = "<cmd>ReviewOpen<cr>", desc = "Open default review", help = "common" },
	{ lhs = "<leader>rm", rhs = "<cmd>ReviewMode<cr>", desc = "Toggle review mode", help = "common" },
	{ lhs = "<leader>rs", rhs = "<cmd>ReviewScope<cr>", desc = "Review scope/session", help = "common" },
	{ lhs = "<leader>rf", rhs = "<cmd>ReviewFiles<cr>", desc = "Focus review files", help = "common" },
	{ lhs = "<leader>rh", rhs = "<cmd>ReviewCommits<cr>", desc = "Focus review commits", help = "common" },
	{ lhs = "<leader>rl", rhs = "<cmd>ReviewComments<cr>", desc = "Focus review comments", help = "common" },
	{ lhs = "<leader>rv", rhs = "<cmd>ReviewLayout<cr>", desc = "Toggle review layout", help = "common" },
	{ lhs = "<leader>rw", rhs = "<cmd>ReviewContext<cr>", desc = "Toggle review context", help = "common" },
	{ lhs = "<leader>rg", rhs = "<cmd>ReviewCode<cr>", desc = "Focus reviewed code", help = "common" },
	{ lhs = "<leader>ra", rhs = "<cmd>ReviewComment<cr>", desc = "Add line/range comment", help = "diff_line" },
	{ lhs = "<leader>rA", rhs = "<cmd>ReviewFileComment<cr>", desc = "Add file comment", help = "file" },
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
local publishing = {}
local setup_done = false

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

local function publishing_transition_error(action)
	if next(publishing) then
		return "TUICR publication is still in progress; cannot " .. action
	end
	return nil
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
	if not vim.deep_equal(saved.bridge, live.bridge) then
		return nil, "persisted TUICR link does not match the live review"
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
	if next(publishing) then
		return nil, "TUICR publication is still in progress"
	end
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
	if next(publishing) then
		notify("Wait for TUICR publication to finish", vim.log.levels.WARN)
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
		apply_commit = function(first, second)
			local workspace = workspace_for_key(expected)
			if not workspace then
				return
			end
			local request, err = review_changes.selection_request(workspace.model, first, second)
			if request then
				M.open(request, workspace.root)
			else
				notify(message(err), vim.log.levels.ERROR)
			end
		end,
		jump_comment = M.jump,
		edit_comment = M.edit,
		delete_comment = M.delete,
		change_type = M.change_type,
		reply_comment = M.reply,
		toggle_resolution = M.toggle_resolution,
		reanchor_comment = function(id, source_win)
			return M.reanchor(id, source_win)
		end,
	}
end

local function disable_ui(workspace)
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
		mode_on = workspace.mode_on == true,
		panel_visible = workspace.panel and review_panel.is_open(workspace.panel) or false,
		panel_focus = workspace.panel and workspace.panel.focused or "files",
		focus = focus_snapshot(workspace),
	}
end

local function restore_ui(workspace, snapshot)
	active = workspace
	if snapshot.mode_on then
		local enabled, enable_err = review_mode.enable(workspace.mode_state)
		if not enabled then
			return nil, enable_err
		end
		workspace.mode_on = true
		if workspace.entry_identity then
			local shown, show_err = M.present(workspace.entry_identity, workspace_key(workspace))
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

local function activate(root, session, model)
	local blocked = publishing_transition_error("replace the active review") or unsaved_transition_error("replace it")
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
	local workspace = {
		root = root,
		layout = existing and existing.layout or "inline",
		context = existing and existing.context or "hunks",
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
		local shown, show_err = M.present(workspace.entry_identity, expected)
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

local function open_resolved(root, scope, supplied)
	local blocked = publishing_transition_error("open another review")
		or unsaved_transition_error("open another review")
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
	return activate(root, session, model)
end

function M.open(request, root)
	local blocked = publishing_transition_error("open another review")
		or unsaved_transition_error("open another review")
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
	local workspace, err = open_resolved(root, scope)
	if not workspace then
		notify("Could not open review: " .. tostring(err), vim.log.levels.ERROR)
	end
	return workspace, err
end

function M.present(identity, expected)
	local workspace = expected and workspace_for_key(expected) or current_workspace()
	if not workspace or workspace ~= current_workspace() then
		return nil, "review session is no longer active"
	end
	local entry = find_entry(workspace, identity)
	if not entry then
		return nil, "review entry is no longer part of the exact model"
	end
	if not workspace.mode_on then
		local enabled, err = review_mode.enable(workspace.mode_state)
		if not enabled then
			return nil, err
		end
		workspace.mode_on = true
	end
	local shown, err = review_presenter.show(workspace.mode_state, entry, {
		layout = workspace.layout,
		context = workspace.context,
	})
	if not shown then
		return nil, err
	end
	local target = review_presenter.current_target(workspace.mode_state)
	review_panel.update_source(workspace.panel, target and target.win or nil)
	workspace.entry_identity = identity
	update_panel(workspace)
	M.refresh_marks(workspace)
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
		if workspace.mode_on then
			review_mode.disable(workspace.mode_state)
			workspace.mode_on = false
		end
		return true
	elseif value ~= "on" then
		notify("Usage: ReviewMode [on|off|toggle]", vim.log.levels.ERROR)
		return nil
	end
	if not workspace.mode_on then
		local enabled, err = review_mode.enable(workspace.mode_state)
		if not enabled then
			notify(err, vim.log.levels.ERROR)
			return nil
		end
		workspace.mode_on = true
	end
	if workspace.entry_identity then
		local shown, err = M.present(workspace.entry_identity)
		if not shown then
			notify(err, vim.log.levels.ERROR)
			return nil
		end
	end
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
	workspace[name] = value
	if workspace.mode_on and workspace.entry_identity then
		local shown, err = M.present(workspace.entry_identity)
		if not shown then
			return nil, err
		end
	end
	update_panel(workspace)
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
	if
		not valid_win(captured.win)
		or not valid_buf(captured.buf)
		or vim.api.nvim_win_get_buf(captured.win) ~= captured.buf
	then
		callback(nil, "review target changed before it could be captured")
		return
	end
	local target = presentation_target(workspace, captured.win)
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

local function context_for_buffer(buf, first, last)
	local count = vim.api.nvim_buf_line_count(buf)
	local context_first = math.max(1, first - 3)
	local context_last = math.min(count, last + 3)
	local context = table.concat(vim.api.nvim_buf_get_lines(buf, context_first - 1, context_last, false), "\n")
	if context == "" then
		context = "\n"
	end
	if #context > review_store.max_anchor_context then
		context = table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n")
		local truncated, truncate_err = review_store.truncate_utf8(context, review_store.max_anchor_context)
		if not truncated then
			return nil, "could not capture valid UTF-8 review context: " .. tostring(truncate_err)
		end
		context = truncated ~= "" and truncated or "\n"
	end
	return context
end

local function make_anchor(workspace, target, kind, first, last)
	local anchor = {
		kind = kind,
		path = target.path,
		side = target.side,
		layer = target.layer,
		stale = workspace.session.stale,
	}
	if kind == "range" then
		local count = vim.api.nvim_buf_line_count(target.buf)
		first, last = math.min(first, last), math.max(first, last)
		anchor.start_line = math.max(1, math.min(first, count))
		anchor.end_line = math.max(anchor.start_line, math.min(last, count))
		local context, context_err = context_for_buffer(target.buf, anchor.start_line, anchor.end_line)
		if not context then
			return nil, context_err
		end
		anchor.context = context
		anchor.context_hash = vim.fn.sha256(anchor.context):lower()
	end
	return anchor
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
	options.recover = function(body, selected_type)
		return composer_recovery(workspace, options.title .. " " .. tostring(selected_type or ""), body, options.anchor)
	end
	return review_editor.compose(options, callback)
end

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
		local target_visible = valid_win(target.win) and vim.api.nvim_win_get_buf(target.win) == target.buf
		if not target_visible or review_panel.is_open(workspace.panel) then
			local shown, show_err = M.present(target.entry.identity, expected)
			if not shown then
				notify(show_err, vim.log.levels.ERROR)
				return
			end
			local presented = presentation_target(workspace)
			review_panel.hide(workspace.panel)
			target = presented
			if not target then
				notify("Could not focus the selected review side", vim.log.levels.ERROR)
				return
			end
			local line = math.max(1, math.min(captured.first, vim.api.nvim_buf_line_count(target.buf)))
			vim.api.nvim_set_current_win(target.win)
			vim.api.nvim_win_set_cursor(target.win, { line, 0 })
		end
		local anchor, anchor_err = make_anchor(workspace, target, kind, captured.first, captured.last)
		if not anchor then
			notify(anchor_err, vim.log.levels.ERROR)
			return
		end
		compose(workspace, {
			title = "New",
			type_cycle = REVIEW_TYPES,
			selected_type = requested_type or REVIEW_TYPES[1],
			source_win = target.win,
			anchor_range = { first = anchor.start_line, last = anchor.end_line },
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
		elseif callback then
			callback(workspace)
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
	compose(workspace, {
		title = "New general comment",
		type_cycle = REVIEW_TYPES,
		selected_type = requested_type or REVIEW_TYPES[1],
		anchor = anchor,
	}, function(body, interrupted, selected_type)
		if not body then
			return true
		end
		local current = active_for_key(expected, "composing a general comment")
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
	return {
		path = target.path,
		side = target.side,
		layer = target.layer,
		line = vim.api.nvim_win_get_cursor(target.win)[1],
		win = target.win,
		buf = target.buf,
	}
end

local function contains_line(anchor, location)
	if not anchor or anchor.kind ~= "range" or not location then
		return false
	end
	local last = anchor.end_line or anchor.start_line
	return anchor.path == location.path
		and anchor.side == location.side
		and anchor.layer == location.layer
		and anchor.start_line <= location.line
		and location.line <= last
end

local function item_label(item)
	local anchor = item.anchor
	local location = anchor.kind == "general" and "general" or anchor.path
	if anchor.kind == "range" then
		location = location .. ":" .. anchor.start_line .. "-" .. (anchor.end_line or anchor.start_line)
	elseif anchor.kind == "file" then
		location = location .. " [file]"
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

local function compose_item(workspace, item, action)
	local expected = workspace_key(workspace)
	local edit = action == "edit"
	local location = current_location(workspace)
	compose(workspace, {
		title = edit and "Edit" or "Reply",
		body = edit and item.body or "",
		type_cycle = edit and REVIEW_TYPES or nil,
		selected_type = edit and item.type or nil,
		source_win = location and location.win or nil,
		anchor_range = item.anchor.kind == "range" and { first = item.anchor.start_line, last = item.anchor.end_line }
			or nil,
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
	direct_mutation(id, "Delete review comment", function(workspace, item)
		return review_store.delete(workspace.session, item.id)
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
			notify("General review comments do not have a location to reanchor", vim.log.levels.INFO)
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
				anchor, anchor_err = make_anchor(current, target, "file", 1, 1)
			else
				local length = (item.anchor.end_line or item.anchor.start_line) - item.anchor.start_line
				local first = vim.api.nvim_win_get_cursor(target.win)[1]
				anchor, anchor_err = make_anchor(current, target, "range", first, first + length)
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
	if anchor.side == "left" and workspace.layout == "inline" and not entry.deleted then
		workspace.layout = "split"
	end
	local shown, err = M.present(entry.identity)
	if not shown then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	local presentation = workspace.mode_state.presentation
	local target = anchor.side == "left" and presentation.left or presentation.right or presentation.inline
	if not target or not valid_win(target.win) then
		notify("Comment side is unavailable", vim.log.levels.ERROR)
		return false
	end
	vim.api.nvim_set_current_win(target.win)
	if anchor.start_line then
		local line = math.max(1, math.min(anchor.start_line, vim.api.nvim_buf_line_count(target.buf)))
		vim.api.nvim_win_set_cursor(target.win, { line, math.max(0, (anchor.start_column or 1) - 1) })
	end
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
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	local blocked = publishing_transition_error("refresh the review") or unsaved_transition_error("refresh it")
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
		local shown, show_err = M.present(identity)
		if not shown then
			notify("Model refreshed but presentation failed: " .. tostring(show_err), vim.log.levels.ERROR)
			return nil
		end
	end
	update_panel(workspace)
	M.refresh_marks(workspace)
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

local function publish_queue(session)
	local queue, eligible = {}, {}
	for _, item in ipairs(session.items) do
		if review_store.delivery_eligible(item) then
			queue[#queue + 1] = item.id
			eligible[item.id] = true
		end
	end
	for _, id in ipairs(queue) do
		local item = find_item(session, id)
		if not null(item.reply_to) then
			local parent = find_item(session, item.reply_to)
			if not parent or (not review_store.tuicr_receipt(parent) and not eligible[parent.id]) then
				return nil, "open reply " .. id .. " has no publishable or delivered parent"
			end
		end
	end
	return queue
end

local function tuicr_anchor(anchor)
	local value = {}
	for _, name in ipairs({ "path", "side", "start_line", "end_line" }) do
		if not null(anchor[name]) then
			value[name] = anchor[name]
		end
	end
	return value
end

local function tuicr_author()
	if type(vim.g.review_author) == "string" and vim.g.review_author:find("%S") then
		return vim.trim(vim.g.review_author)
	end
	if type(vim.env.USER) == "string" and vim.env.USER:find("%S") then
		return vim.trim(vim.env.USER)
	end
	return "Reviewer"
end

local function tuicr_delivery_key(action, round, item, values)
	local payload = {
		"nvim-review-tuicr-v1",
		action,
		round,
		item.id,
		values.author,
		values.type,
		values.body,
		values.anchor.path or vim.NIL,
		values.anchor.side or vim.NIL,
		values.anchor.start_line or vim.NIL,
		values.anchor.end_line or vim.NIL,
		values.reply_to or vim.NIL,
	}
	return item.id .. ":" .. vim.fn.sha256(vim.json.encode(payload))
end

local function publication_snapshot(session, id)
	local item = find_item(session, id)
	if not item then
		return nil
	end
	return {
		id = id,
		revision = session.revision,
		bridge = vim.deepcopy(session.bridge),
		item = vim.deepcopy(item),
		session = vim.deepcopy(session),
	}
end

local function publication_snapshot_matches(session, snapshot)
	return type(session) == "table"
		and type(snapshot) == "table"
		and session.revision == snapshot.revision
		and vim.deep_equal(session.bridge, snapshot.bridge)
		and vim.deep_equal(find_item(session, snapshot.id), snapshot.item)
end

local function save_publication_recovery(root, snapshot, receipt)
	local delivered, mark_err = review_store.mark_tuicr_delivered(snapshot.session, snapshot.id, receipt)
	if not delivered then
		return nil, mark_err
	end
	local markdown, render_err = review_export.render_recovery(delivered)
	if not markdown then
		return nil, render_err
	end
	return save_verified_recovery(root, delivered, markdown)
end

local function finish_publication(expected, publication, text, level)
	if publishing[expected] ~= publication then
		return false
	end
	publishing[expected] = nil
	if text then
		notify(text, level)
	end
	return true
end

function M.publish(force)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	local expected = workspace_key(workspace)
	if next(publishing) then
		notify("TUICR publication is already in progress", vim.log.levels.WARN)
		return nil
	end
	if workspace.unsaved_error then
		notify("Review has an unsaved conflict; resolve it before publishing", vim.log.levels.ERROR)
		return nil
	end
	local snapshot = verified_persisted_snapshot(workspace, "publish review")
	if not snapshot then
		return nil
	end
	if null(snapshot.bridge) or snapshot.bridge.backend ~= "tuicr" then
		notify("Review is not linked to a TUICR round", vim.log.levels.ERROR)
		return nil
	end
	local stale, stale_err = stale_now(workspace)
	if stale == nil then
		notify("Could not check review drift: " .. stale_err, vim.log.levels.ERROR)
		return nil
	end
	local is_stale = stale or session_has_stale_location(snapshot)
	if is_stale and not force then
		notify("Review is stale; use :ReviewPublish! only after verifying the exact snapshot", vim.log.levels.ERROR)
		return nil
	end
	if is_stale then
		if stale then
			snapshot.stale = true
		end
		local markdown, render_err = review_export.render(snapshot, true)
		if not markdown then
			notify(render_err, vim.log.levels.ERROR)
			return nil
		end
		local receipt, recovery_err = save_verified_recovery(workspace.root, snapshot, markdown)
		if not receipt then
			notify("Could not save exact review recovery: " .. tostring(recovery_err), vim.log.levels.ERROR)
			return nil
		end
	end
	local queue, queue_err = publish_queue(snapshot)
	if not queue then
		notify(queue_err, vim.log.levels.ERROR)
		return nil
	elseif #queue == 0 then
		notify("No open undelivered TUICR comments")
		return true
	end
	local publication = {}
	publishing[expected] = publication
	local index, receipts = 1, {}
	local function step()
		local current = workspace_for_key(expected)
		local id = queue[index]
		if publishing[expected] ~= publication then
			return
		elseif not current then
			finish_publication(
				expected,
				publication,
				"Review session closed during TUICR publication",
				vim.log.levels.ERROR
			)
			return
		elseif not id then
			finish_publication(expected, publication, "Published " .. #queue .. " review comments to TUICR")
			update_panel(current)
			return
		end
		local authoritative = verified_persisted_snapshot(current, "continue TUICR publication")
		if not authoritative then
			finish_publication(expected, publication)
			return
		end
		local item = find_item(authoritative, id)
		if not item or not review_store.delivery_eligible(item) then
			finish_publication(
				expected,
				publication,
				"Review comment changed during TUICR publication",
				vim.log.levels.ERROR
			)
			return
		end
		local values = {
			author = tuicr_author(),
			type = item.type,
			body = item.body,
			anchor = tuicr_anchor(item.anchor),
		}
		local action = "add"
		local operation = review_tuicr.add
		if not null(item.reply_to) then
			local parent = find_item(authoritative, item.reply_to)
			values.reply_to = receipts[item.reply_to] or review_store.tuicr_receipt(parent)
			action = "respond"
			operation = review_tuicr.respond
		end
		values.delivery_key = tuicr_delivery_key(action, authoritative.bridge.round, item, values)
		local operation_snapshot = publication_snapshot(authoritative, id)
		local function preflight()
			local latest = workspace_for_key(expected)
			if publishing[expected] ~= publication or not latest then
				return nil, "review publication is no longer active"
			end
			if not publication_snapshot_matches(latest.session, operation_snapshot) then
				return nil, "live review revision, TUICR link, or item payload changed during round status"
			end
			local persisted, persisted_err = matching_persisted_snapshot(latest)
			if not persisted then
				return nil, persisted_err
			end
			if not publication_snapshot_matches(persisted, operation_snapshot) then
				return nil, "persisted review revision, TUICR link, or item payload changed during round status"
			end
			return true
		end
		operation(
			current.root,
			authoritative.bridge.round,
			values,
			{ preflight = preflight },
			function(receipt, publish_err)
				if not receipt then
					finish_publication(
						expected,
						publication,
						"TUICR publication failed: " .. message(publish_err),
						vim.log.levels.ERROR
					)
					return
				end
				local latest = workspace_for_key(expected)
				local receipt_conflict
				if publishing[expected] ~= publication then
					receipt_conflict = "the publication generation changed"
				elseif not latest then
					receipt_conflict = "the review session closed"
				elseif not publication_snapshot_matches(latest.session, operation_snapshot) then
					receipt_conflict = "the live review revision, TUICR link, or item payload changed"
				else
					local persisted, persisted_err = matching_persisted_snapshot(latest)
					if not persisted then
						receipt_conflict = persisted_err
					elseif not publication_snapshot_matches(persisted, operation_snapshot) then
						receipt_conflict = "the persisted review revision, TUICR link, or item payload changed"
					end
				end
				if receipt_conflict then
					local recovery_receipt, recovery_err =
						save_publication_recovery(current.root, operation_snapshot, receipt.id)
					local recovery_detail = recovery_receipt and ("recovery saved to " .. recovery_receipt.path)
						or ("recovery failed: " .. tostring(recovery_err))
					finish_publication(
						expected,
						publication,
						"TUICR accepted receipt "
							.. receipt.id
							.. " for the exact comment, but "
							.. receipt_conflict
							.. "; its receipt was not attached to different content; "
							.. recovery_detail,
						vim.log.levels.ERROR
					)
					return
				end
				local changed, mark_err = review_store.mark_tuicr_delivered(latest.session, id, receipt.id)
				if not changed then
					finish_publication(
						expected,
						publication,
						"Could not persist TUICR receipt " .. receipt.id .. ": " .. tostring(mark_err or "save failed"),
						vim.log.levels.ERROR
					)
					return
				end
				local saved, save_err = save_mutation(latest, changed)
				if not saved then
					finish_publication(
						expected,
						publication,
						"TUICR accepted receipt "
							.. receipt.id
							.. " for the exact comment, but it could not be persisted: "
							.. tostring(save_err or "save failed"),
						vim.log.levels.ERROR
					)
					return
				end
				receipts[id] = receipt.id
				index = index + 1
				step()
			end
		)
	end
	step()
	return true
end

local function round_id(round)
	return type(round) == "table" and (round.round or round.id) or nil
end

function M.link_tuicr(requested)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local expected = workspace_key(workspace)
	local function link(round)
		local current = active_for_key(expected, "linking a TUICR round")
		if not current or not allow_mutation(current) then
			return
		end
		local changed, err = review_store.link_tuicr(current.session, round_id(round) or round)
		if changed then
			save_mutation(current, changed)
		else
			notify(err, vim.log.levels.ERROR)
		end
	end
	review_tuicr.list_rounds(workspace.root, function(rounds, err)
		if not rounds then
			notify("Could not list TUICR rounds: " .. message(err), vim.log.levels.ERROR)
			return
		end
		if requested and requested ~= "" then
			for _, round in ipairs(rounds) do
				if round_id(round) == requested then
					link(round)
					return
				end
			end
			notify("TUICR round is not open for this repository", vim.log.levels.ERROR)
			return
		end
		vim.ui.select(rounds, { prompt = "TUICR round", format_item = round_id }, function(round)
			if round then
				link(round)
			end
		end)
	end)
end

local function anchor_targets_buffer(workspace, anchor, buf)
	if anchor.kind == "general" then
		return false
	end
	if vim.b[buf].nvim_review_path == anchor.path then
		return vim.b[buf].nvim_review_side == anchor.side and vim.b[buf].nvim_review_layer == anchor.layer
	end
	for _, target in ipairs(normal_targets(workspace, buf, 0)) do
		if target.path == anchor.path and target.side == anchor.side and target.layer == anchor.layer then
			return true
		end
	end
	return false
end

function M.decorate_buffer(workspace, buf)
	workspace = workspace or current_workspace()
	if not workspace or not valid_buf(buf) or vim.b[buf].nvim_review_role == "panel" then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, NAMESPACE, 0, -1)
	local count = vim.api.nvim_buf_line_count(buf)
	local marks = {}
	for _, item in ipairs(workspace.session.items or {}) do
		local anchor = item.anchor
		if anchor.kind == "range" and anchor_targets_buffer(workspace, anchor, buf) then
			local first = math.max(1, math.min(anchor.start_line, count))
			local last = math.max(first, math.min(anchor.end_line or first, count))
			local sign = TYPE_SIGNS[item.type] or TYPE_SIGNS.question
			for line = first, last do
				local text = sign.text
				if last > first then
					text = line == first and "╭" or line == last and "╰" or "│"
				end
				marks[line] = marks[line] or {}
				marks[line][#marks[line] + 1] = { text = text, highlight = sign.highlight }
			end
		end
	end
	for line, entries in pairs(marks) do
		local options = { priority = 80 }
		if #entries == 1 then
			options.sign_text = entries[1].text
			options.sign_hl_group = entries[1].highlight
		else
			options.sign_text = #entries < 10 and tostring(#entries) or "9+"
			options.sign_hl_group = "DiagnosticSignInfo"
			options.virt_text = { { string.format("  %d review comments", #entries), "Comment" } }
			options.virt_text_pos = "eol"
		end
		vim.api.nvim_buf_set_extmark(buf, NAMESPACE, line - 1, 0, options)
	end
end

function M.refresh_marks(workspace)
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
		if valid_buf(buf) and (buffer_in_root(workspace.root, buf) or vim.b[buf].nvim_review_path) then
			M.decorate_buffer(workspace, buf)
		end
	end
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
	if suspended then
		return nil, "review UI is already suspended"
	elseif next(publishing) then
		return nil, "TUICR publication is still in progress"
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
		state.panel = review_panel.suspend(workspace.panel)
		if workspace.mode_state.presentation then
			review_presenter.clear(workspace.mode_state)
		end
		state.mode = review_mode.suspend(workspace.mode_state)
		workspace.mode_on = false
	end
	suspended = state
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
		workspace.entry_identity = first_identity(workspace.model, state.entry)
		local restored, restore_err = review_mode.restore(workspace.mode_state, state.mode)
		if not restored then
			review_mode.disable(workspace.mode_state)
			review_panel.hide(workspace.panel)
			return finish(nil, "could not restore review mode: " .. tostring(restore_err), false)
		end
		workspace.mode_on = state.mode_on == true
		if workspace.mode_on and workspace.entry_identity then
			local shown, show_err = M.present(workspace.entry_identity, state.key)
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
	return finish(true, nil, true)
end

function M.close(force)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return false
	end
	local expected = workspace_key(workspace)
	if next(publishing) then
		notify("Wait for TUICR publication to finish", vim.log.levels.WARN)
		return false
	elseif review_editor.has_active() then
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
	M.refresh_marks(nil)
	refresh_trouble()
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

local function command(name, callback, options)
	if vim.fn.exists(":" .. name) == 2 then
		vim.api.nvim_del_user_command(name)
	end
	vim.api.nvim_create_user_command(name, callback, options or {})
end

local function setup_commands()
	command("ReviewOpen", function(value)
		local request = parse_open(vim.split(value.args, "%s+", { trimempty = true }))
		if request then
			M.open(request)
		else
			notify("Usage: ReviewOpen [working|commit [REV]|range FROM TO|branch [BASE [HEAD]]]", vim.log.levels.ERROR)
		end
	end, {
		nargs = "*",
		complete = function()
			return { "working", "commit", "range", "branch" }
		end,
	})
	command("ReviewScope", function()
		local root = root_for_command()
		if root then
			scope_picker(root)
		else
			notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		end
	end)
	command("ReviewSessions", function()
		local root = root_for_command()
		if root then
			choose_saved(root)
		end
	end)
	command("ReviewMode", function(value)
		M.mode(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})
	command("ReviewPanel", function(value)
		M.panel(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "toggle", "open", "close", "files", "commits", "comments" }
		end,
	})
	command("ReviewFiles", M.files)
	command("ReviewCommits", M.commits)
	command("ReviewComments", M.comments)
	command("ReviewThreads", M.comments)
	command("ReviewCode", M.code)
	command("ReviewLayout", function(value)
		M.layout(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "inline", "split" }
		end,
	})
	command("ReviewContext", function(value)
		M.context(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "hunks", "full" }
		end,
	})
	command("ReviewComment", function(value)
		M.comment(value.line1, value.line2, value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return vim.deepcopy(REVIEW_TYPES)
		end,
	})
	command("ReviewFileComment", function(value)
		M.file_comment(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return vim.deepcopy(REVIEW_TYPES)
		end,
	})
	command("ReviewGeneralComment", function(value)
		M.general_comment(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return vim.deepcopy(REVIEW_TYPES)
		end,
	})
	command("ReviewEdit", function(value)
		M.edit(value.args)
	end, { nargs = "?" })
	command("ReviewDeleteDraft", function(value)
		M.delete(value.args)
	end, { nargs = "?" })
	command("ReviewChangeType", function(value)
		M.change_type(value.args)
	end, { nargs = "?" })
	command("ReviewReply", function(value)
		M.reply(value.args)
	end, { nargs = "?" })
	command("ReviewResolve", function(value)
		M.resolve(value.args)
	end, { nargs = "?" })
	command("ReviewReopen", function(value)
		M.reopen(value.args)
	end, { nargs = "?" })
	command("ReviewToggleResolve", function(value)
		M.toggle_resolution(value.args)
	end, { nargs = "?" })
	command("ReviewReanchor", function(value)
		M.reanchor(value.args)
	end, { nargs = "?" })
	command("ReviewNext", M.next)
	command("ReviewPrev", M.prev)
	command("ReviewRefresh", M.refresh)
	command("ReviewExport", function(value)
		M.export(value.bang)
	end, { bang = true })
	command("ReviewPublish", function(value)
		M.publish(value.bang)
	end, { bang = true })
	command("ReviewLinkTuicr", function(value)
		M.link_tuicr(value.args ~= "" and value.args or nil)
	end, { nargs = "?" })
	command("ReviewClose", function(value)
		M.close(value.bang)
	end, { bang = true })
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

local function setup_mappings()
	for _, mapping in ipairs(MAPPINGS) do
		vim.keymap.set("n", mapping.lhs, mapping.rhs, { silent = true, desc = mapping.desc })
	end
	vim.keymap.set("x", "<leader>ra", ":<C-U>'<,'>ReviewComment<CR>", {
		silent = true,
		desc = "Add review comment for selected lines",
	})
end

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("NvimConfigCodeReview", { clear = true })
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
	setup_commands()
	setup_mappings()
	setup_autocmds()
end

M._parse_open = parse_open
M._workspaces = workspaces
M._active_workspace = current_workspace
M._open_scope_picker = scope_picker
M._contains_line = contains_line

return M
