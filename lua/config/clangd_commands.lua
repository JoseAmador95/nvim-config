vim.api.nvim_create_user_command("ClangdSetCompileCommands", function(opts)
	local dir = vim.fn.fnamemodify(opts.args, ":p")

	-- Stop all running clangd clients
	for _, client in ipairs(vim.lsp.get_clients()) do
		if client.name == "clangd" then
			vim.lsp.stop_client(client.id)
		end
	end

	-- Re-register clangd with the new compilation database directory
	vim.lsp.config("clangd", {
		cmd = {
			"clangd",
			"--compile-commands-dir=" .. dir,
			"--background-index",
			"--cross-file-rename",
			"--completion-style=detailed",
			"--header-insertion=never",
		},
	})

	-- Re-enable clangd so it attaches again
	vim.lsp.enable("clangd")

	vim.notify("clangd now using compile_commands from: " .. dir, vim.log.levels.INFO, { title = "LSP" })
end, {
	nargs = 1,
	complete = "dir",
	desc = "Point clangd to a custom compile_commands.json directory",
})
