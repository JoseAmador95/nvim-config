-- Resolve Lazy's writable lockfile per runtime profile. The editor owns the
-- committed source of truth. The pager has only a small plugin allowlist, so
-- giving Lazy the editor lock directly would let it prune unrelated entries.
local M = {}

local fs = require("config.fs")

local function read_lock(path)
	local data, read_err = fs.read_binary(path)
	if not data then
		return nil, read_err
	end

	local ok, lock = pcall(vim.json.decode, data)
	if not ok or type(lock) ~= "table" then
		return nil, "invalid JSON: " .. tostring(lock)
	end
	return lock
end

function M.source(repo_root)
	return vim.fs.joinpath(repo_root, "lazy-lock.json")
end

local function runtime_source(repo_root)
	local override = vim.env.NVIM_CONFIG_LAZY_LOCKFILE
	if not override or override == "" then
		return M.source(repo_root)
	end
	if override:sub(1, 1) ~= "/" then
		error("NVIM_CONFIG_LAZY_LOCKFILE must be an absolute path")
	end
	override = vim.fs.normalize(override)
	local stat = vim.uv.fs_stat(override)
	if not stat or stat.type ~= "file" then
		error("NVIM_CONFIG_LAZY_LOCKFILE is not a readable file: " .. override)
	end
	return override
end

---@param repo_root string
---@param name string
---@return { branch: string, commit: string }? entry
---@return string? error
function M.plugin(repo_root, name)
	local source = M.source(repo_root)
	local lock, lock_err = read_lock(source)
	if not lock then
		return nil, ("cannot read %s: %s"):format(source, tostring(lock_err))
	end

	local entry = lock[name]
	if type(entry) ~= "table" then
		return nil, ("%s has no entry for %s"):format(source, name)
	end
	if type(entry.branch) ~= "string" or entry.branch == "" then
		return nil, ("%s has no branch for %s"):format(source, name)
	end
	if type(entry.commit) ~= "string" or not entry.commit:match("^[0-9a-f][0-9a-f]+$") or #entry.commit ~= 40 then
		return nil, ("%s has no full 40-character commit for %s"):format(source, name)
	end

	return { branch = entry.branch, commit = entry.commit }
end

---@param repo_root string
---@param pager_active boolean
---@param options? { state_root?: string }
---@return string lockfile
function M.resolve(repo_root, pager_active, options)
	local source = runtime_source(repo_root)
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
