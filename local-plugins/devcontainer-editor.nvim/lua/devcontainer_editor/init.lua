-- Editor callbacks and a bounded bridge to the Python lifecycle/transport owner.
local M = {}
local contracts = require("local_plugins.contracts")

local uv = vim.uv
local configured = {}
local is_configured = false
local watcher
local watcher_failures = 0
local watcher_generation = 0
local transport_generation = 0
local transport_status = {
	generation = 0,
	state = "idle",
	processed = 0,
	succeeded = 0,
	failed = 0,
	remaining = 0,
	records = {},
}

local MAX_MESSAGE = 64 * 1024
local MAX_WARNING = 512
local DEFAULT_ACK_TIMEOUT_MS = 5000
local DEFAULT_MAX_MESSAGES_PER_TICK = 32
local DEFAULT_POLL_INTERVAL_MS = 100

local function public_defaults()
	return {
		ack_timeout_ms = DEFAULT_ACK_TIMEOUT_MS,
		claim_timeout_ms = 2000,
		docker_path = "docker",
		lockfile_policy = "preserve",
		max_messages_per_tick = DEFAULT_MAX_MESSAGES_PER_TICK,
		poll_interval_ms = DEFAULT_POLL_INTERVAL_MS,
		ssh_agent = "auto",
		watch = true,
	}
end

