-- Host policy adapter for devcontainer-editor.nvim. Lifecycle and transport
-- validation live in the local plugin; commands, tmux, and UI stay here.
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.devcontainer source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))

local M = {}
local uv = vim.uv
local deferred = require("config.deferred")
local core
local core_configured = false
local policy = require("config.local_config").host_plugin("devcontainer_editor", {
	docker_path = "docker",
	lockfile_policy = "preserve",
	ssh_agent = "auto",
	claim_timeout_ms = 2000,
	ack_timeout_ms = 5000,
	max_messages_per_tick = 32,
	ui = {
		progress = true,
		progress_interval_ms = 500,
		log_width = 72,
		auto_open_log_on_error = true,
	},
})
local launcher = vim.fs.joinpath(config_root, "scripts", "devcontainer-editor")

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local PHASE_LABELS = {
	claimed = "Lifecycle claimed",
	["preparing-config"] = "Preparing configuration",
	["starting-container"] = "Building or starting container",
	["checking-ssh-agent"] = "Checking SSH agent",
	["checking-editor-config"] = "Checking editor configuration",
	["opening-editor"] = "Opening container editor",
	["monitoring-editor"] = "Monitoring container editor",
	["returning-host"] = "Returning to host editor",
}
local READ_ERROR_GRACE_MS = 5000
local RESTARTABLE_RECORD_VERSIONS = { [4] = true, [5] = true, [6] = true }
local progress_generation = 0
local active_progress

local function default_visual_notify(message, level, options)
	local snacks = rawget(_G, "Snacks")
	local notifier = type(snacks) == "table" and snacks.notifier or nil
	if type(notifier) ~= "table" or type(notifier.notify) ~= "function" then
		return false
	end
	return pcall(notifier.notify, message, level, options)
end

local function default_visual_hide(id)
	local snacks = rawget(_G, "Snacks")
	local notifier = type(snacks) == "table" and snacks.notifier or nil
	if type(notifier) ~= "table" or type(notifier.hide) ~= "function" then
		return false
	end
	return pcall(notifier.hide, id)
end

local default_dependencies = {
	visual_notify = default_visual_notify,
	visual_hide = default_visual_hide,
	redraw = function()
		return pcall(vim.cmd, "redraw")
	end,
	now_ms = function()
		return uv.hrtime() / 1000000
	end,
	new_timer = function()
		return uv.new_timer()
	end,
	schedule = vim.schedule,
	kill = uv.kill,
}
local dependencies = vim.tbl_extend("force", {}, default_dependencies)

local function within(parent, path)
	return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function state_root()
	local configured = vim.env.NVIM_DEVCONTAINER_STATE_HOME
	if configured and configured ~= "" then
		configured = vim.fs.normalize(vim.fn.fnamemodify(configured, ":p"))
	else
		local state = vim.env.XDG_STATE_HOME or (vim.env.HOME and vim.fs.joinpath(vim.env.HOME, ".local", "state"))
		configured = state and vim.fs.joinpath(state, "nvim-devcontainer") or nil
		configured = configured and vim.fs.normalize(vim.fn.fnamemodify(configured, ":p")) or nil
	end
	if not configured then
		return nil
	end
	local home = vim.env.HOME and vim.fs.normalize(vim.fn.fnamemodify(vim.env.HOME, ":p")) or nil
	local temporary = uv.os_tmpdir and vim.fs.normalize(uv.os_tmpdir()) or nil
	if (home and within(home, configured)) or (temporary and within(temporary, configured)) then
		return configured
	end
	return nil
end

local function notify(message, level, options)
	vim.notify(
		message,
		level or vim.log.levels.INFO,
		vim.tbl_extend("force", { title = "Dev Container" }, options or {})
	)
end

local function root()
	return require("config.repo").current_root(0) or uv.cwd()
end

local function resolve_cli()
	local loaded, bootstrap = deferred.try("config.tool_bootstrap")
	if not loaded then
		return nil, "could not load certified tools: " .. tostring(bootstrap)
	end
	return bootstrap.resolve("devcontainers-cli", "devcontainer")
end

