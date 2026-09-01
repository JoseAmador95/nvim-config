-- Host policy adapter for devcontainer-editor.nvim. Lifecycle and transport
-- validation live in the local plugin; commands, tmux, and UI stay here.
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.devcontainer source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))

local M = {}
local uv = vim.uv
local deferred = require("config.deferred")
local core
local core_configured = false
local policy = require("config.local_config").plugin("devcontainer_editor", {
	cli = "devcontainer",
	lockfile_policy = "preserve",
	ssh_agent = "auto",
	claim_timeout_ms = 2000,
	ack_timeout_ms = 5000,
	max_messages_per_tick = 32,
})
local launcher = vim.fs.joinpath(config_root, "scripts", "devcontainer-editor")

local function state_root()
	local configured = vim.env.NVIM_DEVCONTAINER_STATE_HOME
	if configured and configured ~= "" then
		return vim.fs.normalize(vim.fn.fnamemodify(configured, ":p"))
	end
	local state = vim.env.XDG_STATE_HOME or (vim.env.HOME and vim.fs.joinpath(vim.env.HOME, ".local", "state"))
	return state and vim.fs.joinpath(state, "nvim-devcontainer") or nil
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Dev Container" })
end

local function root()
	return require("config.repo").current_root(0) or uv.cwd()
end

local function options()
	return {
		state_root = state_root,
		launcher = launcher,
		cli = policy.cli,
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

local function wait_for_claim(project_root, claim_id, timeout_ms)
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local failure
	local last_error
	local ready = vim.wait(timeout_ms or policy.claim_timeout_ms, function()
		local status, status_err = instance.status(project_root)
		if not status then
			last_error = status_err
			return false
		end
		if status.claim_id ~= claim_id then
			last_error = "another lifecycle record still owns the workspace"
			return false
		end
		if status.status == "starting" or status.status == "running" then
			return true
		end
		failure = "detached coordinator entered " .. tostring(status.status)
		return true
	end, 20, false)
	if failure then
		return nil, failure
	end
	if not ready then
		return nil, "detached coordinator did not publish its starting claim: " .. tostring(last_error or "timeout")
	end
	return true
end

local function replace_editor(recreate, allow_network)
	if M.in_workspace() then
		return nil, "already running inside a Dev Container editor"
	end
	local pane, pane_err = exact_pane()
	if not pane then
		return nil, pane_err
	end
	local project_root = root()
	local instance, load_err = ensure_core()
	if not instance then
		return nil, load_err
	end
	local claim_id, claim_err = instance.new_claim_id()
	if not claim_id then
		return nil, claim_err
	end
	local argv, argv_err = instance.lifecycle_argv("up", {
		root = project_root,
		tmux_pane = pane,
		claim_id = claim_id,
		recreate = recreate,
		allow_network = allow_network,
	})
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
	return wait_for_claim(project_root, claim_id)
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

local function result_message(result, fallback)
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

local function show_log()
	if M.in_workspace() then
		local ok, err = M.request_host("container_log")
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
		return
	end
	local ok, err = run_lifecycle("log", { root = root() }, function(result)
		if result.code == 0 then
			notify(result_message(result, "Dev Container log is empty"))
		else
			notify(result_message(result, "Dev Container log failed"), vim.log.levels.ERROR)
		end
	end)
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
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
	end

	vim.api.nvim_create_user_command("DevContainerUp", function(command)
		local ok, err = replace_editor(false, command.bang)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, {
		bang = true,
		desc = "Replace the tmux editor pane with Dev Container Neovim (! authorizes network tools)",
		force = true,
	})

	vim.api.nvim_create_user_command("DevContainerRecreate", function(command)
		local ok, err = replace_editor(true, command.bang)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
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
		local ok, err = M.request_host("host_editor")
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, { desc = "Explicitly return the tmux editor pane to host Neovim", force = true })
	return true
end

M._core = function()
	return assert(ensure_core())
end
M._launcher = launcher
M._replace_editor = replace_editor
M._options = options
M._wait_for_claim = wait_for_claim
M._show_doctor = show_doctor

return M
