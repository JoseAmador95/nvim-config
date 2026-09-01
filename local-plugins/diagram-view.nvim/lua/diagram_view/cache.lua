local M = {}

local uv = vim.uv
local bit = require("bit")
local ffi = require("ffi")
local DIRECTORY_MODE = 448 -- 0700
local FILE_MODE = 384 -- 0600
local DEFAULT_MAX_AGE = 30 * 24 * 60 * 60
local DEFAULT_MAX_BYTES = 256 * 1024 * 1024
local MAX_ENTRY_BYTES = 256 * 1024 * 1024

local declared, declare_err = pcall(
	ffi.cdef,
	[[
		int openat(int dirfd, const char *pathname, int flags, ...);
		int unlinkat(int dirfd, const char *pathname, int flags);
		int renameatx_np(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
		int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
	]]
)
if not declared and tostring(declare_err):find("redefin", 1, true) then
	declared = true
end

local descriptor_api
if declared and ffi.abi("64bit") then
	local system = uv.os_uname().sysname
	if system == "Darwin" then
		descriptor_api = {
			at_fdcwd = -2,
			close_on_exec = 0x01000000,
			directory = 0x00100000,
			nonblock = 0x00000004,
			no_follow = 0x00000100,
			rename = "renameatx_np",
			rename_noreplace_flag = 0x00000004,
			eexist = 17,
			noent = 2,
		}
	elseif system == "Linux" then
		descriptor_api = {
			at_fdcwd = -100,
			close_on_exec = 0x00080000,
			directory = 0x00010000,
			nonblock = 0x00000800,
			no_follow = 0x00020000,
			rename = "renameat2",
			rename_noreplace_flag = 0x00000001,
			eexist = 17,
			noent = 2,
		}
	end
end

local state = {
	root = nil,
	max_age = DEFAULT_MAX_AGE,
	max_bytes = DEFAULT_MAX_BYTES,
	live = {},
	retire_counter = 0,
	test_hook = nil,
}

local function identity_part(value)
	return tostring(value):gsub("ULL$", ""):gsub("LL$", "")
end

local function same_identity(left, right)
	return left
		and right
		and left.type == right.type
		and identity_part(left.dev) == identity_part(right.dev)
		and identity_part(left.ino) == identity_part(right.ino)
end

local function owned_file(actual, expected)
	return same_identity(actual, expected)
		and actual.type == "file"
		and actual.nlink == 1
		and expected.nlink == 1
		and actual.size == expected.size
		and actual.mode == expected.mode
end

local function close_fd(fd)
	if fd then
		pcall(uv.fs_close, fd)
	end
end

local function open_root_anchor()
	if not descriptor_api then
		return nil, "descriptor-relative cache cleanup requires 64-bit Darwin or Linux"
	end
	local before = uv.fs_lstat(state.root)
	if not before or before.type ~= "directory" then
		return nil, "cache root is not a real directory"
	end
	local flags = bit.bor(
		descriptor_api.directory,
		descriptor_api.nonblock,
		descriptor_api.no_follow,
		descriptor_api.close_on_exec
	)
	local raw = ffi.C.openat(descriptor_api.at_fdcwd, state.root, flags)
	if raw < 0 then
		return nil, "could not pin cache root: errno " .. tostring(ffi.errno())
	end
	local fd = tonumber(raw)
	local opened = uv.fs_fstat(fd)
	local current = uv.fs_lstat(state.root)
	if
		not opened
		or opened.type ~= "directory"
		or not same_identity(before, opened)
		or not same_identity(opened, current)
	then
		close_fd(fd)
		return nil, "cache root changed while it was pinned"
	end
	return { fd = fd, identity = opened }
end

local function anchor_valid(anchor)
	local opened = anchor and anchor.fd and uv.fs_fstat(anchor.fd) or nil
	local current = state.root and uv.fs_lstat(state.root) or nil
	return same_identity(opened, anchor and anchor.identity) and same_identity(opened, current)
end

local function open_anchored_file(anchor, name)
	if not anchor_valid(anchor) then
		return nil, "cache root changed before file inspection"
	end
	local flags = bit.bor(descriptor_api.nonblock, descriptor_api.no_follow, descriptor_api.close_on_exec)
	local raw = ffi.C.openat(anchor.fd, name, flags)
	if raw < 0 then
		local number = ffi.errno()
		if number == descriptor_api.noent then
			return false
		end
		return nil, "could not inspect anchored cache entry: errno " .. tostring(number)
	end
	local fd = tonumber(raw)
	local info = uv.fs_fstat(fd)
	close_fd(fd)
	if not info or info.type ~= "file" then
		return nil, "anchored cache entry is not a regular file"
	end
	return info
end

local function exclusive_rename(anchor, source, destination)
	if not anchor_valid(anchor) then
		return nil, "cache root changed before reservation", -1
	end
	local ok, result = pcall(function()
		if descriptor_api.rename == "renameatx_np" then
			return ffi.C.renameatx_np(anchor.fd, source, anchor.fd, destination, descriptor_api.rename_noreplace_flag)
		end
		return ffi.C.renameat2(anchor.fd, source, anchor.fd, destination, descriptor_api.rename_noreplace_flag)
	end)
	if not ok then
		return nil, "exclusive cache reservation is unavailable: " .. tostring(result), -1
	end
	if result == 0 then
		return true
	end
	local number = ffi.errno()
	return nil, "could not reserve cache entry: errno " .. tostring(number), number
end

local function run_test_hook(event, details)
	if type(state.test_hook) ~= "function" then
		return true
	end
	local ok, err = pcall(state.test_hook, event, vim.deepcopy(details))
	return ok and true or nil, ok and nil or tostring(err)
end

local function close_anchor(anchor)
	if anchor_valid(anchor) then
		pcall(uv.fs_fsync, anchor.fd)
	end
	close_fd(anchor.fd)
	anchor.fd = nil
end

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

local function conditional_remove(path, expected)
	if type(path) ~= "string" or vim.fs.dirname(vim.fs.normalize(path)) ~= state.root then
		return nil, "cache cleanup path escapes its pinned root"
	end
	local name = vim.fs.basename(path)
	if not safe_component(name, "cache cleanup entry") then
		return nil, "cache cleanup entry has an unsafe name"
	end
	if not expected or expected.type ~= "file" then
		return nil, "cache cleanup requires an exact regular-file identity"
	end
	local anchor, anchor_err = open_root_anchor()
	if not anchor then
		return nil, anchor_err
	end
	local current, current_err = open_anchored_file(anchor, name)
	if current == false then
		close_anchor(anchor)
		return true
	end
	if not current or not owned_file(current, expected) then
		close_anchor(anchor)
		return nil, current_err or "cache entry identity changed before cleanup"
	end
	local reserved
	for _ = 1, 64 do
		state.retire_counter = state.retire_counter + 1
		reserved = (".%s.retire.%d.%d"):format(name, uv.os_getpid(), state.retire_counter)
		local moved, move_err, number = exclusive_rename(anchor, name, reserved)
		if moved then
			break
		end
		if number == descriptor_api.noent then
			close_anchor(anchor)
			return true
		end
		if number ~= descriptor_api.eexist then
			close_anchor(anchor)
			return nil, move_err
		end
		reserved = nil
	end
	if not reserved then
		close_anchor(anchor)
		return nil, "cache cleanup reservation namespace is exhausted"
	end
	local hook_ok, hook_err = run_test_hook("after_cleanup_reserve", {
		path = path,
		reserved = vim.fs.joinpath(state.root, reserved),
	})
	if not hook_ok then
		close_anchor(anchor)
		return nil, "cache cleanup hook failed; reserved entry preserved: " .. tostring(hook_err)
	end
	local reserved_info, reserved_err = open_anchored_file(anchor, reserved)
	if not reserved_info or not owned_file(reserved_info, expected) then
		close_anchor(anchor)
		return nil, reserved_err or "reserved cache entry identity changed; it was preserved"
	end
	hook_ok, hook_err = run_test_hook("before_cleanup_unlink", {
		path = path,
		reserved = vim.fs.joinpath(state.root, reserved),
	})
	if not hook_ok then
		close_anchor(anchor)
		return nil, "cache cleanup hook failed; reserved entry preserved: " .. tostring(hook_err)
	end
	reserved_info, reserved_err = open_anchored_file(anchor, reserved)
	if not reserved_info or not owned_file(reserved_info, expected) then
		close_anchor(anchor)
		return nil, reserved_err or "reserved cache entry changed at the cleanup boundary"
	end
	if ffi.C.unlinkat(anchor.fd, reserved, 0) ~= 0 then
		local number = ffi.errno()
		close_anchor(anchor)
		return nil, "could not unlink reserved cache entry: errno " .. tostring(number)
	end
	close_anchor(anchor)
	return true
end

function M.remove(path, expected)
	return conditional_remove(path, expected)
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
	if validate then
		local valid_ok, valid = pcall(validate, data)
		if not valid_ok or not valid then
			return nil, "cached renderer output is invalid", path, opened
		end
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
		if kind == "file" and not name:find(".tmp.", 1, true) and not name:find(".retire.", 1, true) then
			local path = vim.fs.joinpath(state.root, name)
			local info = uv.fs_lstat(path)
			if info and info.type == "file" and not state.live[path] then
				local entry = { path = path, size = info.size or 0, mtime = mtime_seconds(info), identity = info }
				if now - entry.mtime > state.max_age then
					conditional_remove(path, entry.identity)
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
			if not state.live[entry.path] and conditional_remove(entry.path, entry.identity) then
				total = total - entry.size
			end
		end
	end
	return true
end

function M.root()
	return state.root
end

function M._set_test_hook(callback)
	state.test_hook = callback
end

return M
