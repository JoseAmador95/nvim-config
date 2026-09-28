local M = {}

local HOME_VARIABLE = "nvim_config_home"
local HOME_PRESENTED_VARIABLE = "tab_first_home_presented"
local TRANSIENT_TITLE_VARIABLE = "nvim_config_transient_title"
local TRANSIENT_LIFECYCLE_GROUP = "TabFirstTransientLifecycle"

local function default_options()
	return {
		enabled = function()
			return true
		end,
		schedule = vim.schedule,
		notify = vim.notify,
		present_home = nil,
		dismiss_ui = nil,
		event = nil,
		is_home_buffer = function(buf)
			if vim.b[buf][HOME_PRESENTED_VARIABLE] == true then
				return vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
			end
			return vim.bo[buf].buftype == ""
				and vim.bo[buf].filetype == ""
				and vim.api.nvim_buf_get_name(buf) == ""
				and not vim.bo[buf].modified
				and vim.api.nvim_buf_line_count(buf) == 1
				and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
		end,
		is_special_buffer = function(buf)
			return vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == ""
		end,
		history = {
			enabled = true,
			max_entries = 200,
			scope = "workspace",
			native_fallback = nil,
			open_location = nil,
			capture_location = nil,
			restore_location = nil,
		},
	}
end

local options = default_options()
local configured = false
local lifecycle_generation = 0

local pending_closes = {}
local focused_windows = {}
local home_recovery_pending = false
local transient_token = 0
local transient_records = {}
local transient_by_identity = {}
local transient_lifecycle_ready = false
local tearing_down = false
local close_tab
local history = {
	entries = {},
	index = 0,
}

local function emit(kind, payload)
	if type(options.event) ~= "function" then
		return
	end
	local event = vim.deepcopy(payload or {})
	event.kind = kind
	pcall(options.event, event)
end

local function is_enabled()
	local ok, value = pcall(options.enabled)
	return ok and value ~= false
end

local function notify(message, level, title)
	pcall(options.notify, message, level, { title = title })
end

local function valid_tab(tabpage)
	return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function tab_number(tabpage)
	if not valid_tab(tabpage) then
		return nil
	end

	local ok, number = pcall(vim.api.nvim_tabpage_get_number, tabpage)
	return ok and number or nil
end

local function is_nonfloating_window(win, tabpage)
	if type(win) ~= "number" or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	if tabpage and vim.api.nvim_win_get_tabpage(win) ~= tabpage then
		return false
	end

	local ok, config = pcall(vim.api.nvim_win_get_config, win)
	return ok and (not config.relative or config.relative == "")
end

