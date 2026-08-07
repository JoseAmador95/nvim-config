local M = {}

local FLAGS = {
	"--background-index",
	"--clang-tidy",
	"--cross-file-rename",
	"--completion-style=detailed",
	"--header-insertion=never",
}

function M.command(compile_commands_dir)
	local config = require("config.local_config").get("clangd", {})
	local executable = config.path
	if not executable or executable == "" then
		executable = "clangd"
	end
	executable = vim.fn.expand(executable)

	local command = { executable }
	if compile_commands_dir then
		command[#command + 1] = "--compile-commands-dir=" .. compile_commands_dir
	end
	vim.list_extend(command, FLAGS)
	return command
end

function M.validate_compile_commands(directory)
	local expanded = vim.fn.fnamemodify(vim.fn.expand(directory), ":p")
	expanded = vim.fs.normalize(expanded)
	if vim.fn.isdirectory(expanded) ~= 1 then
		return nil, "not a directory: " .. expanded
	end

	local database = vim.fs.joinpath(expanded, "compile_commands.json")
	if vim.fn.filereadable(database) ~= 1 then
		return nil, "compile_commands.json not found in " .. expanded
	end
	local read_ok, lines = pcall(vim.fn.readfile, database)
	if not read_ok then
		return nil, "could not read " .. database .. ": " .. tostring(lines)
	end
	local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decode_ok or not vim.islist(decoded) then
		return nil, "invalid compile_commands.json in " .. expanded .. " (expected a JSON array)"
	end
	return expanded
end

return M
