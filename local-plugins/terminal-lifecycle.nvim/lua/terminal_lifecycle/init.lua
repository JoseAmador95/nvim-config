local M = {}
local contracts = require("local_plugins.contracts")

local uv = vim.uv
local records = {}
local dependencies
local create
local dispose_record

local function copy(value)
	return vim.deepcopy(value)
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
		end
		return
	end
	if record.exit_code == 0 and record.spec.policy.dispose_on_success then
		mark_disposed(record, true)
		return
	end
	record.state = "exited-retained"
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
	return backend_call(record, "hide")
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
	map("n", "q", function()
		hide_record(record)
	end, "Hide terminal")
	if type(record.dependencies.open_location) == "function" then
		map("n", "gf", function()
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
end

local function active(record)
	return record.state == "starting" or record.state == "running"
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
	}
	records[record.key] = record

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
	return record
end

function M.setup(opts)
	opts = opts or {}
	local backend = opts.backend or opts.presenter
	if type(backend) ~= "table" or type(backend.open) ~= "function" then
		error("terminal_lifecycle.setup requires a backend with open(spec, callbacks)")
	end
	dependencies = {
		backend = backend,
		notify = opts.notify or vim.notify,
		schedule = opts.schedule or vim.schedule,
		open_location = opts.open_location,
	}
	return M
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
		return records[record.key] or record
	end
	local stopped, stop_err = backend_call(record, "stop")
	if stopped or record.exit_seen then
		return records[record.key] or record
	end
	record.stop_pending = previous.stop_pending
	record.dispose_pending = previous.dispose_pending
	record.restart_pending = previous.restart_pending
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
	local key, key_err = key_for(identity)
	if not key then
		return nil, key_err
	end
	local record = records[key]
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
		}
	end
	local accepting_input = active(record)
		and not record.stop_pending
		and not record.dispose_pending
		and record.restart_pending == nil
		and not record.exit_seen
	return {
		key = key,
		state = record.state,
		exit_code = record.exit_code,
		visible = backend_value(record, "visible", false) == true,
		buf = record.buf or backend_value(record, "buffer"),
		metadata = copy(record.spec.metadata),
		stop_pending = record.stop_pending,
		dispose_pending = record.dispose_pending,
		restart_pending = record.restart_pending ~= nil,
		accepting_input = accepting_input,
	}
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
end

return M
