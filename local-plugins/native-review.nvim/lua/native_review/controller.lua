-- Repository/session-scoped standalone native reviews in one owner-managed tab.
local M = {}

local repo = require("native_review.dependencies").get("repo")
local fs = require("native_review.dependencies").get("fs")
local config = require("native_review.dependencies").get("config")
local tabs = require("native_review.dependencies").get("tabs")
local clipboard = require("native_review.dependencies").get("clipboard")
local comment_types = require("native_review.comment_types")
local review_changes = require("native_review.changes")
local review_editor = require("native_review.editor")
local review_export = require("native_review.export")
local review_lsp = require("native_review.lsp")
local review_mode = require("native_review.mode")
local review_panel = require("native_review.panel")
local review_presenter = require("native_review.presenter")
local review_scope = require("native_review.scope")
local review_store = require("native_review.store")
local review_structural = require("native_review.structural")
local review_engines = require("native_review.engines")

local NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_comments")
local PREVIEW_NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_comment_preview")
local function select_review(items, options, callback)
	options.kind = "native_review"
	vim.ui.select(items, options, callback)
end

local function apply_comment_highlights()
	for _, definition in ipairs(comment_types.all()) do
		if definition.highlight ~= definition.default_link then
			vim.api.nvim_set_hl(0, definition.highlight, { default = true, link = definition.default_link })
		end
	end
end

apply_comment_highlights()
local comment_highlight_group = vim.api.nvim_create_augroup("NvimReviewCommentHighlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
	group = comment_highlight_group,
	callback = apply_comment_highlights,
})
local workspaces = {}
local active
local suspended
local scope_history = {}
local setup_done = false
local inline_preview
local review_surface
local pending_surface_close
local invocation
local surface_transition = false
local handle_surface_request_close
local handle_surface_closed
local workspace_generation = 0
local definition_navigation_options
local operation_epoch = 0
local pending_operation
local pending_engine
local function cancel_engine()
	local pending = pending_engine
	pending_engine = nil
	if pending and pending.cancel then
		pending.cancel()
	end
end
local HISTORY_PROVIDER = "native-review"
local ENTRY_SNAPSHOT_FIELDS = {
	"layer",
	"status",
	"score",
	"old_mode",
	"new_mode",
	"old_oid",
	"new_oid",
	"old_path",
	"new_path",
	"renamed",
	"copied",
	"added",
	"deleted",
	"submodule",
	"conflicted",
	"path",
	"identity",
	"binary",
	"metadata_only",
	"old_text",
	"new_text",
	"hunks",
}
local focus_snapshot
local restore_focus
local surface_focus_snapshot

local function notify(message, level)
	vim.notify(tostring(message), level or vim.log.levels.INFO, { title = "Review" })
end

local function message(err)
	if type(err) ~= "table" then
		return tostring(err)
	end
	if err.code == "review_limit_exceeded" and type(err.details) == "table" then
		local details = err.details
		return ("%s [%s %s, %s: %s > %s]"):format(
			err.message or err.code,
			tostring(details.layer),
			tostring(details.side),
			tostring(details.limit),
			tostring(details.actual),
			tostring(details.maximum)
		)
	end
	return err.message or err.code or vim.inspect(err)
end

local function construction_options(control)
	return {
		control = control,
		max_files = config.max_files,
		max_file_bytes = config.max_file_bytes,
		max_model_bytes = config.max_model_bytes,
	}
end

local function operation_checkpoint(options, phase, progress)
	local callback = options and options.control and options.control.checkpoint
	if type(callback) ~= "function" then
		return true
	end
	local continued, err = callback(phase, vim.deepcopy(progress or {}))
	if continued == false then
		return nil, tostring(err or "review operation was cancelled")
	end
	return true
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

local function bump_workspace_generation(workspace)
	cancel_engine()
	review_structural.close()
	workspace_generation = workspace_generation + 1
	workspace.generation = workspace_generation
	return workspace.generation
end

local function interaction_token()
	local workspace = current_workspace()
	return {
		generation = workspace_generation,
		workspace_key = workspace and workspace_key(workspace) or nil,
	}
end

local function resolve_interaction_token(token, action)
	local workspace = current_workspace()
	local current_key = workspace and workspace_key(workspace) or nil
	if type(token) ~= "table" or token.generation ~= workspace_generation or token.workspace_key ~= current_key then
		notify("Active review changed while " .. action .. "; no changes were made", vim.log.levels.WARN)
		return false
	end
	return true
end

local function find_item(session, id)
	for _, item in ipairs(session and session.items or {}) do
		if item.id == id then
			return item
		end
	end
	return nil
end

local function workspace_token(workspace)
	return {
		workspace_key = workspace_key(workspace),
		generation = workspace.generation,
	}
end

local function resolve_workspace_token(token, action)
	if type(token) ~= "table" then
		notify("Review selection was invalid; no changes were made", vim.log.levels.WARN)
		return nil
	end
	local workspace = current_workspace()
	if not workspace or workspace_key(workspace) ~= token.workspace_key then
		notify("Active review changed while " .. action .. "; no changes were made", vim.log.levels.WARN)
		return nil
	end
	if workspace.generation ~= token.generation then
		notify("Review changed while " .. action .. "; no changes were made", vim.log.levels.WARN)
		return nil
	end
	return workspace
end

local function item_token(workspace, item)
	return {
		workspace_key = workspace_key(workspace),
		generation = workspace.generation,
		item_id = item.id,
	}
end

local function resolve_item_token(token, action)
	local workspace = resolve_workspace_token(token, action)
	if not workspace then
		return nil
	end
	local item = find_item(workspace.session, token.item_id)
	if not item then
		notify("Review comment changed while " .. action .. "; no changes were made", vim.log.levels.WARN)
		return nil
	end
	return workspace, item
end

local function find_entry(workspace, identity)
	for _, entry in ipairs(workspace.model.entries or {}) do
		if entry.identity == identity then
			return entry
		end
	end
	return nil
end

local function entry_snapshot(entry)
	if type(entry) ~= "table" then
		return nil
	end
	local snapshot = {}
	for _, field in ipairs(ENTRY_SNAPSHOT_FIELDS) do
		local value = entry[field]
		snapshot[field] = type(value) == "table" and vim.deepcopy(value) or value
	end
	return snapshot
end

local function entry_matches_snapshot(entry, snapshot)
	local current = entry_snapshot(entry)
	return current ~= nil and type(snapshot) == "table" and vim.deep_equal(current, snapshot)
end

local function same_entry(left, right)
	local snapshot = entry_snapshot(left)
	return snapshot ~= nil and entry_matches_snapshot(right, snapshot)
end

local function status_side(workspace, entry)
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	if presentation and same_entry(presentation.entry, entry) then
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
		local status = { active = false, mode_on = false }
		if pending_operation then
			status.pending = true
			status.operation = {
				kind = pending_operation.kind,
				epoch = pending_operation.epoch,
				phase = pending_operation.phase,
				progress = vim.deepcopy(pending_operation.progress),
			}
		end
		return status
	end
	local status = {
		active = true,
		mode_on = workspace.mode_on == true,
		scope_kind = workspace.scope and workspace.scope.kind or nil,
		scope_label = workspace.scope and workspace.scope.label or nil,
		layout = workspace.layout,
		context = workspace.context,
		engine = workspace.engine or "main",
		effective_engine = workspace.mode_state and workspace.mode_state.presentation and vim.deepcopy(
			workspace.mode_state.presentation.origin_engine
		) or nil,
		inline_comments = workspace.inline_comments ~= false,
	}
	if pending_operation then
		status.pending = true
		status.operation = {
			kind = pending_operation.kind,
			epoch = pending_operation.epoch,
			phase = pending_operation.phase,
			progress = vim.deepcopy(pending_operation.progress),
		}
	end
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
	local event = require("native_review.dependencies").get("event")
	pcall(event, vim.deepcopy(M.status()))
end

local function cancel_pending(reason, emit)
	cancel_engine()
	review_structural.close()
	operation_epoch = operation_epoch + 1
	local pending = pending_operation
	pending_operation = nil
	if pending then
		pending.cancelled = reason or "cancelled"
		if emit then
			emit_changed()
		end
		return true
	end
	return false
end

local function start_async(kind, worker, callback)
	assert(type(worker) == "function", "async review worker must be a function")
	assert(callback == nil or type(callback) == "function", "async review callback must be a function")
	cancel_pending("superseded", false)
	operation_epoch = operation_epoch + 1
	local epoch = operation_epoch
	local operation = {
		kind = kind,
		epoch = epoch,
		phase = "scheduled",
		progress = {},
	}
	pending_operation = operation
	emit_changed()

	local control = {}
	function control.checkpoint(phase, progress)
		if epoch ~= operation_epoch or pending_operation ~= operation then
			return false, "review operation was superseded"
		end
		operation.phase = phase
		operation.progress = vim.deepcopy(progress or {})
		coroutine.yield()
		if epoch ~= operation_epoch or pending_operation ~= operation then
			return false, "review operation was superseded"
		end
		return true
	end

	local thread = coroutine.create(function()
		return worker(control)
	end)
	local function finish(first, second)
		if epoch ~= operation_epoch or pending_operation ~= operation then
			return
		end
		pending_operation = nil
		emit_changed()
		if callback then
			local ok, callback_err = pcall(callback, first, second)
			if not ok then
				notify("Review operation callback failed: " .. tostring(callback_err), vim.log.levels.ERROR)
			end
		end
	end
	local function step()
		if epoch ~= operation_epoch or pending_operation ~= operation then
			return
		end
		local ok, first, second = coroutine.resume(thread)
		if not ok then
			pending_operation = nil
			notify("Review " .. kind .. " failed: " .. tostring(first), vim.log.levels.ERROR)
			emit_changed()
			return
		end
		if coroutine.status(thread) == "dead" then
			finish(first, second)
		else
			vim.schedule(step)
		end
	end
	vim.schedule(step)
	return {
		kind = kind,
		epoch = epoch,
		cancel = function()
			if epoch == operation_epoch and pending_operation == operation then
				cancel_pending("cancelled", true)
				return true
			end
			return false
		end,
	}
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

local function update_panel(workspace, selected_identity)
	if workspace.panel then
		return review_panel.refresh(workspace.panel, workspace, selected_identity)
	end
	return true
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
		bump_workspace_generation(workspace)
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
	bump_workspace_generation(workspace)
	workspace.unsaved_error = nil
	workspace.recovery = nil
	update_panel(workspace)
	M.refresh_marks(workspace)
	refresh_trouble()
	return true
end

local function mutation_failed(workspace, err)
	if registered(workspace) then
		bump_workspace_generation(workspace)
	end
	notify(err, vim.log.levels.ERROR)
	return false
end

local function stale_now(workspace, control)
	if workspace.scope.kind ~= "working" then
		return false
	end
	local drift, err = review_scope.detect_drift(workspace.scope, construction_options(control))
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

local function same_surface(first, second)
	return type(first) == "table"
		and type(second) == "table"
		and first.tabpage == second.tabpage
		and first.token == second.token
end

local function surface_valid()
	return review_surface ~= nil and tabs.valid_transient(review_surface) == true
end

local function on_surface()
	return surface_valid() and vim.api.nvim_get_current_tabpage() == review_surface.tabpage
end