local function options()
	return {
		state_root = state_root,
		launcher = launcher,
		docker_path = policy.docker_path,
		resolve_cli = resolve_cli,
		lockfile_policy = policy.lockfile_policy,
		ssh_agent = policy.ssh_agent,
		claim_timeout_ms = policy.claim_timeout_ms,
		ack_timeout_ms = policy.ack_timeout_ms,
		max_messages_per_tick = policy.max_messages_per_tick,
		open = require("config.editor").open_file_in_tab,
		notify = notify,
	}
end

local function ensure_core()
	if core_configured and core then
		return core
	end
	local candidate = core
	if not candidate then
		local loaded, result = deferred.try("devcontainer_editor")
		if not loaded then
			return nil, tostring(result)
		end
		candidate = result
	end
	local ok, result = pcall(candidate.setup, options())
	if not ok then
		core = nil
		return nil, tostring(result)
	end
	core = candidate
	core_configured = true
	return core
end

function M.in_workspace()
	return vim.env.NVIM_DEVCONTAINER == "1"
end

function M.network_authorized()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end

function M.request_host(action, dependencies, on_success)
	local instance, err = ensure_core()
	return instance and instance.request_host(action, dependencies, on_success) or nil, err
end

local function exact_pane()
	local pane = vim.env.TMUX_PANE
	if type(pane) ~= "string" or not pane:match("^%%%d+$") then
		return nil, "DevContainerUp requires tmux's single-pane editor window"
	end
	local ok, process = pcall(
		vim.system,
		{ "tmux", "display-message", "-p", "-t", pane, "#{window_name}\t#{window_panes}\t#{pane_dead}" },
		{ text = true }
	)
	if not ok then
		return nil, "could not inspect tmux editor pane: " .. tostring(process)
	end
	local result = process:wait()
	if result.code ~= 0 or vim.trim(result.stdout or "") ~= "editor\t1\t0" then
		return nil, "DevContainerUp requires tmux's single-pane editor window"
	end
	return pane
end

local function read_workspace_status(instance, project_root)
	local called, status, status_err = pcall(instance.status, project_root)
	if not called then
		return nil, tostring(status)
	end
	return status, status_err
end

local function wait_for_claim(project_root, claim_id, timeout_ms)
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local failure
	local last_error
	local observed
	local ready = vim.wait(timeout_ms or policy.claim_timeout_ms, function()
		local status, status_err = read_workspace_status(instance, project_root)
		if not status then
			last_error = status_err
			return false
		end
		if status.claim_id ~= claim_id then
			last_error = "another lifecycle record still owns the workspace"
			return false
		end
		if status.status == "starting" or status.status == "running" then
			observed = vim.deepcopy(status)
			return true
		end
		observed = vim.deepcopy(status)
		failure = type(status.error) == "string" and status.error ~= "" and status.error
			or "detached coordinator entered " .. tostring(status.status)
		return true
	end, 20, false)
	if failure then
		return nil, failure, observed
	end
	if not ready then
		return nil, "detached coordinator did not publish its starting claim: " .. tostring(last_error or "timeout")
	end
	return observed
end

local result_message

local function existing_lifecycle_message(status, recreate)
	local requested_command = recreate and ":DevContainerRecreate" or ":DevContainerUp"
	if status == "error" or status == "stopped" then
		return (
			"Dev Container lifecycle is %s; run :DevContainerLog for details, "
			.. "then :DevContainerHostEditor to recover it, and retry %s"
		):format(status, requested_command)
	end
	if status == "starting" then
		return "Dev Container lifecycle is starting; wait for the registered container editor to open"
	end
	if status == "running" then
		return "Dev Container lifecycle is running; use the registered container editor instead of starting another lifecycle"
	end
	return "Dev Container lifecycle is " .. tostring(status) .. "; it cannot be opened from this host editor"
end

local function preflight(project_root, current)
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local specification = { root = project_root }
	if current then
		specification.cli_path = current.cli_path
		specification.docker_path = current.docker_path
		specification.config = current.config_path
	end
	local argv, argv_err = instance.lifecycle_argv("doctor", specification)
	if not argv then
		return nil, argv_err
	end
	local started, process = pcall(vim.system, argv, { text = true })
	if not started then
		return nil, "could not start Dev Container preflight: " .. tostring(process)
	end
	local result = process:wait()
	if result.code ~= 0 then
		return nil, result_message(result, "Dev Container preflight failed")
	end
	return true
