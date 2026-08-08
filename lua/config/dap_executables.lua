local M = {}

function M.mason_bin_dir()
	return require("config.tool_paths").mason_bin()
end

-- Prefer a real executable from PATH (including Mason's bin directory, which
-- init.lua prepends). Keep a deterministic future Mason path during the first
-- install so adapters work after Mason finishes without a config reload.
function M.resolve(name)
	local resolved = vim.fn.exepath(name)
	if resolved ~= "" then
		return resolved, true
	end
	return vim.fs.joinpath(M.mason_bin_dir(), name), false
end

return M
