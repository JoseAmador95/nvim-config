-- Host policy adapter for exact-editor.nvim.
local exact = require("exact_editor")
local M = {}

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

local function resolve_workspace(path)
	local root = require("config.repo").root(path)
	if not root then
		return nil
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
	instance.workspaces = {}
	for root in pairs(instance.roots or {}) do
		local workspace = { runtime = "host", root = root, repo_identity = root }
		instance.workspaces[exact._workspace_identity(workspace)] = workspace
	end
	return instance
end

function M.state_root()
	return state_root()
end

function M.write_registry(instance)
	return exact.write_registry(migrate_instance(instance))
end

function M.consume_request(request_id, instance, dependencies)
	local deps = vim.tbl_extend("force", options(), dependencies or {})
	return exact.consume_request(request_id, migrate_instance(instance), deps)
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

return M
