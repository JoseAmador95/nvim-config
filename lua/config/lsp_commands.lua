local H = require("config.lsp_helpers")

-- Code Actions
vim.api.nvim_create_user_command("CodeActions", function()
	H.CodeActions()
end, { desc = "Show LSP code actions" })

-- Format current buffer
vim.api.nvim_create_user_command("FormatFile", function()
	H.FormatFile()
end, { desc = "Format current buffer via LSP" })

-- Toggle inline diagnostics (virtual text)
vim.api.nvim_create_user_command("ToggleInlineDiagnostics", function()
	H.ToggleInlineDiagnostics()
end, { desc = "Toggle inline diagnostics (virtual text)" })

-- Show diagnostics in a floating tooltip at cursor
vim.api.nvim_create_user_command("DiagFloat", function()
	H.ShowDiagnosticsFloat()
end, { desc = "Show diagnostics at cursor in floating window" })

-- Next / Prev diagnostic
vim.api.nvim_create_user_command("DiagNext", function()
	H.NextDiagnostic()
end, { desc = "Jump to next diagnostic" })

vim.api.nvim_create_user_command("DiagPrev", function()
	H.PrevDiagnostic()
end, { desc = "Jump to previous diagnostic" })

-- Toggle inlay hints
vim.api.nvim_create_user_command("ToggleInlayHints", function()
	H.ToggleInlayHints()
end, { desc = "Toggle LSP inlay hints for current buffer" })

-- Point clangd to a compile_commands directory (with :command completion)
vim.api.nvim_create_user_command("ClangdSetCompileCommands", function(opts)
	H.ClangdSetCompileCommands(opts.args)
end, {
	nargs = 1,
	complete = "dir",
	desc = "Point clangd to a compile_commands.json directory",
})