end

---Resolve and validate the exact host runtime before allocating a lifecycle claim.
---@param project_root string
---@return table|nil runtime
---@return string|nil error
function M.prepare_up(project_root)
	if M.in_workspace() then
		return nil, "cannot prepare a host Dev Container lifecycle from inside a container editor"
	end
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local runtime, runtime_err = instance.resolve_runtime()
	if not runtime then
		return nil, runtime_err
	end
	local ready, preflight_err = preflight(project_root, runtime)
	if not ready then
		return nil, preflight_err
	end
	return vim.deepcopy(runtime)
end

---Validate a dead v4/v5/v6 record with its persisted runtime before a restart claim.
---@param project_root string
---@return boolean|nil ok
---@return string|nil error
function M.preflight_record(project_root)
	if M.in_workspace() then
		return nil, "cannot prepare a host Dev Container restart from inside a container editor"
	end
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local current, status_err = read_workspace_status(instance, project_root)
	if not current then
		return nil, status_err
	end
	if current.status ~= "dead" then
		return nil, "Dev Container lifecycle is " .. tostring(current.status) .. "; only a dead record can restart"
	end
	if not RESTARTABLE_RECORD_VERSIONS[current.version] then
		return nil, "Dev Container restart requires a version 4, 5, or 6 workspace record"
	end
	return preflight(project_root, current)
end

local function immutable_descriptor(value)
	local snapshot = vim.deepcopy(value)
	return setmetatable({}, {
		__index = snapshot,
		__newindex = function()
			error("lifecycle descriptor is immutable", 2)
		end,
		__metatable = false,
	})
end

local function replace_editor(recreate, allow_network, requested_root)
	if M.in_workspace() then
		return nil, "already running inside a Dev Container editor"
	end
	local pane, pane_err = exact_pane()
	if not pane then
		return nil, pane_err
	end
	local project_root = requested_root or root()
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local lifecycle_action = "up"
	local current, status_err = read_workspace_status(instance, project_root)
	if current then
		if current.status ~= "dead" then
			return nil, existing_lifecycle_message(current.status, recreate)
		end
		if not RESTARTABLE_RECORD_VERSIONS[current.version] then
			return nil, "Dev Container restart requires a version 4, 5, or 6 workspace record"
		end
		lifecycle_action = "restart-dead"
	elseif not tostring(status_err):find("missing or not a regular file", 1, true) then
		return nil, status_err
	end
	local runtime
	if lifecycle_action == "up" then
		runtime, status_err = M.prepare_up(project_root)
		if not runtime then
			return nil, status_err
		end
	else
		local ready, preflight_err = preflight(project_root, current)
		if not ready then
			return nil, preflight_err
		end
	end
	local claim_id, claim_err = instance.new_claim_id()
	if not claim_id then
		return nil, claim_err
	end
	local specification = {
		root = project_root,
		tmux_pane = pane,
		claim_id = claim_id,
		recreate = recreate,
		allow_network = allow_network,
	}
	if runtime then
		specification.cli_path = runtime.cli_path
		specification.docker_path = runtime.docker_path
	end
	local argv, argv_err = instance.lifecycle_argv(lifecycle_action, specification)
	if not argv then
		return nil, argv_err
	end
	local shell_command = "exec " .. table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
	local started, process = pcall(vim.system, { "tmux", "run-shell", "-b", "-t", pane, shell_command }, {
		text = true,
	})
	if not started then
		return nil, "could not start detached coordinator: " .. tostring(process)
	end
	local result = process:wait()
	if result.code ~= 0 then
		return nil, vim.trim(result.stderr or "tmux rejected the detached coordinator")
	end
	local observed, claim_wait_err, failed = wait_for_claim(project_root, claim_id)
	if not observed then
		return nil,
			claim_wait_err,
			failed and immutable_descriptor({
				root = project_root,
				claim_id = claim_id,
				status = failed.status,
				phase = failed.phase,
			}) or nil
	end
	return immutable_descriptor({
		root = project_root,
		claim_id = claim_id,
		status = observed.status,
		phase = observed.phase,
	})