local SETUP_KEYS = {
	ack_timeout_ms = true,
	claim_timeout_ms = true,
	docker_path = true,
	event = true,
	launcher = true,
	lockfile_policy = true,
	max_messages_per_tick = true,
	notify = true,
	open = true,
	poll_interval_ms = true,
	resolve_cli = true,
	spool_root = true,
	ssh_agent = true,
	state_root = true,
	uuid = true,
	watch = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function reject_unknown(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains unknown key: " .. tostring(key)
		end
	end
	return true
end

local function positive_integer(value, label)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		return nil, label .. " must be a positive integer"
	end
	return value
end

local function emit(kind, details)
	if type(configured.event) ~= "function" then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	pcall(configured.event, event)
end

local function publish_transport(state, fields)
	transport_generation = transport_generation + 1
	transport_status = vim.tbl_extend("force", {
		generation = transport_generation,
		state = state,
		processed = 0,
		succeeded = 0,
		failed = 0,
		remaining = 0,
		records = {},
	}, copy(fields or {}))
	emit("transport", { status = transport_status })
	return copy(transport_status)
end

local function bounded_warning(value, maximum)
	local detail = tostring(value):gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if #detail > maximum then
		detail = detail:sub(1, math.max(maximum - 3, 0)) .. "..."
	end
	return detail
end

local function validate_setup(opts)
	local known, known_err = reject_unknown(opts, SETUP_KEYS, "devcontainer_editor setup")
	if not known then
		return nil, known_err
	end
	local candidate = copy(opts)
	for field, fallback in pairs({
		docker_path = "docker",
		lockfile_policy = "preserve",
		ssh_agent = "auto",
		claim_timeout_ms = 2000,
		ack_timeout_ms = DEFAULT_ACK_TIMEOUT_MS,
		max_messages_per_tick = DEFAULT_MAX_MESSAGES_PER_TICK,
		poll_interval_ms = DEFAULT_POLL_INTERVAL_MS,
	}) do
		if candidate[field] == nil then
			candidate[field] = fallback
		end
	end
	for _, field in ipairs({
		"claim_timeout_ms",
		"ack_timeout_ms",
		"max_messages_per_tick",
		"poll_interval_ms",
	}) do
		local _, value_err = positive_integer(candidate[field], "devcontainer_editor " .. field)
		if value_err then
			return nil, value_err
		end
	end
	if type(candidate.docker_path) ~= "string" or candidate.docker_path == "" or candidate.docker_path:find("%z") then
		return nil, "devcontainer_editor docker_path must be a non-empty string"
	end
	if candidate.lockfile_policy ~= "preserve" then
		return nil, "devcontainer_editor lockfile_policy must be preserve"
	end
	if candidate.ssh_agent ~= "auto" and candidate.ssh_agent ~= "off" then
		return nil, "devcontainer_editor ssh_agent must be auto or off"
	end
	if
		candidate.launcher ~= nil
		and (type(candidate.launcher) ~= "string" or candidate.launcher == "" or candidate.launcher:find("\0", 1, true))
	then
		return nil, "devcontainer_editor launcher must be a non-empty string without NUL bytes"
	end
	for _, field in ipairs({ "event", "notify", "open", "resolve_cli", "uuid" }) do
		if candidate[field] ~= nil and type(candidate[field]) ~= "function" then
			return nil, "devcontainer_editor " .. field .. " must be a function"
		end
	end
	for _, field in ipairs({ "spool_root", "state_root" }) do
		local value = candidate[field]
		if value ~= nil and type(value) ~= "string" and type(value) ~= "function" then
			return nil, "devcontainer_editor " .. field .. " must be a string or function"
		end
		if type(value) == "string" and (value == "" or value:find("\0", 1, true)) then
			return nil, "devcontainer_editor " .. field .. " must be non-empty and without NUL bytes"
		end
	end
	if candidate.watch ~= nil and type(candidate.watch) ~= "boolean" then
		return nil, "devcontainer_editor watch must be boolean"
	end
	return candidate
end

function M.workspace_key(value)
	local workspace, workspace_err = contracts.normalize_workspace_key(value)
	if not workspace then
		return nil, workspace_err
	end
	if workspace.root:sub(1, 2) == "//" then
		return nil, "workspace root must be absolute"
	end
	local root = vim.fs.normalize(workspace.root)
	if root ~= workspace.root then
		return nil, "workspace root must be lexically canonical"
	end
	return { runtime = workspace.runtime, root = root, repo_identity = workspace.repo_identity }
end

function M.in_workspace()
	return vim.env.NVIM_DEVCONTAINER == "1"
end

function M.network_authorized()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end

local function valid_id(value)
	if type(value) ~= "string" or #value ~= 36 or value:lower() ~= value then
		return false
	end
	if value:sub(9, 9) ~= "-" or value:sub(14, 14) ~= "-" or value:sub(19, 19) ~= "-" or value:sub(24, 24) ~= "-" then
		return false
	end
	if value:sub(15, 15) ~= "4" or not value:sub(20, 20):match("[89ab]") then
		return false
	end
	return value:gsub("%-", ""):match("^[0-9a-f]+$") ~= nil
end

local bridge
local bridge_failure
local correlation = 0
local MAX_PENDING = 128

local function report_error(deps, message)
	local report = (deps or {}).notify or configured.notify
	if report then
		pcall(report, message, vim.log.levels.ERROR)
	end
end

local function fail_bridge(current, message)
	if bridge ~= current then
		return
	end
	bridge = nil
	bridge_failure = message
	for _, pending in pairs(current.pending) do
		pending.error, pending.done = message, true
	end
	for _, callback in pairs(current.host) do
		callback(nil, message)
	end
	current.host = {}
	if current.job then
		vim.fn.jobstop(current.job)
	end
end

local function bridge_message(current, line)
	local ok, value = pcall(vim.json.decode, line)
	if
		not ok
		or type(value) ~= "table"
		or type(value.id) ~= "number"
		or value.id < 1
		or value.id % 1 ~= 0
		or (value.event ~= nil and value.event ~= "host_result")
		or (value.result ~= nil) == (value.error ~= nil)
		or (value.error ~= nil and type(value.error) ~= "string")
	then
		fail_bridge(current, "Dev Container bridge returned an invalid response")
		return
	end
	if value.event == "host_result" then
		local callback = current.host[value.id]
		current.host[value.id] = nil
		if not callback then
			fail_bridge(current, "Dev Container bridge returned an unknown host correlation")
			return
		end
		local called, callback_err = pcall(callback, value.result, value.error)
		if not called then
			report_error(nil, "Dev Container host callback failed: " .. tostring(callback_err))
		end
	elseif current.pending[value.id] then
		local pending = current.pending[value.id]
		pending.result, pending.error, pending.done = value.result, value.error, true
	else
		fail_bridge(current, "Dev Container bridge returned an unknown correlation")
	end
end

local function bridge_output(current, data)
	if bridge ~= current then
		return
	end
	current.input = current.input .. table.concat(data, "\n")
	while bridge == current do
		local newline = current.input:find("\n", 1, true)
		if not newline then
			break
		end
		if newline > MAX_MESSAGE then
			break
		end
		local line = current.input:sub(1, newline - 1)
		current.input = current.input:sub(newline + 1)
		bridge_message(current, line)
	end
	if #current.input >= MAX_MESSAGE then
		fail_bridge(current, "Dev Container bridge response exceeds 64 KiB")
	end
end

local function configured_path(name)
	local value = configured[name]
	if type(value) == "function" then
		local ok, result = pcall(value)
		if not ok then
			return nil, name .. " callback failed: " .. tostring(result)
		end
		value = result
	end
	if value ~= nil and (type(value) ~= "string" or value == "" or value:find("%z")) then
		return nil, name .. " must resolve to a non-empty string without NUL bytes"
	end
	return value
end

local function start_bridge()
	if bridge then
		return bridge
	end
	if bridge_failure then
		return nil, bridge_failure
	end
	local python = vim.fn.exepath("python3")
	if python == "" then
		return nil, "Dev Container requires Python 3 on the host and inside the container"
	end
	if not configured.launcher then
		return nil, "devcontainer launcher is not configured"
	end
	local environment = vim.empty_dict()
	for option, variable in pairs({
		state_root = "NVIM_DEVCONTAINER_STATE_HOME",
		spool_root = "NVIM_DEVCONTAINER_SPOOL_ROOT",
	}) do
		local value, err = configured_path(option)
		if err then
			return nil, err
		end
		environment[variable] = value
	end
	local current = { pending = {}, host = {}, input = "", diagnostic = "" }
	bridge = current
	local ok, job = pcall(vim.fn.jobstart, {
		python,
		"-I",
		"-S",
		configured.launcher,
		"bridge",
		"--ack-timeout-ms",
		string.format("%.0f", configured.ack_timeout_ms),
		"--max-messages-per-tick",
		string.format("%.0f", configured.max_messages_per_tick),
	}, {
		env = environment,
		on_stdout = function(_, data)
			bridge_output(current, data)
		end,
		on_stderr = function(_, data)
			current.diagnostic = (current.diagnostic .. table.concat(data, "\n")):sub(-4096)
			local warning = vim.trim(table.concat(data, "\n"))
			if warning ~= "" and configured.notify then
				pcall(configured.notify, bounded_warning(warning, MAX_WARNING), vim.log.levels.WARN)
			end
		end,
		on_exit = function(_, code)
			fail_bridge(current, "Dev Container bridge exited (" .. code .. "): " .. vim.trim(current.diagnostic))
		end,
	})
	if not ok or job <= 0 then
		fail_bridge(current, "could not start Dev Container Python bridge: " .. tostring(job))
		return nil, bridge_failure
	end
	current.job = job
	return current
end

local function bridge_call(method, params, on_host_result)
	local current, start_err = start_bridge()
	if not current then
		return nil, start_err
	end
	if vim.tbl_count(current.pending) + vim.tbl_count(current.host) >= MAX_PENDING then
		return nil, "too many pending Dev Container bridge calls"
	end
	correlation = correlation + 1
	local id = correlation
	local pending = {}
	local payload = vim.json.encode({ id = id, method = method, params = params or vim.empty_dict() }) .. "\n"
	if #payload > MAX_MESSAGE then
		return nil, "Dev Container bridge request exceeds 64 KiB"
	end
	current.pending[id], current.host[id] = pending, on_host_result
	local sent, send_err = pcall(vim.fn.chansend, current.job, payload)
	if not sent or send_err == 0 then
		fail_bridge(current, "Dev Container bridge pipe failed: " .. tostring(send_err))
	end
	if
		not pending.done
		and not vim.wait(configured.ack_timeout_ms, function()
			return pending.done == true
		end, 10, false)
	then
		fail_bridge(current, "Dev Container bridge timed out; pending actions will not be replayed")
	end
	current.pending[id] = nil
	if pending.error then
		current.host[id] = nil
		return nil, pending.error
	end
	return pending.result
end

local function supplied_uuid()
	if not configured.uuid then
		return vim.NIL
	end
	local ok, value = pcall(configured.uuid)
	return ok and value or nil, not ok and tostring(value) or nil
end

function M.new_claim_id()
	local value, err = supplied_uuid()
	if value == nil then
		return nil, err or "UUID provider did not return an id"
	end
	return bridge_call("new_claim_id", { request_id = value })
end

function M.route(path, from_root, to_root, kind)
	return bridge_call("route", { path = path, from_root = from_root, to_root = to_root, kind = kind or vim.NIL })
end

function M.status(host_root)
	if host_root ~= nil then
		return bridge_call("status", { root = host_root })
	end
	return copy({
		configured = is_configured,
		transport = transport_status,
		watcher = { active = watcher ~= nil, failures = watcher_failures },
		bridge = { active = bridge ~= nil, error = bridge_failure },
	})
end

function M.log_path(host_root)
	return bridge_call("log_path", { root = host_root })
end

local function cursor_column(line, column)
	column = math.min(column, #line)
	while column > 0 do
		local byte = line:byte(column + 1)
		if not byte or byte < 128 or byte > 191 then
			break
		end
		column = column - 1
	end
	return column
end

local function confirm_open(record)
	local opened, result = pcall(configured.open or error, record.path, { lnum = record.line, col = record.column })
	local row = math.min(record.line, vim.api.nvim_buf_line_count(0))
	local text = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
	local column = cursor_column(text, record.column - 1)
	local position = vim.api.nvim_win_get_cursor(0)
	local at_column = position[2] == column
		or (column == #text and position[2] == cursor_column(text, math.max(#text - 1, 0)))
	local confirmed = opened
		and result ~= false
		and vim.api.nvim_buf_get_name(0) == record.path
		and position[1] == row
		and at_column
	local message = opened and "editor did not confirm opening the requested location" or tostring(result)
	return bridge_call("complete_open", {
		request_id = record.request_id,
		ok = confirmed,
		error = confirmed and vim.NIL or bounded_warning(message, MAX_WARNING),
	})
end

function M.consume_spool_once()
	local batch, err = bridge_call("poll")
	if not batch then
		return nil, err, publish_transport("error", { error = err })
	end
	local records, first_error, succeeded = {}, nil, 0
	for _, record in ipairs(batch.records) do
		local ok, failure
		if record.error then
			failure = record.error
		else
			ok, failure = confirm_open(record)
		end
		first_error = first_error or failure
		succeeded = succeeded + (ok and 1 or 0)
		records[#records + 1] = { name = record.name, ok = ok == true, error = failure }
	end
	local report = publish_transport(first_error and "partial" or (batch.remaining > 0 and "backlog" or "idle"), {
		processed = #records,
		succeeded = succeeded,
		failed = #records - succeeded,
		remaining = batch.remaining,
		records = records,
		error = first_error,
	})
	return not first_error and #records or nil, first_error, report
end

function M.request_host(action, dependencies, on_success)
	if type(dependencies) == "function" and on_success == nil then
		on_success, dependencies = dependencies, nil
	end
	if on_success ~= nil and type(on_success) ~= "function" then
		return nil, "host success callback must be a function"
	end
	local supplied, uuid_err = supplied_uuid()
	if supplied == nil then
		return nil, uuid_err or "UUID provider did not return an id"
	end
	local request_id, err = bridge_call("request_host", {
		action = action,
		request_id = supplied,
		timeout_ms = (dependencies or {}).ack_timeout_ms or configured.ack_timeout_ms,
	}, function(value, failure)
		if failure then
			report_error(dependencies, failure)
		elseif on_success then
			on_success(value)
		end
	end)
	return request_id and true or nil, request_id or err
end

function M.resolve_runtime()
	if type(configured.resolve_cli) ~= "function" then
		return nil, "certified Dev Containers CLI resolver is not configured"
	end
	local called, selected, resolve_err = pcall(configured.resolve_cli)
	if not called then
		return nil, "certified Dev Containers CLI resolution failed: " .. tostring(selected)
	end
	if selected == nil then
		return nil, tostring(resolve_err or "no certified Dev Containers CLI is active")
	end
	return bridge_call("runtime", { cli_path = selected, docker_path = configured.docker_path })
end

function M.lifecycle_argv(action, spec)
	if
		action ~= "up"
		and action ~= "restart-dead"
		and action ~= "status"
		and action ~= "log"
		and action ~= "host"
		and action ~= "doctor"
	then
		return nil, "unsupported lifecycle action"
	end
	local launcher = configured.launcher
	if type(launcher) ~= "string" or launcher == "" then
		return nil, "devcontainer launcher is not configured"
	end
	local argv = { launcher, action }
	if type(spec) == "table" and spec.root then
		vim.list_extend(argv, { "--repo", spec.root })
	end
	if action == "up" or action == "doctor" then
		local runtime
		local runtime_err
		if type(spec) == "table" and (spec.cli_path ~= nil or spec.docker_path ~= nil) then
			runtime, runtime_err = bridge_call("runtime", {
				cli_path = spec.cli_path,
				docker_path = spec.docker_path,
			})
		else
			runtime, runtime_err = M.resolve_runtime()
		end
		if not runtime then
			return nil, runtime_err
		end
		vim.list_extend(argv, { "--cli-path", runtime.cli_path, "--docker-path", runtime.docker_path })
		vim.list_extend(argv, { "--lockfile-policy", configured.lockfile_policy or "preserve" })
		vim.list_extend(argv, { "--ssh-agent", configured.ssh_agent or "auto" })
		if action == "doctor" and type(spec) == "table" and spec.config then
			vim.list_extend(argv, { "--config", spec.config })
		end
	end
	if (action == "up" or action == "restart-dead") and type(spec) == "table" then
		if type(spec.tmux_pane) ~= "string" or not spec.tmux_pane:match("^%%%d+$") then
			return nil, "Dev Container lifecycle requires one explicit tmux pane"
		end
		if not valid_id(spec.claim_id) then
			return nil, "Dev Container lifecycle requires one canonical claim id"
		end
		vim.list_extend(argv, { "--tmux-pane", spec.tmux_pane })
		vim.list_extend(argv, { "--claim-id", spec.claim_id })
		if spec.config then
			vim.list_extend(argv, { "--config", spec.config })
		end
		if spec.recreate then
			argv[#argv + 1] = "--recreate"
		end
		if action == "up" and spec.allow_network then
			argv[#argv + 1] = "--allow-network"
		end
	elseif action == "up" or action == "restart-dead" then
		return nil, "Dev Container lifecycle requires one explicit tmux pane"
	elseif action == "host" and type(spec) == "table" and spec.tmux_pane ~= nil then
		if type(spec.tmux_pane) ~= "string" or not spec.tmux_pane:match("^%%%d+$") then
			return nil, "Dev Container host recovery requires one explicit tmux pane"
		end
		vim.list_extend(argv, { "--tmux-pane", spec.tmux_pane })
	end
	return argv
end

function M.stop()
	if not is_configured and not watcher and not bridge then
		return M
	end
	watcher_generation = watcher_generation + 1
	if watcher then
		local current = watcher
		watcher = nil
		current:stop()
		current:close()
	end
	if bridge then
		fail_bridge(bridge, "Dev Container bridge stopped; pending actions will not be replayed")
	end
	publish_transport("stopped")
	emit("stopped")
	return M
end

local function schedule_watch(delay, expected, generation)
	expected = expected or watcher
	generation = generation or watcher_generation
	if not expected or watcher ~= expected or watcher_generation ~= generation then
		return
	end
	expected:start(
		delay,
		0,
		vim.schedule_wrap(function()
			if watcher ~= expected or watcher_generation ~= generation then
				return
			end
			local ok, err, report = M.consume_spool_once()
			if ok == nil then
				watcher_failures = math.min(watcher_failures + 1, 5)
				if type(configured.notify) == "function" then
					configured.notify(err, vim.log.levels.ERROR)
				end
			else
				watcher_failures = 0
			end
			local next_delay = configured.poll_interval_ms
			if report and report.remaining > 0 then
				next_delay = 0
			elseif watcher_failures > 0 then
				next_delay = math.min(configured.poll_interval_ms * (2 ^ watcher_failures), 2000)
			end
			schedule_watch(next_delay, expected, generation)
		end)
	)
end

function M.effective_config()
	if not is_configured then
		return public_defaults()
	end
	return copy({
		ack_timeout_ms = configured.ack_timeout_ms,
		claim_timeout_ms = configured.claim_timeout_ms,
		docker_path = configured.docker_path,
		lockfile_policy = configured.lockfile_policy,
		max_messages_per_tick = configured.max_messages_per_tick,
		poll_interval_ms = configured.poll_interval_ms,
		ssh_agent = configured.ssh_agent,
		watch = configured.watch ~= false,
	})
end

function M.transport_status()
	return copy(transport_status)
end

function M.reconnect()
	-- Explicit commands can begin fresh calls after failure; queued actions are gone.
	bridge_failure = nil
	return M
end

function M.teardown()
	if not is_configured then
		return M
	end
	M.stop()
	emit("teardown")
	configured = {}
	is_configured = false
	watcher_failures = 0
	return M
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local candidate, candidate_err = validate_setup(opts)
	if not candidate then
		error(candidate_err)
	end
	if is_configured then
		M.teardown()
	end
	bridge_failure = nil
	configured = candidate
	is_configured = true
	watcher_failures = 0
	publish_transport("idle")
	emit("setup", { config = M.effective_config() })
	if M.in_workspace() and configured.watch ~= false then
		watcher_generation = watcher_generation + 1
		watcher = uv.new_timer()
		schedule_watch(0, watcher, watcher_generation)
	end
	return M
end

return M
