local M = {}
local contracts = require("local_plugins.contracts")

local uv = vim.uv
local DEFAULT_STOP_TIMEOUT_MS = 5000
local records = {}
local dependencies
local create
local dispose_record

local SETUP_KEYS = {
	backend = true,
	presenter = true,
	notify = true,
	schedule = true,
	defer = true,
	open_location = true,
	stop_timeout_ms = true,
	buffer_mappings = true,
	on_state_change = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function exact_keys(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains an unknown option: " .. tostring(key)
		end
	end
	return true
end

local function now_ms()
	return math.floor(uv.hrtime() / 1000000)
end

local function non_empty_string(value)
	return type(value) == "string" and value ~= "" and not value:find("\0", 1, true)
end

local function normalize_argv(argv)
	if type(argv) ~= "table" or not vim.islist(argv) or #argv == 0 then
		return nil, "launch.argv must be a non-empty array"
	end
	local normalized = {}
	for index, value in ipairs(argv) do
		if type(value) ~= "string" or value:find("\0", 1, true) or (index == 1 and value == "") then
			local requirement = index == 1 and "a non-empty string without NUL bytes" or "a string without NUL bytes"
			return nil, ("launch.argv[%d] must be %s"):format(index, requirement)
		end
		normalized[index] = value
	end
	return normalized
end

local function normalize_directory(path)
	if not non_empty_string(path) or path:sub(1, 1) ~= "/" then
		return nil, "launch.cwd must be an absolute path"
	end
	local normalized = vim.fs.normalize(path)
	local stat = uv.fs_stat(normalized)
	if not stat or stat.type ~= "directory" then
		return nil, "launch.cwd is not a directory: " .. normalized
	end
	return uv.fs_realpath(normalized) or normalized
end

local function normalize_env(env)
	if type(env) ~= "table" or (next(env) ~= nil and vim.islist(env)) then
		return nil, "launch.env must be an explicit string map (use {} to inherit the host environment)"
	end
	local normalized = vim.empty_dict()
	for name, value in pairs(env) do
		if
			type(name) ~= "string"
			or name == ""
			or name:find("[=%z]")
			or type(value) ~= "string"
			or value:find("\0", 1, true)
		then
			return nil, "launch.env must contain only valid string names and values"
		end
		normalized[name] = value
	end
	return normalized
end

local function normalize_key_list(value, label)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or not vim.islist(value) then
		return nil, label .. " must be an array"
	end
	local normalized = {}
	for index, key in ipairs(value) do
		if not non_empty_string(key) then
			return nil, ("%s[%d] must be a non-empty string without NUL bytes"):format(label, index)
		end
		normalized[index] = key
	end
	return normalized
end

local function normalize_map(value, label)
	if value == nil then
		return vim.empty_dict()
	end
	if type(value) ~= "table" or (next(value) ~= nil and vim.islist(value)) then
		return nil, label .. " must be a map"
	end
	return copy(value)
end

local function normalize(spec)
	local shared, shared_err = contracts.normalize_terminal_spec(spec)
	if not shared then
		return nil, shared_err
	end
	spec = shared
	local argv, argv_err = normalize_argv(spec.launch.argv)
	if not argv then
		return nil, argv_err
	end
	local cwd, cwd_err = normalize_directory(spec.launch.cwd)
	if not cwd then
		return nil, cwd_err
	end
	local env, env_err = normalize_env(spec.launch.env)
	if not env then
		return nil, env_err
	end
	local policy, policy_err = normalize_map(spec.policy, "policy")
	if not policy then
		return nil, policy_err
	end
	if policy.dispose_on_success ~= nil and type(policy.dispose_on_success) ~= "boolean" then
		return nil, "policy.dispose_on_success must be boolean"
	end
	if policy.dispose_on_stop ~= nil and type(policy.dispose_on_stop) ~= "boolean" then
		return nil, "policy.dispose_on_stop must be boolean"
	end
	policy.dispose_on_success = policy.dispose_on_success ~= false
	policy.dispose_on_stop = policy.dispose_on_stop == true

	local view, view_err = normalize_map(spec.view, "view")
	if not view then
		return nil, view_err
	end
	local passthrough, passthrough_err = normalize_key_list(view.passthrough, "view.passthrough")
	if not passthrough then
		return nil, passthrough_err
	end
	local hide_keys, hide_keys_err = normalize_key_list(view.hide_keys, "view.hide_keys")
	if not hide_keys then
		return nil, hide_keys_err
	end
	view.passthrough = passthrough
	view.hide_keys = hide_keys

	local metadata, metadata_err = normalize_map(spec.metadata, "metadata")
	if not metadata then
		return nil, metadata_err
	end

	return {
		key = spec.key,
		launch = { argv = argv, cwd = cwd, env = env },
		policy = policy,
		view = view,
		metadata = metadata,
	}
end

local function key_for(value)
	if non_empty_string(value) then
		return value
	end
	if type(value) == "table" and non_empty_string(value.key) then
		return value.key
	end
	return nil, "terminal identity must be a key string or a table containing key"
end

local function launch_signature(spec)
	local env = {}
	for name, value in pairs(spec.launch.env) do
		env[#env + 1] = { name, value }
	end
	table.sort(env, function(left, right)
		return left[1] < right[1]
	end)
	return vim.json.encode({ spec.launch.argv, spec.launch.cwd, env })
end

local function backend_call(record, method, ...)
	local callback = record.backend[method]
	if type(callback) ~= "function" then
		return nil, "terminal backend does not implement " .. method
	end
	local ok, result, err = pcall(callback, record.handle, ...)
	if not ok then
		return nil, tostring(result)
	end
	if result == nil or result == false then
		return nil, tostring(err or ("terminal backend " .. method .. " failed"))
	end
	return result, err
end

local function backend_value(record, method, fallback)
	local callback = record.backend[method]
	if type(callback) ~= "function" or record.handle == nil then
		return fallback
	end
	local ok, value = pcall(callback, record.handle)
	if not ok or value == nil then
		return fallback
	end
	return value
end

local function active(record)
	return record.state == "starting" or record.state == "running"
end

local function status_snapshot(record, key)
	if not record then
		return {
			key = key,
			state = "disposed",
			exit_code = nil,
			visible = false,
			buf = nil,
			stop_pending = false,
			dispose_pending = false,
			restart_pending = false,
			accepting_input = false,
			stop_timeout_ms = dependencies and dependencies.stop_timeout_ms or DEFAULT_STOP_TIMEOUT_MS,
			stop_timed_out = false,
		}
	end
	local accepting_input = active(record)
		and not record.stop_pending
		and not record.dispose_pending
		and record.restart_pending == nil
		and not record.exit_seen
	return {
		key = record.key,
		state = record.state,
		exit_code = record.exit_code,
		visible = record.visible == true,
		buf = record.buf,
		metadata = copy(record.spec.metadata),
		stop_pending = record.stop_pending,
		dispose_pending = record.dispose_pending,
		restart_pending = record.restart_pending ~= nil,
		accepting_input = accepting_input,
		stop_timeout_ms = record.dependencies.stop_timeout_ms,
		stop_requested_at_ms = record.stop_requested_at_ms,
		stop_deadline_ms = record.stop_deadline_ms,
		stop_timed_out = record.stop_timed_out == true,
	}
end

local function emit_state(record, reason)
	local callback = record and record.dependencies and record.dependencies.on_state_change
	if type(callback) ~= "function" then
		return
	end
	local event = status_snapshot(record, record.key)
	event.kind = "state"
	event.reason = reason
	pcall(callback, copy(event))
end

local function notify(record, message, level)
	local callback = record.dependencies.notify
	if type(callback) == "function" then
		pcall(callback, message, level)
	end
end

local function dispose_visual(record)
	if record.visual_disposed or record.handle == nil then
		return
	end
	record.visual_disposed = true
	record.visible = false
	local callback = record.backend.dispose
	if type(callback) == "function" then
		pcall(callback, record.handle)
	end
end

local function mark_disposed(record, close_visual)
	if record.state == "disposed" then
		if close_visual then
			dispose_visual(record)
		end
		return
	end
	if records[record.key] == record then
		records[record.key] = nil
	end
	record.state = "disposed"
	record.visible = false
	emit_state(record, "disposed")
	if close_visual then
		local schedule = record.dependencies.schedule
		if type(schedule) == "function" then
			schedule(function()
				dispose_visual(record)
			end)
		else
			dispose_visual(record)
		end
	end
end

local function handle_exit(record, exit_code)
	if record.exit_seen then
		return
	end
	record.exit_seen = true
	record.exit_code = tonumber(exit_code) or 0
	local dispose_pending = record.dispose_pending
	local restart_pending = record.restart_pending
	local stop_pending = record.stop_pending
	record.dispose_pending = false
	record.restart_pending = nil
	record.stop_pending = false
	record.stop_requested_at_ms = nil
	record.stop_deadline_ms = nil
	record.stop_timed_out = false
	if dispose_pending then
		mark_disposed(record, true)
		return
	end
	if restart_pending then
		mark_disposed(record, true)
		local replacement, restart_err = create(restart_pending)
		if not replacement then
			notify(record, "Could not restart terminal: " .. tostring(restart_err), vim.log.levels.ERROR)
		end
		return
	end
	if stop_pending then
		if record.spec.policy.dispose_on_stop then
			mark_disposed(record, true)
		else
			record.state = "exited-retained"
			record.visible = true
			emit_state(record, "stopped")
		end
		return
	end
	if record.exit_code == 0 and record.spec.policy.dispose_on_success then
		mark_disposed(record, true)
		return
	end
	record.state = "exited-retained"
	record.visible = true
	emit_state(record, "exited")
	if record.exit_code ~= 0 then
		local title = record.spec.view.title or record.key
		notify(
			record,
			("%s exited with code %d; output was retained"):format(title, record.exit_code),
			vim.log.levels.ERROR
		)
	end
end

local function hide_record(record)
	if record.state == "disposed" or record.handle == nil then
		return nil, "terminal does not exist"
	end
	local hidden, err = backend_call(record, "hide")
	if hidden then
		record.visible = false
		emit_state(record, "hidden")
	end
	return hidden, err
end

local function configure_buffer(record, buf)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	record.buf = buf
	vim.b[buf].terminal_lifecycle = {
		key = record.key,
		ephemeral = true,
		metadata = copy(record.spec.metadata),
	}
	vim.b[buf].terminal_lifecycle_ephemeral = true
	vim.bo[buf].swapfile = false

	local function map(modes, lhs, rhs, desc)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	local mappings = record.dependencies.buffer_mappings
	if mappings.close then
		map("n", mappings.close, function()
			hide_record(record)
		end, "Hide terminal")
	end
	if mappings.open_location and type(record.dependencies.open_location) == "function" then
		map("n", mappings.open_location, function()
			local ok, opened, err = pcall(record.dependencies.open_location, copy(record.spec), buf)
			if not ok or opened ~= true then
				notify(record, tostring(ok and err or opened), vim.log.levels.WARN)
				return
			end
			hide_record(record)
		end, "Open location")
	end
	for _, lhs in ipairs(record.spec.view.passthrough) do
		map("t", lhs, lhs, "Pass terminal key through")
	end
	for _, lhs in ipairs(record.spec.view.hide_keys) do
		map({ "n", "t" }, lhs, function()
			hide_record(record)
		end, "Hide terminal")
	end
	emit_state(record, "buffer")
end

create = function(spec)
	if not dependencies then
		return nil, "terminal_lifecycle.setup(opts) must be called before opening a terminal"
	end
	local record = {
		key = spec.key,
		spec = spec,
		signature = launch_signature(spec),
		state = "starting",
		exit_code = nil,
		backend = dependencies.backend,
		dependencies = dependencies,
		stop_pending = false,
		dispose_pending = false,
		restart_pending = nil,
		exit_seen = false,
		visual_disposed = false,
		visible = false,
		stop_sequence = 0,
		stop_requested_at_ms = nil,
		stop_deadline_ms = nil,
		stop_timed_out = false,
	}
	records[record.key] = record
	emit_state(record, "starting")

	local callbacks = {
		on_buffer = function(buf)
			if record.state ~= "disposed" then
				configure_buffer(record, buf)
			end
		end,
		on_exit = function(exit_code)
			handle_exit(record, exit_code)
		end,
		on_dispose = function()
			if not active(record) then
				mark_disposed(record, false)
				return
			end
			if record.handle == nil then
				record.dispose_pending = true
				return
			end
			local disposed, dispose_err = dispose_record(record)
			if not disposed then
				notify(record, "Could not stop disposed terminal: " .. tostring(dispose_err), vim.log.levels.ERROR)
			end
		end,
	}
	local ok, handle, open_err = pcall(record.backend.open, copy(spec), callbacks)
	if not ok or handle == nil or handle == false then
		mark_disposed(record, false)
		return nil, tostring(ok and open_err or handle)
	end
	record.handle = handle
	record.visible = backend_value(record, "visible", true) == true
	if not record.buf then
		local buf = backend_value(record, "buffer")
		if type(buf) == "number" then
			configure_buffer(record, buf)
		end
	end
	if record.state == "starting" and record.dispose_pending then
		record.dispose_pending = false
		local disposed, dispose_err = dispose_record(record)
		if not disposed then
			notify(record, "Could not stop disposed terminal: " .. tostring(dispose_err), vim.log.levels.ERROR)
		end
	end
	if record.state == "starting" then
		record.state = "running"
		emit_state(record, "running")
	elseif record.state == "disposed" then
		dispose_visual(record)
	end
	return record
end

local function resolve(spec, create_missing)
	local key = key_for(spec)
	local record = key and records[key] or nil
	if record then
		if type(spec) == "table" and spec.launch ~= nil then
			local normalized, normalize_err = normalize(spec)
			if not normalized then
				return nil, normalize_err
			end
			if record.signature ~= launch_signature(normalized) then
				return nil, "terminal launch changed; call restart explicitly"
			end
		end
		return record, nil, false
	end
	if not create_missing then
		return nil, "terminal does not exist"
	end
	local normalized, normalize_err = normalize(spec)
	if not normalized then
		return nil, normalize_err
	end
	local created, create_err = create(normalized)
	return created, create_err, created ~= nil
end

local function show_and_focus(record)
	local shown, show_err = backend_call(record, "show")
	if not shown then
		return nil, show_err
	end
	local focused, focus_err = backend_call(record, "focus")
	if not focused then
		return nil, focus_err
	end
	record.visible = true
	emit_state(record, "shown")
	return record
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local options_ok, options_err = exact_keys(opts, SETUP_KEYS, "setup")
	if not options_ok then
		error(options_err)
	end
	local backend = opts.backend or opts.presenter
	if type(backend) ~= "table" or (next(backend) ~= nil and vim.islist(backend)) then
		error("terminal_lifecycle.setup requires a backend object")
	end
	for _, name in ipairs({ "open", "show", "focus", "hide", "visible", "buffer", "stop", "dispose", "lines" }) do
		if type(backend[name]) ~= "function" then
			error("terminal_lifecycle.setup backend requires " .. name)
		end
	end
	if opts.backend ~= nil and opts.presenter ~= nil and opts.backend ~= opts.presenter then
		error("setup.backend and setup.presenter cannot disagree")
	end
	for _, name in ipairs({ "notify", "schedule", "defer", "open_location", "on_state_change" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error("setup." .. name .. " must be a function")
		end
	end
	local stop_timeout_ms = opts.stop_timeout_ms
	if stop_timeout_ms == nil then
		stop_timeout_ms = DEFAULT_STOP_TIMEOUT_MS
	end
	if type(stop_timeout_ms) ~= "number" or stop_timeout_ms < 0 or stop_timeout_ms % 1 ~= 0 then
		error("setup.stop_timeout_ms must be a non-negative integer")
	end
	local mapping_options = opts.buffer_mappings
	if mapping_options == nil then
		mapping_options = {}
	end
	local mappings_ok, mappings_err =
		exact_keys(mapping_options, { close = true, open_location = true }, "setup.buffer_mappings")
	if not mappings_ok then
		error(mappings_err)
	end
	local mappings = { close = "q", open_location = "gf" }
	for _, name in ipairs({ "close", "open_location" }) do
		local value = mapping_options[name]
		if value ~= nil then
			if value ~= false and not non_empty_string(value) then
				error("setup.buffer_mappings." .. name .. " must be false or a non-empty string")
			end
			mappings[name] = value
		end
	end
	local next_dependencies = {
		backend = backend,
		notify = opts.notify or vim.notify,
		schedule = opts.schedule or vim.schedule,
		defer = opts.defer or vim.defer_fn,
		open_location = opts.open_location,
		stop_timeout_ms = stop_timeout_ms,
		buffer_mappings = mappings,
		on_state_change = opts.on_state_change,
	}
	dependencies = next_dependencies
	return M
end

function M.effective_config()
	if not dependencies then
		return {
			stop_timeout_ms = DEFAULT_STOP_TIMEOUT_MS,
			buffer_mappings = { close = "q", open_location = "gf" },
		}
	end
	return copy({
		stop_timeout_ms = dependencies.stop_timeout_ms,
		buffer_mappings = dependencies.buffer_mappings,
	})
end

function M.open(spec)
	local record, err = resolve(spec, true)
	if not record then
		return nil, err
	end
	if record.state == "disposed" then
		return record
	end
	return show_and_focus(record)
end

function M.toggle(spec)
	local record, err, created = resolve(spec, true)
	if not record then
		return nil, err
	end
	if created or record.state == "disposed" then
		return record
	end
	if backend_value(record, "visible", false) then
		local hidden, hide_err = hide_record(record)
		return hidden and record or nil, hide_err
	end
	return show_and_focus(record)
end

function M.focus(spec)
	local record, err = resolve(spec, true)
	if not record then
		return nil, err
	end
	if record.state == "disposed" then
		return record
	end
	return show_and_focus(record)
end

local function request_stop(record, intent, restart_spec)
	local previous = {
		stop_pending = record.stop_pending,
		dispose_pending = record.dispose_pending,
		restart_pending = record.restart_pending,
	}
	if intent == "dispose" then
		record.dispose_pending = true
		record.restart_pending = nil
	elseif intent == "restart" then
		if record.dispose_pending then
			return nil, "terminal disposal is already pending"
		end
		record.restart_pending = restart_spec
	elseif not record.dispose_pending then
		record.restart_pending = nil
	end
	record.stop_pending = true
	if previous.stop_pending then
		emit_state(record, intent .. "-coalesced")
		return records[record.key] or record
	end
	record.stop_sequence = record.stop_sequence + 1
	local sequence = record.stop_sequence
	record.stop_requested_at_ms = now_ms()
	record.stop_deadline_ms = record.stop_requested_at_ms + record.dependencies.stop_timeout_ms
	record.stop_timed_out = false
	emit_state(record, intent .. "-requested")
	local deferred, defer_err = pcall(record.dependencies.defer, function()
		if
			records[record.key] == record
			and record.stop_pending
			and not record.exit_seen
			and record.stop_sequence == sequence
		then
			record.stop_timed_out = true
			emit_state(record, "stop-timeout")
		end
	end, record.dependencies.stop_timeout_ms)
	if not deferred then
		notify(record, "Could not observe terminal stop timeout: " .. tostring(defer_err), vim.log.levels.WARN)
	end
	local stopped, stop_err = backend_call(record, "stop")
	if stopped or record.exit_seen then
		return records[record.key] or record
	end
	record.stop_pending = previous.stop_pending
	record.dispose_pending = previous.dispose_pending
	record.restart_pending = previous.restart_pending
	record.stop_requested_at_ms = nil
	record.stop_deadline_ms = nil
	record.stop_timed_out = false
	emit_state(record, "stop-request-failed")
	return nil, stop_err
end

local function stop_record(record)
	if record.state == "disposed" then
		return nil, "terminal does not exist"
	end
	if record.state == "exited-retained" then
		return record
	end
	return request_stop(record, "stop")
end

dispose_record = function(record)
	if record.state == "disposed" then
		return nil, "terminal does not exist"
	end
	if record.state == "exited-retained" then
		mark_disposed(record, true)
		return record
	end
	return request_stop(record, "dispose")
end

function M.restart(spec)
	local normalized, err = normalize(spec)
	if not normalized then
		return nil, err
	end
	local record = records[normalized.key]
	if record then
		if record.state == "exited-retained" then
			mark_disposed(record, true)
			return create(normalized)
		end
		return request_stop(record, "restart", normalized)
	end
	return create(normalized)
end

function M.stop(identity)
	local key, key_err = key_for(identity)
	if not key then
		return nil, key_err
	end
	local record = records[key]
	if not record then
		return nil, "terminal does not exist"
	end
	return stop_record(record)
end

function M.dispose(identity)
	local key, key_err = key_for(identity)
	if not key then
		return nil, key_err
	end
	local record = records[key]
	if not record then
		return nil, "terminal does not exist"
	end
	return dispose_record(record)
end

function M.status(identity)
	if identity == nil then
		local keys = vim.tbl_keys(records)
		table.sort(keys)
		local terminals = {}
		for _, key in ipairs(keys) do
			terminals[#terminals + 1] = status_snapshot(records[key], key)
		end
		return copy({ configured = dependencies ~= nil, terminals = terminals })
	end
	local key, key_err = key_for(identity)
	if not key then
		return nil, key_err
	end
	return copy(status_snapshot(records[key], key))
end

function M.list()
	local keys = vim.tbl_keys(records)
	table.sort(keys)
	local result = {}
	for _, key in ipairs(keys) do
		result[#result + 1] = status_snapshot(records[key], key)
	end
	return copy(result)
end

local function filter_matches(filter, status)
	if filter == nil then
		return true
	end
	if type(filter) == "function" then
		local ok, matched = pcall(filter, copy(status))
		return ok and matched == true
	end
	if type(filter) ~= "table" or vim.islist(filter) then
		return nil, "dispose filter must be a function or map"
	end
	local ok, err = exact_keys(filter, { key = true, state = true, metadata = true }, "dispose filter")
	if not ok then
		return nil, err
	end
	if filter.key ~= nil and filter.key ~= status.key then
		return false
	end
	if filter.state ~= nil and filter.state ~= status.state then
		return false
	end
	if filter.metadata ~= nil then
		if type(filter.metadata) ~= "table" or vim.islist(filter.metadata) then
			return nil, "dispose filter.metadata must be a map"
		end
		for key, value in pairs(filter.metadata) do
			if not vim.deep_equal(value, (status.metadata or {})[key]) then
				return false
			end
		end
	end
	return true
end

function M.dispose_all(filter)
	local selected = {}
	for _, status in ipairs(M.list()) do
		local matched, match_err = filter_matches(filter, status)
		if matched == nil then
			return nil, match_err
		end
		if matched then
			selected[#selected + 1] = status.key
		end
	end
	local result = {}
	for _, key in ipairs(selected) do
		local disposed, dispose_err = M.dispose(key)
		if not disposed then
			return nil, dispose_err, copy(result)
		end
		result[#result + 1] = M.status(key)
	end
	return copy(result)
end

function M.teardown(filter)
	local disposed, err, partial = M.dispose_all(filter)
	if not disposed then
		return nil, err, partial
	end
	dependencies = nil
	return true, disposed
end

function M.lines(identity)
	local key, key_err = key_for(identity)
	if not key then
		return nil, key_err
	end
	local record = records[key]
	if not record or record.state == "disposed" then
		return nil, "terminal does not exist"
	end
	return backend_call(record, "lines")
end

M._normalize = normalize
M._reset = function()
	local active = records
	records = {}
	for _, record in pairs(active) do
		record.state = "disposed"
		dispose_visual(record)
	end
	dependencies = nil
end

return M