end

local open_lifecycle_log

local function close_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	local closing = false
	if type(timer.is_closing) == "function" then
		local ok, value = pcall(timer.is_closing, timer)
		closing = ok and value == true
	end
	if not closing then
		pcall(timer.close, timer)
	end
end

local function cancel_progress(hide)
	progress_generation = progress_generation + 1
	local current = active_progress
	active_progress = nil
	if not current then
		return
	end
	close_timer(current.timer)
	if hide and current.displayed then
		pcall(dependencies.visual_hide, current.id)
	end
end

local function progress_id(project_root)
	local ok, digest = pcall(vim.fn.sha256, project_root)
	return "devcontainer:" .. (ok and digest or tostring(#project_root))
end

local function valid_claim_id(value)
	if type(value) ~= "string" or #value ~= 36 or value:lower() ~= value then
		return false
	end
	if value:sub(9, 9) ~= "-" or value:sub(14, 14) ~= "-" or value:sub(19, 19) ~= "-" or value:sub(24, 24) ~= "-" then
		return false
	end
	local compact, hyphens = value:gsub("%-", "")
	return value:sub(15, 15) == "4"
		and value:sub(20, 20):match("[89ab]") ~= nil
		and hyphens == 4
		and #compact == 32
		and compact:match("^[0-9a-f]+$") ~= nil
end

local function announce_container_ready(instance)
	local claim_id = vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID
	if claim_id == nil then
		return false
	end
	-- This flag is an inherited one-shot handoff, not durable lifecycle state.
	-- Clearing it prevents :restart from announcing the same claim again.
	vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID = nil
	local host_root = vim.env.NVIM_DEVCONTAINER_HOST_ROOT
	if not valid_claim_id(claim_id) or type(host_root) ~= "string" or host_root == "" or host_root:find("%z") then
		return false
	end
	local settled = false
	local request_warning
	local function publish_failure(message)
		if settled then
			return
		end
		settled = true
		notify("Could not confirm Dev Container startup: " .. tostring(message), vim.log.levels.ERROR, {
			id = progress_id(host_root),
			timeout = false,
		})
	end
	local function request_confirmation()
		dependencies.schedule(function()
			local called, started, request_err = pcall(instance.request_host, "editor_ready", {
				notify = function(message, level)
					if level == vim.log.levels.ERROR then
						publish_failure(message)
					else
						request_warning = tostring(message)
					end
				end,
			}, function()
				if settled then
					return
				end
				settled = true
				local message = "Dev Container editor is running\nLogs: :DevContainerLog"
				if request_warning then
					message = message .. "\n" .. request_warning
				end
				notify(message, vim.log.levels.INFO, {
					id = progress_id(host_root),
					timeout = 3000,
				})
			end)
			if not called then
				publish_failure(started)
			elseif not started then
				publish_failure(request_err or "authenticated readiness request could not be started")
			end
		end)
	end
	if vim.g.did_very_lazy == true then
		request_confirmation()
	else
		vim.api.nvim_create_autocmd("User", {
			group = vim.api.nvim_create_augroup("NvimConfigDevContainerReady", { clear = true }),
			pattern = "VeryLazy",
			once = true,
			desc = "Confirm the completed Dev Container editor handoff",
			callback = request_confirmation,
		})
	end
	return true
end

local function progress_frame(tracker, stage)
	if policy.ui.progress == false then
		return
	end
	tracker.frame = tracker.frame + 1
	local elapsed = math.max(0, dependencies.now_ms() - tracker.started_ms) / 1000
	local message = string.format(
		"%s %s · %.1fs\nLogs: :DevContainerLog",
		SPINNER[((tracker.frame - 1) % #SPINNER) + 1],
		stage,
		elapsed
	)
	local called, shown = pcall(dependencies.visual_notify, message, vim.log.levels.INFO, {
		id = tracker.id,
		title = "Dev Container",
		timeout = false,
		history = false,
	})
	tracker.displayed = tracker.displayed or (called and shown ~= false)
end

local function begin_progress(project_root)
	cancel_progress(true)
	local tracker = {
		generation = progress_generation,
		root = project_root,
		id = progress_id(project_root),
		started_ms = dependencies.now_ms(),
		frame = 0,
		last_stage = "Preparing Dev Container",
		displayed = false,
		post_claim = false,
	}
	active_progress = tracker
	progress_frame(tracker, tracker.last_stage)
	if policy.ui.progress ~= false then
		pcall(dependencies.redraw)
	end
	return tracker.generation
end

local function terminal_message(detail, post_claim)
	local message = tostring(detail or "Dev Container lifecycle failed")
	if not post_claim then
		return message
	end
	if not message:find(":DevContainerLog", 1, true) then
		message = message .. "\nLogs: :DevContainerLog"
	end
	if not message:find(":DevContainerHostEditor", 1, true) then
		message = message .. "\nRecovery: :DevContainerHostEditor"
	end
	return message
end

local function finish_progress(generation, success, detail, post_claim, auto_open)
	local tracker = active_progress
	if not tracker or tracker.generation ~= generation or progress_generation ~= generation then
		return false
	end
	active_progress = nil
	progress_generation = progress_generation + 1
	close_timer(tracker.timer)
	local message = success and "Dev Container editor is running\nLogs: :DevContainerLog"
		or terminal_message(detail, post_claim)
	notify(message, success and vim.log.levels.INFO or vim.log.levels.ERROR, {
		id = tracker.id,
		timeout = success and 3000 or false,
	})
	if not success and auto_open and policy.ui.auto_open_log_on_error ~= false and open_lifecycle_log then
		pcall(open_lifecycle_log, tracker.root, true)
	end
	return true
end

local function coordinator_alive(pid)
	if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then
		return nil
	end
	local called, result, detail, name = pcall(dependencies.kill, pid, 0)
	if called and result ~= nil and result ~= false then
		return true
	end
	local error_text = table.concat({ tostring(result or ""), tostring(detail or ""), tostring(name or "") }, " ")
	if error_text:find("ESRCH", 1, true) or error_text:lower():find("no such process", 1, true) then
		return false
	end
	return nil
end

local function poll_progress(generation)
	local tracker = active_progress
	if not tracker or tracker.generation ~= generation or progress_generation ~= generation then
		return false
	end
	local instance, load_err = ensure_core()
	local status, status_err
	if instance then
		status, status_err = read_workspace_status(instance, tracker.root)
	else
		status_err = load_err
	end
	local now = dependencies.now_ms()
	if not status then
		tracker.read_error_since = tracker.read_error_since or now
		tracker.last_read_error = tostring(status_err or "workspace record is unavailable")
		if now - tracker.read_error_since >= READ_ERROR_GRACE_MS then
			return finish_progress(
				generation,
				false,
				"Dev Container lifecycle state remained unreadable: " .. tracker.last_read_error,
				true,
				false
			)
		end
		progress_frame(tracker, tracker.last_stage)
		return true
	end
	tracker.read_error_since = nil
	tracker.last_read_error = nil
	if status.claim_id ~= tracker.claim_id then
		return finish_progress(generation, false, "Dev Container lifecycle claim changed unexpectedly", true, false)
	end
	if status.status == "running" then
		return finish_progress(generation, true, nil, true)
	end
	if status.status == "error" or status.status == "dead" or status.status == "stopped" then
		local detail = type(status.error) == "string" and status.error ~= "" and status.error
			or "Dev Container lifecycle entered " .. status.status
		return finish_progress(generation, false, detail, true, true)
	end
	if status.status ~= "starting" then
		return finish_progress(
			generation,
			false,
			"Dev Container lifecycle entered an unexpected state: " .. tostring(status.status),
			true,
			true
		)
	end
	if coordinator_alive(status.pid) == false then
		return finish_progress(
			generation,
			false,
			"Dev Container coordinator exited while startup was still active",
			true,
			true
		)
	end
	tracker.last_stage = PHASE_LABELS[status.phase] or tracker.last_stage or "Starting Dev Container"
	progress_frame(tracker, tracker.last_stage)
	return true
end

local function arm_progress(generation, descriptor)
	local tracker = active_progress
	if not tracker or tracker.generation ~= generation or progress_generation ~= generation then
		return nil, "Dev Container progress tracker was replaced"
	end
	tracker.claim_id = descriptor.claim_id
	tracker.post_claim = true
	tracker.last_stage = PHASE_LABELS[descriptor.phase] or "Starting Dev Container"
	if descriptor.status == "running" then
		finish_progress(generation, true, nil, true)
		return true
	end
	progress_frame(tracker, tracker.last_stage)
	local timer, timer_err = dependencies.new_timer()
	if not timer then
		finish_progress(
			generation,
			false,
			"Could not create Dev Container progress timer: " .. tostring(timer_err),
			true,
			false
		)
		return nil, timer_err
	end
	tracker.timer = timer
	local interval = policy.ui.progress_interval_ms
	local started, result, start_err = pcall(timer.start, timer, interval, interval, function()
		local current = active_progress
		if
			not current
			or current.generation ~= generation
			or progress_generation ~= generation
			or current.scheduled
		then
			return
		end
		current.scheduled = true
		dependencies.schedule(function()
			local scheduled = active_progress
			if not scheduled or scheduled.generation ~= generation or progress_generation ~= generation then
				return
			end
			scheduled.scheduled = false
			poll_progress(generation)
		end)
	end)
	if not started or result == nil then
		tracker.timer = nil
		close_timer(timer)
		finish_progress(
			generation,
			false,
			"Could not start Dev Container progress timer: " .. tostring(started and start_err or result),
			true,
			false
		)
		return nil, start_err or result
	end
	return true
end

local function execute_replace(recreate, allow_network)
	local project_root = root()
	local generation = begin_progress(project_root)
	local descriptor, replace_err, failed = replace_editor(recreate, allow_network, project_root)
	if not descriptor then
		local post_claim = failed ~= nil and failed.claim_id ~= nil
		local terminal_failure = post_claim
			and (failed.status == "error" or failed.status == "dead" or failed.status == "stopped")
		finish_progress(generation, false, replace_err, post_claim, terminal_failure)
		return nil, replace_err
	end
	local armed, arm_err = arm_progress(generation, descriptor)
	if not armed then
		return nil, arm_err
	end
	return descriptor
end

local function run_lifecycle(action, specification, callback)
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local argv, err = instance.lifecycle_argv(action, specification)
	if not argv then
		return nil, err
	end
	local ok, process = pcall(vim.system, argv, { text = true }, function(result)
		vim.schedule(function()
			callback(result)
		end)
	end)
	return ok and true or nil, ok and nil or tostring(process)
end

result_message = function(result, fallback)
	local stdout = vim.trim(result.stdout or "")
	local stderr = vim.trim(result.stderr or "")
	return stdout ~= "" and stdout or stderr ~= "" and stderr or fallback
end

local function show_status()
	local ok, err = run_lifecycle("status", { root = root() }, function(result)
		if result.code == 0 then
			notify(result_message(result, "No Dev Container workspace state"))
		else
			notify(result_message(result, "Dev Container status failed"), vim.log.levels.ERROR)
		end
	end)
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
end

open_lifecycle_log = function(project_root, quiet)
	local instance, load_err = ensure_core()
	if not instance then
		if not quiet then
			notify(load_err, vim.log.levels.ERROR)
		end
		return nil, load_err
	end
	local path, path_err = instance.log_path(project_root)
	if not path then
		if not quiet then
			notify(path_err, vim.log.levels.ERROR)
		end
		return nil, path_err
	end
	local loaded, log_watch = deferred.try("config.log_watch")
	if not loaded then
		local detail = "Could not load live log viewer: " .. tostring(log_watch)
		if not quiet then
			notify(detail, vim.log.levels.ERROR)
		end
		return nil, detail
	end
	local opened, open_err = log_watch.follow_path(path, {
		width = policy.ui.log_width,
		title = "Dev Container Log",
		presenter = "devcontainer-log",
	})
	if not opened and not quiet then
		notify("Could not open Dev Container log: " .. tostring(open_err), vim.log.levels.ERROR)
	end
	return opened, open_err
end

local function show_log()
	if M.in_workspace() then
		local ok, err = M.request_host("container_log")
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
		return
	end
	open_lifecycle_log(root(), false)
end

local function show_doctor()
	local ok, err = run_lifecycle("doctor", { root = root() }, function(result)
		if result.code == 0 then
			notify(result_message(result, "Dev Container configuration is ready"))
		else
			notify(result_message(result, "Dev Container doctor failed"), vim.log.levels.ERROR)
		end
	end)
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
end

local function return_to_host()
	if M.in_workspace() then
		return M.request_host("host_editor")
	end
	local project_root = root()
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local status, status_err = read_workspace_status(instance, project_root)
	if not status then
		if tostring(status_err):find("missing or not a regular file", 1, true) then
			return true, "already running in the host editor; no Dev Container record exists"
		end
		return nil, status_err
	end
	if status.status == "starting" or status.status == "running" then
		return nil,
			"Dev Container lifecycle is " .. status.status .. "; request host recovery from the container editor"
	end
	if status.status ~= "error" and status.status ~= "stopped" and status.status ~= "dead" then
		return nil, "Dev Container lifecycle status cannot be recovered from the host"
	end
	local pane, pane_err = exact_pane()
	if not pane then
		return nil, pane_err
	end
	return run_lifecycle("host", { root = project_root, tmux_pane = pane }, function(result)
		if result.code ~= 0 then
			notify(result_message(result, "Dev Container host recovery failed"), vim.log.levels.ERROR)
		else
			notify("Dev Container lifecycle recovered; retry :DevContainerUp")
		end
	end)
end

function M.setup()
	if M.in_workspace() then
		local instance, err = ensure_core()
		if not instance then
			error("Could not initialize Dev Container editor: " .. tostring(err))
		end
		vim.g.nvim_devcontainer_status = {
			project = vim.fs.basename(vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT or "container"),
			network = M.network_authorized() and "online" or "offline",
		}
		vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigDevContainerChanged" })
		announce_container_ready(instance)
	end

	vim.api.nvim_create_user_command("DevContainerUp", function(command)
		execute_replace(false, command.bang)
	end, {
		bang = true,
		desc = "Replace the tmux editor pane with Dev Container Neovim (! authorizes network tools)",
		force = true,
	})

	vim.api.nvim_create_user_command("DevContainerRecreate", function(command)
		execute_replace(true, command.bang)
	end, {
		bang = true,
		desc = "Recreate the Dev Container and open its exact Neovim editor",
		force = true,
	})

	vim.api.nvim_create_user_command("DevContainerStatus", show_status, {
		desc = "Show private Dev Container lifecycle state",
		force = true,
	})

	vim.api.nvim_create_user_command("DevContainerLog", show_log, {
		desc = "Show the private Dev Container lifecycle log",
		force = true,
	})

	vim.api.nvim_create_user_command("DevContainerDoctor", show_doctor, {
		desc = "Validate Dev Container CLI and lockfile policy support",
		force = true,
	})

	vim.api.nvim_create_user_command("DevContainerHostEditor", function()
		local ok, err = return_to_host()
		if not ok then
			notify(err, vim.log.levels.ERROR)
		elseif type(err) == "string" then
			notify(err)
		end
	end, { desc = "Explicitly return the tmux editor pane to host Neovim", force = true })
	local group = vim.api.nvim_create_augroup("NvimConfigDevContainer", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		desc = "Stop Dev Container progress UI before exit",
		callback = M.teardown,
	})
	return true
end

function M.teardown()
	cancel_progress(true)
	return true
end

M._core = function()
	return assert(ensure_core())
end
M._launcher = launcher
M._replace_editor = replace_editor
M._execute_replace = execute_replace
M._options = options
M._wait_for_claim = wait_for_claim
M._show_doctor = show_doctor
M._show_log = show_log
M._preflight = preflight
M._return_to_host = return_to_host
M._poll_progress = poll_progress
M._coordinator_alive = coordinator_alive
M._active_progress = function()
	return active_progress
			and {
				generation = active_progress.generation,
				root = active_progress.root,
				claim_id = active_progress.claim_id,
				last_stage = active_progress.last_stage,
				read_error_since = active_progress.read_error_since,
				id = active_progress.id,
			}
		or nil
end
M._set_progress_dependencies = function(overrides)
	M.teardown()
	dependencies = vim.tbl_extend("force", {}, default_dependencies, overrides or {})
end

return M