local function nonfloating_windows(tabpage)
	local windows = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if is_nonfloating_window(win, tabpage) then
			windows[#windows + 1] = win
		end
	end
	return windows
end

local function focused_window(tabpage)
	local win = focused_windows[tabpage]
	if is_nonfloating_window(win, tabpage) then
		return win
	end

	win = nonfloating_windows(tabpage)[1]
	focused_windows[tabpage] = win
	return win
end

local function has_home_marker(tabpage)
	if not valid_tab(tabpage) then
		return false
	end

	local ok, value = pcall(vim.api.nvim_tabpage_get_var, tabpage, HOME_VARIABLE)
	return ok and value == true
end

local function home_window(tabpage)
	if not valid_tab(tabpage) then
		return nil
	end

	local windows = nonfloating_windows(tabpage)
	if #windows ~= 1 then
		return nil
	end
	return windows[1]
end

local function has_home_shape(tabpage)
	local win = home_window(tabpage)
	if not win or vim.wo[win].diff then
		return false
	end

	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local ok, result = pcall(options.is_home_buffer, buf)
	return ok and result == true
end

local function buffer_is_blank(buf)
	return vim.api.nvim_buf_line_count(buf) == 1 and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
end

local function close_handle(tabpage)
	local number = tab_number(tabpage)
	if not number then
		return false, "the tab no longer exists"
	end

	local ok, error_message = pcall(vim.api.nvim_cmd, {
		cmd = "tabclose",
		args = { tostring(number) },
	}, {})
	return ok, error_message
end

local function delete_owned_buffer(buf, owned)
	if
		not owned
		or not vim.api.nvim_buf_is_valid(buf)
		or vim.api.nvim_buf_get_name(buf) ~= ""
		or vim.bo[buf].modified
		or not buffer_is_blank(buf)
	then
		return
	end
	if #vim.fn.win_findbuf(buf) > 0 then
		return
	end
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function transient_identity(owner, key)
	return owner .. "\0" .. key
end

local function transient_handle(record)
	return {
		tabpage = record.tabpage,
		token = record.token,
	}
end

local function transient_record(handle)
	if type(handle) ~= "table" or type(handle.tabpage) ~= "number" or type(handle.token) ~= "number" then
		return nil
	end
	local record = transient_records[handle.tabpage]
	if not record or record.token ~= handle.token or not valid_tab(record.tabpage) then
		return nil
	end
	return record
end

local function forget_transient(record)
	if transient_records[record.tabpage] == record then
		transient_records[record.tabpage] = nil
	end
	if transient_by_identity[record.identity] == record then
		transient_by_identity[record.identity] = nil
	end
	pending_closes[record.tabpage] = nil
	focused_windows[record.tabpage] = nil
end

local function notify_transient_callback(kind, err)
	notify(("Transient tab %s callback failed: %s"):format(kind, tostring(err)), vim.log.levels.ERROR, "Tabs")
end

local function finish_transient(record, reason)
	if record.closed_notified then
		return
	end
	record.closed_notified = true
	forget_transient(record)
	local callback = record.on_closed
	record.on_request_close = nil
	record.on_closed = nil
	delete_owned_buffer(record.bufnr, record.owned_buf)
	if type(callback) == "function" then
		local ok, err = pcall(callback, transient_handle(record), reason)
		if not ok then
			notify_transient_callback("on_closed", err)
		end
	end
end

local function reconcile_transients()
	local stale = {}
	for _, record in pairs(transient_records) do
		if not valid_tab(record.tabpage) then
			stale[#stale + 1] = record
		end
	end
	for _, record in ipairs(stale) do
		finish_transient(record, record.close_reason or "external")
	end
end

local function run_transient_preflight(record, reason)
	if record.preflight_running or type(record.on_request_close) ~= "function" then
		return true
	end
	record.preflight_running = true
	local ok, accepted = pcall(record.on_request_close, transient_handle(record), reason)
	record.preflight_running = false
	if not ok then
		notify_transient_callback("on_request_close", accepted)
		return false
	end
	return accepted ~= false
end

local function closing_transient_from_event(event)
	local current = vim.api.nvim_get_current_tabpage()
	local record = transient_records[current]
	if record then
		return record
	end
	local number = tonumber(event and event.match)
	if not number then
		return nil
	end
	for _, candidate in pairs(transient_records) do
		if tab_number(candidate.tabpage) == number then
			return candidate
		end
	end
	return nil
end

local function ensure_transient_lifecycle()
	local group = vim.api.nvim_create_augroup(TRANSIENT_LIFECYCLE_GROUP, { clear = true })
	vim.api.nvim_create_autocmd("TabClosedPre", {
		group = group,
		desc = "Preflight externally closed transient tabs",
		callback = function(event)
			local record = closing_transient_from_event(event)
			if not record or record.close_reason then
				return
			end
			local pending = pending_closes[record.tabpage]
			if type(pending) == "table" and pending.token == record.token then
				record.close_reason = "supported"
				return
			end
			record.close_reason = "external"
			run_transient_preflight(record, "external")
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		desc = "Reconcile closed transient tabs",
		callback = reconcile_transients,
	})
	transient_lifecycle_ready = true
end

local function rollback_landing(landing, landing_buf, landing_buf_owned, restore)
	if valid_tab(restore) then
		pcall(vim.api.nvim_set_current_tabpage, restore)
	end
	if valid_tab(landing) then
		close_handle(landing)
	end
	delete_owned_buffer(landing_buf, landing_buf_owned)
	if valid_tab(restore) then
		pcall(vim.api.nvim_set_current_tabpage, restore)
	end
end

local function normalized_path(path)
	local absolute = vim.fn.fnamemodify(path, ":p")
	return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

local function set_cursor(win, lnum, col)
	local buf = vim.api.nvim_win_get_buf(win)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(tonumber(lnum) or 1, line_count))
	local line = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ""
	local target_col = math.max(0, math.min((tonumber(col) or 1) - 1, #line))
	vim.api.nvim_win_set_cursor(win, { target_line, target_col })
end

local function same_document(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end
	if left.kind == "provider" or right.kind == "provider" then
		return left.kind == "provider"
			and right.kind == "provider"
			and type(left.provider) == "string"
			and left.provider ~= ""
			and left.provider == right.provider
			and type(left.document_key) == "string"
			and left.document_key ~= ""
			and left.document_key == right.document_key
	end
	return type(left.path) == "string" and left.path ~= "" and left.path == right.path
end

local function same_location(left, right)
	if not same_document(left, right) then
		return false
	end
	if left.kind == "provider" then
		return type(left.location_key) == "string"
			and left.location_key ~= ""
			and left.location_key == right.location_key
	end
	return left.lnum == right.lnum and left.col == right.col
end

local function trim_forward()
	for index = #history.entries, history.index + 1, -1 do
		table.remove(history.entries, index)
	end
end

local function append_history(entry)
	history.entries[#history.entries + 1] = vim.deepcopy(entry)
	history.index = #history.entries
	local limit = math.max(1, tonumber(options.history.max_entries) or 200)
	while #history.entries > limit do
		table.remove(history.entries, 1)
		history.index = history.index - 1
	end
end

local function window_has_path(win, path)
	if not is_nonfloating_window(win) then
		return false
	end
	if M.is_transient(vim.api.nvim_win_get_tabpage(win)) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local special_ok, special = pcall(options.is_special_buffer, buf)
	if not special_ok or special then
		return false
	end
	local name = vim.api.nvim_buf_get_name(buf)
	return name ~= "" and normalized_path(name) == path
end

local function window_for_path(path, preferred_tab, preferred_win)
	if window_has_path(preferred_win, path) then
		return vim.api.nvim_win_get_tabpage(preferred_win), preferred_win
	end

	local function find_in_tab(tabpage)
		if not valid_tab(tabpage) or M.is_transient(tabpage) then
			return nil
		end
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
			if window_has_path(win, path) then
				return win
			end
		end
		return nil
	end

	local preferred = find_in_tab(preferred_tab)
	if preferred then
		return preferred_tab, preferred
	end
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		if tabpage ~= preferred_tab then
			local win = find_in_tab(tabpage)
			if win then
				return tabpage, win
			end
		end
	end
	return nil, nil
end

local function history_enabled()
	return options.history.enabled ~= false
end

local function notify_history_callback(kind, err)
	notify(("Navigation history %s callback failed: %s"):format(kind, tostring(err)), vim.log.levels.ERROR, "Tabs")
end

local function provider_entry(entry)
	return type(entry) == "table"
		and entry.kind == "provider"
		and type(entry.provider) == "string"
		and entry.provider ~= ""
		and type(entry.document_key) == "string"
		and entry.document_key ~= ""
		and type(entry.location_key) == "string"
		and entry.location_key ~= ""
		and type(entry.label) == "string"
		and type(entry.payload) == "table"
end

local function file_entry(entry)
	return type(entry) == "table"
		and entry.kind == nil
		and type(entry.path) == "string"
		and entry.path ~= ""
		and type(entry.lnum) == "number"
		and entry.lnum % 1 == 0
		and entry.lnum >= 1
		and type(entry.col) == "number"
		and entry.col % 1 == 0
		and entry.col >= 1
end

local function history_entry(entry)
	return provider_entry(entry) or file_entry(entry)
end

local function callback_restore_result(kind, ok, restored, err, reported)
	if not ok then
		notify_history_callback(kind, restored)
		return nil
	elseif restored == true then
		return true
	elseif restored == false and err == nil then
		return false
	end
	if reported ~= true then
		notify_history_callback(kind, err or "did not confirm whether the location was stale")
	end
	return nil
end

local function restore_history_entry(entry)
	if not history_entry(entry) then
		return false
	elseif entry.kind == "provider" then
		if type(options.history.restore_location) ~= "function" then
			notify_history_callback("restore_location", "provider restoration is not configured")
			return nil
		end
		local ok, restored, restore_err, reported = pcall(options.history.restore_location, vim.deepcopy(entry))
		return callback_restore_result("restore_location", ok, restored, restore_err, reported)
	end
	local tabpage, win = window_for_path(entry.path, entry.tabpage, entry.winid)
	if win then
		vim.api.nvim_set_current_tabpage(tabpage)
		vim.api.nvim_set_current_win(win)
		set_cursor(win, entry.lnum, entry.col)
		return true
	end

	local buffer_available = entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr)
	if not buffer_available and vim.fn.filereadable(entry.path) ~= 1 then
		return false
	end
	if type(options.history.open_location) == "function" then
		local ok, restored, restore_err, reported = pcall(options.history.open_location, vim.deepcopy(entry))
		return callback_restore_result("open_location", ok, restored, restore_err, reported)
	end

	local ok, restored = pcall(M.open, entry.path, {
		lnum = entry.lnum,
		col = entry.col,
		record_history = false,
	})
	if not ok then
		notify_history_callback("open_location", restored)
		return nil
	elseif restored == nil then
		notify_history_callback("open_location", "canonical opening did not return a destination")
		return nil
	end
	return true
end

local function prepare_traversal()
	local current = M.capture()
	if not current or history.index == 0 then
		return
	end
	if same_location(history.entries[history.index], current) then
		history.entries[history.index] = vim.deepcopy(current)
		return
	end
	trim_forward()
	append_history(current)
end

local function traversal_count(opts)
	local count = tonumber(opts.count) or 1
	if count ~= count or count == math.huge or count == -math.huge then
		return 1
	end
	return math.max(1, math.floor(count))
end

local function fallback(direction, opts, count)
	if opts.fallback ~= false and type(options.history.native_fallback) == "function" then
		options.history.native_fallback(direction, count)
	end
	return false
end

local function traverse(direction, opts)
	opts = opts or {}
	local remaining = traversal_count(opts)
	if not history_enabled() then
		return fallback(direction, opts, remaining)
	end
	if #history.entries == 0 then
		return fallback(direction, opts, remaining)
	end

	prepare_traversal()
	local candidate = history.index + direction
	local restored = false
	while remaining > 0 and candidate >= 1 and candidate <= #history.entries do
		local result = restore_history_entry(history.entries[candidate])
		if result == nil then
			return restored
		elseif result == true then
			history.index = candidate
			remaining = remaining - 1
			restored = true
		end
		candidate = candidate + direction
	end
	return restored
end

---Configure host-owned integrations. Repeated setup preserves tabs and history.
---@param opts? table
function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	assert(
		type(opts) == "table" and (next(opts) == nil or not vim.islist(opts)),
		"tab-first setup options must be an object"
	)
	local allowed = {
		enabled = true,
		schedule = true,
		notify = true,
		present_home = true,
		dismiss_ui = true,
		event = true,
		is_home_buffer = true,
		is_special_buffer = true,
		history = true,
	}
	for key in pairs(opts) do
		assert(allowed[key], "tab-first setup contains an unknown option: " .. tostring(key))
	end
	for _, key in ipairs({
		"enabled",
		"schedule",
		"notify",
		"present_home",
		"dismiss_ui",
		"event",
		"is_home_buffer",
		"is_special_buffer",
	}) do
		assert(opts[key] == nil or type(opts[key]) == "function", "tab-first " .. key .. " must be a function")
	end
	local history_options = opts.history
	if history_options == nil then
		history_options = {}
	end
	assert(
		type(history_options) == "table" and (next(history_options) == nil or not vim.islist(history_options)),
		"tab-first history must be an object"
	)
	for key in pairs(history_options) do
		assert(
			key == "enabled"
				or key == "max_entries"
				or key == "scope"
				or key == "native_fallback"
				or key == "open_location"
				or key == "capture_location"
				or key == "restore_location",
			"tab-first history contains an unknown option: " .. tostring(key)
		)
	end
	assert(
		history_options.enabled == nil or type(history_options.enabled) == "boolean",
		"tab-first history.enabled must be boolean"
	)
	assert(
		history_options.max_entries == nil
			or (
				type(history_options.max_entries) == "number"
				and history_options.max_entries % 1 == 0
				and history_options.max_entries >= 1
			),
		"tab-first history.max_entries must be a positive integer"
	)
	assert(
		history_options.scope == nil or history_options.scope == "workspace",
		"tab-first history.scope must be workspace"
	)
	for _, key in ipairs({ "native_fallback", "open_location", "capture_location", "restore_location" }) do
		assert(
			history_options[key] == nil or type(history_options[key]) == "function",
			"tab-first history." .. key .. " must be a function"
		)
	end
	local defaults = default_options()
	options = vim.tbl_deep_extend("force", defaults, opts)
	options.history = vim.tbl_deep_extend("force", defaults.history, history_options)
	pending_closes = {}
	home_recovery_pending = false
	configured = true
	lifecycle_generation = lifecycle_generation + 1
	ensure_transient_lifecycle()
	return true
end

function M.effective_config()
	return {
		history = {
			enabled = options.history.enabled,
			max_entries = options.history.max_entries,
			scope = options.history.scope,
		},
	}
end

function M.status()
	local pending = 0
	for _ in pairs(pending_closes) do
		pending = pending + 1
	end
	return vim.deepcopy({
		configured = configured,
		history = {
			enabled = options.history.enabled,
			max_entries = options.history.max_entries,
			scope = options.history.scope,
			entries = #history.entries,
			index = history.index,
		},
		pending_closes = pending,
		home_recovery_pending = home_recovery_pending,
	})
end

function M.teardown()
	lifecycle_generation = lifecycle_generation + 1
	tearing_down = true
	pcall(vim.api.nvim_del_augroup_by_name, TRANSIENT_LIFECYCLE_GROUP)
	transient_lifecycle_ready = false
	local records = {}
	for _, record in pairs(transient_records) do
		records[#records + 1] = record
	end
	for _, record in ipairs(records) do
		if valid_tab(record.tabpage) then
			pcall(vim.api.nvim_tabpage_del_var, record.tabpage, TRANSIENT_TITLE_VARIABLE)
		end
		finish_transient(record, "teardown")
	end
	transient_records = {}
	transient_by_identity = {}
	tearing_down = false
	pending_closes = {}
	focused_windows = {}
	home_recovery_pending = false
	history.entries = {}
	history.index = 0
	options = default_options()
	configured = false
	return true
end

---Remember the current normal window so tab labels survive transient floats.
function M.remember_current_window()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	if valid_tab(tabpage) and is_nonfloating_window(win, tabpage) then
		focused_windows[tabpage] = win
	end
end

---Whether a tab is the explicitly marked, still-pristine home landing page.
---@param tabpage integer
---@return boolean
function M.is_home(tabpage)
	return not M.is_transient(tabpage) and has_home_marker(tabpage) and has_home_shape(tabpage)
end

---Mark a pristine scratch or dashboard tab as the reusable home landing page.
---@param tabpage integer
---@return boolean
function M.mark_home(tabpage)
	if M.is_transient(tabpage) or not has_home_shape(tabpage) then
		return false
	end
	vim.api.nvim_tabpage_set_var(tabpage, HOME_VARIABLE, true)
	return true
end

---@param tabpage integer
function M.unmark_home(tabpage)
	if valid_tab(tabpage) then
		pcall(vim.api.nvim_tabpage_del_var, tabpage, HOME_VARIABLE)
	end
end

---@param tabpage integer
---@param title string
---@return boolean
function M.mark_transient(tabpage, title)
	if not valid_tab(tabpage) or type(title) ~= "string" or title == "" then
		return false
	end
	return pcall(vim.api.nvim_tabpage_set_var, tabpage, TRANSIENT_TITLE_VARIABLE, title)
end

---@param tabpage integer
function M.unmark_transient(tabpage)
	if valid_tab(tabpage) then
		pcall(vim.api.nvim_tabpage_del_var, tabpage, TRANSIENT_TITLE_VARIABLE)
	end
end

---@param tabpage integer
---@return string?
function M.transient_title(tabpage)
	if not valid_tab(tabpage) then
		return nil
	end

	local ok, title = pcall(vim.api.nvim_tabpage_get_var, tabpage, TRANSIENT_TITLE_VARIABLE)
	return ok and type(title) == "string" and title ~= "" and title or nil
end

---@param tabpage integer
---@return boolean
function M.is_transient(tabpage)
	return M.transient_title(tabpage) ~= nil
end

local function validate_transient_spec(spec)
	assert(
		type(spec) == "table" and (next(spec) == nil or not vim.islist(spec)),
		"tab-first transient spec must be an object"
	)
	for name in pairs(spec) do
		assert(
			name == "owner" or name == "key" or name == "title" or name == "on_request_close" or name == "on_closed",
			"tab-first transient spec contains an unknown option: " .. tostring(name)
		)
	end
	for _, name in ipairs({ "owner", "key", "title" }) do
		local value = spec[name]
		assert(type(value) == "string" and value ~= "", "tab-first transient " .. name .. " must be non-empty")
	end
	assert(
		not spec.owner:find("\0", 1, true) and not spec.key:find("\0", 1, true),
		"tab-first transient owner and key cannot contain NUL"
	)
	for _, name in ipairs({ "on_request_close", "on_closed" }) do
		assert(
			spec[name] == nil or type(spec[name]) == "function",
			"tab-first transient " .. name .. " must be a function"
		)
	end
end

---Whether an opaque transient lease still owns its exact live tab.
---@param handle table
---@return boolean
function M.valid_transient(handle)
	return transient_record(handle) ~= nil
end

---Focus the exact tab owned by an opaque transient lease.
---@param handle table
---@return boolean?
---@return string? err
function M.focus_transient(handle)
	local record = transient_record(handle)
	if not record then
		return nil, "transient tab handle is stale"
	end
	local ok, err = pcall(vim.api.nvim_set_current_tabpage, record.tabpage)
	if not ok or not transient_record(handle) then
		reconcile_transients()
		return nil, ok and "transient tab closed while it was focused" or tostring(err)
	end
	return true
end

---Replace the stable title for an exact transient lease.
---@param handle table
---@param title string
---@return boolean?
---@return string? err
function M.rename_transient(handle, title)
	if type(title) ~= "string" or title == "" then
		return nil, "transient tab title must be non-empty"
	end
	local record = transient_record(handle)
	if not record then
		return nil, "transient tab handle is stale"
	end
	local ok, err = pcall(vim.api.nvim_tabpage_set_var, record.tabpage, TRANSIENT_TITLE_VARIABLE, title)
	if not ok then
		return nil, tostring(err)
	end
	record.title = title
	return true
end

---Create or focus one dedicated transient tab for an owner/key identity.
---@param spec { owner: string, key: string, title: string, on_request_close?: fun(handle: table, reason: string): boolean?, on_closed?: fun(handle: table, reason: string) }
---@return table? handle
---@return string? err
function M.acquire_transient(spec)
	validate_transient_spec(spec)
	if tearing_down then
		return nil, "tab-first is tearing down"
	end
	if not transient_lifecycle_ready then
		ensure_transient_lifecycle()
	end
	local identity = transient_identity(spec.owner, spec.key)
	local existing = transient_by_identity[identity]
	if existing and not valid_tab(existing.tabpage) then
		finish_transient(existing, existing.close_reason or "external")
		existing = nil
	end
	if existing then
		local handle = transient_handle(existing)
		local focused, focus_err = M.focus_transient(handle)
		if not focused then
			return nil, focus_err
		end
		local renamed, rename_err = M.rename_transient(handle, spec.title)
		if not renamed then
			return nil, rename_err
		end
		existing.on_request_close = spec.on_request_close
		existing.on_closed = spec.on_closed
		return transient_handle(existing)
	end

	local existing_buffers = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		existing_buffers[buf] = true
	end
	local opened, open_err = pcall(vim.api.nvim_cmd, { cmd = "tabnew" }, {})
	if not opened then
		return nil, tostring(open_err)
	end
	local tabpage = vim.api.nvim_get_current_tabpage()
	local bufnr = vim.api.nvim_get_current_buf()
	local owned_buf = not existing_buffers[bufnr]
	M.unmark_home(tabpage)
	if not M.mark_transient(tabpage, spec.title) then
		close_handle(tabpage)
		delete_owned_buffer(bufnr, owned_buf)
		return nil, "could not mark the new tab as transient"
	end
	transient_token = transient_token + 1
	local record = {
		bufnr = bufnr,
		closed_notified = false,
		identity = identity,
		key = spec.key,
		on_closed = spec.on_closed,
		on_request_close = spec.on_request_close,
		owned_buf = owned_buf,
		owner = spec.owner,
		tabpage = tabpage,
		title = spec.title,
		token = transient_token,
	}
	transient_records[tabpage] = record
	transient_by_identity[identity] = record
	return transient_handle(record)
end

---Release one exact owner lease after its owner has completed cleanup.
---@param handle table
---@return boolean?
---@return string? err
function M.release_transient(handle)
	local record = transient_record(handle)
	if not record then
		return nil, "transient tab handle is stale"
	end
	if record.close_reason == "external" then
		return nil, "transient tab is already closing externally"
	end
	record.releasing = true
	return close_tab(record.tabpage, "released", true)
end

---@return integer?
function M.find_home()
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		if M.is_home(tabpage) then
			return tabpage
		end
	end
	return nil
end

---Attempt to repair or adopt the sole safe home dashboard.
---@return boolean recovered
function M.recover_home()
	local tabpages = vim.api.nvim_list_tabpages()
	if #tabpages ~= 1 then
		return false
	end

	local tabpage = tabpages[1]
	if M.is_transient(tabpage) then
		return false
	end
	local win = home_window(tabpage)
	if not win or vim.wo[win].diff then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= "" or vim.bo[buf].modified then
		return false
	end

	local classified, is_home = pcall(options.is_home_buffer, buf)
	local dashboard = classified and is_home and vim.bo[buf].buftype == "nofile"
	local marked = has_home_marker(tabpage)
	local marked_landing = marked and vim.bo[buf].buftype == "" and vim.bo[buf].filetype == ""
	if not dashboard and not marked_landing then
		return false
	end
	if dashboard and not buffer_is_blank(buf) then
		if not marked then
			M.mark_home(tabpage)
		end
		return true
	end
	if not buffer_is_blank(buf) then
		return false
	end
	if type(options.present_home) ~= "function" then
		notify("Could not open home dashboard: presenter is unavailable", vim.log.levels.ERROR, "Tabs")
		return false
	end

	local opened, error_message = pcall(options.present_home, {
		tabpage = tabpage,
		buf = buf,
		win = win,
	})
	if not opened then
		notify("Could not open home dashboard: " .. tostring(error_message), vim.log.levels.ERROR, "Tabs")
		return false
	end
	vim.b[buf][HOME_PRESENTED_VARIABLE] = true
	M.mark_home(tabpage)
	return true
end

---Schedule one safe home recovery; duplicate requests coalesce.
---@return boolean queued
function M.ensure_home()
	if not is_enabled() or home_recovery_pending then
		return false
	end

	home_recovery_pending = true
	local generation = lifecycle_generation
	options.schedule(function()
		if generation ~= lifecycle_generation then
			return
		end
		home_recovery_pending = false
		if is_enabled() then
			M.recover_home()
		end
	end)
	return true
end

---Keep a tab label on its last focused normal window while a UI float is active.
---@param item { name: string, tabnr: integer }
---@return string
function M.name_formatter(item)
	local label = type(item) == "table" and type(item.name) == "string" and item.name or "[No Name]"
	if type(item) ~= "table" or not valid_tab(item.tabnr) then
		return label
	end

	local title = M.transient_title(item.tabnr)
	if title then
		return title
	end
	if not is_enabled() then
		return label
	end

	local active = vim.api.nvim_tabpage_get_win(item.tabnr)
	if is_nonfloating_window(active, item.tabnr) then
		focused_windows[item.tabnr] = active
		return item.name
	end

	local win = focused_window(item.tabnr)
	if not win then
		return label
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local path = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
	return path ~= "" and vim.fn.fnamemodify(path, ":t") or "[No Name]"
end

local function reset_transient_close(record)
	if record and transient_records[record.tabpage] == record then
		record.close_reason = nil
		record.releasing = nil
	end
end

---Close one stable tab handle without deleting user buffers.
---@param tabpage? integer
---@param reason? string
---@param skip_preflight? boolean
---@return boolean
close_tab = function(tabpage, reason, skip_preflight)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	if not valid_tab(tabpage) then
		return false
	end
	local transient = transient_records[tabpage]
	if transient and not skip_preflight then
		if not run_transient_preflight(transient, "supported") then
			return false
		end
		if not valid_tab(tabpage) then
			reconcile_transients()
			return true
		end
	end
	if transient then
		transient.close_reason = reason or "supported"
	end
	if M.is_home(tabpage) and #vim.api.nvim_list_tabpages() == 1 then
		reset_transient_close(transient)
		M.ensure_home()
		return true
	end

	if tabpage == vim.api.nvim_get_current_tabpage() and type(options.dismiss_ui) == "function" then
		pcall(options.dismiss_ui)
	end

	local original = vim.api.nvim_get_current_tabpage()
	local landing
	local landing_buf
	local landing_buf_owned
	if #vim.api.nvim_list_tabpages() == 1 then
		local existing_buffers = {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			existing_buffers[buf] = true
		end
		local ok, error_message = pcall(vim.api.nvim_cmd, { cmd = "tabnew" }, {})
		if not ok then
			reset_transient_close(transient)
			notify("Could not close tab: " .. tostring(error_message), vim.log.levels.ERROR, "Tabs")
			return false
		end

		landing = vim.api.nvim_get_current_tabpage()
		landing_buf = vim.api.nvim_get_current_buf()
		landing_buf_owned = not existing_buffers[landing_buf]
		if not M.mark_home(landing) then
			rollback_landing(landing, landing_buf, landing_buf_owned, original)
			reset_transient_close(transient)
			notify("Could not close tab: could not create a clean home tab", vim.log.levels.ERROR, "Tabs")
			return false
		end
	end

	local ok, error_message = close_handle(tabpage)
	if not ok then
		if landing then
			rollback_landing(landing, landing_buf, landing_buf_owned, original)
		elseif valid_tab(original) then
			pcall(vim.api.nvim_set_current_tabpage, original)
		end
		reset_transient_close(transient)
		notify("Could not close tab: " .. tostring(error_message), vim.log.levels.ERROR, "Tabs")
		return false
	end
	reconcile_transients()

	if landing or M.find_home() then
		M.ensure_home()
	end
	return true
end

function M.close(tabpage)
	return close_tab(tabpage, "supported", false)
end

---Queue one close per stable tab handle.
---@param tabpage? integer
---@return boolean
function M.request_close(tabpage)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()
	if not valid_tab(tabpage) or pending_closes[tabpage] then
		return false
	end

	local transient = transient_records[tabpage]
	if transient then
		if not run_transient_preflight(transient, "supported") then
			return false
		end
		if not valid_tab(tabpage) then
			reconcile_transients()
			return true
		end
	end
	pending_closes[tabpage] = { token = transient and transient.token or nil }
	local generation = lifecycle_generation
	options.schedule(function()
		if generation ~= lifecycle_generation then
			return
		end
		pending_closes[tabpage] = nil
		if valid_tab(tabpage) then
			local current = transient_records[tabpage]
			local skip_preflight = transient and current == transient and current.token == transient.token
			close_tab(tabpage, "supported", skip_preflight)
		end
	end)
	return true
end

---Open a path canonically, preferring its exact visible split and then home.
---@param filepath string
---@param opts? { lnum?: integer, col?: integer, record_history?: boolean, history_origin?: table }
---@return table
function M.open(filepath, opts)
	assert(type(filepath) == "string" and filepath ~= "", "filepath must be a non-empty string")
	opts = opts or {}
	local origin
	if opts.record_history ~= false and history_enabled() then
		origin = opts.history_origin ~= nil and vim.deepcopy(opts.history_origin) or M.capture()
	end
	local absolute = vim.fn.fnamemodify(filepath, ":p")
	local target_path = normalized_path(absolute)
	local destination

	local tabpage, win =
		window_for_path(target_path, vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win())
	if win then
		local buf = vim.api.nvim_win_get_buf(win)
		vim.api.nvim_set_current_tabpage(tabpage)
		vim.api.nvim_set_current_win(win)
		set_cursor(win, opts.lnum, opts.col)
		destination = { tabpage = tabpage, winid = win, bufnr = buf, reused = "visible" }
	end

	if not destination then
		local home = M.find_home()
		if home then
			vim.api.nvim_set_current_tabpage(home)
			vim.api.nvim_cmd({ cmd = "edit", args = { absolute } }, {})
			M.unmark_home(home)
			set_cursor(vim.api.nvim_get_current_win(), opts.lnum, opts.col)
			destination = {
				tabpage = home,
				winid = vim.api.nvim_get_current_win(),
				bufnr = vim.api.nvim_get_current_buf(),
				reused = "home",
			}
		else
			vim.api.nvim_cmd({ cmd = "tabedit", args = { absolute } }, {})
			set_cursor(vim.api.nvim_get_current_win(), opts.lnum, opts.col)
			destination = {
				tabpage = vim.api.nvim_get_current_tabpage(),
				winid = vim.api.nvim_get_current_win(),
				bufnr = vim.api.nvim_get_current_buf(),
				reused = false,
			}
		end
	end

	destination.path = target_path
	if origin then
		M.record_transition(origin, M.capture())
	end
	emit("opened", { path = destination.path, reused = destination.reused })
	return destination
end

M.open_file_in_tab = M.open

---Capture the current provider-owned or file-backed editor location.
---@return table?
function M.capture()
	if not history_enabled() then
		return nil
	end
	if type(options.history.capture_location) == "function" then
		local ok, entry, capture_err = pcall(options.history.capture_location)
		if not ok then
			notify_history_callback("capture_location", entry)
			return nil
		elseif entry ~= nil then
			if provider_entry(entry) then
				return vim.deepcopy(entry)
			end
			notify_history_callback("capture_location", "returned an invalid provider entry")
			return nil
		elseif capture_err ~= nil then
			notify_history_callback("capture_location", capture_err)
			return nil
		end
	end
	if M.is_transient(vim.api.nvim_get_current_tabpage()) then
		return nil
	end

	local win = vim.api.nvim_get_current_win()
	if not is_nonfloating_window(win) then
		return nil
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if vim.bo[buf].buftype ~= "" then
		return nil
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	return {
		path = normalized_path(path),
		bufnr = buf,
		winid = win,
		tabpage = vim.api.nvim_get_current_tabpage(),
		lnum = cursor[1],
		col = cursor[2] + 1,
	}
end

---Return whether two captured entries identify the same semantic location.
---@param left table?
---@param right table?
---@return boolean
function M.same_location(left, right)
	return same_location(left, right)
end

---Record one semantic origin/destination transition.
---@param origin table?
---@param destination table?
---@return boolean
function M.record_transition(origin, destination)
	if
		not history_enabled()
		or not history_entry(origin)
		or not history_entry(destination)
		or same_location(origin, destination)
	then
		return false
	end
	trim_forward()
	if history.index > 0 and same_document(history.entries[history.index], origin) then
		history.entries[history.index] = vim.deepcopy(origin)
	else
		append_history(origin)
	end
	if same_location(history.entries[history.index], destination) then
		history.entries[history.index] = vim.deepcopy(destination)
	else
		append_history(destination)
	end
	emit("history", { index = history.index, entries = #history.entries })
	return true
end

---@param opts? { fallback?: boolean, count?: integer }
---@return boolean
function M.back(opts)
	return traverse(-1, opts)
end

---@param opts? { fallback?: boolean, count?: integer }
---@return boolean
function M.forward(opts)
	return traverse(1, opts)
end

---Refresh the current semantic entry before presenting the history.
function M.prepare_history()
	prepare_traversal()
end

---Restore a selected history entry by stable stack index.
---@param index integer
---@return boolean
function M.restore_history(index)
	if type(index) ~= "number" or not history.entries[index] then
		return false
	end
	if restore_history_entry(history.entries[index]) then
		history.index = index
		return true
	end
	return false
end

---@return { entries: table[], index: integer }
function M.history_snapshot()
	return vim.deepcopy(history)
end

function M.history_reset()
	history.entries = {}
	history.index = 0
end

M.snapshot = M.history_snapshot
M.reset = M.history_reset

return M
