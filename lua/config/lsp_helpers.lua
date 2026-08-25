local M = {}

local function notify(msg)
	vim.notify(msg, vim.log.levels.INFO, { title = "LSP" })
end

-- === LSP actions you already asked for ===
function M.CodeActions()
	vim.lsp.buf.code_action()
end

-- === Extra helpers you might want from earlier steps ===
-- Toggle current-line inline diagnostics on/off
function M.ToggleInlineDiagnostics()
	local config = vim.diagnostic.config()
	local enabled = type(config.virtual_lines) == "table" or config.virtual_lines == true
	local virtual_lines = false
	if not enabled then
		virtual_lines = { current_line = true }
	end
	vim.diagnostic.config({
		virtual_lines = virtual_lines,
	})
	notify("Inline diagnostics: " .. (enabled and "OFF" or "ON"))
end

-- Show diagnostics at cursor in a small float
function M.ShowDiagnosticsFloat()
	vim.diagnostic.open_float({ border = "rounded", focusable = false })
end

-- Next/prev diagnostic
function M.NextDiagnostic()
	vim.diagnostic.jump({ count = 1 })
end

function M.PrevDiagnostic()
	vim.diagnostic.jump({ count = -1 })
end

-- Toggle inlay hints (handy for C/C++)
function M.ToggleInlayHints()
	local buf = vim.api.nvim_get_current_buf()
	local currently = vim.lsp.inlay_hint.is_enabled({ bufnr = buf })
	vim.lsp.inlay_hint.enable(not currently, { bufnr = buf })
	notify("Inlay hints: " .. ((not currently) and "ON" or "OFF"))
end

return M
