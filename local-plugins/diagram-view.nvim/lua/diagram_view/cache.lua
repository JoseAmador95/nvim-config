local M = {}

local uv = vim.uv
local DIRECTORY_MODE = 448 -- 0700
local FILE_MODE = 384 -- 0600
local DEFAULT_MAX_AGE = 30 * 24 * 60 * 60
local DEFAULT_MAX_BYTES = 256 * 1024 * 1024
local MAX_ENTRY_BYTES = 256 * 1024 * 1024

local state = {
	root = nil,
	max_age = DEFAULT_MAX_AGE,
	max_bytes = DEFAULT_MAX_BYTES,
	live = {},
}

local function lstat(path)
	local info, err = uv.fs_lstat(path)
	if not info and err and not tostring(err):find("ENOENT", 1, true) then
		return nil, err
	end
	return info
end

local function safe_component(value, label)
	if type(value) ~= "string" or value == "" or value:find("[^%w_.%-]") then
		return nil, label .. " contains unsupported characters"
	end
	return value
end

local function ensure_root()
	local info, err = lstat(state.root)
	if err then
		return nil, "could not inspect cache root: " .. tostring(err)
	end
	if info then
		if info.type ~= "directory" then
			return nil, "cache root must be a real directory"
		end
		local secured, chmod_err = uv.fs_chmod(state.root, DIRECTORY_MODE)
		if not secured then
			return nil, "could not secure cache root: " .. tostring(chmod_err)
		end
		return true
	end
	local parent = vim.fs.dirname(state.root)
	local parent_info, parent_err = lstat(parent)
	if parent_err then
		return nil, "could not inspect cache parent: " .. tostring(parent_err)
	end
	if not parent_info or parent_info.type ~= "directory" then
		return nil, "cache parent must be an existing real directory"
	end
	local created, mkdir_err = uv.fs_mkdir(state.root, DIRECTORY_MODE)
	if not created then
		return nil, "could not create cache root: " .. tostring(mkdir_err)
	end
	return true
end

function M.setup(opts)
	if type(opts) ~= "table" or type(opts.root) ~= "string" or opts.root == "" or opts.root:find("\0", 1, true) then
		return nil, "cache root must be a non-empty path"
	end
	local root = vim.fs.normalize(opts.root)
	if root:sub(1, 1) ~= "/" then
		return nil, "cache root must be absolute"
	end
	state.root = root
	state.max_age = math.max(1, math.floor(tonumber(opts.max_age_seconds) or DEFAULT_MAX_AGE))
	state.max_bytes = math.max(1, math.floor(tonumber(opts.max_bytes) or DEFAULT_MAX_BYTES))
	state.live = {}
	return true
end

function M.path(key, extension)
	if not state.root then
		return nil, "cache is not configured"
	end
	local safe_key, key_err = safe_component(key, "cache key")
	if not safe_key then
		return nil, key_err
	end
	local safe_extension, extension_err = safe_component(extension, "cache extension")
	if not safe_extension then
		return nil, extension_err
	end
	return vim.fs.joinpath(state.root, safe_key .. "." .. safe_extension)
end

local function inspect_file(path)
	local info, err = lstat(path)
	if err then
		return nil, "could not inspect cache entry: " .. tostring(err)
	end
	if info and info.type ~= "file" then
		return nil, "cache entry must be a regular file"
	end
	return info or false
end

function M.read(key, extension, validate)
	local root_ok, root_err = ensure_root()
	if not root_ok then
		return nil, root_err
	end
	local path, path_err = M.path(key, extension)
	if not path then
		return nil, path_err
	end
	local info, inspect_err = inspect_file(path)
	if inspect_err then
		return nil, inspect_err
	end
	if not info then
		return nil, nil, path
	end
	if info.size > MAX_ENTRY_BYTES then
		return nil, "cache entry exceeds the 256 MiB limit"
	end
	local fd, open_err = uv.fs_open(path, "r", FILE_MODE)
	if not fd then
		return nil, "could not open cache entry: " .. tostring(open_err)
	end
	local opened, stat_err = uv.fs_fstat(fd)
	local current = uv.fs_lstat(path)
	if
		not opened
		or opened.type ~= "file"
		or not current
		or current.type ~= "file"
		or opened.dev ~= info.dev
		or opened.ino ~= info.ino
		or current.dev ~= opened.dev
		or current.ino ~= opened.ino
	then
		uv.fs_close(fd)
		return nil, "cache entry changed while opening: " .. tostring(stat_err or "identity mismatch")
	end
	if opened.size > MAX_ENTRY_BYTES then
		uv.fs_close(fd)
		return nil, "cache entry exceeds the 256 MiB limit"
	end
	local secured, chmod_err = uv.fs_fchmod(fd, FILE_MODE)
	if not secured then
		uv.fs_close(fd)
		return nil, "could not secure cache entry: " .. tostring(chmod_err)
	end
	local data, read_err = uv.fs_read(fd, opened.size, 0)
	local now = os.time()
	pcall(uv.fs_futime, fd, now, now)
	local closed, close_err = uv.fs_close(fd)
	if not data then
		return nil, "could not read cache entry: " .. tostring(read_err)
	end
	if not closed then
		return nil, "could not close cache entry: " .. tostring(close_err)
	end
	local final = uv.fs_lstat(path)
	if not final or final.type ~= "file" or final.dev ~= opened.dev or final.ino ~= opened.ino then
		return nil, "cache entry changed while reading"
	end
	if validate and not validate(data) then
		return nil, "cached renderer output is invalid", path
	end
	return data, nil, path
