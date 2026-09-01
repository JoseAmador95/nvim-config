-- Host policy adapter for devcontainer-editor.nvim. Lifecycle and transport
-- validation live in the local plugin; commands, tmux, and UI stay here.
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.devcontainer source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))

local M = {}
local uv = vim.uv
local core = require("devcontainer_editor")
local launcher = vim.fs.joinpath(config_root, "scripts", "devcontainer-editor")
local CLAIM_TIMEOUT_MS = 2000

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
		open = require("config.editor").open_file_in_tab,
		notify = notify,
	}
end

core.setup(options())

function M.in_workspace()
	return core.in_workspace()
end

function M.network_authorized()
	return core.network_authorized()
end

function M.request_host(action, dependencies, on_success)
	return core.request_host(action, dependencies, on_success)
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
	local failure
	local last_error
	local ready = vim.wait(timeout_ms or CLAIM_TIMEOUT_MS, function()
		local status, status_err = core.status(project_root)
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
	local claim_id, claim_err = core.new_claim_id()
	if not claim_id then
		return nil, claim_err
	end
	local argv, argv_err = core.lifecycle_argv("up", {
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
	local argv, err = core.lifecycle_argv(action, specification)
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

function M.setup()
	core.setup(options())
	if M.in_workspace() then
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
	})

	vim.api.nvim_create_user_command("DevContainerRecreate", function(command)
		local ok, err = replace_editor(true, command.bang)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, {
		bang = true,
		desc = "Recreate the Dev Container and open its exact Neovim editor",
	})

	vim.api.nvim_create_user_command("DevContainerStatus", show_status, {
		desc = "Show private Dev Container lifecycle state",
	})

	vim.api.nvim_create_user_command("DevContainerLog", show_log, {
		desc = "Show the private Dev Container lifecycle log",
	})

	vim.api.nvim_create_user_command("DevContainerHostEditor", function()
		local ok, err = M.request_host("host_editor")
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, { desc = "Explicitly return the tmux editor pane to host Neovim" })
end

M._core = core
M._launcher = launcher
M._replace_editor = replace_editor
M._options = options
M._wait_for_claim = wait_for_claim

return M
