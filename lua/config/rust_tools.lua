local M = {}

local missing_analyzer_notified = false

M._notify = function(message, level)
	vim.notify(message, level, { title = "Rust" })
end

function M.external_executable(name)
	return require("config.tool_paths").external_executable(name)
end

function M.rust_analyzer()
	return M.external_executable("rust-analyzer")
end

function M.notify_missing_analyzer()
	if missing_analyzer_notified or M.rust_analyzer() then
		return false
	end
	missing_analyzer_notified = true
	M._notify(
		"rust-analyzer was not found in host/user PATH; Rust remains edit-only. Install it outside Mason, then restart. See :checkhealth nvimconfig.",
		vim.log.levels.WARN
	)
	return true
end

function M.setup_missing_analyzer_notice(analyzer_path)
	local group = vim.api.nvim_create_augroup("NvimConfigRustTools", { clear = true })
	if analyzer_path then
		return
	end
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "rust",
		callback = M.notify_missing_analyzer,
		desc = "Explain edit-only Rust support when rust-analyzer is external and missing",
	})
end

function M._reset_for_tests()
	missing_analyzer_notified = false
end

return M
