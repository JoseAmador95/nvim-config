-- Host policy adapter for exact-editor.nvim.
local deferred = require("config.deferred")
local editor = require("config.editor")
local local_config = require("config.local_config")
local repo = require("config.repo")

local M = {}

local exact_environment = {
	runtime = "NVIM_EXACT_EDITOR_RUNTIME",
	root = "NVIM_EXACT_EDITOR_WORKSPACE_ROOT",
	repo_identity = "NVIM_EXACT_EDITOR_REPO_IDENTITY",
}

local activation = {
	complete = false,
	entered = false,
	exiting = false,
	generation = 0,
	group = nil,
	pending = false,
	queue = nil,
	timer = nil,
}
local exact

local function loaded_exact()
	if type(exact) == "table" then
		return exact
	end
	local loaded = package.loaded.exact_editor
	if type(loaded) == "table" then
		exact = loaded
		return exact
	end
	return nil
end

-- This is the single audited import boundary for the exact-editor core. The
-- deferred lifecycle below and explicit adapter APIs are its only callers.
local function activate()
	local loaded = loaded_exact()
	if loaded then
		return loaded
	end
	loaded = deferred.load("exact_editor")
	assert(type(loaded) == "table", "exact-editor returned no module")
	exact = loaded
	return exact
end

local function state_root()
	local root
	if vim.env.NVIM_EXACT_EDITOR_STATE_HOME and vim.env.NVIM_EXACT_EDITOR_STATE_HOME ~= "" then
		root = vim.env.NVIM_EXACT_EDITOR_STATE_HOME
	elseif vim.env.XDG_STATE_HOME and vim.env.XDG_STATE_HOME ~= "" then
		root = vim.fs.joinpath(vim.env.XDG_STATE_HOME, "exact-editor")
	else
		root = vim.fs.joinpath(vim.env.HOME, ".local", "state", "exact-editor")
	end
	return vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
end

local function container_workspace()
	local values = {}
	local supplied = 0
	for field, name in pairs(exact_environment) do
		local value = vim.env[name]
		if value ~= nil then
			supplied = supplied + 1
		end
		values[field] = value
	end
	if supplied ~= 3 then
		return nil, "Dev Container exact editor requires runtime, workspace root, and repository identity"
	end
	if values.runtime ~= "container" then
		return nil, "Dev Container exact editor runtime must be container"
	end
	if
		type(values.root) ~= "string"
		or values.root == ""
		or values.root:sub(1, 1) ~= "/"
		or values.root:find("\0", 1, true)
		or vim.fs.normalize(values.root) ~= values.root
	then
		return nil, "Dev Container exact editor workspace root must be absolute and lexically canonical"
	end
	if
		type(values.repo_identity) ~= "string"
		or values.repo_identity == ""
		or values.repo_identity:find("\0", 1, true)
	then
		return nil, "Dev Container exact editor repository identity is invalid"
	end
	return values
end

local function resolve_workspace(path)
	local root = repo.root(path)
	if not root then
		return nil
	end
	if vim.env.NVIM_DEVCONTAINER == "1" then
		local workspace, workspace_err = container_workspace()
		if not workspace then
			return nil, workspace_err
		end
		if vim.fs.normalize(root) ~= workspace.root then
			return nil
		end
		return workspace
	end
	return { runtime = "host", root = root, repo_identity = root }
end

local function install_finish_mapping(buf, callback)
	local lhs = "<leader>q"
	vim.keymap.set("n", lhs, callback, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Save and finish external editor",
	})
	return function()
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.keymap.del, "n", lhs, { buffer = buf })
		end
	end
end

local function policy()
	return local_config.plugin("exact_editor", {
		activation_delay_ms = 300,
		workspace_retention = "visited",
		registry_heartbeat_seconds = 21600,
	})
end

local function options()
	local configured = policy()
	return {
		state_root = state_root,
		resolve_workspace = resolve_workspace,
		resolve_relative = repo.resolve_relative,
		open = editor.open_file_in_tab,
		install_finish_mapping = install_finish_mapping,
		workspace_retention = configured.workspace_retention,
		registry_heartbeat_seconds = configured.registry_heartbeat_seconds,
	}
end

local function request_dependencies()
	local setup_options = options()
	return {
		open_file = setup_options.open,
		resolve_relative = setup_options.resolve_relative,
		install_finish_mapping = setup_options.install_finish_mapping,
	}
end

local function migrate_instance(instance, core)
	if not instance or instance.workspaces then
		return instance
	end
	local workspaces = {}
	for root in pairs(instance.roots or {}) do
		local workspace, workspace_err = resolve_workspace(root)
		if workspace then
			workspaces[core._workspace_identity(workspace)] = workspace
		elseif workspace_err then
			return nil, workspace_err
		end
	end
	instance.workspaces = workspaces
	return instance
end

local function cancel_timer(timer)
	if timer == nil then
		return
	end
	pcall(function()
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
	end)
end

local function clear_group()
	if activation.group ~= nil then
		pcall(vim.api.nvim_del_augroup_by_id, activation.group)
		activation.group = nil
	end
	activation.entered = false
	activation.queue = nil
end

local function invalidate_deferred(remove_group)
	activation.generation = activation.generation + 1
	activation.pending = false
	cancel_timer(activation.timer)
	activation.timer = nil
	if remove_group then
		clear_group()
	end