end

local function temporary_path(path)
	return path .. (".tmp.%d.%d"):format(uv.os_getpid(), uv.hrtime())
end

function M.write(key, extension, data)
	if type(data) ~= "string" then
		return nil, "cache data must be a string"
	end
	if #data > MAX_ENTRY_BYTES then
		return nil, "cache data exceeds the 256 MiB limit"
	end
	local root_ok, root_err = ensure_root()
	if not root_ok then
		return nil, root_err
	end
	local path, path_err = M.path(key, extension)
	if not path then
		return nil, path_err
	end
	local _, inspect_err = inspect_file(path)
	if inspect_err then
		return nil, inspect_err
	end
	local temporary = temporary_path(path)
	local fd, open_err = uv.fs_open(temporary, "wx", FILE_MODE)
	if not fd then
		return nil, "could not create temporary cache entry: " .. tostring(open_err)
	end
	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			uv.fs_close(fd)
			uv.fs_unlink(temporary)
			return nil, "could not write temporary cache entry: " .. tostring(write_err)
		end
		offset = offset + written
	end
	local secured, chmod_err = uv.fs_fchmod(fd, FILE_MODE)
	local written_info, stat_err = uv.fs_fstat(fd)
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if not secured or not written_info or not synced or not closed then
		uv.fs_unlink(temporary)
		return nil,
			"could not secure or flush temporary cache entry: " .. tostring(
				chmod_err or stat_err or sync_err or close_err
			)
	end
	local _, recheck_err = inspect_file(path)
	if recheck_err then
		uv.fs_unlink(temporary)
		return nil, recheck_err
	end
	local replaced, rename_err = uv.fs_rename(temporary, path)
	if not replaced then
		uv.fs_unlink(temporary)
		return nil, "could not replace cache entry atomically: " .. tostring(rename_err)
	end
	local final = uv.fs_lstat(path)
	if not final or final.type ~= "file" or final.dev ~= written_info.dev or final.ino ~= written_info.ino then
		return nil, "cache entry changed while replacing"
	end
	return path
end

function M.retain(path)
	if path then
		state.live[path] = (state.live[path] or 0) + 1
	end
end

function M.release(path)
	if not path or not state.live[path] then
		return
	end
	state.live[path] = state.live[path] - 1
	if state.live[path] <= 0 then
		state.live[path] = nil
	end
end

local function mtime_seconds(info)
	if type(info.mtime) == "table" then
		return tonumber(info.mtime.sec) or 0
	end
	return tonumber(info.mtime) or 0
end

function M.prune()
	local root_ok, root_err = ensure_root()
	if not root_ok then
		return nil, root_err
	end
	local scanner = uv.fs_scandir(state.root)
	if not scanner then
		return true
	end
	local entries = {}
	local total = 0
	local now = os.time()
	while true do
		local name, kind = uv.fs_scandir_next(scanner)
		if not name then
			break
		end
		if kind == "file" and not name:find(".tmp.", 1, true) then
			local path = vim.fs.joinpath(state.root, name)
			local info = uv.fs_lstat(path)
			if info and info.type == "file" and not state.live[path] then
				local entry = { path = path, size = info.size or 0, mtime = mtime_seconds(info) }
				if now - entry.mtime > state.max_age then
					pcall(uv.fs_unlink, path)
				else
					entries[#entries + 1] = entry
					total = total + entry.size
				end
			end
		end
	end
	if total > state.max_bytes then
		table.sort(entries, function(left, right)
			if left.mtime == right.mtime then
				return left.path < right.path
			end
			return left.mtime < right.mtime
		end)
		for _, entry in ipairs(entries) do
			if total <= state.max_bytes then
				break
			end
			if not state.live[entry.path] and uv.fs_unlink(entry.path) then
				total = total - entry.size
			end
		end
	end
	return true
end

function M.root()
	return state.root
end

return M
