local M = {}

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
local roots = {}

local function canonical(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local absolute = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
	return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

function M.profile()
	return require("config.local_config").get("clangd", {}).profile or "full"
end

function M.command(root)
	local config = require("config.local_config").get("clangd", {})
	local executable = config.path
	if not executable or executable == "" then
		executable = "clangd"
	end
	local command = { vim.fn.expand(executable) }
	local state = root and roots[canonical(root)] or nil
	local directory = state and (state.manual or state.cmake) or nil
	if directory then
		command[#command + 1] = "--compile-commands-dir=" .. directory
	end
	vim.list_extend(command, M.profile() == "light" and LIGHT_FLAGS or FULL_FLAGS)
	return command
end

function M.on_new_config(config, root)
	config.cmd = M.command(root)
end

function M.validate_compile_commands(directory)
	local expanded = canonical(directory)
	if not expanded or vim.fn.isdirectory(expanded) ~= 1 then
		return nil, "not a directory: " .. tostring(expanded or directory)
	end
	local database = vim.fs.joinpath(expanded, "compile_commands.json")
	if vim.fn.filereadable(database) ~= 1 then
		return nil, "compile_commands.json not found in " .. expanded
	end
	local data, read_err = require("config.fs").read_binary(database)
	if not data then
		return nil, "could not read " .. database .. ": " .. tostring(read_err)
	end
	local ok, decoded = pcall(vim.json.decode, data)
	if not ok or not vim.islist(decoded) then
		return nil, "invalid compile_commands.json in " .. expanded .. " (expected a JSON array)"
	end
	return expanded
end

local function client_root(client)
	return client.config and canonical(client.config.root_dir) or nil
end

function M.restart_root(root)
	root = canonical(root)
	if not root then
		return
	end
	local buffers = {}
	for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
		if client_root(client) == root then
			for buf in pairs(client.attached_buffers or {}) do
				buffers[buf] = true
			end
			client:stop()
		end
	end
	vim.defer_fn(function()
		for buf in pairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				local config = vim.deepcopy(vim.lsp.config.clangd or {})
				config.root_dir = root
				config.cmd = M.command(root)
				vim.lsp.start(config, {
					bufnr = buf,
					reuse_client = function()
						return false
					end,
				})
			end
		end
	end, 100)
end

local function update(root, source, directory)
	root = canonical(root)
	if not root then
		return false, "invalid project root"
	end
	local validated, err = M.validate_compile_commands(directory)
	if not validated then
		return false, err
	end
	roots[root] = roots[root] or {}
	if roots[root][source] == validated then
		return true
	end
	roots[root][source] = validated
	M.restart_root(root)
	vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
	return true
end

function M.set_cmake(root, directory)
	return update(root, "cmake", directory)
end

function M.set_manual(root, directory)
	return update(root, "manual", directory)
end

function M.status(root)
	root = canonical(root)
	local state = root and roots[root] or nil
	return {
		profile = M.profile(),
		directory = state and (state.manual or state.cmake) or nil,
		source = state and (state.manual and "manual" or state.cmake and "cmake" or nil) or nil,
	}
end

M._roots = roots

return M