end

local function ui_attached(ui_count)
	local ok, count = pcall(ui_count)
	return ok and type(count) == "number" and count > 0
end

local function report_activation_error(message)
	vim.notify(
		"Could not activate exact editor: " .. tostring(message),
		vim.log.levels.ERROR,
		{ title = "Exact editor" }
	)
end

local function configured_core()
	local core = loaded_exact()
	if not core then
		return false
	end
	local ok, status = pcall(core.status)
	return ok and type(status) == "table" and status.configured == true
end

function M.state_root()
	return state_root()
end

function M.write_registry(instance)
	local core = activate()
	local migrated, migrate_err = migrate_instance(instance, core)
	if not migrated then
		return nil, migrate_err
	end
	return core.write_registry(migrated)
end

function M.consume_request(request_id, instance, dependencies)
	local core = activate()
	local migrated, migrate_err = migrate_instance(instance, core)
	if not migrated then
		return nil, migrate_err
	end
	local deps = vim.tbl_extend("force", request_dependencies(), dependencies or {})
	return core.consume_request(request_id, migrated, deps)
end

function M.setup()
	local result = activate().setup(options())
	if result then
		activation.complete = true
		invalidate_deferred(true)
	end
	return result
end

-- Register a lightweight host lifecycle without importing exact-editor. A real
-- UI must have crossed UIEnter and remained attached for the configured delay
-- before the synchronous socket, state, and Git setup is allowed to run.
function M.setup_deferred(dependencies)
	local deps = dependencies or {}
	if activation.exiting then
		return nil
	end
	if activation.complete or configured_core() then
		activation.complete = true
		invalidate_deferred(true)
		return true
	end
	if activation.group ~= nil then
		if activation.queue then
			activation.queue()
		end
		return nil
	end

	local ui_count = deps.ui_count or function()
		return #vim.api.nvim_list_uis()
	end
	local has_entered = deps.has_entered or function()
		return vim.v.vim_did_enter == 1
	end
	local defer_fn = deps.defer_fn
	if defer_fn == nil and type(deps.schedule) == "function" then
		defer_fn = function(callback)
			return deps.schedule(callback)
		end
	end
	defer_fn = defer_fn or vim.defer_fn
	local setup = deps.setup or function()
		return activate().setup(deps.options or options())
	end
	local delay = deps.activation_delay_ms
	local function activation_delay()
		if delay == nil then
			delay = policy().activation_delay_ms
		end
		assert(
			type(delay) == "number" and delay % 1 == 0 and delay >= 0 and delay <= 5000,
			"exact editor activation delay must be an integer between 0 and 5000 milliseconds"
		)
		return delay
	end

	local function queue()
		if
			not activation.entered
			or activation.exiting
			or activation.complete
			or activation.pending
			or not ui_attached(ui_count)
		then
			return
		end
		local delay_ok, resolved_delay = pcall(activation_delay)
		if not delay_ok then
			report_activation_error(resolved_delay)
			return
		end
		activation.pending = true
		local generation = activation.generation
		local function run()
			if generation ~= activation.generation or activation.exiting then
				return
			end
			activation.pending = false
			activation.timer = nil
			if not ui_attached(ui_count) then
				return
			end
			local ok, result = pcall(setup)
			if not ok then
				report_activation_error(result)
				return
			end
			if result then
				activation.complete = true
				invalidate_deferred(true)
			end
		end
		local scheduled, timer = pcall(defer_fn, run, resolved_delay)
		if not scheduled then
			activation.pending = false
			report_activation_error(timer)
			return
		end
		if activation.pending and generation == activation.generation then
			activation.timer = timer
		else
			cancel_timer(timer)
		end
	end

	activation.group = vim.api.nvim_create_augroup("config_exact_editor_deferred", { clear = true })
	activation.queue = queue
	vim.api.nvim_create_autocmd("UIEnter", {
		group = activation.group,
		callback = function()
			activation.entered = true
			queue()
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = activation.group,
		once = true,
		callback = function()
			activation.exiting = true
			invalidate_deferred(true)
		end,
	})
	local entered_ok, entered = pcall(has_entered)
	if entered_ok and entered then
		activation.entered = true
		queue()
	end
	return nil
end

function M.status()
	return activate().status()
end

function M.effective_config()
	local result = activate().effective_config()
	result.activation_delay_ms = policy().activation_delay_ms
	return result
end

function M.teardown()
	invalidate_deferred(true)
	activation.exiting = false
	local core = loaded_exact()
	if not core then
		activation.complete = false
		return true
	end
	local result = core.teardown()
	activation.complete = result ~= true and configured_core() or false
	return result
end

function M._cleanup(instance)
	return activate()._cleanup(instance)
end

function M._prepare_state(root)
	return activate()._prepare_state(root)
end

M._options = options

-- These tables are retained as properties for existing host/tests, but merely
-- reading the adapter does not import the core. Access is an explicit API use.
local lazy_exports = {
	_record_keys = true,
	_wait_request_keys = true,
	_wait_state_keys = true,
}

setmetatable(M, {
	__index = function(_, key)
		if lazy_exports[key] then
			return activate()[key]
		end
	end,
})

return M
