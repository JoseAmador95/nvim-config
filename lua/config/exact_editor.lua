-- Host policy adapter for exact-editor.nvim.
local exact = require("exact_editor")
local M = {}

local exact_environment = {
	runtime = "NVIM_EXACT_EDITOR_RUNTIME",
	root = "NVIM_EXACT_EDITOR_WORKSPACE_ROOT",
	repo_identity = "NVIM_EXACT_EDITOR_REPO_IDENTITY",
}

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
	local root = require("config.repo").root(path)
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

local function options()
	local open = require("config.editor").open_file_in_tab
	return {
		state_root = state_root,
		resolve_workspace = resolve_workspace,
		resolve_relative = require("config.repo").resolve_relative,
		open = open,
		open_file = open,
		install_finish_mapping = install_finish_mapping,
	}
end

local function migrate_instance(instance)
	if not instance or instance.workspaces then
		return instance
	end
	local workspaces = {}
	for root in pairs(instance.roots or {}) do
		local workspace, workspace_err = resolve_workspace(root)
		if workspace then
			workspaces[exact._workspace_identity(workspace)] = workspace
		elseif workspace_err then
			return nil, workspace_err
		end
	end
	instance.workspaces = workspaces
	return instance
end

function M.state_root()
	return state_root()
end

function M.write_registry(instance)
	local migrated, migrate_err = migrate_instance(instance)
	if not migrated then
		return nil, migrate_err
	end
	return exact.write_registry(migrated)
end

function M.consume_request(request_id, instance, dependencies)
	local migrated, migrate_err = migrate_instance(instance)
	if not migrated then
		return nil, migrate_err
	end
	local deps = vim.tbl_extend("force", options(), dependencies or {})
	return exact.consume_request(request_id, migrated, deps)
end

function M.setup()
	return exact.setup(options())
end

function M.setup_deferred(dependencies)
	local deps = vim.tbl_extend("force", { options = options() }, dependencies or {})
	return exact.setup_deferred(deps)
end

function M._cleanup(instance)
	return exact._cleanup(instance)
end

M._record_keys = exact._record_keys
M._wait_request_keys = exact._wait_request_keys
M._wait_state_keys = exact._wait_state_keys
M._prepare_state = exact._prepare_state
M._options = options

return M
