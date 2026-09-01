-- Host policy adapter for clangd-compile-db.nvim. Profiles, executable paths,
-- CMake integration, commands, and notifications remain in the configuration.
local M = {}
local router = require("clangd_compile_db")
local local_config = require("config.local_config")

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

local function canonical(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	return vim.uv.fs_realpath(absolute) or absolute
end

function M.profile()
	return local_config.get("clangd", {}).profile or "full"
end

function M.command(root)
	local config = local_config.get("clangd", {})
	local executable = type(config.path) == "string" and config.path ~= "" and config.path or "clangd"
	local command = { vim.fn.expand(executable) }
	local directory = root and router.command_directory(root) or nil
	if directory then
		command[#command + 1] = "--compile-commands-dir=" .. directory
	end
	vim.list_extend(command, M.profile() == "light" and LIGHT_FLAGS or FULL_FLAGS)
	return command
end

local lsp = {
	clients = function()
		return vim.lsp.get_clients({ name = "clangd" })
	end,
	client_root = function(client)
		return client.config and client.config.root_dir or nil
	end,
	stop = function(client)
		client:stop()
	end,
	buffer_valid = function(bufnr)
		return vim.api.nvim_buf_is_valid(bufnr)
	end,
	config = function(root, _active)
		local config = vim.deepcopy(vim.lsp.config.clangd or {})
		config.root_dir = root
		-- The router publishes active state (including nil) before this callback,
		-- so no clangd process can start with the previous compile database.
		config.cmd = M.command(root)
		return config
	end,
	start = function(config, bufnr)
		return vim.lsp.start(config, {
			bufnr = bufnr,
			reuse_client = function()
				return false
			end,
		})
	end,
	attach = function(bufnr, client_id)
		return vim.lsp.buf_attach_client(bufnr, client_id)
	end,
}

router.setup({
	lsp = lsp,
	events = function()
		vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
	end,
})
router.register_provider("cmake", { priority = 10 })

function M.on_new_config(config, root)
	config.cmd = M.command(root)
end

function M.validate_compile_commands(directory, options)
	local validated, err = router.validate(directory, options)
	return validated and validated.directory or nil, err, validated and validated.validity or nil
end

function M.set_cmake(root, directory)
	local state, err = router.set_provider(root, "cmake", directory)
	return state ~= nil, err
end

function M.set_manual(root, directory, options)
	local state, err = router.set_override(root, directory, options)
	return state ~= nil, err
end

function M.clear_manual(root)
	local state, err = router.clear_override(root)
	return state ~= nil, err
end

function M.restart_root(root)
	return router.restart(root)
end

function M.status(root)
	root = canonical(root)
	local state = router.status(root)
	local active = state.active
	return {
		profile = M.profile(),
		state = state.state,
		directory = active and active.directory or nil,
		source = active and active.provider or nil,
		validity = active and active.validity or nil,
		candidate = vim.deepcopy(state.candidate),
		error = state.error,
		generation = state.generation,
	}
end

M._router = router

return M
