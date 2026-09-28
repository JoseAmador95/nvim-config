local M = {}
local inline_diagnostics = require("config.inline_diagnostics")

local function notify(msg)
	vim.notify(msg, vim.log.levels.INFO, { title = "LSP" })
end

-- === LSP actions you already asked for ===
function M.CodeActions()
	vim.lsp.buf.code_action()
end

-- === Extra helpers you might want from earlier steps ===
-- Toggle the configured inline-diagnostic presenter on/off.
function M.ToggleInlineDiagnostics()
	local mode, err = inline_diagnostics.toggle()
	if not mode then
		vim.notify("Could not toggle inline diagnostics: " .. tostring(err), vim.log.levels.ERROR, { title = "LSP" })
		return
	end
	notify("Inline diagnostics: " .. mode)
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
