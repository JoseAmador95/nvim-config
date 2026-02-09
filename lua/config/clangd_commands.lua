vim.api.nvim_create_user_command("ClangdSetCompileCommands", function(opts)
	local dir = vim.fn.fnamemodify(opts.args, ":p")
	local devcontainer_tools = require("config.devcontainer_tools")

	-- Stop all running clangd clients (new API: vim.lsp.get_clients)
	for _, client in ipairs(vim.lsp.get_clients()) do
		if client.name == "clangd" then
			vim.lsp.stop_client(client.id)
		end
	end

	-- Re-register clangd with the new compilation database directory
	vim.lsp.config("clangd", {
		cmd = devcontainer_tools.clangd_cmd({
			"--compile-commands-dir=" .. dir, -- official clangd flag
			"--background-index",
			"--cross-file-rename",
			"--completion-style=detailed",
			"--header-insertion=never",
		}),
	})

	-- Re-enable clangd so it attaches again
	vim.lsp.enable("clangd")

	print("clangd now using compile_commands from: " .. dir)
end, {
	nargs = 1,
	complete = "dir",
	desc = "Point clangd to a custom compile_commands.json directory",
})
