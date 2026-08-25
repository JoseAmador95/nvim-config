-- Diffview ownership and the narrow private seam used by native reviews.
local M = {}

local RESTORE_INTERVAL_MS = 20
local RESTORE_ATTEMPTS = 500
local INITIAL_GIT_ENVIRONMENT = require("config.repo").git_safety_environment()

local pending
local controller
local tabs = {}
local views = setmetatable({}, { __mode = "k" })
local view_activity = setmetatable({}, { __mode = "k" })
local buffer_options = {}
local controller_call

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Review" })
end

local function valid_tab(tabpage)
	return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function routing_error()
	local variable = require("config.repo").git_routing_variable()
	if variable then
		return "native reviews require " .. variable .. " to be unset so Diffview cannot change repositories"
	end
	return nil
end

local function current_review()
	return tabs[vim.api.nvim_get_current_tabpage()]
end

local function view_windows(view)
	if not view or not valid_tab(view.tabpage) then
		return {}
	end
	return vim.api.nvim_tabpage_list_wins(view.tabpage)
end

-- `modifiable` and `readonly` are buffer-local, so restore them before the
-- user returns to a normal source tab that may share Diffview's local buffer.
local function protect_view(view)
	local tabpage = view and view.tabpage
	if not tabs[tabpage] then
		return
	end
	local saved = buffer_options[tabpage] or {}
	for _, win in ipairs(view_windows(view)) do
		if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
			local buf = vim.api.nvim_win_get_buf(win)
			if not saved[buf] and vim.api.nvim_buf_is_valid(buf) then
				saved[buf] = { modifiable = vim.bo[buf].modifiable, readonly = vim.bo[buf].readonly }
				vim.bo[buf].modifiable = false
				vim.bo[buf].readonly = true
			end
		end
	end
	buffer_options[tabpage] = saved
end

local function restore_view(view)
	local tabpage = view and view.tabpage
	local saved = tabpage and buffer_options[tabpage]
	if not saved then
		return
	end
	for buf, options in pairs(saved) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modifiable = options.modifiable
			vim.bo[buf].readonly = options.readonly
		end
	end
	buffer_options[tabpage] = nil
end