local function encoded_history_key(...)
	local values = { ... }
	for index, value in ipairs(values) do
		values[index] = ("%d:%s"):format(#value, value)
	end
	return table.concat(values, "|")
end

local function history_document_key(payload)
	return encoded_history_key(
		payload.workspace_key,
		payload.scope_id,
		payload.entry_identity,
		payload.layer,
		payload.side,
		payload.path
	)
end

local function history_location_key(payload)
	return ("%d:%d"):format(payload.line, payload.col)
end

local function source_line_count(text)
	if text == "" then
		return 0
	end
	local _, newlines = text:gsub("\n", "")
	return newlines + (text:sub(-1) == "\n" and 0 or 1)
end

local function validate_history_location(entry, location)
	if type(location) ~= "table" then
		return false
	elseif type(location.entry_identity) ~= "string" or location.entry_identity ~= entry.identity then
		return false
	elseif type(location.layer) ~= "string" or location.layer ~= (entry.layer or "history") then
		return false
	elseif location.side ~= "old" and location.side ~= "new" then
		return false
	elseif type(location.path) ~= "string" or location.path == "" then
		return false
	elseif location.path ~= (location.side == "old" and entry.old_path or entry.new_path) then
		return false
	elseif type(location.line) ~= "number" or location.line % 1 ~= 0 or location.line < 0 then
		return false
	elseif type(location.col) ~= "number" or location.col % 1 ~= 0 or location.col < 1 then
		return false
	elseif location.line == 0 and location.col ~= 1 then
		return false
	end
	local text = location.side == "old" and entry.old_text or entry.new_text
	local line_count = entry.metadata_only and 0 or source_line_count(type(text) == "string" and text or "")
	return (location.line == 0 and line_count == 0) or (location.line >= 1 and location.line <= line_count)
end

local function valid_provider_entry(value)
	local payload = type(value) == "table" and value.payload or nil
	if
		type(payload) ~= "table"
		or value.kind ~= "provider"
		or value.provider ~= HISTORY_PROVIDER
		or type(value.document_key) ~= "string"
		or value.document_key == ""
		or type(value.location_key) ~= "string"
		or value.location_key == ""
		or type(value.label) ~= "string"
		or type(payload.workspace_key) ~= "string"
		or payload.workspace_key == ""
		or type(payload.workspace_generation) ~= "number"
		or payload.workspace_generation % 1 ~= 0
		or type(payload.scope_id) ~= "string"
		or payload.scope_id == ""
		or type(payload.entry_identity) ~= "string"
		or payload.entry_identity == ""
		or type(payload.layer) ~= "string"
		or payload.layer == ""
		or (payload.side ~= "old" and payload.side ~= "new")
		or type(payload.path) ~= "string"
		or payload.path == ""
		or type(payload.line) ~= "number"
		or payload.line % 1 ~= 0
		or payload.line < 0
		or type(payload.col) ~= "number"
		or payload.col % 1 ~= 0
		or payload.col < 1
	then
		return nil
	end
	if value.document_key ~= history_document_key(payload) or value.location_key ~= history_location_key(payload) then
		return nil
	end
	return payload
end

local function presentation_source_window(state, win)
	local presentation = state and state.presentation or nil
	local entry = presentation and presentation.entry or nil
	for _, name in ipairs({ "inline", "left", "right" }) do
		local candidate = presentation and presentation[name] or nil
		if candidate and candidate.win == win then
			if candidate.side == "unified" then
				return type(entry) == "table"
					and (
						type(entry.old_path) == "string" and entry.old_path ~= ""
						or type(entry.new_path) == "string" and entry.new_path ~= ""
					)
			end
			local path = candidate.side == "old" and entry and entry.old_path
				or candidate.side == "new" and entry and entry.new_path
				or nil
			return type(path) == "string" and path ~= ""
		end
	end
	return false
end

---Capture the current review cursor without exposing transient UI identities.
---@return table?
---@return string? err
function M.capture_location()
	local workspace = current_workspace()
	local state = workspace and workspace.mode_state or nil
	if
		not workspace
		or not registered(workspace)
		or suspended ~= nil
		or not surface_valid()
		or not on_surface()
		or workspace.mode_on ~= true
		or not state
		or state.enabled ~= true
		or type(workspace.scope) ~= "table"
		or type(workspace.scope.id) ~= "string"
		or workspace.scope.id == ""
	then
		return nil
	end
	local current_win = vim.api.nvim_get_current_win()
	if not presentation_source_window(state, current_win) then
		return nil
	elseif type(review_presenter.capture_location) ~= "function" then
		return nil, "review presenter capture callback is unavailable"
	end
	local workspace_key_before = workspace_key(workspace)
	local workspace_generation = workspace.generation
	local scope_id = workspace.scope.id
	local entry_identity = workspace.entry_identity
	local presentation = state.presentation
	local presentation_generation = presentation and presentation.generation or nil
	local presentation_entry_snapshot = entry_snapshot(presentation and presentation.entry or nil)
	local expected_surface = vim.deepcopy(review_surface)
	local location, capture_err = review_presenter.capture_location(state)
	if not location then
		return nil, capture_err or "review source location could not be captured"
	end
	if
		current_workspace() ~= workspace
		or not registered(workspace)
		or workspace_key(workspace) ~= workspace_key_before
		or workspace.generation ~= workspace_generation
		or type(workspace.scope) ~= "table"
		or workspace.scope.id ~= scope_id
		or not same_surface(review_surface, expected_surface)
		or not surface_valid()
		or not on_surface()
		or workspace.mode_on ~= true
		or workspace.mode_state ~= state
		or state.enabled ~= true
		or state.presentation ~= presentation
		or not state.presentation
		or state.presentation.generation ~= presentation_generation
		or workspace.entry_identity ~= entry_identity
		or vim.api.nvim_get_current_win() ~= current_win
		or not presentation_source_window(state, current_win)
	then
		return nil, "review owner changed while capturing the source location"
	end
	if location.entry_identity ~= entry_identity then
		return nil, "captured review entry changed during location capture"
	end
	local entry = find_entry(workspace, location.entry_identity)
	if not entry then
		return nil, "captured review entry is no longer available"
	elseif not validate_history_location(entry, location) then
		return nil, "captured review location is invalid"
	elseif not entry_matches_snapshot(entry, presentation_entry_snapshot) then
		return nil, "captured review entry no longer matches the current model"
	end
	local payload = {
		workspace_key = workspace_key_before,
		workspace_generation = workspace_generation,
		scope_id = scope_id,
		entry_identity = location.entry_identity,
		layer = location.layer,
		side = location.side,
		path = location.path,
		line = location.line,
		col = location.col,
	}
	return {
		kind = "provider",
		provider = HISTORY_PROVIDER,
		document_key = history_document_key(payload),
		location_key = history_location_key(payload),
		label = ("Review %s %s:%d:%d"):format(payload.side:upper(), payload.path, payload.line, payload.col),
		payload = payload,
	}
end

local function history_owner_current(workspace, state, payload, expected_surface)
	return current_workspace() == workspace
		and registered(workspace)
		and workspace_key(workspace) == payload.workspace_key
		and workspace.generation == payload.workspace_generation
		and type(workspace.scope) == "table"
		and workspace.scope.id == payload.scope_id
		and same_surface(review_surface, expected_surface)
		and surface_valid()
		and workspace.mode_on == true
		and workspace.mode_state == state
		and state.enabled == true
end

local function history_surface_current(workspace, state, expected_surface)
	return current_workspace() == workspace
		and registered(workspace)
		and same_surface(review_surface, expected_surface)
		and surface_valid()
		and workspace.mode_state == state
end

local function history_presentation_entry(workspace, state, location, expected_entry_snapshot)
	local entry = find_entry(workspace, location.entry_identity)
	if not entry then
		return nil, "review entry is no longer available"
	elseif not validate_history_location(entry, location) then
		return nil, "review location no longer matches the current model"
	elseif not entry_matches_snapshot(entry, expected_entry_snapshot) then
		return nil, "review entry changed in the current model"
	elseif not state.presentation then
		return nil, "review presentation is no longer available"
	elseif not entry_matches_snapshot(state.presentation.entry, expected_entry_snapshot) then
		return nil, "review presentation no longer matches the current model"
	end
	return entry
end

local function call_history_operation(callback, ...)
	local ok, first, second = pcall(callback, ...)
	if not ok then
		return nil, tostring(first)
	end
	return first, second
end

local function history_restore_snapshot(workspace, state, expected_surface)
	local previous_entry = find_entry(workspace, workspace.entry_identity)
	local snapshot = {
		entry_identity = workspace.entry_identity,
		entry_snapshot = entry_snapshot(previous_entry),
		caller_focus = focus_snapshot(workspace),
		review_focus = surface_focus_snapshot(workspace),
		locations = {},
	}
	local candidates = {}
	local seen = {}
	local function add_candidate(win)
		if valid_win(win) and vim.api.nvim_win_get_tabpage(win) == expected_surface.tabpage and not seen[win] then
			seen[win] = true
			candidates[#candidates + 1] = win
		end
	end
	if valid_tab(expected_surface.tabpage) then
		add_candidate(vim.api.nvim_tabpage_get_win(expected_surface.tabpage))
	end
	add_candidate(workspace.panel and workspace.panel.source_win or nil)
	local target_ok, target = pcall(review_presenter.current_target, state)
	if not target_ok then
		return nil, "previous review target could not be inspected: " .. tostring(target)
	end
	add_candidate(target and target.win or nil)
	for _, name in ipairs({ "inline", "left", "right" }) do
		local pane = state.presentation and state.presentation[name] or nil
		add_candidate(pane and pane.win or nil)
	end
	for _, win in ipairs(candidates) do
		local snapshot_err
		local call_ok, call_err = pcall(vim.api.nvim_win_call, win, function()
			if previous_entry and presentation_source_window(state, win) then
				local pane_focus = focus_snapshot(workspace)
				if type(review_presenter.capture_location) ~= "function" then
					snapshot_err = "review presenter capture callback is unavailable"
					return
				end
				local location, capture_err = review_presenter.capture_location(state)
				if not location then
					snapshot_err = capture_err or "previous review cursor could not be captured"
				elseif not validate_history_location(previous_entry, location) then
					snapshot_err = "previous review cursor snapshot is invalid"
				else
					local captured = vim.deepcopy(location)
					snapshot.location = snapshot.location or captured
					snapshot.locations[#snapshot.locations + 1] = {
						focus = pane_focus,
						location = captured,
					}
				end
			end
		end)
		if not call_ok then
			return nil, "previous review snapshot failed: " .. tostring(call_err)
		elseif snapshot_err then
			return nil, snapshot_err
		end
	end
	if previous_entry and #snapshot.locations == 0 then
		return nil, "previous review cursor is unavailable for an atomic restore"
	end
	if previous_entry then
		local current_entry = find_entry(workspace, snapshot.entry_identity)
		if not current_entry then
			return nil, "previous review entry is no longer available"
		elseif not entry_matches_snapshot(current_entry, snapshot.entry_snapshot) then
			return nil, "previous review entry changed while its state was captured"
		end
	end
	return snapshot
end

local function rollback_history_restore(workspace, state, payload, expected_surface, snapshot)
	if not history_owner_current(workspace, state, payload, expected_surface) then
		return nil, "review owner changed before rollback"
	end
	local previous_entry = find_entry(workspace, snapshot.entry_identity)
	if not previous_entry then
		return nil, "previous review entry is no longer available"
	elseif not entry_matches_snapshot(previous_entry, snapshot.entry_snapshot) then
		return nil, "previous review entry changed before rollback"
	elseif not snapshot.location or not validate_history_location(previous_entry, snapshot.location) then
		return nil, "previous review location no longer matches the current model"
	end
	local shown, show_err = call_history_operation(M.present, snapshot.entry_identity, payload.workspace_key, {
		emit = false,
		side = snapshot.location.side,
	})
	if shown ~= true then
		return nil, "previous review presentation could not be restored: " .. tostring(show_err)
	end
	if not history_owner_current(workspace, state, payload, expected_surface) then
		return nil, "review owner changed while rolling back"
	end
	local current_entry, current_entry_err =
		history_presentation_entry(workspace, state, snapshot.location, snapshot.entry_snapshot)
	if not current_entry then
		return nil, "previous review model changed while rolling back: " .. tostring(current_entry_err)
	end
	local generation = state.presentation.generation
	local function rollback_current()
		if not history_owner_current(workspace, state, payload, expected_surface) then
			return false, "review owner changed during rollback"
		end
		local entry, entry_err =
			history_presentation_entry(workspace, state, snapshot.location, snapshot.entry_snapshot)
		if not entry then
			return false, entry_err
		elseif state.presentation.generation ~= generation then
			return false, "review presentation changed during rollback"
		end
		return true
	end
	for _, captured in ipairs(snapshot.locations) do
		local restored, restore_err =
			call_history_operation(review_presenter.restore_location, state, captured.location, generation)
		local current, current_err = rollback_current()
		if restored ~= true or not current then
			return nil,
				("previous %s review cursor could not be restored: %s"):format(
					captured.location.side,
					tostring(restore_err or current_err or "restore did not succeed")
				)
		end
	end
	for _, captured in ipairs(snapshot.locations) do
		local focused, focus_err = call_history_operation(restore_focus, workspace, captured.focus)
		local current, current_err = rollback_current()
		if focused ~= true or not current then
			return nil,
				("previous %s review view could not be restored: %s"):format(
					captured.location.side,
					tostring(focus_err or current_err or "focus restore did not succeed")
				)
		end
	end
	if snapshot.review_focus then
		local focused, focus_err = call_history_operation(restore_focus, workspace, snapshot.review_focus)
		local current, current_err = rollback_current()
		if focused ~= true or not current then
			return nil,
				"previous review focus could not be restored: " .. tostring(
					focus_err or current_err or "focus restore did not succeed"
				)
		end
	end
	if snapshot.caller_focus then
		local focused, focus_err = call_history_operation(restore_focus, workspace, snapshot.caller_focus)
		local current, current_err = rollback_current()
		if focused ~= true or not current then
			return nil,
				"calling focus could not be restored: " .. tostring(
					focus_err or current_err or "focus restore did not succeed"
				)
		end
	end
	return true
end

local function failed_history_restore(workspace, state, payload, expected_surface, snapshot, err)
	local rolled_back, rollback_err =
		call_history_operation(rollback_history_restore, workspace, state, payload, expected_surface, snapshot)
	if not rolled_back then
		if snapshot.caller_focus and snapshot.caller_focus.kind == "window" then
			pcall(restore_focus, nil, snapshot.caller_focus)
		end
		if history_surface_current(workspace, state, expected_surface) then
			emit_changed()
		end
	end
	local detail = "Could not restore review navigation: " .. tostring(err)
	if not rolled_back then
		detail = detail .. "; rollback failed: " .. tostring(rollback_err)
	end
	notify(detail, rolled_back and vim.log.levels.WARN or vim.log.levels.ERROR)
	return false, detail, true
end

---Restore a captured logical review cursor only into its still-live owner.
---@param value table
---@return boolean restored
---@return string? err
---@return boolean? already_reported
function M.restore_location(value)
	local payload = valid_provider_entry(value)
	if not payload or suspended ~= nil then
		return false
	end
	local workspace = current_workspace()
	local state = workspace and workspace.mode_state or nil
	if
		not workspace
		or not registered(workspace)
		or workspace_key(workspace) ~= payload.workspace_key
		or workspace.generation ~= payload.workspace_generation
		or type(workspace.scope) ~= "table"
		or workspace.scope.id ~= payload.scope_id
		or not surface_valid()
		or workspace.mode_on ~= true
		or not state
		or state.enabled ~= true
		or type(review_presenter.restore_location) ~= "function"
	then
		return false
	end
	local expected_surface = vim.deepcopy(review_surface)
	local entry = find_entry(workspace, payload.entry_identity)
	if not entry or not validate_history_location(entry, payload) then
		return false
	end
	local destination_entry_snapshot = entry_snapshot(entry)
	local snapshot, snapshot_err = call_history_operation(history_restore_snapshot, workspace, state, expected_surface)
	if not snapshot then
		local detail = "Could not restore review navigation: " .. tostring(snapshot_err)
		notify(detail, vim.log.levels.WARN)
		return false, detail, true
	end
	if not history_owner_current(workspace, state, payload, expected_surface) then
		if snapshot.caller_focus and snapshot.caller_focus.kind == "window" then
			pcall(restore_focus, nil, snapshot.caller_focus)
		end
		return false
	end
	local shown, show_err = call_history_operation(M.present, payload.entry_identity, payload.workspace_key, {
		emit = false,
		side = payload.side,
	})
	if shown ~= true then
		return failed_history_restore(workspace, state, payload, expected_surface, snapshot, show_err)
	end
	if not history_owner_current(workspace, state, payload, expected_surface) then
		return failed_history_restore(
			workspace,
			state,
			payload,
			expected_surface,
			snapshot,
			"review owner changed while presenting the destination"
		)
	end
	local destination_entry, destination_entry_err =
		history_presentation_entry(workspace, state, payload, destination_entry_snapshot)
	if not destination_entry then
		return failed_history_restore(
			workspace,
			state,
			payload,
			expected_surface,
			snapshot,
			"review destination model changed while presenting: " .. tostring(destination_entry_err)
		)
	end
	local presentation_generation = state.presentation.generation
	local restored, restore_err =
		call_history_operation(review_presenter.restore_location, state, payload, presentation_generation)
	if restored ~= true then
		return failed_history_restore(
			workspace,
			state,
			payload,
			expected_surface,
			snapshot,
			restore_err or "destination cursor restore did not succeed"
		)
	end
	if not history_owner_current(workspace, state, payload, expected_surface) then
		return failed_history_restore(
			workspace,
			state,
			payload,
			expected_surface,
			snapshot,
			"review owner changed while restoring the destination cursor"
		)
	end
	destination_entry, destination_entry_err =
		history_presentation_entry(workspace, state, payload, destination_entry_snapshot)
	if not destination_entry or state.presentation.generation ~= presentation_generation then
		return failed_history_restore(
			workspace,
			state,
			payload,
			expected_surface,
			snapshot,
			"review destination changed while restoring its cursor: "
				.. tostring(destination_entry_err or "presentation generation changed")
		)
	end
	emit_changed()
	return true
end

local function surface_title(workspace)
	local name = vim.fs.basename(vim.fs.normalize(workspace.root))
	local label = workspace.scope and workspace.scope.label or workspace.session.id
	return ("Review: %s · %s"):format(name, label)
end

local function panel_open(workspace)
	return workspace and workspace.panel and review_panel.is_open(workspace.panel) or false
end

local function disable_ui(workspace, close_panel)
	cancel_engine()
	clear_inline_preview()
	if workspace.panel then
		if close_panel then
			review_panel.close(workspace.panel)
			workspace.panel.source_win = nil
		else
			review_panel.hide(workspace.panel)
		end
	end
	if workspace.mode_state then
		review_mode.disable(workspace.mode_state)
	end
	workspace.mode_on = false
	if close_panel then
		workspace.mode_state = nil
	end
end

local function window_focus_snapshot(win)
	local value = {
		kind = "window",
		tab = vim.api.nvim_win_get_tabpage(win),
		win = win,
		buf = vim.api.nvim_win_get_buf(win),
	}
	vim.api.nvim_win_call(win, function()
		value.view = vim.fn.winsaveview()
	end)
	return value
end

focus_snapshot = function(workspace)
	local win = vim.api.nvim_get_current_win()
	local value = window_focus_snapshot(win)
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

local function rememberable_surface_focus(workspace, value)
	if type(value) ~= "table" then
		return false
	end
	if value.kind == "panel" then
		local pane = workspace.panel and workspace.panel.panes and workspace.panel.panes[value.pane] or nil
		return panel_open(workspace) and pane and pane.win == value.win and valid_win(pane.win) or false
	elseif value.kind == "presentation" then
		local presentation = workspace.mode_state and workspace.mode_state.presentation
		for _, name in ipairs({ "inline", "left", "right" }) do
			local side = presentation and presentation[name] or nil
			if side and side.side == value.side and side.win == value.win and valid_win(side.win) then
				return true
			end
		end
		return false
	elseif
		value.kind == "window"
		and valid_win(value.win)
		and surface_valid()
		and vim.api.nvim_win_get_tabpage(value.win) == review_surface.tabpage
	then
		local window_config = vim.api.nvim_win_get_config(value.win)
		return not window_config.relative or window_config.relative == ""
	end
	return false
end

-- A supported close can target the review tab while another tab is current.
-- In that case the process-global current window is not review UI, so derive
-- the resumable focus from the review's own live surface instead.
surface_focus_snapshot = function(workspace)
	if workspace and current_workspace() == workspace and on_surface() then
		local current = focus_snapshot(workspace)
		if rememberable_surface_focus(workspace, current) then
			workspace.surface_focus = vim.deepcopy(current)
			return current
		end
	end
	local remembered = workspace and workspace.surface_focus or nil
	if rememberable_surface_focus(workspace, remembered) then
		return vim.deepcopy(remembered)
	end
	local focused = workspace and workspace.panel and workspace.panel.focused
	local pane = focused and workspace.panel.panes and workspace.panel.panes[focused] or nil
	if pane and valid_win(pane.win) then
		local value = window_focus_snapshot(pane.win)
		value.kind = "panel"
		value.pane = focused
		return value
	end
	local target = workspace and workspace.mode_state and review_presenter.current_target(workspace.mode_state) or nil
	if target and valid_win(target.win) then
		local value = window_focus_snapshot(target.win)
		value.kind = "presentation"
		value.side = target.side
		return value
	end
	-- The fallback deliberately carries no ordinary-window identity. Once the
	-- surface is rebuilt, restore_focus() will select its current target.
	return { kind = "surface" }
end

local function remember_surface_focus()
	local workspace = current_workspace()
	if workspace and on_surface() then
		local current = focus_snapshot(workspace)
		if rememberable_surface_focus(workspace, current) then
			workspace.surface_focus = vim.deepcopy(current)
			return true
		end
	end
	return false
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

local function normal_window(tab, preferred)
	if valid_win(preferred) and vim.api.nvim_win_get_tabpage(preferred) == tab then
		local window_config = vim.api.nvim_win_get_config(preferred)
		if not window_config.relative or window_config.relative == "" then
			return preferred
		end
	end
	if not valid_tab(tab) then
		return nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
		local window_config = vim.api.nvim_win_get_config(win)
		if not window_config.relative or window_config.relative == "" then
			return win
		end
	end
	return nil
end

restore_focus = function(workspace, snapshot)
	if not snapshot then
		return false
	end
	if snapshot.kind == "panel" and panel_open(workspace) then
		return review_panel.focus(workspace.panel, snapshot.pane)
	elseif snapshot.kind == "presentation" and workspace and workspace.mode_state then
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
	local target = workspace and workspace.mode_state and review_presenter.current_target(workspace.mode_state) or nil
	return target and set_focus(target.win, snapshot, false) or false
end

local function ui_snapshot(workspace, focus)
	return {
		entry_identity = workspace.entry_identity,
		layout = workspace.layout,
		context = workspace.context,
		engine = workspace.engine or "main",
		inline_comments = workspace.inline_comments ~= false,
		mode_on = workspace.mode_on == true,
		panel_visible = panel_open(workspace),
		panel_focus = workspace.panel and workspace.panel.focused or "files",
		focus = focus or focus_snapshot(workspace),
	}
end

local function capture_invocation()
	if surface_transition or on_surface() then
		return nil
	end
	local tab = vim.api.nvim_get_current_tabpage()
	local win = normal_window(tab, vim.api.nvim_get_current_win())
	if not win then
		return nil
	end
	local value = {
		tab = tab,
		win = win,
		buf = vim.api.nvim_win_get_buf(win),
	}
	vim.api.nvim_win_call(win, function()
		value.view = vim.fn.winsaveview()
	end)
	invocation = value
	local focus = vim.deepcopy(value)
	focus.kind = "window"
	return focus
end

local function call_during_surface_transition(callback, ...)
	surface_transition = true
	local ok, first, second = pcall(callback, ...)
	surface_transition = false
	if not ok then
		return nil, tostring(first)
	end
	return first, second
end

local function restore_invocation()
	if not invocation then
		return false
	end
	if set_focus(invocation.win, invocation, true) then
		return true
	end
	if not valid_tab(invocation.tab) then
		return false
	end
	vim.api.nvim_set_current_tabpage(invocation.tab)
	local win = normal_window(invocation.tab, vim.api.nvim_tabpage_get_win(invocation.tab))
	return set_focus(win, invocation, false)
end

local function bind_workspace(workspace)
	if not workspace.mode_state then
		workspace.mode_state = review_mode.new(workspace)
	end
	workspace.mode_state.handlers = workspace.mode_state.handlers or {}
	workspace.mode_state.handlers.definition_options = definition_navigation_options
	if not workspace.panel then
		workspace.panel = review_panel.new(workspace, panel_callbacks(workspace_key(workspace)))
	end
	return true
end

local function acquire_surface(workspace)
	local invoked_from_surface = on_surface()
	capture_invocation()
	local had_surface = surface_valid()
	if had_surface then
		local focused, focus_err = call_during_surface_transition(tabs.focus_transient, review_surface)
		if not focused then
			review_surface = nil
			if not invoked_from_surface then
				restore_invocation()
			end
			return nil, focus_err
		end
		local renamed, rename_err =
			call_during_surface_transition(tabs.rename_transient, review_surface, surface_title(workspace))
		if not renamed then
			if not invoked_from_surface then
				restore_invocation()
			end
			return nil, rename_err
		end
		return true, false
	elseif review_surface then
		review_surface = nil
	end
	local handle, err = call_during_surface_transition(tabs.acquire_transient, {
		owner = "native-review",
		key = "workspace",
		title = surface_title(workspace),
		on_request_close = function(handle_value, reason)
			return handle_surface_request_close(handle_value, reason)
		end,
		on_closed = function(handle_value, reason)
			handle_surface_closed(handle_value, reason)
		end,
	})
	if not handle then
		if not invoked_from_surface then
			restore_invocation()
		end
		return nil, err
	end
	review_surface = handle
	return true, true
end

local function release_surface()
	pending_surface_close = nil
	if not surface_valid() then
		review_surface = nil
		return true
	end
	local handle = review_surface
	review_surface = nil
	local released, err = call_during_surface_transition(tabs.release_transient, handle)
	if not released then
		if tabs.valid_transient(handle) then
			review_surface = handle
		end
		return nil, err
	end
	return true
end

local function release_bound_ui(workspace, snapshot)
	workspace.resume_ui = snapshot or ui_snapshot(workspace)
	-- The logical workspace survives a physical release. Advance its epoch so
	-- no picker or confirmation captured from the released UI can revive when
	-- the tab is rebuilt.
	bump_workspace_generation(workspace)
	for _, candidate in pairs(workspaces) do
		disable_ui(candidate, true)
	end
	local released, err = release_surface()
	if not released then
		return nil, err
	end
	restore_invocation()
	return true
end

local function restore_ui(workspace, snapshot)
	active = workspace
	workspace.entry_identity = snapshot.entry_identity
	workspace.layout = snapshot.layout
	workspace.context = snapshot.context
	workspace.engine = snapshot.engine or "main"
	workspace.inline_comments = snapshot.inline_comments
	if snapshot.mode_on or snapshot.panel_visible then
		local acquired, acquire_err = acquire_surface(workspace)
		if not acquired then
			return nil, acquire_err
		end
		bind_workspace(workspace)
	end
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
	if
		snapshot.panel_visible and (not workspace.panel or not review_panel.open(workspace.panel, snapshot.panel_focus))
	then
		return nil, "could not restore the review panel"
	end
	restore_focus(workspace, snapshot.focus)
	workspace.resume_ui = nil
	M.refresh_marks(workspace)
	return true
end

handle_surface_request_close = function(handle, reason)
	if not same_surface(handle, review_surface) then
		return true
	end
	pending_surface_close = nil
	local workspace = current_workspace()
	local surface_was_current = on_surface()
	local ordinary_focus
	if reason == "supported" then
		if not surface_was_current then
			ordinary_focus = capture_invocation() or focus_snapshot(nil)
		end
		if review_editor.prepare_close() ~= true then
			notify(
				"Could not close the review tab because its open comment was not saved or recovered",
				vim.log.levels.ERROR
			)
			return false
		end
	end
	if workspace and workspace.mode_on then
		workspace.resume_ui = ui_snapshot(workspace, surface_focus_snapshot(workspace))
	end
	pending_surface_close = {
		tabpage = handle.tabpage,
		token = handle.token,
		restore_invocation = surface_was_current,
		ordinary_focus = ordinary_focus,
	}
	return true
end

handle_surface_closed = function(handle, reason)
	if not same_surface(handle, review_surface) then
		return
	end
	cancel_pending("review surface closed", true)
	local close_state = same_surface(handle, pending_surface_close) and pending_surface_close or nil
	pending_surface_close = nil
	review_surface = nil
	local workspace = current_workspace()
	if workspace then
		bump_workspace_generation(workspace)
	end
	for _, candidate in pairs(workspaces) do
		disable_ui(candidate, true)
	end
	if close_state and close_state.restore_invocation == false then
		restore_focus(nil, close_state.ordinary_focus)
	else
		restore_invocation()
	end
	M.refresh_marks(workspace)
	refresh_trouble()
	if reason == "external" then
		notify("Review tab was closed; the logical review remains available with :ReviewMode on", vim.log.levels.WARN)
	end
	emit_changed()
end

local function workspace_preferences(existing, preferences)
	preferences = preferences or {}
	local inline_comments = preferences.inline_comments
	if inline_comments == nil then
		inline_comments = existing and existing.inline_comments
	end
	if inline_comments == nil then
		inline_comments = config.inline_comments
	end
	return {
		layout = preferences.layout or (existing and existing.layout) or config.layout,
		context = preferences.context or (existing and existing.context) or config.context,
		engine = preferences.engine or (existing and existing.engine) or "main",
		inline_comments = inline_comments,
	}
end

local function activate(root, session, model, options)
	local blocked = unsaved_transition_error("replace it") or composer_transition_error("replace the active review")
	if blocked then
		return nil, blocked
	end
	local expected = key(root, session.id)
	local existing = workspaces[expected]
	local previous = current_workspace()
	local preferences = options and options.preferences or nil
	local resolved_preferences = workspace_preferences(existing, preferences)
	local workspace = {
		root = root,
		layout = resolved_preferences.layout,
		context = resolved_preferences.context,
		engine = resolved_preferences.engine,
		inline_comments = resolved_preferences.inline_comments,
		scope = session.scope,
		session = session,
		model = model,
		entry_identity = first_identity(model, existing and existing.entry_identity),
	}
	bump_workspace_generation(workspace)
	local invoked_from_surface = on_surface()
	local acquired, acquire_err = acquire_surface(workspace)
	if not acquired then
		return nil, acquire_err
	end
	local previous_ui = previous and ui_snapshot(previous) or nil
	if previous then
		-- A failed activation can restore this exact object. Invalidate its
		-- outstanding actions before it can participate in that rollback.
		bump_workspace_generation(previous)
		disable_ui(previous)
	end
	bind_workspace(workspace)
	workspace.mode_on = false
	workspaces[expected] = workspace
	active = workspace

	local function rollback(err)
		disable_ui(workspace, true)
		workspaces[expected] = existing
		active = previous
		if previous then
			local restored, restore_err = restore_ui(previous, previous_ui)
			if not restored then
				disable_ui(previous, true)
				release_surface()
				restore_invocation()
				return nil, tostring(err) .. "; previous review could not be restored: " .. tostring(restore_err)
			end
			if not previous_ui.mode_on and not previous_ui.panel_visible then
				release_surface()
			end
		else
			release_surface()
			M.refresh_marks(nil)
		end
		if not invoked_from_surface then
			restore_invocation()
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
	workspace.resume_ui = nil
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
	local model, model_err = review_changes.build(root, scope, construction_options(options and options.control))
	if not model then
		return nil, message(model_err)
	end
	local continued, checkpoint_err = operation_checkpoint(options, "controller.open_publish", {
		root = root,
		scope_id = scope.id,
	})
	if not continued then
		return nil, checkpoint_err
	end
	if created then
		local saved, save_err = review_store.save(root, session)
		if not saved then
			return nil, save_err
		end
		session = saved
	end
	if suspended then
		local restored, restore_err = M.restore_after_session()
		if not restored then
			return nil, "could not restore the suspended review before opening another one: " .. tostring(restore_err)
		end
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
	local scope, scope_err =
		review_scope.resolve(root, request or { kind = "branch" }, construction_options(options and options.control))
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
	cancel_pending("superseded by synchronous open", true)
	local workspace, err = open_request(request, root)
	if workspace then
		clear_scope_history()
		emit_changed()
	end
	return workspace, err
end

function M.open_async(request, root, callback)
	local captured_request = vim.deepcopy(request)
	local captured_root = root or root_for_command()
	return start_async("open", function(control)
		if not captured_root then
			notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
			return nil
		end
		local workspace, err = open_request(captured_request, captured_root, { control = control })
		if workspace then
			clear_scope_history()
		end
		return workspace, err
	end, callback)
end

function M.cancel_pending(reason, emit)
	cancel_engine()
	return cancel_pending(reason or "cancelled", emit ~= false)
end

local function open_saved_async(root, session, callback)
	local captured_session = vim.deepcopy(session)
	return start_async("open", function(control)
		local workspace, err = open_resolved(root, captured_session.scope, captured_session, { control = control })
		if workspace then
			clear_scope_history()
		end
		return workspace, err
	end, callback)
end

open_drilldown = function(request, parent)
	cancel_pending("superseded by review drilldown", true)
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
			engine = parent.engine,
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
	cancel_pending("superseded by review scope navigation", true)
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

	if suspended then
		local restored, restore_err = M.restore_after_session()
		if not restored then
			return nil,
				"could not restore the suspended review before returning to its parent scope: " .. tostring(restore_err)
		end
		child = current_workspace()
		if not child then
			return nil, "review session disappeared while restoring its suspended UI"
		end
	end
	local acquired, acquire_err = acquire_surface(child)
	if not acquired then
		return nil, "could not focus the review tab: " .. tostring(acquire_err)
	end
	-- Invalidate callbacks from the child before either restoring the parent
	-- or rolling back to this same child after a failed restore.
	bump_workspace_generation(child)
	local child_ui = ui_snapshot(child)
	disable_ui(child)
	local parent = frame.workspace
	local restored, restore_err
	if registered(parent) then
		-- Restoring a saved workspace is a new activation epoch. This second
		-- bump also protects histories created before generation invalidation
		-- became part of the drilldown contract.
		bump_workspace_generation(parent)
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

local function present_owner_current(workspace, generation, state, expected_surface)
	return current_workspace() == workspace
		and registered(workspace)
		and workspace.generation == generation
		and same_surface(review_surface, expected_surface)
		and surface_valid()
		and workspace.mode_on == true
		and workspace.mode_state == state
		and state.enabled == true
end

-- File navigation keeps its synchronous public contract. The subprocess is
-- asynchronous and the bounded wait pumps events, allowing owner cancellation.
local function prepared_engine(workspace, entry)
	local id = workspace.engine or "main"
	local snapshot = entry_snapshot(entry)
	local cache = workspace.engine_prepared
	if cache and cache.id == id and entry_matches_snapshot(entry, cache.snapshot) then
		return cache.result
	end
	cancel_engine()
	local request = { workspace = workspace, generation = workspace.generation }
	pending_engine = request
	local completed, result, err = false, nil, nil
	local ok, handle = pcall(review_engines.prepare, id, snapshot, function(value, failure)
		completed, result, err = true, value, failure
	end)
	if not ok then
		completed, err = true, tostring(handle)
	elseif type(handle) == "function" then
		request.cancel = handle
	end
	vim.wait(6000, function()
		return completed
			or pending_engine ~= request
			or current_workspace() ~= workspace
			or workspace.generation ~= request.generation
	end, 10)
	local current = pending_engine == request
		and current_workspace() == workspace
		and workspace.generation == request.generation
		and entry_matches_snapshot(find_entry(workspace, entry.identity), snapshot)
	if pending_engine == request then
		cancel_engine()
	end
	if not current then
		return nil, "Review engine preparation was superseded"
	elseif not completed or not result then
		return nil, err or "Review engine preparation timed out"
	end
	workspace.engine_prepared = { id = id, snapshot = snapshot, result = result }
	return result
end

function M.present(identity, expected, options)
	clear_inline_preview()
	if suspended then
		local restored, restore_err = M.restore_after_session()
		if not restored then
			return nil, restore_err
		end
	end
	local workspace = expected and workspace_for_key(expected) or current_workspace()
	if not workspace or workspace ~= current_workspace() then
		return nil, "review session is no longer active"
	end
	local entry = find_entry(workspace, identity)
	if not entry then
		return nil, "review entry is no longer part of the exact model"
	end
	cancel_engine()
	local engine_result, engine_err = prepared_engine(workspace, entry)
	if not engine_result then
		return nil, engine_err
	end
	review_structural.close()
	local selected_entry_snapshot = entry_snapshot(entry)
	local generation = workspace.generation
	local previous_identity = workspace.entry_identity
	local resume_ui = workspace.resume_ui
	local acquired, surface_result = acquire_surface(workspace)
	if not acquired then
		return nil, surface_result
	end
	local new_surface = surface_result == true
	bind_workspace(workspace)
	local state = workspace.mode_state
	local expected_surface = vim.deepcopy(review_surface)
	local enabled_for_present = false
	if not workspace.mode_on then
		local enabled, err = review_mode.enable(state)
		if not enabled then
			if new_surface then
				disable_ui(workspace, true)
				release_surface()
				restore_invocation()
				workspace.resume_ui = resume_ui
			end
			return nil, err
		end
		workspace.mode_on = true
		enabled_for_present = true
	end
	if not present_owner_current(workspace, generation, state, expected_surface) then
		return nil, "review owner changed before presenting the entry"
	elseif not entry_matches_snapshot(find_entry(workspace, identity), selected_entry_snapshot) then
		return nil, "review entry changed before it could be presented"
	end
	local shown, err = call_history_operation(review_presenter.show, state, entry, {
		layout = workspace.layout,
		context = workspace.context,
		side = options and options.side or nil,
		engine_result = engine_result,
	})
	if not shown then
		if not present_owner_current(workspace, generation, state, expected_surface) then
			return nil, "review owner changed while presenting the entry: " .. tostring(err)
		end
		if enabled_for_present then
			review_mode.disable(state)
			workspace.mode_on = false
		end
		if new_surface then
			disable_ui(workspace, true)
			release_surface()
			restore_invocation()
			workspace.resume_ui = resume_ui
		end
		return nil, err
	end
	if
		not present_owner_current(workspace, generation, state, expected_surface)
		or not entry_matches_snapshot(find_entry(workspace, identity), selected_entry_snapshot)
		or not state.presentation
		or not entry_matches_snapshot(state.presentation.entry, selected_entry_snapshot)
		or workspace.entry_identity ~= previous_identity
	then
		return nil, "review owner changed while presenting the entry"
	end
	local presentation = state.presentation
	local presentation_generation = presentation.generation
	local function finalization_current()
		return present_owner_current(workspace, generation, state, expected_surface)
			and entry_matches_snapshot(find_entry(workspace, identity), selected_entry_snapshot)
			and workspace.entry_identity == previous_identity
			and state.presentation == presentation
			and entry_matches_snapshot(presentation.entry, selected_entry_snapshot)
			and presentation.generation == presentation_generation
	end
	local target, target_err = call_history_operation(review_presenter.current_target, state)
	if not finalization_current() then
		return nil, "review owner changed while resolving the presented entry"
	end
	if target_err then
		return nil, "could not resolve the presented review target: " .. tostring(target_err)
	end
	local _, source_err =
		call_history_operation(review_panel.update_source, workspace.panel, target and target.win or nil)
	if not finalization_current() then
		return nil, "review owner changed while finalizing the presented entry"
	end
	if source_err then
		return nil, "could not update the review panel source: " .. tostring(source_err)
	end
	local panel_refreshed, panel_err = call_history_operation(update_panel, workspace, identity)
	if not finalization_current() then
		return nil, "review owner changed while refreshing the review panel"
	end
	if panel_refreshed ~= true then
		return nil, "could not refresh the review panel: " .. tostring(panel_err or "refresh did not succeed")
	end
	local _, marks_err = call_history_operation(M.refresh_marks, workspace)
	if not finalization_current() then
		return nil, "review owner changed while refreshing review decorations"
	end
	if marks_err then
		return nil, "could not refresh review decorations: " .. tostring(marks_err)
	end
	workspace.entry_identity = identity
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
		if suspended then
			return true
		end
		if not workspace.mode_on and not surface_valid() then
			return true
		end
		local acquired, acquire_err = acquire_surface(workspace)
		if not acquired then
			notify(acquire_err, vim.log.levels.ERROR)
			return nil
		end
		if review_editor.prepare_close() ~= true then
			notify(
				"Could not disable review mode because its open comment was not saved or recovered",
				vim.log.levels.ERROR
			)
			return nil
		end
		local snapshot = ui_snapshot(workspace)
		local released, release_err = release_bound_ui(workspace, snapshot)
		if not released then
			local restored, restore_err = restore_ui(workspace, snapshot)
			notify(
				"Could not release review tab: "
					.. tostring(release_err)
					.. (restored and "" or "; UI restore failed: " .. tostring(restore_err)),
				vim.log.levels.ERROR
			)
			return nil
		end
		emit_changed()
		return true
	elseif value ~= "on" then
		notify("Usage: ReviewMode [on|off|toggle]", vim.log.levels.ERROR)
		return nil
	end
	if suspended then
		local restored, restore_err = M.restore_after_session()
		if not restored then
			notify(restore_err, vim.log.levels.ERROR)
			return nil
		end
		workspace = current_workspace()
		if workspace and workspace.mode_on and surface_valid() then
			return true
		end
	end
	if workspace.mode_on and surface_valid() then
		local focused, focus_err = acquire_surface(workspace)
		if not focused then
			notify(focus_err, vim.log.levels.ERROR)
			return nil
		end
		return true
	end
	local snapshot = workspace.resume_ui
		or {
			entry_identity = workspace.entry_identity,
			layout = workspace.layout,
			context = workspace.context,
			engine = workspace.engine or "main",
			inline_comments = workspace.inline_comments ~= false,
			mode_on = true,
			panel_visible = true,
			panel_focus = "files",
		}
	snapshot = vim.deepcopy(snapshot)
	snapshot.mode_on = true
	local restored, restore_err = restore_ui(workspace, snapshot)
	if not restored then
		for _, candidate in pairs(workspaces) do
			disable_ui(candidate, true)
		end
		release_surface()
		restore_invocation()
		workspace.resume_ui = snapshot
		notify(restore_err, vim.log.levels.ERROR)
		return nil
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
	if not workspace.mode_on and not M.mode("on") then
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

function M.engine(id)
	local workspace = current_workspace()
	local blocked = composer_transition_error("change the diff engine")
	if not workspace or blocked then
		local err = blocked or "No active review"
		notify(err, vim.log.levels.ERROR)
		return nil, err
	end
	if not id or id == "" then
		local token = workspace_token(workspace)
		select_review(review_engines.list(), {
			prompt = "Review diff engine",
			format_item = function(item)
				return item.label
					.. " · "
					.. item.version
					.. (item.id == (workspace.engine or "main") and " · selected" or "")
			end,
		}, function(item)
			if item and resolve_workspace_token(token, "selecting a diff engine") then
				M.engine(item.id)
			end
		end)
		return true
	end
	if not review_engines.origin(id) then
		local err = "Unknown review engine: " .. tostring(id)
		notify(err, vim.log.levels.ERROR)
		return nil, err
	end
	local entry = find_entry(workspace, workspace.entry_identity)
	if not entry then
		workspace.engine = id
		emit_changed()
		return true
	end
	cancel_engine()
	local snapshot = entry_snapshot(entry)
	local request = { generation = workspace.generation, workspace = workspace }
	pending_engine = request
	local ok, handle = pcall(review_engines.prepare, id, snapshot, function(result, err)
		if
			pending_engine ~= request
			or workspace ~= current_workspace()
			or workspace.generation ~= request.generation
			or workspace.entry_identity ~= entry.identity
			or not entry_matches_snapshot(find_entry(workspace, entry.identity), snapshot)
		then
			return
		end
		pending_engine = nil
		local blocked_now = composer_transition_error("change the diff engine")
		if not result or blocked_now then
			notify(blocked_now or err or "Could not prepare the diff engine", vim.log.levels.ERROR)
			return
		end
		local previous, previous_cache = workspace.engine, workspace.engine_prepared
		local location = workspace.mode_state
				and workspace.mode_state.presentation
				and review_presenter.capture_location(workspace.mode_state)
			or nil
		workspace.engine = id
		workspace.engine_prepared = { id = id, snapshot = snapshot, result = result }
		if workspace.mode_on then
			local shown, show_err = M.present(entry.identity, nil, { emit = false })
			if not shown then
				workspace.engine, workspace.engine_prepared = previous, previous_cache
				notify(show_err, vim.log.levels.ERROR)
				return
			end
			if location then
				review_presenter.restore_location(workspace.mode_state, location)
			end
		end
		update_panel(workspace)
		emit_changed()
	end)
	if not ok then
		if pending_engine == request then
			pending_engine = nil
		end
		notify(tostring(handle), vim.log.levels.ERROR)
		return nil, tostring(handle)
	end
	if pending_engine == request and type(handle) == "function" then
		request.cancel = handle
	end
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
	if workspace.mode_state then
		review_presenter.refresh_winbars(workspace.mode_state)
	end
	emit_changed()
	return true
end

function M.code()
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return
	end
	if not workspace.mode_on and not M.mode("on") then
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
			if side.projection or side.side == "unified" and presentation.projection then
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

local function capture_definition_origin(workspace, presentation, source)
	if
		type(source) ~= "table"
		or not valid_win(source.win)
		or not valid_buf(source.buf)
		or vim.api.nvim_win_get_buf(source.win) ~= source.buf
		or source.generation ~= presentation.generation
		or (source.role ~= "current" and source.role ~= "snapshot" and source.role ~= "unified")
		or vim.b[source.buf].nvim_review_role ~= source.role
	then
		return nil
	end
	local captured = {
		buf = source.buf,
		bufhidden = vim.bo[source.buf].bufhidden,
		buftype = vim.bo[source.buf].buftype,
		changedtick = vim.api.nvim_buf_get_changedtick(source.buf),
		entry_identity = presentation.entry.identity,
		entry_text = presentation.entry.new_text,
		generation = source.generation,
		modified = vim.bo[source.buf].modified,
		name = vim.api.nvim_buf_get_name(source.buf),
		presentation = presentation,
		role = source.role,
		text = buffer_text(source.buf),
		win = source.win,
	}
	if source.role ~= "current" then
		return captured
	elseif
		captured.buftype ~= ""
		or captured.modified
		or type(captured.entry_text) ~= "string"
		or captured.text ~= captured.entry_text
	then
		return nil
	end
	local relative, resolved = repo.relative_existing(workspace.root, captured.name)
	if not relative or not resolved or relative ~= presentation.entry.new_path then
		return nil
	end
	local disk = fs.read_binary(resolved)
	if disk == nil or disk ~= captured.text then
		return nil
	end
	captured.relative = relative
	captured.resolved = vim.fs.normalize(resolved)
	return captured
end

local function definition_origin_owned(workspace, state, captured)
	if
		current_workspace() ~= workspace
		or not registered(workspace)
		or workspace.mode_state ~= state
		or workspace.mode_on ~= true
		or state.enabled ~= true
	then
		return false
	end
	local presentation = state.presentation
	if
		not presentation
		or presentation ~= captured.presentation
		or presentation.generation ~= captured.generation
		or presentation.entry.identity ~= captured.entry_identity
		or not valid_win(captured.win)
		or not valid_buf(captured.buf)
		or vim.api.nvim_win_get_buf(captured.win) ~= captured.buf
		or vim.api.nvim_buf_get_changedtick(captured.buf) ~= captured.changedtick
		or vim.api.nvim_buf_get_name(captured.buf) ~= captured.name
		or vim.bo[captured.buf].bufhidden ~= captured.bufhidden
		or vim.bo[captured.buf].buftype ~= captured.buftype
		or vim.bo[captured.buf].modified ~= captured.modified
		or vim.b[captured.buf].nvim_review_role ~= captured.role
		or presentation.entry.new_text ~= captured.entry_text
	then
		return false
	end
	for _, name in ipairs({ "inline", "right" }) do
		local side = presentation[name]
		if
			side
			and side.win == captured.win
			and side.buf == captured.buf
			and (side.side == "new" or side.side == "unified")
		then
			return true
		end
	end
	return false
end

local function definition_origin_valid(workspace, state, captured)
	if not definition_origin_owned(workspace, state, captured) or buffer_text(captured.buf) ~= captured.text then
		return false
	end
	if captured.role == "current" then
		local relative, resolved = repo.relative_existing(workspace.root, captured.name)
		if
			not relative
			or not resolved
			or relative ~= captured.relative
			or vim.fs.normalize(resolved) ~= captured.resolved
			or fs.read_binary(resolved) ~= captured.text
		then
			return false
		end
	end
	return true
end

local function workspace_token_valid(workspace, token)
	return current_workspace() == workspace
		and registered(workspace)
		and token.workspace_key == workspace_key(workspace)
		and token.generation == workspace.generation
end

local function destination_text(workspace, resolved)
	local disk, disk_err = fs.read_binary(resolved)
	if disk == nil then
		return nil, "CURRENT definition target is unavailable: " .. tostring(disk_err or resolved)
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if valid_buf(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
			local _, candidate = repo.relative_existing(workspace.root, vim.api.nvim_buf_get_name(buf))
			if candidate and vim.fs.normalize(candidate) == vim.fs.normalize(resolved) then
				if vim.bo[buf].buftype ~= "" or vim.bo[buf].modified or buffer_text(buf) ~= disk then
					return nil, "loaded CURRENT definition target differs from its file on disk"
				end
			end
		end
	end
	return disk
end

local function eligible_definition_entries(workspace, relative)
	local entries = {}
	for _, entry in ipairs(workspace.model.entries or {}) do
		if
			entry.new_path == relative
			and not entry.deleted
			and not entry.metadata_only
			and not entry.binary
			and type(entry.new_text) == "string"
		then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

local function definition_candidate(workspace, entries, current_text, current_line)
	local candidates = {}
	for _, entry in ipairs(entries) do
		local mapped = review_lsp.map_current_line(entry.new_text, current_text, current_line)
		if mapped then
			candidates[#candidates + 1] = { entry = entry, line = mapped }
		end
	end
	if #candidates == 0 then
		return nil, "CURRENT definition line does not map to frozen NEW content"
	end
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	local current_layer = presentation and (presentation.entry.layer or "history") or nil
	local same_layer = {}
	for _, candidate in ipairs(candidates) do
		if (candidate.entry.layer or "history") == current_layer then
			same_layer[#same_layer + 1] = candidate
		end
	end
	if #same_layer == 1 then
		return same_layer[1]
	elseif #same_layer > 1 or #candidates > 1 then
		return nil, "CURRENT definition maps to more than one review entry"
	end
	return candidates[1]
end

local function real_target_matches_frozen(workspace, presentation, entry, target)
	local right = presentation and presentation.right
	if not right or not right.real or right.buf ~= target.buf or right.win ~= target.win then
		return true
	elseif
		not valid_buf(right.buf)
		or vim.bo[right.buf].buftype ~= ""
		or vim.bo[right.buf].modified
		or buffer_text(right.buf) ~= entry.new_text
	then
		return nil, "LSP returned an invalid definition location"
	end
	local relative, resolved = repo.relative_existing(workspace.root, vim.api.nvim_buf_get_name(right.buf))
	return relative == entry.new_path and resolved ~= nil and fs.read_binary(resolved) == entry.new_text
end

local function route_definition_location(workspace, state, token, location)
	if not workspace_token_valid(workspace, token) then
		return true
	elseif
		type(location) ~= "table"
		or type(location.path) ~= "string"
		or location.path == ""
		or location.path:find("\0", 1, true) ~= nil
		or type(location.lnum) ~= "number"
		or location.lnum < 1
		or location.lnum % 1 ~= 0
		or (location.col ~= nil and (type(location.col) ~= "number" or location.col < 1 or location.col % 1 ~= 0))
	then
		return nil, "LSP returned an invalid definition location"
	end
	local stat = vim.uv.fs_stat(location.path)
	if not stat or stat.type ~= "file" then
		return nil, "CURRENT definition target is unavailable: " .. location.path
	end
	local relative, resolved = repo.relative_existing(workspace.root, location.path)
	if not relative or not resolved then
		if repo.contains(workspace.root, location.path) then
			return nil, "CURRENT definition target could not be classified inside the repository"
		end
		return false
	end
	local entries = eligible_definition_entries(workspace, relative)
	if #entries == 0 then
		return false
	end
	local current_text, current_err = destination_text(workspace, resolved)
	if current_text == nil then
		return nil, current_err
	end
	local selected, candidate_err = definition_candidate(workspace, entries, current_text, location.lnum)
	if not selected then
		return nil, candidate_err
	elseif not workspace_token_valid(workspace, token) then
		return true
	end

	local presentation = state.presentation
	if
		not presentation
		or presentation.entry.identity ~= selected.entry.identity
		or (presentation.right and presentation.right.real and current_text ~= selected.entry.new_text)
	then
		local shown, show_err = M.present(selected.entry.identity, token.workspace_key)
		if not shown then
			return false, show_err
		end
	end
	if not workspace_token_valid(workspace, token) then
		return true
	end
	presentation = state.presentation
	local target, target_err = review_presenter.reveal_new_location(
		state,
		selected.entry.new_path,
		selected.line,
		presentation and presentation.generation or nil
	)
	if not target then
		return false, target_err
	elseif
		not valid_win(target.win)
		or not valid_buf(target.buf)
		or vim.api.nvim_win_get_buf(target.win) ~= target.buf
	then
		return false, "review definition target changed before it could be focused"
	elseif not real_target_matches_frozen(workspace, presentation, selected.entry, target) then
		return false, "live CURRENT target changed before its frozen review location could be focused"
	elseif not workspace_token_valid(workspace, token) then
		return true
	end
	local text = vim.api.nvim_buf_get_lines(target.buf, target.line - 1, target.line, false)[1] or ""
	local column = type(location.col) == "number" and location.col or 1
	column = math.max(0, math.min(column - 1, #text))
	vim.api.nvim_win_set_cursor(target.win, { target.line, column })
	vim.api.nvim_set_current_win(target.win)
	return true
end

definition_navigation_options = function(state, source)
	local workspace = state and state.workspace
	local presentation = state and state.presentation
	if not workspace or not presentation or type(source) ~= "table" then
		return nil
	end
	local captured = capture_definition_origin(workspace, presentation, source)
	if not captured then
		-- This callback is only exposed by review-owned buffers. Once invoked,
		-- failure to capture an exact frozen origin is a safety decision, not an
		-- invitation to fall back to ordinary host navigation.
		return {
			pending = function()
				return false
			end,
			route = function()
				return true
			end,
			valid = function()
				return false
			end,
		}
	end
	local token = workspace_token(workspace)
	return {
		pending = function()
			return workspace_token_valid(workspace, token) and definition_origin_owned(workspace, state, captured)
		end,
		valid = function()
			return workspace_token_valid(workspace, token) and definition_origin_valid(workspace, state, captured)
		end,
		route = function(location)
			if
				not workspace_token_valid(workspace, token) or not definition_origin_owned(workspace, state, captured)
			then
				return true
			end
			return route_definition_location(workspace, state, token, location)
		end,
	}
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
		select_review(targets, {
			prompt = "Review layer",
			format_item = function(value)
				return string.format("[%s] %s", value.layer, value.path)
			end,
		}, function(selected)
			-- vim.ui.select cancellation is an intentional no-op, not an error.
			callback(selected)
		end)
	end
end

local function source_lines(entry, side)
	local text = side == "left" and entry.old_text or entry.new_text
	if type(text) ~= "string" or text == "" then
		return {}
	end
	-- Git and display projections use LF boundaries. A standalone CR is a
	-- source byte, not an additional line or an invented comment coordinate.
	text = text:gsub("\r\n", "\n")
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
	local source_ref, source_err =
		review_presenter.source_at(workspace.mode_state, display_line, target.generation, target.win)
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
			resolved, resolve_err = review_presenter.resolve_range(
				workspace.mode_state,
				first,
				last,
				target.generation,
				preferred_side,
				target.win
			)
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
	if presentation.projection and presentation.inline or presentation.split_projections then
		local location, location_err =
			review_presenter.locate_anchor(workspace.mode_state, anchor, presentation.generation)
		if not location then
			return nil, location_err
		end
		local rows, rows_err = review_presenter.rows_for_anchor(workspace.mode_state, anchor, presentation.generation)
		if not rows then
			return nil, rows_err
		end
		local revealed, reveal_err =
			review_presenter.reveal_rows(workspace.mode_state, rows, presentation.generation, location.win)
		if not revealed then
			return nil, reveal_err
		end
		return {
			buf = location.buf,
			first = rows[1],
			last = rows[#rows],
			rows = rows,
			win = location.win,
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
	return value == nil or comment_types.contains(value)
end

local function focus_review_ui(token, action)
	local workspace = resolve_workspace_token(token, action)
	if not workspace then
		return nil
	end
	if not M.mode("on") then
		return nil
	end
	return resolve_workspace_token(token, action)
end

local function effective_origin(workspace)
	local presentation = workspace.mode_state and workspace.mode_state.presentation
	return presentation and presentation.origin_engine and vim.deepcopy(presentation.origin_engine)
		or review_engines.origin("main")
end

local function add_from_capture(workspace, captured, requested_type, kind)
	if not allow_mutation(workspace) then
		return
	end
	local token = workspace_token(workspace)
	workspace = focus_review_ui(token, "opening a review comment composer")
	if not workspace then
		return
	end
	choose_target(workspace, captured, function(target, target_err)
		workspace = resolve_workspace_token(token, "selecting a review target")
		if not workspace then
			return
		end
		if not target then
			if target_err then
				notify(target_err, vim.log.levels.ERROR)
			end
			return
		end
		local anchor, anchor_err, display = make_anchor(workspace, target, kind, captured.first, captured.last)
		if not anchor then
			notify(anchor_err, vim.log.levels.ERROR)
			return
		end
		local target_visible = valid_win(target.win)
			and vim.api.nvim_win_get_buf(target.win) == target.buf
			and surface_valid()
			and vim.api.nvim_win_get_tabpage(target.win) == review_surface.tabpage
		if not target_visible or review_panel.is_open(workspace.panel) then
			local shown, show_err = M.present(target.entry.identity, token.workspace_key)
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
		local origin_engine = effective_origin(workspace)
		compose(workspace, {
			title = anchor.kind == "file" and "New file comment" or "New",
			type_cycle = true,
			selected_type = requested_type or "issue",
			source_win = target.win,
			anchor_line = anchor.kind == "range" and display.last or nil,
			anchor_range = anchor.kind == "range" and { first = display.first, last = display.last } or nil,
			anchor = anchor,
		}, function(body, interrupted, selected_type)
			if not body then
				return true
			end
			local current = resolve_workspace_token(token, "composing a review comment")
			if not current or (not interrupted and not allow_mutation(current)) then
				return false
			end
			local changed, err = review_store.add(current.session, {
				type = selected_type or requested_type or "issue",
				body = body,
				anchor = anchor,
				origin_engine = origin_engine,
			})
			if not changed then
				return mutation_failed(current, err)
			end
			return save_mutation(current, changed) == true
		end)
	end)
end

local function choose_saved(root, callback, token)
	token = token or interaction_token()
	local sessions, err = review_store.list(root)
	if not sessions then
		notify("Could not list review sessions: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	select_review(sessions, {
		prompt = "Saved review session",
		format_item = function(session)
			return string.format("%s · %d comments", session.scope.label, #session.items)
		end,
	}, function(session)
		if not session then
			return
		end
		if not resolve_interaction_token(token, "selecting a saved review session") then
			return
		end
		open_saved_async(root, session, function(workspace, open_err)
			if not workspace then
				notify("Could not open saved review: " .. tostring(open_err), vim.log.levels.ERROR)
			elseif callback then
				callback(workspace)
			end
		end)
	end)
end

local function user_input(prompt, token, callback)
	vim.ui.input({ prompt = prompt }, function(value)
		if not resolve_interaction_token(token, "selecting a review scope") then
			return
		end
		if value and vim.trim(value) ~= "" then
			callback(vim.trim(value))
		end
	end)
end

local function scope_picker(root, callback)
	local token = interaction_token()
	local choices = {
		{ label = "Branch · default branch…HEAD", action = "branch" },
		{ label = "Working tree · staged / unstaged / untracked", action = "working" },
		{ label = "Commit…", action = "commit" },
		{ label = "Range…", action = "range" },
		{ label = "Saved review session…", action = "saved" },
	}
	local function opened(request)
		if not resolve_interaction_token(token, "selecting a review scope") then
			return
		end
		M.open_async(request, root, function(workspace)
			if workspace and callback then
				callback(workspace)
			end
		end)
	end
	select_review(choices, {
		prompt = "Review scope",
		format_item = function(value)
			return value.label
		end,
	}, function(choice)
		if not choice then
			return
		elseif not resolve_interaction_token(token, "selecting a review scope") then
			return
		elseif choice.action == "branch" or choice.action == "working" then
			opened({ kind = choice.action })
		elseif choice.action == "commit" then
			user_input("Commit: ", token, function(revision)
				opened({ kind = "commit", rev = revision })
			end)
		elseif choice.action == "range" then
			user_input("Range from: ", token, function(from)
				user_input("Range to: ", token, function(to)
					opened({ kind = "range", from = from, to = to })
				end)
			end)
		else
			choose_saved(root, callback, token)
		end
	end)
end

function M.comment(first, last, requested_type)
	if not valid_type(requested_type) then
		notify("Usage: ReviewComment [" .. table.concat(comment_types.ids(), "|") .. "]", vim.log.levels.ERROR)
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
		notify("Usage: ReviewFileComment [" .. table.concat(comment_types.ids(), "|") .. "]", vim.log.levels.ERROR)
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
	if not valid_type(requested_type) then
		notify("Usage: ReviewGeneralComment [" .. table.concat(comment_types.ids(), "|") .. "]", vim.log.levels.ERROR)
		return
	end
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	local token = workspace_token(workspace)
	workspace = focus_review_ui(token, "opening a review-level comment composer")
	if not workspace then
		return
	end
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
	local origin_engine = effective_origin(workspace)
	compose(workspace, {
		title = "New review-level comment",
		type_cycle = true,
		selected_type = requested_type or "issue",
		source_win = source.win,
		anchor = anchor,
	}, function(body, interrupted, selected_type)
		if not body then
			return true
		end
		local current = resolve_workspace_token(token, "composing a review-level comment")
		if not current or (not interrupted and not allow_mutation(current)) then
			return false
		end
		local changed, err = review_store.add(current.session, {
			type = selected_type or "issue",
			body = body,
			anchor = anchor,
			origin_engine = origin_engine,
		})
		if not changed then
			return mutation_failed(current, err)
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
		local source_ref = review_presenter.source_at(workspace.mode_state, display_line, target.generation, target.win)
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
	if
		presentation
		and (
			(presentation.projection and presentation.inline and presentation.inline.buf == buf)
			or presentation.split_projections
				and ((presentation.left and presentation.left.buf == buf and anchor.side == "left") or (presentation.right and presentation.right.buf == buf and anchor.side == "right"))
		)
	then
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
	local definition = comment_types.get(item.type)
	local prefix = ("  [%s %s][%s] %s · "):format(
		definition.icon,
		definition.id,
		review_store.item_status(item),
		range
	)
	local body, multiline = first_body_line(item.body)
	return prefix .. display_excerpt(body, maximum - vim.fn.strdisplaywidth(prefix), multiline)
end

local function inline_preview_chunks(item, maximum)
	local text = inline_preview_text(item, maximum)
	local definition = comment_types.get(item.type)
	local badge = ("[%s %s]"):format(definition.icon, definition.id)
	local first = text:find(badge, 1, true)
	if not first then
		return { { text, "Comment" } }
	end
	return {
		{ text:sub(1, first - 1), "Comment" },
		{ badge, definition.highlight },
		{ text:sub(first + #badge), "Comment" },
	}
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
			virtual[#virtual + 1] = inline_preview_chunks(item, maximum)
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
	local definition = comment_types.get(item.type)
	return string.format(
		"%02d %s %-10s %-14s %s %s",
		item.sequence,
		definition.icon,
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
	local selection_token = workspace_token(workspace)
	if id and id ~= "" then
		local item = find_item(workspace.session, id)
		if item then
			callback(item_token(workspace, item))
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
		callback(item_token(workspace, candidates[1]))
	else
		local candidate_tokens = {}
		local choices = {}
		for _, item in ipairs(candidates) do
			candidate_tokens[item.id] = item_token(workspace, item)
			choices[#choices + 1] = vim.deepcopy(item)
		end
		workspace = focus_review_ui(selection_token, "opening a review comment chooser")
		if not workspace then
			return
		end
		select_review(choices, { prompt = prompt, format_item = item_label }, function(selected)
			if not selected then
				return
			end
			local token = candidate_tokens[selected.id]
			if not token then
				notify("Review selection was invalid; no changes were made", vim.log.levels.WARN)
				return
			end
			callback(vim.deepcopy(token))
		end)
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

local function compose_item(token, action)
	local workspace, item = resolve_item_token(token, "opening a review comment composer")
	if not workspace or not allow_mutation(workspace) then
		return false
	end
	workspace = focus_review_ui(token, "opening a review comment composer")
	if not workspace then
		return false
	end
	workspace, item = resolve_item_token(token, "opening a review comment composer")
	if not workspace or not item then
		return false
	end
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
	local origin_engine = effective_origin(workspace)
	compose(workspace, {
		title = title,
		body = edit and item.body or "",
		start_in_insert = not edit,
		type_cycle = edit,
		selected_type = edit and item.type or (comment_types.contains(item.type) and item.type or "issue"),
		source_win = location.win,
		anchor_line = display and display.last or nil,
		anchor_range = display and { first = display.first, last = display.last } or nil,
		anchor = item.anchor,
	}, function(body, interrupted, selected_type)
		if not body then
			return true
		end
		local current, stable = resolve_item_token(token, "composing a review comment")
		if not current or not stable or (not interrupted and not allow_mutation(current)) then
			return false
		end
		local values = {
			type = selected_type or (edit and stable.type or "issue"),
			body = body,
			anchor = stable.anchor,
			origin_engine = not edit and origin_engine or nil,
		}
		local changed, err = edit and review_store.edit(current.session, stable.id, values)
			or review_store.reply(current.session, stable.id, values)
		if not changed then
			return mutation_failed(current, err)
		end
		return save_mutation(current, changed) == true
	end)
end

function M.edit(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, "Edit review comment", function(token)
		compose_item(token, "edit")
	end)
end

function M.reply(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, "Reply to review comment", function(token)
		compose_item(token, "reply")
	end)
end

local function apply_direct_mutation(token, action, mutator)
	local workspace, item = resolve_item_token(token, action)
	if not workspace or not item or not allow_mutation(workspace) then
		return false
	end
	local changed, err = mutator(workspace, item)
	if not changed then
		return mutation_failed(workspace, err)
	end
	return save_mutation(workspace, changed) == true
end

local function direct_mutation(id, prompt, mutator)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, prompt, function(token)
		apply_direct_mutation(token, "changing a review comment", mutator)
	end)
end

function M.delete(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, "Delete review comment", function(token)
		local current, selected = resolve_item_token(token, "confirming review comment deletion")
		if not current or not selected then
			return
		end
		current = focus_review_ui(token, "confirming review comment deletion")
		if not current then
			return
		end
		current, selected = resolve_item_token(token, "confirming review comment deletion")
		if not current or not selected then
			return
		end
		select_review({ "Cancel", "Delete" }, { prompt = delete_prompt(selected) }, function(choice)
			if choice ~= "Delete" then
				return
			end
			apply_direct_mutation(token, "deleting a review comment", function(stable_workspace, stable)
				return review_store.delete(stable_workspace.session, stable.id)
			end)
		end)
	end)
end

function M.change_type(id)
	local workspace = current_workspace()
	if not workspace or not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, "Change review comment type", function(token)
		local current = focus_review_ui(token, "opening the review comment type chooser")
		if not current then
			return
		end
		select_review(comment_types.ids(), {
			prompt = "Review comment type",
			format_item = function(item_type)
				local definition = comment_types.get(item_type)
				return definition and (definition.icon .. " " .. definition.id) or tostring(item_type)
			end,
		}, function(item_type)
			if not item_type then
				return
			end
			if not comment_types.contains(item_type) then
				notify("Review comment type selection was invalid; no changes were made", vim.log.levels.WARN)
				return
			end
			apply_direct_mutation(token, "changing a review comment type", function(stable_workspace, stable)
				return review_store.set_type(stable_workspace.session, stable.id, item_type)
			end)
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
	if not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, "Resolve or reopen review comment", function(token)
		apply_direct_mutation(token, "toggling review comment resolution", function(stable_workspace, item)
			return review_store.set_resolution(
				stable_workspace.session,
				item.id,
				item.resolution == "resolved" and "open" or "resolved"
			)
		end)
	end)
end

function M.reanchor(id, source_win)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
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
	if not allow_mutation(workspace) then
		return
	end
	choose_item(workspace, id, "Reanchor review comment", function(token)
		local current, selected = resolve_item_token(token, "selecting a review comment")
		if not current or not selected or not allow_mutation(current) then
			return
		end
		if selected.anchor.kind == "general" then
			notify("Review-level comments do not have a location to reanchor", vim.log.levels.INFO)
			return
		end
		current = focus_review_ui(token, "opening a review target chooser")
		if not current then
			return
		end
		choose_target(current, captured, function(target, target_err)
			current, selected = resolve_item_token(token, "reanchoring a review comment")
			if not current or not selected or not allow_mutation(current) then
				return
			end
			if not target then
				if target_err then
					notify(target_err, vim.log.levels.ERROR)
				end
				return
			end
			if
				not valid_win(target.win)
				or not valid_buf(target.buf)
				or vim.api.nvim_win_get_buf(target.win) ~= target.buf
			then
				notify("Reviewed code window is no longer available", vim.log.levels.ERROR)
				return
			end
			local anchor, anchor_err
			if selected.anchor.kind == "file" then
				anchor, anchor_err =
					make_anchor(current, target, "file", captured.first, captured.first, selected.anchor.side)
			else
				local length = (selected.anchor.end_line or selected.anchor.start_line) - selected.anchor.start_line
				local first = vim.api.nvim_win_get_cursor(target.win)[1]
				if target.unified then
					local resolved
					resolved, anchor_err = review_presenter.resolve_range(
						current.mode_state,
						first,
						first,
						target.generation,
						selected.anchor.side
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
			local changed, err = review_store.edit(current.session, selected.id, {
				type = selected.type,
				body = selected.body,
				anchor = anchor,
			})
			if changed then
				save_mutation(current, changed)
			else
				mutation_failed(current, err)
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
		if not workspace.mode_on and not M.mode("on") then
			return false
		end
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
	if presentation.projection or presentation.split_projections then
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

local function refresh_target_error(workspace, expected)
	if
		not registered(workspace)
		or current_workspace() ~= workspace
		or workspace_key(workspace) ~= expected.workspace_key
	then
		return "active review changed while refresh was pending; current review was kept unchanged"
	end
	if
		workspace.generation ~= expected.generation
		or workspace.session ~= expected.session
		or workspace.session.revision ~= expected.revision
	then
		return "review content changed while refresh was pending; current review was kept unchanged"
	end
	return nil
end

local function refresh_current(options)
	options = options or {}
	clear_inline_preview()
	local workspace
	if options.target_captured then
		workspace = options.workspace
	else
		workspace = current_workspace()
	end
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	local expected = options.expected
		or {
			workspace_key = workspace_key(workspace),
			generation = workspace.generation,
			session = workspace.session,
			revision = workspace.session.revision,
		}
	local target_err = refresh_target_error(workspace, expected)
	if target_err then
		notify("Could not refresh review: " .. target_err, vim.log.levels.ERROR)
		return nil, target_err
	end
	local blocked = unsaved_transition_error("refresh it")
	if blocked then
		notify("Could not refresh review: " .. blocked, vim.log.levels.ERROR)
		return nil, blocked
	end
	local stale, stale_err = stale_now(workspace, options.control)
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
	local model, model_err = review_changes.build(workspace.root, loaded.scope, construction_options(options.control))
	if not model then
		notify("Could not rebuild exact review: " .. message(model_err), vim.log.levels.ERROR)
		return nil, message(model_err)
	end
	local continued, checkpoint_err = operation_checkpoint(options, "controller.refresh_publish", {
		root = workspace.root,
		scope_id = loaded.scope.id,
	})
	if not continued then
		return nil, checkpoint_err
	end
	target_err = refresh_target_error(workspace, expected)
	if target_err then
		notify("Could not refresh review: " .. target_err, vim.log.levels.ERROR)
		return nil, target_err
	end
	local identity = first_identity(model, workspace.entry_identity)
	-- Nothing becomes visible until both persistence and exact model construction succeed.
	local previous = {
		session = workspace.session,
		scope = workspace.scope,
		model = workspace.model,
		entry_identity = workspace.entry_identity,
	}
	workspace.session = loaded
	workspace.scope = loaded.scope
	workspace.model = model
	bump_workspace_generation(workspace)
	workspace.entry_identity = identity
	if workspace.mode_on and identity then
		local shown, show_err = M.present(identity, nil, { emit = false })
		if not shown then
			workspace.session = previous.session
			workspace.scope = previous.scope
			workspace.model = previous.model
			workspace.entry_identity = previous.entry_identity
			bump_workspace_generation(workspace)
			local restored = true
			local restore_err
			if previous.entry_identity then
				restored, restore_err = M.present(previous.entry_identity, nil, { emit = false })
			end
			local detail = "Model refresh presentation failed: " .. tostring(show_err)
			if not restored then
				detail = detail .. "; previous review presentation could not be restored: " .. tostring(restore_err)
			end
			notify(detail, vim.log.levels.ERROR)
			return nil, detail
		end
	end
	update_panel(workspace)
	M.refresh_marks(workspace)
	if options.emit ~= false then
		emit_changed()
	end
	return true
end

function M.refresh()
	cancel_pending("superseded by synchronous refresh", true)
	return refresh_current()
end

function M.refresh_async(callback)
	local workspace = current_workspace()
	local expected = workspace
			and {
				workspace_key = workspace_key(workspace),
				generation = workspace.generation,
				session = workspace.session,
				revision = workspace.session.revision,
			}
		or nil
	return start_async("refresh", function(control)
		return refresh_current({
			control = control,
			emit = false,
			target_captured = true,
			workspace = workspace,
			expected = expected,
		})
	end, callback)
end

function M.export(force)
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return nil
	end
	if suspended then
		notify(
			"Review UI is suspended for session serialization; use :ReviewMode on before exporting",
			vim.log.levels.ERROR
		)
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
	local available_ok, available = pcall(clipboard.available)
	local result, err = review_export.deliver(snapshot, force == true, {
		has_clipboard = available_ok and available == true,
		setreg = clipboard.setreg,
	})
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
	if
		presentation
		and (
			(presentation.projection and presentation.inline and presentation.inline.buf == buf)
			or presentation.split_projections
				and ((presentation.left and presentation.left.buf == buf and anchor.side == "left") or (presentation.right and presentation.right.buf == buf and anchor.side == "right"))
		)
	then
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
	local definition = comment_types.get(item_type)
	local icon = definition.icon
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
		if vim.fn.strdisplaywidth(icon) > 1 then
			return icon
		end
		return aggregate_connector(mark) .. icon
	end
	return aggregate_connector(mark)
end

local function file_comment_virtual_line(item)
	local side = item.anchor.side == "left" and "OLD" or "NEW"
	local definition = comment_types.get(item.type)
	local badge = ("[%s %s]"):format(definition.icon, definition.id)
	local prefix = ("0 │ [%s]%s[%s] "):format(side, badge, review_store.item_status(item))
	local body, multiline = first_body_line(item.body)
	local excerpt = display_excerpt(body, math.max(1, 88 - vim.fn.strdisplaywidth(prefix)), multiline)
	return {
		{ "0 │ ", "LineNr" },
		{ ("[%s]"):format(side), "Comment" },
		{ badge, definition.highlight },
		{ ("[%s] "):format(review_store.item_status(item)), "Comment" },
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
			local item_type = item.type
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
		local ordered_types = comment_types.rail_ids()
		local inactive_types = {}
		for item_type in pairs(line_marks) do
			if not comment_types.contains(item_type) then
				inactive_types[#inactive_types + 1] = item_type
			end
		end
		table.sort(inactive_types)
		vim.list_extend(ordered_types, inactive_types)
		for type_index, item_type in ipairs(ordered_types) do
			local mark = line_marks[item_type]
			if mark then
				local definition = comment_types.get(item_type)
				vim.api.nvim_buf_set_extmark(buf, NAMESPACE, line - 1, 0, {
					priority = math.max(1, 90 - type_index),
					sign_hl_group = definition.highlight,
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
			origin_engine = item.origin_engine and vim.deepcopy(item.origin_engine) or nil,
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

local function discard_suspended_preview(state)
	if not state or not state.preview then
		return true
	end
	local called, discarded = pcall(review_export.discard_preview, state.preview)
	if not called or discarded ~= true then
		return nil, called and "preview receipt was rejected" or tostring(discarded)
	end
	state.preview = nil
	return true
end

local function rollback_suspended_preview(state)
	if not state or not state.preview then
		return true
	end
	local called, restored = pcall(review_export.restore_preview, state.preview)
	if called and restored == true then
		state.preview = nil
		return true
	end
	local restore_err = called and "preview receipt was rejected" or tostring(restored)
	local discarded, discard_err = discard_suspended_preview(state)
	if discarded then
		return true, "preview restore failed (" .. restore_err .. "); retained preview was discarded safely"
	end
	return nil,
		"preview restore failed (" .. restore_err .. ") and retained-preview cleanup failed: " .. tostring(discard_err)
end

function M.suspend_for_session()
	clear_inline_preview()
	if review_editor.has_active() then
		return nil, "review composer has unsent text; save or cancel it first"
	end
	if suspended then
		if suspended.rollback_failed then
			return nil, "previous review UI suspension rollback is incomplete; use :ReviewMode on to retry"
		end
		local latest_focus = capture_invocation()
		if latest_focus then
			suspended.focus = latest_focus
		end
		return true
	end
	local workspace = current_workspace()
	local ordinary_focus = capture_invocation()
	local state = {
		focus = ordinary_focus or focus_snapshot(workspace),
		key = workspace and workspace_key(workspace) or nil,
	}
	local preview, preview_err = review_export.suspend_preview()
	if preview_err then
		return nil, "could not suspend review export preview: " .. tostring(preview_err)
	end
	state.preview = preview
	if workspace then
		if workspace.mode_on or surface_valid() then
			local acquired, acquire_err = acquire_surface(workspace)
			if not acquired then
				local preview_settled, preview_rollback_err = rollback_suspended_preview(state)
				if not preview_settled then
					state.rollback_failed = true
					suspended = state
				end
				restore_focus(workspace, state.focus)
				local suffix = preview_rollback_err and "; " .. preview_rollback_err or ""
				return nil, "could not focus review tab for session save: " .. tostring(acquire_err) .. suffix
			end
			state.ui = ui_snapshot(workspace)
			local released, release_err = release_bound_ui(workspace, state.ui)
			if not released then
				local restored, restore_err = restore_ui(workspace, state.ui)
				if restored then
					state.ui = nil
				end
				local preview_settled, preview_rollback_err = rollback_suspended_preview(state)
				if not restored or not preview_settled then
					state.rollback_failed = true
					suspended = state
				end
				restore_focus(workspace, state.focus)
				return nil,
					"could not release review tab for session save: "
						.. tostring(release_err)
						.. (restored and "" or "; UI restore failed: " .. tostring(restore_err))
						.. (preview_rollback_err and "; " .. preview_rollback_err or "")
			end
		else
			bump_workspace_generation(workspace)
			state.resume_ui = workspace.resume_ui and vim.deepcopy(workspace.resume_ui) or nil
			state.ui = {
				entry_identity = workspace.entry_identity,
				layout = workspace.layout,
				context = workspace.context,
				engine = workspace.engine or "main",
				inline_comments = workspace.inline_comments ~= false,
				mode_on = false,
				panel_visible = false,
				panel_focus = "files",
				focus = state.focus,
			}
		end
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
		local _, discard_err = discard_suspended_preview(state)
		local suffix = discard_err and "; preview cleanup failed: " .. tostring(discard_err) or ""
		return finish(nil, "review session disappeared while UI was suspended" .. suffix, false)
	end
	if workspace and state.ui then
		local restored, restore_err = restore_ui(workspace, state.ui)
		if not restored then
			for _, candidate in pairs(workspaces) do
				disable_ui(candidate, true)
			end
			release_surface()
			workspace.resume_ui = vim.deepcopy(state.ui)
			suspended = state
			return finish(nil, "could not restore review UI: " .. tostring(restore_err), false)
		end
		if not state.ui.mode_on then
			workspace.resume_ui = state.resume_ui
		end
	end
	local preview_target = workspace and workspace.mode_state and review_presenter.current_target(workspace.mode_state)
		or nil
	local preview_called, preview_restored =
		pcall(review_export.restore_preview, state.preview, preview_target and preview_target.win)
	if not preview_called or preview_restored ~= true then
		if workspace then
			workspace.resume_ui = state.ui and vim.deepcopy(state.ui) or workspace.resume_ui
			for _, candidate in pairs(workspaces) do
				disable_ui(candidate, true)
			end
			release_surface()
		end
		suspended = state
		local detail = preview_called and "preview receipt was rejected" or tostring(preview_restored)
		return finish(nil, "could not restore review export preview: " .. detail, false)
	end
	local ok, err = finish(true, nil, true)
	emit_changed()
	return ok, err
end

function M.close(force)
	cancel_pending("review closed", true)
	clear_inline_preview()
	local workspace = current_workspace()
	if not workspace then
		notify("No active review", vim.log.levels.ERROR)
		return false
	end
	local expected = workspace_key(workspace)
	if review_editor.prepare_close() ~= true then
		notify("Could not close review because its open comment was not saved or recovered", vim.log.levels.ERROR)
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
	local suspended_state = suspended
	local snapshot
	if surface_valid() then
		local acquired, acquire_err = acquire_surface(workspace)
		if not acquired then
			notify("Could not focus review tab before close: " .. tostring(acquire_err), vim.log.levels.ERROR)
			return false
		end
		snapshot = ui_snapshot(workspace)
		local released, release_err = release_bound_ui(workspace, snapshot)
		if not released then
			local restored, restore_err = restore_ui(workspace, snapshot)
			notify(
				"Could not close review tab: "
					.. tostring(release_err)
					.. (restored and "" or "; UI restore failed: " .. tostring(restore_err)),
				vim.log.levels.ERROR
			)
			return false
		end
	else
		disable_ui(workspace, true)
		if not suspended_state then
			restore_invocation()
		end
	end
	local discarded, discard_err = discard_suspended_preview(suspended_state)
	if not discarded then
		notify("Could not discard suspended review preview: " .. tostring(discard_err), vim.log.levels.ERROR)
		return false
	end
	suspended = nil
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

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("NvimConfigCodeReview", { clear = true })
	vim.api.nvim_create_autocmd("CursorHold", {
		group = group,
		callback = function()
			show_inline_preview()
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave", "WinScrolled" }, {
		group = group,
		callback = clear_inline_preview,
	})
	vim.api.nvim_create_autocmd({ "WinLeave", "TabLeave" }, {
		group = group,
		callback = function()
			clear_inline_preview()
			remember_surface_focus()
			capture_invocation()
		end,
		desc = "Remember the latest ordinary review invocation",
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
	apply_comment_highlights()
	review_panel.refresh_highlights()
	if setup_done then
		local workspace = current_workspace()
		if workspace then
			update_panel(workspace)
			M.refresh_marks(workspace)
		end
		return
	end
	setup_done = true
	review_lsp.setup()
	setup_autocmds()
end

function M.structural_diff()
	local workspace = current_workspace()
	local entry = workspace and find_entry(workspace, workspace.entry_identity)
	if not entry or not workspace.mode_on or not surface_valid() then
		local err = "Select a file in an active review before opening structural diff"
		notify(err, vim.log.levels.WARN)
		return nil, err
	end
	local snapshot = entry_snapshot(entry)
	local generation = workspace.generation
	-- Model entries are immutable proxies; the snapshot exposes plain data.
	local opened, err = review_structural.open(snapshot, function()
		return workspace == current_workspace()
			and workspace.generation == generation
			and workspace.mode_on == true
			and surface_valid()
			and workspace.entry_identity == entry.identity
			and entry_matches_snapshot(find_entry(workspace, entry.identity), snapshot)
	end)
	if not opened then
		notify(err, vim.log.levels.WARN)
	end
	return opened, err
end

function M.teardown()
	cancel_engine()
	cancel_pending("review teardown", false)
	clear_inline_preview()
	local _, discard_err = discard_suspended_preview(suspended)
	if discard_err then
		notify(
			"Could not discard suspended review preview during teardown: " .. tostring(discard_err),
			vim.log.levels.ERROR
		)
	end
	for key, workspace in pairs(workspaces) do
		disable_ui(workspace, true)
		workspaces[key] = nil
	end
	release_surface()
	active = nil
	suspended = nil
	pending_surface_close = nil
	pending_operation = nil
	invocation = nil
	clear_scope_history()
	pcall(vim.api.nvim_del_augroup_by_name, "NvimConfigCodeReview")
	if review_lsp.teardown then
		review_lsp.teardown()
	end
	setup_done = false
	M.refresh_marks(nil)
	return true
end

M._parse_open = parse_open
M._workspaces = workspaces
M._scope_history = scope_history
M._active_workspace = current_workspace
M._open_scope_picker = scope_picker
M._choose_saved = choose_saved
M._root_for_command = root_for_command
M._contains_line = contains_line
M._workspace_preferences = workspace_preferences
M._inline_preview_text = inline_preview_text
M._inline_preview_chunks = inline_preview_chunks
M._show_inline_preview = show_inline_preview
M._clear_inline_preview = clear_inline_preview
M._preview_namespace = PREVIEW_NAMESPACE

return M
