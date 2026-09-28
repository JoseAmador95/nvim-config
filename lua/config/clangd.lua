-- Host policy adapter for clangd-compile-db.nvim. Profiles, executable paths,
-- CMake integration, commands, and notifications remain in the configuration.
local M = {}
local router
local router_configured = false
local ensure_router
local local_config = require("config.local_config")
local deferred = require("config.deferred")
local lsp_catalog = require("config.lsp_catalog")
local lsp_runtime = require("config.lsp_runtime")

local plugin_config = local_config.plugin("clangd_compile_db", {
	path = "clangd",
	profile = "full",
	restart_timeout_ms = 5000,
	max_validation_bytes = 256 * 1024 * 1024,
})

local FULL_FLAGS = {
	"--background-index",
	"--clang-tidy",
	"--cross-file-rename",
	"--completion-style=detailed",
	"--header-insertion=never",
}
local LIGHT_FLAGS = {
	"--cross-file-rename",
	"--completion-style=detailed",
	"--header-insertion=never",
}
local CLANGD_BINDING = assert(lsp_catalog.server("clangd"))

local function canonical(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	return vim.uv.fs_realpath(absolute) or absolute
end

function M.profile()
	return plugin_config.profile
end

local function command_for_active(active)
	local command = { vim.fn.expand(plugin_config.path) }
	local directory = active and active.directory or nil
	if directory then
		command[#command + 1] = "--compile-commands-dir=" .. directory
	end
	vim.list_extend(command, M.profile() == "light" and LIGHT_FLAGS or FULL_FLAGS)
	return command
end

function M.command(root)
	local instance = root and assert(ensure_router()) or nil
	return command_for_active(instance and instance.active(root) or nil)
end

local function arguments_for_active(active)
	local command = command_for_active(active)
	table.remove(command, 1)
	return command
end

local function rpc_start_for_active(active, dispatchers, config)
	return lsp_runtime.managed_start(
		CLANGD_BINDING,
		dispatchers,
		config,
		arguments_for_active(active),
		vim.fn.expand(plugin_config.path)
	)
end

-- Neovim 0.12 invokes function-valued commands only when it owns a concrete
-- root-scoped client. Resolve the compile database at that boundary instead of
-- relying on the legacy on_new_config callback, which native autoactivation
-- does not call.
function M.rpc_start(dispatchers, config)
	local instance = config and config.root_dir and assert(ensure_router()) or nil
	local active = instance and instance.active(config.root_dir) or nil
	return rpc_start_for_active(active, dispatchers, config)
end

local function client_is_stopped(client)
	return type(client.is_stopped) == "function" and client:is_stopped() or false
end

local function clangd_clients()
	return vim.lsp.get_clients({
		name = "clangd",
		_uninitialized = true,
	})
end

local function root_clients(root)
	local expected = canonical(root)
	local result = {}
	for _, client in ipairs(clangd_clients()) do
		if canonical(client.config and client.config.root_dir) == expected and not client_is_stopped(client) then
			result[#result + 1] = client
		end
	end
	return result
end

local function wait_root_stopped(root, timeout_ms)
	return vim.wait(timeout_ms, function()
		return #root_clients(root) == 0
	end, 20, false)
end

local lsp = {
	clients = clangd_clients,
	client_root = function(client)
		return client.config and client.config.root_dir or nil
	end,
	stop = function(client)
		client:stop()
	end,
	wait_stopped = function(_, root, timeout_ms)
		return wait_root_stopped(root, timeout_ms)
	end,
	buffer_valid = function(bufnr)
		return vim.api.nvim_buf_is_valid(bufnr)
	end,
	config = function(root, active)
		local config = vim.deepcopy(vim.lsp.config.clangd or {})
		config.root_dir = root
		-- Build from the transaction's immutable target. Reentrant provider
		-- updates schedule a follow-up restart instead of changing this launch.
		-- The verified executable is still resolved at Neovim's final RPC seam.
		config.cmd = function(dispatchers, runtime_config)
			return rpc_start_for_active(active, dispatchers, runtime_config)
		end
		return config
	end,
	reconcile = function(root, timeout_ms)
		local buffers = {}
		local clients = root_clients(root)
		for _, client in ipairs(clients) do
			for bufnr in pairs(client.attached_buffers or {}) do
				buffers[bufnr] = true
			end
			client:stop()
		end
		if #clients > 0 and not wait_root_stopped(root, timeout_ms) then
			return nil, "timed out stopping an autoactivated clangd client"
		end
		local ordered = vim.tbl_keys(buffers)
		table.sort(ordered)
		return ordered
	end,
	start = function(config)
		-- attach=false makes the return value an unambiguous ownership result:
		-- nil means no client was created, while an id is owned by this restart.
		local client_id = vim.lsp.start(config, {
			attach = false,
			reuse_client = function()
				return false
			end,
		})
		if not client_id then
			return { owned = false, error = "Neovim did not create a clangd client" }
		end
		return { owned = true, client_id = client_id }
	end,
	attach = function(bufnr, client_id)
		return vim.lsp.buf_attach_client(bufnr, client_id)
	end,
	wait_initialized = function(client_id, root, timeout_ms)
		local expected = canonical(root)
		local terminal_error
		local completed = vim.wait(timeout_ms, function()
			local client = vim.lsp.get_client_by_id(client_id)
			if not client then
				terminal_error = "owned clangd client exited before initialization"
				return true
			end
			if canonical(client.config and client.config.root_dir) ~= expected then
				terminal_error = "owned clangd client root changed before initialization"
				return true
			end
			if client_is_stopped(client) then
				terminal_error = "owned clangd client stopped before initialization"
				return true
			end
			return client.initialized == true
		end, 20, false)
		if terminal_error then
			return nil, terminal_error
		end
		if not completed then
			return nil, "timed out waiting for owned clangd client initialization"
		end
		return true
	end,
	discard = function(client_id, _, timeout_ms)
		local client = vim.lsp.get_client_by_id(client_id)
		if not client or client_is_stopped(client) then
			return true
		end
		client:stop()
		local stopped = vim.wait(timeout_ms, function()
			local current = vim.lsp.get_client_by_id(client_id)
			return not current or client_is_stopped(current)
		end, 20, false)
		return stopped, stopped and nil or "timed out stopping the owned clangd client"
	end,
}

ensure_router = function()
	if router_configured and router then
		return router
	end
	local candidate = router
	if not candidate then
		local loaded, result = deferred.try("clangd_compile_db")
		if not loaded then
			return nil, tostring(result)
		end
		candidate = result
	end
	local ok, result = pcall(candidate.setup, {
		lsp = lsp,
		event = function(event)
			if event.kind ~= "status" then
				return
			end
			vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
		end,
		max_validation_bytes = plugin_config.max_validation_bytes,
		restart_timeout_ms = plugin_config.restart_timeout_ms,
	})
	if not ok or not result then
		router = nil
		return nil, tostring(ok and "clangd router setup failed" or result)
	end
	local registered, register_err = candidate.register_provider("cmake", { priority = 10 })
	if not registered then
		router = nil
		return nil, tostring(register_err)
	end
	router = candidate
	router_configured = true
	return router
end

function M.validate_compile_commands(directory, options)
	local instance = assert(ensure_router())
	local validated, err = instance.validate(directory, options)
	return validated and validated.directory or nil, err, validated and validated.validity or nil
end

function M.set_cmake(root, directory)
	local instance = assert(ensure_router())
	local state, err = instance.set_provider(root, "cmake", directory)
	return state ~= nil, err
end

function M.set_manual(root, directory, options)
	local instance = assert(ensure_router())
	local state, err = instance.set_override(root, directory, options)
	return state ~= nil, err
end

function M.clear_manual(root)
	local instance = assert(ensure_router())
	local state, err = instance.clear_override(root)
	return state ~= nil, err
end

function M.restart_root(root)
	return assert(ensure_router()).restart(root)
end

function M.refresh(root)
	local state, err = assert(ensure_router()).refresh(root)
	return state ~= nil, err
end

function M.status(root)
	root = canonical(root)
	local state = assert(ensure_router()).status(root)
	local active = state.active
	local applied = state.applied
	return {
		profile = M.profile(),
		state = state.state,
		-- Keep the flat desired fields for existing status consumers while
		-- exposing the transactional distinction explicitly.
		directory = active and active.directory or nil,
		source = active and active.provider or nil,
		validity = active and active.validity or nil,
		desired = {
			directory = active and active.directory or nil,
			source = active and active.provider or nil,
			validity = active and active.validity or nil,
			revision = state.active_revision,
		},
		applied = {
			directory = applied and applied.directory or nil,
			source = applied and applied.provider or nil,
			validity = applied and applied.validity or nil,
			revision = state.applied_revision,
		},
		candidate = vim.deepcopy(state.candidate),
		error = state.error,
		generation = state.generation,
		active_revision = state.active_revision,
		applied_revision = state.applied_revision,
		restart_pending = state.restart_pending,
	}
end

M._router = ensure_router

return M