local function protected_buffers(view)
	local buffers = {}
	for buf in pairs(buffer_options[view and view.tabpage] or {}) do
		buffers[#buffers + 1] = buf
	end
	return buffers
end

local function on_view_enter(view)
	protect_view(view)
	local workspace = view and tabs[view.tabpage]
	if workspace then
		controller_call("view_enter", workspace)
	end
end

local function on_view_leave(view)
	local workspace = view and tabs[view.tabpage]
	if workspace then
		controller_call("clear_buffers", workspace, protected_buffers(view))
	end
	restore_view(view)
end

local function mark_tab(tabpage, workspace)
	local ok, tab_config = pcall(require, "config.tabs")
	if ok and type(tab_config.mark_transient) == "function" then
		local stale = workspace.session and workspace.session.stale and " [stale]" or ""
		local unsaved = workspace.unsaved_error and " [unsaved]" or ""
		local label = workspace.scope.label or workspace.scope.kind
		tab_config.mark_transient(tabpage, "Review · " .. label .. stale .. unsaved)
	end
end

local function unmark_tab(tabpage)
	local ok, tab_config = pcall(require, "config.tabs")
	if ok and type(tab_config.unmark_transient) == "function" then
		tab_config.unmark_transient(tabpage)
	end
end

local function isolate_adapter(view, workspace)
	local adapter = view and view.adapter
	if type(adapter) ~= "table" or type(adapter.get_command) ~= "function" then
		return nil, "Diffview did not expose the Git adapter for the review"
	end
	local adapter_root = adapter.ctx and adapter.ctx.toplevel
	local expected = vim.fs.normalize(vim.uv.fs_realpath(workspace.root) or workspace.root)
	local actual = type(adapter_root) == "string" and vim.fs.normalize(vim.uv.fs_realpath(adapter_root) or adapter_root)
		or nil
	if actual ~= expected then
		return nil, "Diffview opened the review with a different repository root"
	end
	local command = adapter:get_command()
	if type(command) ~= "table" or not vim.islist(command) or #command == 0 then
		return nil, "Diffview exposed an invalid Git command for the review"
	end
	local isolated = require("config.repo").clean_git_command(vim.deepcopy(command))
	adapter.get_command = function()
		return vim.deepcopy(isolated)
	end
	return true
end

controller_call = function(name, ...)
	local callback = controller and controller[name]
	if type(callback) == "function" then
		local ok, err = pcall(callback, ...)
		if not ok then
			notify("Review callback failed: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function restore_selection(workspace, request, attempts)
	if not request.target or not valid_tab(workspace.tabpage) then
		return
	end
	attempts = attempts or RESTORE_ATTEMPTS
	local previous_tab = vim.api.nvim_get_current_tabpage()
	local previous_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_tabpage(workspace.tabpage)
	local view = require("diffview.lib").get_current_view()
	local loading = view
		and (
			(view_activity[view] or 0) > 0
			or view.initialized ~= nil and view.initialized ~= true
			or view.panel and view.panel.updating == true
			or view.cur_entry and view.cur_entry.opened ~= true
		)
	local selected = not loading and M.select_file(request.path, request.target.layer, request.target)
	if request.target.focus == false and valid_tab(previous_tab) then
		vim.api.nvim_set_current_tabpage(previous_tab)
		if vim.api.nvim_win_is_valid(previous_win) then
			vim.api.nvim_set_current_win(previous_win)
		end
	end
	if selected then
		return
	end
	if attempts > 1 then
		vim.defer_fn(function()
			restore_selection(workspace, request, attempts - 1)
		end, RESTORE_INTERVAL_MS)
	else
		notify("Could not restore the exact review location", vim.log.levels.ERROR)
	end
end

local function on_view_opened(view)
	if not pending or not valid_tab(view and view.tabpage) then
		return
	end
	local request = pending
	pending = nil
	local workspace = request.workspace
	local isolated, isolate_err = isolate_adapter(view, workspace)
	if not isolated then
		notify(isolate_err, vim.log.levels.ERROR)
		if type(view.close) == "function" then
			pcall(view.close, view)
		end
		return
	end
	workspace.tabpage = view.tabpage
	workspace.view_mode = request.mode
	tabs[view.tabpage] = workspace
	views[view] = workspace
	view_activity[view] = 0
	if view.emitter and type(view.emitter.on) == "function" then
		view.emitter:on("file_open_pre", function()
			view_activity[view] = (view_activity[view] or 0) + 1
		end)
		view.emitter:on("file_open_post", function()
			view_activity[view] = math.max(0, (view_activity[view] or 1) - 1)
		end)
	end
	mark_tab(view.tabpage, workspace)
	protect_view(view)
	controller_call("view_opened", workspace, view)
	restore_selection(workspace, request)
end

local function on_view_closed(view)
	local workspace = views[view]
	if not workspace then
		return
	end
	local tabpage = view.tabpage
	local owned_buffers = protected_buffers(view)
	restore_view(view)
	views[view] = nil
	view_activity[view] = nil
	tabs[tabpage] = nil
	unmark_tab(tabpage)
	workspace.tabpage = nil
	controller_call("clear_buffers", workspace, owned_buffers)
	if workspace.reopening then
		workspace.reopening = nil
		return
	end
	controller_call("view_closed", workspace)
end

local function on_diff_buf_win_enter(buf, win, context)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local workspace = tabs[vim.api.nvim_win_get_tabpage(win)]
	if not workspace then
		return
	end
	vim.w[win].nvim_review_diff_symbol = context.symbol
	protect_view(require("diffview.lib").get_current_view())
	controller_call("decorate_buffer", workspace, buf, win)
end

local function build_args(workspace, mode, path)
	local args = { "-C" .. workspace.root }
	if mode == "history" then
		if workspace.scope.file_history_range then
			args[#args + 1] = "--range=" .. workspace.scope.file_history_range
		end
		if path and path ~= "" then
			args[#args + 1] = ":(literal)" .. path
		end
		return "DiffviewFileHistory", args
	end
	vim.list_extend(args, workspace.scope.diffview_args)
	if path and path ~= "" then
		args[#args + 1] = "--selected-file=" .. path
	end
	return "DiffviewOpen", args
end

local function invoke(workspace, mode, path, dependencies, target)
	local deps = dependencies or {}
	local command, args = build_args(workspace, mode, path)
	local request = {
		workspace = workspace,
		mode = mode,
		path = path or target and target.current_path,
		target = target,
	}
	pending = request
	local previous_environment = {}
	for name, value in pairs(INITIAL_GIT_ENVIRONMENT) do
		previous_environment[name] = vim.env[name] or vim.NIL
		vim.env[name] = value
	end
	local ok, err = pcall(deps.command or vim.api.nvim_cmd, { cmd = command, args = args }, {})
	for name, value in pairs(previous_environment) do
		vim.env[name] = value == vim.NIL and nil or value
	end
	if not ok then
		pending = nil
		return nil, tostring(err)
	end
	local schedule = deps.schedule or vim.schedule
	schedule(function()
		if pending == request then
			pending = nil
			notify("Diffview did not open a review tab", vim.log.levels.ERROR)
		end
	end)
	return true
end

---Open a review-owned exact diff or file-history view.
---@param workspace table
---@param mode? "files"|"history"
---@param path? string
---@param dependencies? table
---@param target? table
---@return boolean? opened
---@return string? error_message
function M.open(workspace, mode, path, dependencies, target)
	mode = mode or "files"
	if type(workspace) ~= "table" or type(workspace.root) ~= "string" or type(workspace.scope) ~= "table" then
		return nil, "review workspace is invalid"
	end
	if mode ~= "files" and mode ~= "history" then
		return nil, "review view mode must be files or history"
	end
	if mode == "history" and workspace.scope.kind == "working" then
		return nil, "working-tree reviews do not have a frozen commit range"
	end
	local environment_err = routing_error()
	if environment_err then
		return nil, environment_err
	end
	if valid_tab(workspace.tabpage) then
		vim.api.nvim_set_current_tabpage(workspace.tabpage)
		if workspace.view_mode == mode then
			local selection_path = path or target and target.current_path
			if selection_path then
				M.select_file(selection_path, target and target.layer, target)
			end
			return true
		end
		workspace.reopening = true
		local closed, close_err = M.close(dependencies)
		if not closed then
			workspace.reopening = nil
			return nil, close_err
		end
		local schedule = dependencies and dependencies.schedule or vim.schedule
		schedule(function()
			local opened, err = invoke(workspace, mode, path, dependencies, target)
			if not opened then
				notify(err, vim.log.levels.ERROR)
			end
		end)
		return true
	end
	return invoke(workspace, mode, path, dependencies, target)
end

---Return the review workspace attached to a tab, if any.
---@param tabpage? integer
---@return table?
function M.workspace(tabpage)
	return tabs[tabpage or vim.api.nvim_get_current_tabpage()]
end

---Refresh the stable title after workspace state such as drift changes.
---@param workspace table
function M.update_title(workspace)
	if workspace and valid_tab(workspace.tabpage) then
		mark_tab(workspace.tabpage, workspace)
	end
end

---Return whether the current tab belongs to the native review UI.
---@return boolean
function M.active()
	return current_review() ~= nil
end

local function current_entry(dependencies)
	local deps = dependencies or {}
	local view = deps.view or require("diffview.lib").get_current_view()
	if not view or type(view.infer_cur_file) ~= "function" then
		return nil, nil, "current window is not a Diffview file"
	end
	local ok, entry = pcall(view.infer_cur_file, view, false)
	if not ok or type(entry) ~= "table" or type(entry.path) ~= "string" then
		return nil, nil, "Diffview has no selected file"
	end
	return view, entry
end

local function entry_layer(workspace, entry)
	if workspace.scope.kind ~= "working" then
		return "historical"
	end
	if entry.kind == "staged" then
		return "staged"
	elseif entry.status == "?" then
		return "untracked"
	end
	return "unstaged"
end

local function active_diff_pane(view, symbol, win)
	local layout = type(view.cur_layout) == "table" and view.cur_layout or nil
	local pane = layout and layout[symbol] or nil
	if type(win) ~= "number" or type(pane) ~= "table" or pane.id ~= win or not vim.api.nvim_win_is_valid(win) then
		return nil, "focus a review diff pane before choosing a code location"
	end
	if type(pane.is_nulled) ~= "function" or type(pane.is_file_open) ~= "function" then
		return nil, "Diffview did not expose the selected review pane"
	end
	local checked_null, nulled = pcall(pane.is_nulled, pane)
	local checked_file, file_open = pcall(pane.is_file_open, pane)
	if not checked_null or not checked_file or nulled or not file_open then
		return nil, "review comments are unavailable for a missing diff side"
	end
	return pane
end

---Read the current Diffview target through one isolated, pinned private seam.
---@param dependencies? table
---@return table? target
---@return string? error_message
function M.current_target(dependencies)
	local workspace = current_review()
	if not workspace then
		return nil, "current tab is not a review workspace"
	end
	local environment_err = routing_error()
	if environment_err then
		return nil, environment_err
	end
	local view, entry, entry_err = current_entry(dependencies)
	if not view then
		return nil, entry_err
	end
	local deps = dependencies or {}
	local win = deps.win or vim.api.nvim_get_current_win()
	if workspace.scope.kind == "working" and entry.kind == "conflicting" then
		return nil, "review comments are unavailable for unresolved conflict layouts"
	end
	local symbol = deps.symbol or vim.w[win].nvim_review_diff_symbol
	local from_panel = false
	if symbol ~= "a" and symbol ~= "b" and symbol ~= "c" and symbol ~= "d" then
		if not deps.allow_panel then
			return nil, "focus a review diff pane before choosing a code location"
		end
		symbol = "b"
		from_panel = true
		local layout = type(view.cur_layout) == "table" and view.cur_layout or nil
		win = layout and type(layout.b) == "table" and layout.b.id or nil
	end
	local _, pane_err = active_diff_pane(view, symbol, win)
	if pane_err then
		return nil, pane_err
	end
	local side = symbol == "a" and "left" or "right"
	local oldpath = type(entry.oldpath) == "string" and entry.oldpath ~= "" and entry.oldpath or nil
	local path = side == "left" and oldpath or entry.path
	return {
		path = path or entry.path,
		current_path = entry.path,
		side = side,
		layer = entry_layer(workspace, entry),
		status = entry.status,
		symbol = symbol,
		bufnr = vim.api.nvim_win_get_buf(win),
		winid = win,
		view = view,
		revision = workspace.view_mode == "history"
				and type(entry.commit) == "table"
				and type(entry.commit.hash) == "string"
				and entry.commit.hash
			or nil,
		from_panel = from_panel,
	}
end

local function focus_target(workspace, target, defer, view, attempts)
	if not target then
		return
	end
	attempts = attempts or RESTORE_ATTEMPTS
	local defer_fn = defer or vim.defer_fn
	defer_fn(function()
		if not valid_tab(workspace.tabpage) then
			return
		end
		if view and ((view_activity[view] or 0) > 0 or view.cur_entry and view.cur_entry.opened ~= true) then
			if attempts > 1 then
				focus_target(workspace, target, defer, view, attempts - 1)
			end
			return
		end
		local wanted = target.side == "left" and "a" or "b"
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(workspace.tabpage)) do
			if vim.api.nvim_win_is_valid(win) and vim.w[win].nvim_review_diff_symbol == wanted then
				if target.focus ~= false then
					vim.api.nvim_set_current_win(win)
				end
				if target.line then
					local buf = vim.api.nvim_win_get_buf(win)
					local line = math.max(1, math.min(target.line, vim.api.nvim_buf_line_count(buf)))
					local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
					local column = math.max(0, math.min(target.column or 0, #text))
					vim.api.nvim_win_set_cursor(win, { line, column })
				end
				return
			end
		end
	end, RESTORE_INTERVAL_MS)
end

---Select an exact repository-relative path and working-tree layer.
---@param path string
---@param layer? string
---@param target? table
---@param dependencies? table
---@return boolean
function M.select_file(path, layer, target, dependencies)
	local workspace = current_review()
	if not workspace or routing_error() or type(path) ~= "string" or path == "" then
		return false
	end
	local deps = dependencies or {}
	local view = deps.view or require("diffview.lib").get_current_view()
	if not view then
		return false
	end
	if view.files and type(view.files.iter) == "function" and type(view.set_file) == "function" then
		for _, entry in view.files:iter() do
			local path_matches = entry.path == path or entry.oldpath == path
			if path_matches and (not layer or entry_layer(workspace, entry) == layer) then
				view:set_file(entry, true, true)
				focus_target(workspace, target, deps.defer, view)
				return true
			end
		end
		return false
	end
	if
		(layer == nil or layer == "historical")
		and type(view.set_file) == "function"
		and type(view.panel) == "table"
		and type(view.panel.entries) == "table"
	then
		local current = type(view.panel.cur_item) == "table" and view.panel.cur_item[2] or nil
		local current_revision = current
				and type(current.commit) == "table"
				and type(current.commit.hash) == "string"
				and current.commit.hash
			or nil
		if
			current
			and (current.path == path or current.oldpath == path)
			and (not target or not target.revision or target.revision == current_revision)
		then
			view:set_file(current, true)
			focus_target(workspace, target, deps.defer, view)
			return true
		end
		for _, commit in ipairs(view.panel.entries) do
			for _, entry in ipairs(commit.files or {}) do
				local revision = type(entry.commit) == "table" and entry.commit.hash
				if
					(entry.path == path or entry.oldpath == path)
					and (not target or not target.revision or target.revision == revision)
				then
					view:set_file(entry, true)
					focus_target(workspace, target, deps.defer, view)
					return true
				end
			end
		end
		return false
	end
	if layer or type(view.set_file_by_path) ~= "function" then
		return false
	end
	view:set_file_by_path(path, true, true)
	focus_target(workspace, target, deps.defer, view)
	return true
end

---Validate that inherited Git routing still cannot redirect the owned view.
---@return boolean
---@return string? error_message
function M.environment_safe()
	local err = routing_error()
	return err == nil, err
end

---Close the current review-owned Diffview tab.
---@return boolean
function M.close(dependencies)
	if not current_review() then
		return nil, "current tab is not a review workspace"
	end
	local deps = dependencies or {}
	local view = deps.view
	if not view and not deps.close then
		view = require("diffview.lib").get_current_view()
	end
	if view then
		local loading = (view_activity[view] or 0) > 0
			or view.initialized ~= nil and view.initialized ~= true
			or view.panel and view.panel.updating == true
			or view.cur_entry and view.cur_entry.opened ~= true
		if loading then
			return nil, "Diffview is still loading the selected file; retry when the diff is ready"
		end
	end
	local tabpage = vim.api.nvim_get_current_tabpage()
	local close = deps.close or require("diffview").close
	local ok, err = pcall(close)
	if not ok then
		return nil, tostring(err)
	end
	if tabs[tabpage] then
		return nil, "Diffview did not close the review view"
	end
	return true
end

---Guard a mutating Diffview mapping while preserving it in ordinary views.
---@param action function
---@return function
function M.guard(action)
	return function(...)
		if M.active() then
			notify("Review views are read-only", vim.log.levels.WARN)
			return
		end
		return action(...)
	end
end

---Route Diffview's goto-file mapping through the review code toggle.
---@param fallback function
---@return function
function M.code_or(fallback)
	return function(...)
		if M.active() then
			controller_call("code")
			return
		end
		return fallback(...)
	end
end

---Route Diffview's close action through the review lifecycle guard.
---@param fallback function
---@return function
function M.close_or(fallback)
	return function()
		if M.active() then
			controller_call("close")
			return
		end
		return fallback()
	end
end

---Route Diffview's live refresh through working-scope drift validation.
---@param fallback function
---@return function
function M.refresh_or(fallback)
	return function(...)
		if M.active() then
			controller_call("refresh")
			return
		end
		return fallback(...)
	end
end

---Install callbacks owned by the review controller.
---@param callbacks table
function M.set_controller(callbacks)
	controller = callbacks
end

---Hooks passed directly to Diffview's documented setup API.
---@return table
function M.hooks()
	return {
		view_opened = on_view_opened,
		view_closed = on_view_closed,
		view_enter = on_view_enter,
		view_leave = on_view_leave,
		diff_buf_win_enter = on_diff_buf_win_enter,
	}
end

M._build_args = build_args
M._on_view_opened = on_view_opened
M._on_view_closed = on_view_closed

return M
