local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP" })
end

function M.set_compile_commands(argument)
	local clangd = require("config.clangd")
	local directory, validation_error = clangd.validate_compile_commands(argument)
	if not directory then
		notify("clangd compile database rejected: " .. validation_error, vim.log.levels.ERROR)
		return false
	end

	-- Validation deliberately happens before touching any healthy clients.
	for _, client in ipairs(vim.lsp.get_clients()) do
		if client.name == "clangd" then
			client:stop()
		end
	end

	vim.lsp.config("clangd", { cmd = clangd.command(directory) })
	vim.lsp.enable("clangd")
	notify("clangd now using compile_commands from: " .. directory)
	return true
end

function M.setup()
	vim.api.nvim_create_user_command("ClangdSetCompileCommands", function(opts)
		M.set_compile_commands(opts.args)
	end, {
		nargs = 1,
		complete = "dir",
		desc = "Point clangd to a validated compile_commands.json directory",
	})
end

M.setup()

return M
