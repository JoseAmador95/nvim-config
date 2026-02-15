local M = {}

-- === LSP actions you already asked for ===
function M.CodeActions()
	vim.lsp.buf.code_action()
end

-- === Extra helpers you might want from earlier steps ===
-- Toggle inline diagnostics (virtual text) on/off
function M.ToggleInlineDiagnostics()
	local cfg = vim.diagnostic.config()
	local current = cfg.virtual_text
	-- `virtual_text` may be a table or boolean; normalize to boolean
	local enabled = (type(current) == "table") and true or (current ~= false)
	vim.diagnostic.config({ virtual_text = not enabled })
	print("Inline diagnostics: " .. ((not enabled) and "ON" or "OFF"))
end

-- Show diagnostics at cursor in a small float
function M.ShowDiagnosticsFloat()
	vim.diagnostic.open_float(nil, { border = "rounded", focusable = false })
end

-- Next/prev diagnostic
function M.NextDiagnostic()
	vim.diagnostic.goto_next()
end

function M.PrevDiagnostic()
	vim.diagnostic.goto_prev()
end

-- Toggle inlay hints (handy for C/C++)
function M.ToggleInlayHints()
	local buf = vim.api.nvim_get_current_buf()
	local currently = vim.lsp.inlay_hint.is_enabled({ bufnr = buf })
	vim.lsp.inlay_hint.enable(not currently, { bufnr = buf })
	print("Inlay hints: " .. ((not currently) and "ON" or "OFF"))
end

return M
