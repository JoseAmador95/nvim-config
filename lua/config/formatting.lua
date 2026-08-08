local M = {}

M._notify = function(message, level)
	vim.notify_once(message, level, { title = "Format" })
end

local function conform_or_notify()
	local ok, conform = pcall(require, "conform")
	if ok then
		return conform
	end
	M._notify("Conform is not available; no formatter was run", vim.log.levels.WARN)
	return nil
end

local function has_formatter(conform, bufnr)
	if #conform.list_formatters(bufnr) > 0 then
		return true
	end
	local ft = vim.bo[bufnr].filetype
	M._notify(
		("No external formatter is available for %s; LSP formatting is disabled"):format(
			ft ~= "" and ft or "this buffer"
		),
		vim.log.levels.WARN
	)
	return false
end

function M.on_save(bufnr)
	local conform = conform_or_notify()
	if not conform or not has_formatter(conform, bufnr) then
		return nil
	end
	return { timeout_ms = 2000, lsp_format = "never" }
end

function M.format(opts)
	opts = opts or {}
	local conform = conform_or_notify()
	local bufnr = opts.bufnr or 0
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	if not conform or not has_formatter(conform, bufnr) then
		return false
	end

	local format_opts = vim.tbl_extend("force", {}, opts, {
		bufnr = bufnr,
		lsp_format = "never",
	})
	return conform.format(format_opts) ~= false
end

return M
