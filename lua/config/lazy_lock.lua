-- Resolve Lazy's writable lockfile per runtime profile. The editor owns the
-- committed source of truth. The pager has only a small plugin allowlist, so
-- giving Lazy the editor lock directly would let it prune unrelated entries.
local M = {}

local fs = require("config.fs")

function M.source(repo_root)
	return vim.fs.joinpath(repo_root, "lazy-lock.json")
end

---@param repo_root string
---@param pager_active boolean
---@param options? { state_root?: string }
---@return string lockfile
function M.resolve(repo_root, pager_active, options)
	local source = M.source(repo_root)
	if not pager_active then
		return source
	end

	local data, read_err = fs.read_binary(source)
	if not data then
		error("Could not read the editor plugin lockfile: " .. tostring(read_err))
	end

	local state_root = options and options.state_root or vim.fn.stdpath("state")
	local directory = vim.fs.joinpath(state_root, "nvim-config")
	vim.fn.mkdir(directory, "p", tonumber("700", 8))
	pcall(vim.uv.fs_chmod, directory, tonumber("700", 8))
	local identity = vim.fn.sha256(vim.fs.normalize(source)):sub(1, 16)
	local target = vim.fs.joinpath(directory, "pager-lazy-lock-" .. identity .. ".json")
	local written, write_err = fs.write_binary_atomic(target, data)
	if not written then
		error("Could not prepare the pager plugin lockfile: " .. tostring(write_err))
	end
	return target
end

return M
