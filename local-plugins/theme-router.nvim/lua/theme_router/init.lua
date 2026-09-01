local M = {}

local STATE_VERSION = 1
local MAX_STATE_BYTES = 64 * 1024
local FILE_MODE = 384 -- 0600
local DIRECTORY_MODE = 448 -- 0700
local MARKER_CONTENTS = "version: 1\n"
local LOCK_FILE = ".theme-router.lock"
local LOCK_WAIT_MILLISECONDS = 250
local LOCK_POLL_MILLISECONDS = 5

local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	pcall(
		ffi.cdef,
		[[
			int fcntl(int fd, int cmd, ...);
			int flock(int fd, int operation);
			unsigned int getuid(void);
			int openat(int fd, const char *path, int flags, ...);
			int mkdirat(int fd, const char *path, unsigned int mode);
			int renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int renameatx_np(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int unlinkat(int fd, const char *path, int flags);
		]]
	)
end

local SYSTEM = uv.os_uname().sysname
local DARWIN_F_GETPATH = 50
local DARWIN_PATH_BYTES = 1024
local OPEN_FLAGS = SYSTEM == "Darwin"
		and {
			at_fdcwd = -2,
			create = 512,
			directory = 1048576,
			exclusive = 2048,
			close_on_exec = 16777216,
			nonblock = 4,
			no_follow = 256,
			write_only = 1,
		}
	or {
		at_fdcwd = -100,
		create = 64,
		directory = 65536,
		exclusive = 128,
		close_on_exec = 524288,
		nonblock = 2048,
		no_follow = 131072,
		write_only = 1,
	}

local LOCK_EXCLUSIVE = 2
local LOCK_NONBLOCKING = 4
local LOCK_UNLOCK = 8

local state = {
	configured = false,
	opts = nil,
	painters = {},
	selection = nil,
	active = nil,
	last_known_good = nil,
}
local test_hook

local SETUP_KEYS = {
	state_path = true,
	legacy_path = true,
	default = true,
	fallback = true,
	notify = true,
	event = true,
	on_state_change = true,
	paint = true,
	context = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function exact_options(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains an unknown option: " .. tostring(key)
		end
	end
	return true
end

local function nonempty_string(value, label)
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, label .. " must be a non-empty string without NUL bytes"
	end
	return value
end

local function colorscheme_name(value, label)
	local name, err = nonempty_string(value, label)
	if not name then
		return nil, err
	end
	if name:find("[^%w_.@+/%-]") then
		return nil, label .. " contains unsupported characters"
	end
	return name
end

local function notify(message, level)
	if not state.opts or not state.opts.notify then
		return
	end
	pcall(state.opts.notify, message, level)
end

local function emit(kind, details)
	if not state.opts then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	local callbacks = { state.opts.event, state.opts.on_state_change }
	for index = 1, 2 do
		local callback = callbacks[index]
		if type(callback) == "function" then
			local ok, err = pcall(callback, copy(event))
			if not ok then
				notify("Theme event callback failed: " .. tostring(err), vim.log.levels.WARN)
			end
		end
	end
end

local function run_test_hook(phase, details)
	if not test_hook then
		return true
	end
	local ok, err = pcall(test_hook, phase, copy(details or {}))
	return ok and true or nil, ok and nil or tostring(err)
end

local function append_warning(current, warning)
	if not warning or warning == "" then
		return current
	end
	if not current or current == "" then
		return tostring(warning)
	end
	return tostring(current) .. "; " .. tostring(warning)
end

local function lstat(path)
	local info, err = uv.fs_lstat(path)
	if not info and err and not tostring(err):find("ENOENT", 1, true) then
		return nil, err
	end
	return info
end

local function same_time(left, right)
	left = left or {}
	right = right or {}
	return left.sec == right.sec and left.nsec == right.nsec
end

local function same_object(left, right, kind)
	return left
		and right
		and left.type == kind
		and right.type == kind
		and left.dev == right.dev
		and left.ino == right.ino
end

local function same_file_snapshot(left, right)
	return same_object(left, right, "file")
		and left.size == right.size
		and same_time(left.mtime, right.mtime)
		and same_time(left.ctime, right.ctime)
end

local function same_file_after_rename(left, right)
	-- Renaming an entry updates ctime on supported hosts. Identity, size, and
	-- content mtime still prove that the quarantined object is the checked target.
	return same_object(left, right, "file") and left.size == right.size and same_time(left.mtime, right.mtime)
end

local function same_entry_snapshot(left, right)
	return left
		and right
		and left.type == right.type
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and same_time(left.mtime, right.mtime)
		and same_time(left.ctime, right.ctime)
end

local function same_entry_after_rename(left, right)
	return left
		and right
		and left.type == right.type
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and same_time(left.mtime, right.mtime)
end

local function descriptor_path(fd)
	if SYSTEM == "Linux" then
		return uv.fs_readlink("/proc/self/fd/" .. tostring(fd))
	end
	if SYSTEM ~= "Darwin" or not ffi_ok then
		return nil
	end
	local ok, path = pcall(function()
		local buffer = ffi.new("char[?]", DARWIN_PATH_BYTES)
		if ffi.C.fcntl(fd, DARWIN_F_GETPATH, buffer) ~= 0 then
			return nil
		end
		return ffi.string(buffer)
	end)
	return ok and path or nil
end

local function descriptor_is_bound(fd, expected)
	local path = descriptor_path(fd)
	return type(path) == "string" and vim.fs.normalize(path) == expected
end

local function close_fd(fd)
	if fd == nil then
		return true
	end
	return uv.fs_close(fd)
end

local function sync_directory_fd(fd, path, operation)
	if not descriptor_is_bound(fd, path) then
		return nil, operation .. " parent directory changed before fsync"
	end
	local hook_ok, hook_err = run_test_hook("directory_fsync", {
		operation = operation,
		path = path,
		committed = true,
	})
	if not hook_ok then
		return nil, operation .. " parent directory fsync hook failed: " .. tostring(hook_err)
	end
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return nil, operation .. " parent directory fsync failed: " .. tostring(sync_err)
	end
	if not descriptor_is_bound(fd, path) then
		return nil, operation .. " parent directory changed after fsync"
	end
	return true
end

local function ffi_ready()
	return ffi_ok and (SYSTEM == "Darwin" or SYSTEM == "Linux")
end

local function open_directory(path, secure)
	local info, inspect_err = lstat(path)
	if inspect_err then
		return nil, tostring(inspect_err)
	end
	if not info or info.type ~= "directory" then
		return nil, "directory is missing, a symlink, or non-directory: " .. path
	end
	local expected = uv.fs_realpath(path)
	if not expected then
		return nil, "directory could not be resolved: " .. path
	end
	if not ffi_ready() then
		return nil, "descriptor-relative filesystem operations are unavailable"
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow
	local raw_fd = ffi.C.openat(OPEN_FLAGS.at_fdcwd, path, flags)
	if raw_fd < 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	local fd = tonumber(raw_fd)
	local opened = uv.fs_fstat(fd)
	if not same_object(info, opened, "directory") or not descriptor_is_bound(fd, expected) then
		close_fd(fd)
		return nil, "directory changed while it was opened: " .. path
	end
	if secure then
		local secured, chmod_err = uv.fs_fchmod(fd, DIRECTORY_MODE)
		if not secured then
			close_fd(fd)
			return nil, tostring(chmod_err)
		end
	end
	local after = uv.fs_fstat(fd)
	local current = lstat(path)
	if
		not same_object(opened, after, "directory")
		or not same_object(after, current, "directory")
		or not descriptor_is_bound(fd, expected)
	then
		close_fd(fd)
		return nil, "directory changed while it was secured: " .. path
	end
	return fd, expected
end

local function open_parent(path, create, secure)
	local parent = vim.fs.dirname(path)
	local info, inspect_err = lstat(parent)
	if inspect_err then
		return nil, tostring(inspect_err)
	end
	if not info and create then
		if not ffi_ready() then
			return nil, "descriptor-relative filesystem operations are unavailable"
		end
		local grandparent = vim.fs.dirname(parent)
		local grand_fd, grand_err = open_directory(grandparent, false)
		if not grand_fd then
			return nil, grand_err
		end
		local result = ffi.C.mkdirat(grand_fd, vim.fs.basename(parent), DIRECTORY_MODE)
		local errno = ffi.errno()
		local creation_warning
		if result == 0 then
			local _, sync_err = sync_directory_fd(grand_fd, grandparent, "theme state directory creation")
			creation_warning = append_warning(creation_warning, sync_err)
		end
		local closed, close_err = close_fd(grand_fd)
		if not closed then
			if result == 0 then
				creation_warning = append_warning(
					creation_warning,
					"theme state directory creation parent close failed: " .. tostring(close_err)
				)
			else
				return nil, "could not close theme state directory parent: " .. tostring(close_err)
			end
		end
		if result ~= 0 and errno ~= 17 then
			return nil, "could not create directory (errno " .. tostring(errno) .. "): " .. parent
		end
		info = lstat(parent)
		if result == 0 then
			local fd, opened_or_err = open_directory(parent, secure)
			if not fd then
				return nil, opened_or_err .. (creation_warning and "; " .. creation_warning or "")
			end
			return fd, opened_or_err, creation_warning
		end
	end
	if not info then
		return false, parent
	end
	local fd, opened_or_err = open_directory(parent, secure)
	if not fd then
		return nil, opened_or_err
	end
	return fd, opened_or_err
end

local function openat_file(parent_fd, name, flags, mode)
	if not ffi_ready() then
		return nil, "descriptor-relative filesystem operations are unavailable"
	end
	local fd
	if mode and mode ~= 0 then
		-- Lua numbers are passed as doubles to variadic C functions. openat(2)
		-- expects mode_t when O_CREAT is present, so box the argument explicitly.
		fd = ffi.C.openat(parent_fd, name, flags, ffi.new("unsigned int", mode))
	else
		fd = ffi.C.openat(parent_fd, name, flags)
	end
	if fd < 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return tonumber(fd)
end

local function open_entry(parent_fd, parent, path, label)
	local flags = OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow
	local fd, open_err = openat_file(parent_fd, vim.fs.basename(path), flags, 0)
	if not fd then
		return nil, ("Could not open %s: %s"):format(label, open_err)
	end
	local opened = uv.fs_fstat(fd)
	local expected = vim.fs.joinpath(parent, vim.fs.basename(path))
	if not opened or opened.type ~= "file" or opened.nlink ~= 1 or not descriptor_is_bound(fd, expected) then
		close_fd(fd)
		return nil, label .. " changed or is not a regular file without symlinks"
	end
	return fd, opened
end

local function open_entry_optional(parent_fd, parent, path, label)
	local flags = OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow
	local fd, open_err, errno = openat_file(parent_fd, vim.fs.basename(path), flags, 0)
	if not fd and errno == 2 then
		return false
	end
	if not fd then
		return nil, ("Could not open %s: %s"):format(label, open_err)
	end
	local opened = uv.fs_fstat(fd)
	local expected = vim.fs.joinpath(parent, vim.fs.basename(path))
	if not opened or opened.type ~= "file" or opened.nlink ~= 1 or not descriptor_is_bound(fd, expected) then
		close_fd(fd)
		return nil, label .. " changed or is not a regular file without symlinks"
	end
	return fd, opened
end

local function release_namespace_lock(lock)
	local warning = lock.warning
	local opened = uv.fs_fstat(lock.fd)
	local current, current_err = uv.fs_lstat(lock.path)
	if
		not opened
		or not current
		or not same_entry_snapshot(lock.snapshot, opened)
		or not same_entry_snapshot(opened, current)
		or not descriptor_is_bound(lock.fd, lock.path)
	then
		warning = append_warning(
			warning,
			"theme namespace lock changed while held: " .. tostring(current_err or "identity mismatch")
		)
	end
	if ffi.C.flock(lock.fd, LOCK_UNLOCK) ~= 0 then
		warning = append_warning(warning, "could not unlock theme namespace: errno " .. tostring(ffi.errno()))
	end
	local closed, close_err = close_fd(lock.fd)
	if not closed then
		warning = append_warning(warning, "could not close theme namespace lock: " .. tostring(close_err))
	end
	if not descriptor_is_bound(lock.parent_fd, lock.parent) then
		warning = append_warning(warning, "theme namespace parent changed while lock was held")
	end
	local parent_closed, parent_close_err = close_fd(lock.parent_fd)
	if not parent_closed then
		warning = append_warning(
			warning,
			"could not close theme namespace parent after lock release: " .. tostring(parent_close_err)
		)
	end
	return true, warning
end

local function acquire_namespace_lock()
	local parent_fd, parent_or_err, parent_warning = open_parent(state.opts.state_path, true, true)
	if not parent_fd then
		return nil, "Could not open theme namespace parent: " .. tostring(parent_or_err)
	end
	local parent = parent_or_err
	local path = vim.fs.joinpath(parent, LOCK_FILE)
	local base_flags = OPEN_FLAGS.write_only + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.close_on_exec
	local fd, open_err, open_errno =
		openat_file(parent_fd, LOCK_FILE, base_flags + OPEN_FLAGS.create + OPEN_FLAGS.exclusive, FILE_MODE)
	local created = fd ~= nil
	if not fd and open_errno == 17 then
		fd, open_err = openat_file(parent_fd, LOCK_FILE, base_flags, 0)
	end
	if not fd then
		close_fd(parent_fd)
		return nil, "Could not open theme namespace lock: " .. tostring(open_err)
	end

	local owner_uid = ffi_ok and tonumber(ffi.C.getuid()) or nil
	local opened = uv.fs_fstat(fd)
	local current, current_err = uv.fs_lstat(path)
	if
		type(owner_uid) ~= "number"
		or not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or opened.uid ~= owner_uid
		or not current
		or not same_entry_snapshot(opened, current)
		or not descriptor_is_bound(fd, path)
		or not descriptor_is_bound(parent_fd, parent)
	then
		close_fd(fd)
		close_fd(parent_fd)
		return nil,
			"Theme namespace lock must be an owner-owned single-link regular file: " .. tostring(
				current_err or "identity mismatch"
			)
	end

	local warning = parent_warning
	if opened.mode % 512 ~= FILE_MODE then
		local secured, secure_err = uv.fs_fchmod(fd, FILE_MODE)
		if not secured then
			close_fd(fd)
			close_fd(parent_fd)
			return nil, "Could not secure theme namespace lock: " .. tostring(secure_err)
		end
	end
	local secured = uv.fs_fstat(fd)
	current, current_err = uv.fs_lstat(path)
	if
		not secured
		or secured.type ~= "file"
		or secured.nlink ~= 1
		or secured.uid ~= owner_uid
		or secured.mode % 512 ~= FILE_MODE
		or not current
		or not same_entry_snapshot(secured, current)
		or not descriptor_is_bound(fd, path)
		or not descriptor_is_bound(parent_fd, parent)
	then
		close_fd(fd)
		close_fd(parent_fd)
		return nil,
			"Theme namespace lock changed while it was secured: " .. tostring(current_err or "identity mismatch")
	end
	if created or opened.mode % 512 ~= FILE_MODE then
		local synced, sync_err = uv.fs_fsync(fd)
		if not synced then
			warning = append_warning(warning, "theme namespace lock fsync failed: " .. tostring(sync_err))
		end
	end
	if created then
		local _, sync_err = sync_directory_fd(parent_fd, parent, "theme namespace lock creation")
		warning = append_warning(warning, sync_err)
	end

	local deadline = uv.hrtime() + LOCK_WAIT_MILLISECONDS * 1000000
	while ffi.C.flock(fd, LOCK_EXCLUSIVE + LOCK_NONBLOCKING) ~= 0 do
		local errno = ffi.errno()
		if errno ~= 4 and errno ~= 11 and errno ~= 35 then
			close_fd(fd)
			close_fd(parent_fd)
			return nil, "Could not acquire theme namespace lock: errno " .. tostring(errno)
		end
		if uv.hrtime() >= deadline then
			close_fd(fd)
			close_fd(parent_fd)
			return nil, "Theme namespace is locked by another process"
		end
		vim.wait(LOCK_POLL_MILLISECONDS, function()
			return false
		end, LOCK_POLL_MILLISECONDS)
	end

	local locked = uv.fs_fstat(fd)
	current, current_err = uv.fs_lstat(path)
	if
		not locked
		or not current
		or not same_entry_snapshot(secured, locked)
		or not same_entry_snapshot(locked, current)
		or not descriptor_is_bound(fd, path)
		or not descriptor_is_bound(parent_fd, parent)
	then
		ffi.C.flock(fd, LOCK_UNLOCK)
		close_fd(fd)
		close_fd(parent_fd)
		return nil, "Theme namespace lock changed during acquisition: " .. tostring(current_err or "identity mismatch")
	end
	local lock = {
		fd = fd,
		parent_fd = parent_fd,
		parent = parent,
		path = path,
		snapshot = locked,
		warning = warning,
	}
	local hook_ok, hook_err = run_test_hook("lock_acquired", { fd = fd, path = path, parent = parent })
	if not hook_ok then
		local _, release_warning = release_namespace_lock(lock)
		return nil, append_warning("Theme namespace lock hook failed: " .. tostring(hook_err), release_warning)
	end
	return lock
end

local function inspect_parent(create)
	local parent = vim.fs.dirname(state.opts.state_path)
	local info, err = lstat(parent)
	if err then
		return nil, "Could not inspect theme state directory: " .. tostring(err)
	end
	if info then
		if info.type ~= "directory" then
			return nil, "Theme state directory must be real; symlinks and non-directories are rejected"
		end
		local fd, open_err = open_directory(parent, true)
		if not fd then
			return nil, "Could not secure theme state directory: " .. tostring(open_err)
		end
		close_fd(fd)
		return true
	end
	if not create then
		return true
	end
	local fd, create_err = open_parent(state.opts.state_path, true, true)
	if not fd then
		return nil, "Could not create theme state directory: " .. tostring(create_err)
	end
	close_fd(fd)
	return true
end

local function inspect_target(path, label)
	label = label or "Theme state"
	local info, err = lstat(path)
	if err then
		return nil, ("Could not inspect %s: %s"):format(label:lower(), tostring(err))
	end
	if info and (info.type ~= "file" or info.nlink ~= 1) then
		return nil,
			label .. " must be a single-link regular file; symlinks, hardlinks, and non-regular targets are rejected"
	end
	return info or false
end

local function read_bounded_file(path, info, label, secure_parent)
	label = label or "Theme state"
	if info.size > MAX_STATE_BYTES then
		return nil, label .. " exceeds the 64 KiB limit"
	end
	local parent_fd, parent_or_err = open_parent(path, false, secure_parent == true)
	if not parent_fd then
		return nil, "Could not open " .. label:lower() .. " parent: " .. tostring(parent_or_err)
	end
	local parent = parent_or_err
	local fd, opened_or_err = open_entry(parent_fd, parent, path, label)
	if not fd then
		close_fd(parent_fd)
		return nil, opened_or_err
	end
	local opened = opened_or_err
	if not same_file_snapshot(info, opened) or opened.size > MAX_STATE_BYTES then
		close_fd(fd)
		close_fd(parent_fd)
		return nil, label .. " changed while it was opened"
	end
	local secured, chmod_err = uv.fs_fchmod(fd, FILE_MODE)
	if not secured then
		close_fd(fd)
		close_fd(parent_fd)
		return nil, "Could not secure " .. label:lower() .. ": " .. tostring(chmod_err)
	end
	local baseline = uv.fs_fstat(fd)
	if not same_object(opened, baseline, "file") or baseline.size > MAX_STATE_BYTES then
		close_fd(fd)
		close_fd(parent_fd)
		return nil, label .. " changed while it was secured"
	end
	local contents, read_err = uv.fs_read(fd, baseline.size, 0)
	local after = uv.fs_fstat(fd)
	local verify_fd, verify_or_err = open_entry(parent_fd, parent, path, label)
	local verified = verify_fd and same_file_snapshot(baseline, verify_or_err)
	close_fd(verify_fd)
	local child_bound = descriptor_is_bound(fd, vim.fs.joinpath(parent, vim.fs.basename(path)))
	local parent_bound = descriptor_is_bound(parent_fd, parent)
	local close_ok, close_err = close_fd(fd)
	close_fd(parent_fd)
	if type(contents) ~= "string" or #contents ~= baseline.size then
		return nil, "Could not read " .. label:lower() .. ": " .. tostring(read_err or "short read")
	end
	if not after or not same_file_snapshot(baseline, after) or not verified or not child_bound or not parent_bound then
		return nil, label .. " changed while it was read: " .. tostring(verify_or_err or "identity mismatch")
	end
	if not close_ok then
		return nil, "Could not close " .. label:lower() .. ": " .. tostring(close_err)
	end
	return contents
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_yaml_comment(value)
	local single = false
	local double = false
	local escaped = false
	for index = 1, #value do
		local char = value:sub(index, index)
		if double then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				double = false
			end
		elseif single then
			if char == "'" then
				if value:sub(index + 1, index + 1) ~= "'" then
					single = false
				end
			end
		elseif char == '"' then
			double = true
		elseif char == "'" then
			single = true
		elseif char == "#" and (index == 1 or value:sub(index - 1, index - 1):match("%s")) then
			return trim(value:sub(1, index - 1))
		end
	end
	if single or double or escaped then
		return nil, "unterminated quoted scalar"
	end
	return trim(value)
end

local function parse_colorscheme_scalar(raw)
	local scalar, comment_err = strip_yaml_comment(raw)
	if not scalar then
		return nil, comment_err
	end
	if scalar == "" then
		return nil, "colorscheme must not be empty"
	end
	local first = scalar:sub(1, 1)
	if first == '"' then
		local ok, decoded = pcall(vim.json.decode, scalar)
		if not ok or type(decoded) ~= "string" then
			return nil, "colorscheme has a malformed double-quoted scalar"
		end
		return colorscheme_name(decoded, "colorscheme")
	end
	if first == "'" then
		if scalar:sub(-1) ~= "'" or #scalar < 2 then
			return nil, "colorscheme has a malformed single-quoted scalar"
		end
		local inner = scalar:sub(2, -2)
		if inner:gsub("''", ""):find("'", 1, true) then
			return nil, "colorscheme has a malformed single-quoted scalar"
		end
		return colorscheme_name(inner:gsub("''", "'"), "colorscheme")
	end
	return colorscheme_name(scalar, "colorscheme")
end

local function parse_yaml(contents)
	if type(contents) ~= "string" then
		return nil, "Theme state must be text"
	end
	local fields = {}
	local seen = {}
	local lines = vim.split(contents, "\n", { plain = true })
	for line_number, line in ipairs(lines) do
		if line:find("\0", 1, true) then
			return nil, ("Theme state line %d contains a NUL byte"):format(line_number)
		end
		if not line:match("^%s*$") and not line:match("^%s*#") then
			if line:match("^%s") then
				return nil, ("Theme state line %d must use a top-level key"):format(line_number)
			end
			local key, raw = line:match("^([%a_][%w_-]*)%s*:%s*(.-)%s*$")
			if not key then
				return nil, ("Theme state line %d is malformed"):format(line_number)
			end
			if key ~= "version" and key ~= "colorscheme" then
				return nil, ("Theme state contains unknown key '%s'"):format(key)
			end
			if seen[key] then
				return nil, ("Theme state contains duplicate key '%s'"):format(key)
			end
			seen[key] = true
			if key == "version" then
				local scalar, scalar_err = strip_yaml_comment(raw)
				if not scalar then
					return nil, "Theme state version is malformed: " .. scalar_err
				end
				if not scalar:match("^[0-9]+$") then
					return nil, "Theme state version must be an integer scalar"
				end
				fields.version = tonumber(scalar)
			else
				local colorscheme, scalar_err = parse_colorscheme_scalar(raw)
				if not colorscheme then
					return nil, "Theme state colorscheme is malformed: " .. scalar_err
				end
				fields.colorscheme = colorscheme
			end
		end
	end
	if fields.version == nil then
		return nil, "Theme state is missing required key 'version'"
	end
	if fields.version ~= STATE_VERSION then
		return nil, "Unsupported theme state version: " .. tostring(fields.version)
	end
	if fields.colorscheme == nil then
		return nil, "Theme state is missing required key 'colorscheme'"
	end
	return { version = STATE_VERSION, colorscheme = fields.colorscheme }
end

local function yaml_contents(name)
	return table.concat({
		"# Shared Neovim and nvimpager theme selection.",
		"version: 1",
		"colorscheme: " .. vim.json.encode(name),
		"",
	}, "\n")
end

local function unlinkat_entry(parent_fd, name)
	if ffi.C.unlinkat(parent_fd, name, 0) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function renameat_noreplace(parent_fd, source, destination)
	if not ffi_ready() then
		return nil, "descriptor-relative no-clobber rename is unavailable"
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(parent_fd, source, parent_fd, destination, 4) -- RENAME_EXCL
		end
		return ffi.C.renameat2(parent_fd, source, parent_fd, destination, 1) -- RENAME_NOREPLACE
	end)
	if not ok then
		return nil, "no-clobber rename is unavailable: " .. tostring(result)
	end
	if result ~= 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return true
end

local function renameat_exchange(parent_fd, left, right)
	if not ffi_ready() then
		return nil, "descriptor-relative exchange rename is unavailable"
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(parent_fd, left, parent_fd, right, 2) -- RENAME_SWAP
		end
		return ffi.C.renameat2(parent_fd, left, parent_fd, right, 2) -- RENAME_EXCHANGE
	end)
	if not ok then
		return nil, "exchange rename is unavailable: " .. tostring(result)
	end
	if result ~= 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return true
end

local function entry_snapshot(parent_fd, parent, path, label)
	local fd, opened_or_err = open_entry_optional(parent_fd, parent, path, label)
	if fd == false then
		return false
	end
	if not fd then
		return nil, opened_or_err
	end
	local closed, close_err = close_fd(fd)
	if not closed then
		return nil, "Could not close " .. label:lower() .. ": " .. tostring(close_err)
	end
	return opened_or_err
end

local function exact_entry_snapshot(parent_fd, parent, path, label, secure)
	local fd, opened_or_err = open_entry_optional(parent_fd, parent, path, label)
	if fd == false then
		return false
	end
	if not fd then
		return nil, opened_or_err
	end
	if secure then
		local secured, secure_err = uv.fs_fchmod(fd, FILE_MODE)
		if not secured then
			close_fd(fd)
			return nil, "Could not secure " .. label:lower() .. ": " .. tostring(secure_err)
		end
	end
	local before = uv.fs_fstat(fd)
	if not before or before.size > MAX_STATE_BYTES then
		close_fd(fd)
		return nil, label .. " exceeds the 64 KiB limit"
	end
	local contents, read_err = uv.fs_read(fd, before.size, 0)
	local after = uv.fs_fstat(fd)
	local expected_path = vim.fs.joinpath(parent, vim.fs.basename(path))
	local bound = descriptor_is_bound(fd, expected_path)
	local closed, close_err = close_fd(fd)
	if not contents or #contents ~= before.size or not same_file_snapshot(before, after) or not bound or not closed then
		return nil,
			label .. " changed while its exact snapshot was read: " .. tostring(
				read_err or close_err or "identity mismatch"
			)
	end
	return { data = contents, stat = after }
end

local function exact_snapshot_matches(expected, current, renamed)
	if type(expected) ~= "table" or type(current) ~= "table" or expected.data ~= current.data then
		return false
	end
	if renamed then
		return same_file_after_rename(expected.stat, current.stat)
	end
	return same_file_snapshot(expected.stat, current.stat)
end

local function any_entry_snapshot(parent_fd, parent, path, label)
	if not descriptor_is_bound(parent_fd, parent) then
		return nil, label .. " parent changed"
	end
	local current, current_err = lstat(path)
	if current_err then
		return nil, label .. " could not be inspected: " .. tostring(current_err)
	end
	if not descriptor_is_bound(parent_fd, parent) then
		return nil, label .. " parent changed"
	end
	return current or false
end

local function conditional_unlink_exact(parent_fd, parent, name, label, expected, hook_phase, missing_ok)
	local reserved = (".%s.remove.%d.%d"):format(name, uv.os_getpid(), uv.hrtime())
	local reserved_path = vim.fs.joinpath(parent, reserved)
	local moved, move_err, move_errno = renameat_noreplace(parent_fd, name, reserved)
	if not moved and move_errno == 2 then
		if missing_ok == false then
			return nil, label .. " disappeared before cleanup"
		end
		return true
	end
	if not moved then
		return nil, label .. " cleanup could not reserve the exact entry: " .. tostring(move_err)
	end
	local warning
	local _, reserve_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup reservation")
	warning = append_warning(warning, reserve_sync_err)
	local current, current_err = exact_entry_snapshot(parent_fd, parent, reserved_path, label)
	if hook_phase then
		local hook_ok, hook_err = run_test_hook(hook_phase, {
			label = label,
			path = vim.fs.joinpath(parent, name),
			reserved_path = reserved_path,
		})
		if not hook_ok then
			local restored, restore_err = renameat_noreplace(parent_fd, reserved, name)
			if restored then
				local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
				warning = append_warning(warning, restore_sync_err)
			end
			local retained = restored and vim.fs.joinpath(parent, name) or reserved_path
			return nil,
				label .. " cleanup hook failed; entry preserved at " .. retained .. ": " .. tostring(
					hook_err or restore_err
				) .. (warning and "; " .. warning or "")
		end
	end
	local rechecked, recheck_err = exact_entry_snapshot(parent_fd, parent, reserved_path, label)
	if
		not current
		or not rechecked
		or not exact_snapshot_matches(expected, current, true)
		or not exact_snapshot_matches(current, rechecked, false)
	then
		local restored, restore_err = renameat_noreplace(parent_fd, reserved, name)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		local retained = restored and vim.fs.joinpath(parent, name) or reserved_path
		return nil,
			label .. " cleanup preserved a changed entry at " .. retained .. ": " .. tostring(
				current_err or recheck_err or restore_err or "snapshot mismatch"
			) .. (warning and "; " .. warning or "")
	end
	local validated_hook_ok, validated_hook_err = run_test_hook("cleanup_validated_before_quarantine", {
		label = label,
		path = vim.fs.joinpath(parent, name),
		reserved_path = reserved_path,
	})
	if not validated_hook_ok then
		local restored, restore_err = renameat_noreplace(parent_fd, reserved, name)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		local retained = restored and vim.fs.joinpath(parent, name) or reserved_path
		return nil,
			label .. " cleanup validation hook failed; entry preserved at " .. retained .. ": " .. tostring(
				validated_hook_err or restore_err
			) .. (warning and "; " .. warning or "")
	end

	-- Move the validated pathname through one final no-clobber reservation. A
	-- replacement introduced after the last read is moved, identified, and
	-- restored; it is never passed directly to unlink(2).
	local quarantined = reserved .. (".quarantine.%d"):format(uv.hrtime())
	local quarantined_path = vim.fs.joinpath(parent, quarantined)
	local sealed, seal_err = renameat_noreplace(parent_fd, reserved, quarantined)
	if not sealed then
		return nil,
			label
				.. " cleanup could not quarantine the validated entry; entry was preserved at "
				.. reserved_path
				.. ": "
				.. tostring(seal_err)
				.. (warning and "; " .. warning or "")
	end
	local _, seal_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup quarantine")
	warning = append_warning(warning, seal_sync_err)
	local sealed_snapshot, sealed_err = exact_entry_snapshot(parent_fd, parent, quarantined_path, label)
	if not sealed_snapshot or not exact_snapshot_matches(rechecked, sealed_snapshot, true) then
		local restored, restore_err = renameat_noreplace(parent_fd, quarantined, name)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		local retained = restored and vim.fs.joinpath(parent, name) or quarantined_path
		return nil,
			label .. " cleanup quarantined a replacement and preserved it at " .. retained .. ": " .. tostring(
				sealed_err or restore_err or "snapshot mismatch"
			) .. (warning and "; " .. warning or "")
	end
	local removed, remove_err = unlinkat_entry(parent_fd, quarantined)
	if not removed then
		return nil,
			"Could not remove "
				.. label:lower()
				.. "; quarantined entry remains at "
				.. quarantined_path
				.. ": "
				.. tostring(remove_err)
	end
	local _, remove_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup unlink")
	warning = append_warning(warning, remove_sync_err)
	return true, warning
end

local function conditional_unlink_identity(parent_fd, parent, name, label, expected)
	local reserved = (".%s.remove.%d.%d"):format(name, uv.os_getpid(), uv.hrtime())
	local reserved_path = vim.fs.joinpath(parent, reserved)
	local moved, move_err, move_errno = renameat_noreplace(parent_fd, name, reserved)
	if not moved and move_errno == 2 then
		return true
	end
	if not moved then
		return nil, label .. " cleanup could not reserve the exact entry: " .. tostring(move_err)
	end
	local warning
	local _, reserve_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup reservation")
	warning = append_warning(warning, reserve_sync_err)
	local current, current_err = entry_snapshot(parent_fd, parent, reserved_path, label)
	local rechecked, recheck_err = entry_snapshot(parent_fd, parent, reserved_path, label)
	if
		not current
		or not rechecked
		or not same_file_after_rename(expected, current)
		or not same_file_snapshot(current, rechecked)
	then
		local restored, restore_err = renameat_noreplace(parent_fd, reserved, name)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		local retained = restored and vim.fs.joinpath(parent, name) or reserved_path
		return nil,
			label .. " cleanup preserved a changed entry at " .. retained .. ": " .. tostring(
				current_err or recheck_err or restore_err or "snapshot mismatch"
			) .. (warning and "; " .. warning or "")
	end
	local validated_hook_ok, validated_hook_err = run_test_hook("cleanup_validated_before_quarantine", {
		label = label,
		path = vim.fs.joinpath(parent, name),
		reserved_path = reserved_path,
	})
	if not validated_hook_ok then
		local restored, restore_err = renameat_noreplace(parent_fd, reserved, name)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		return nil,
			label
				.. " cleanup validation hook failed: "
				.. tostring(validated_hook_err or restore_err)
				.. (warning and "; " .. warning or "")
	end
	local quarantined = reserved .. (".quarantine.%d"):format(uv.hrtime())
	local quarantined_path = vim.fs.joinpath(parent, quarantined)
	local sealed, seal_err = renameat_noreplace(parent_fd, reserved, quarantined)
	if not sealed then
		return nil,
			label
				.. " cleanup could not quarantine the validated entry: "
				.. tostring(seal_err)
				.. (warning and "; " .. warning or "")
	end
	local _, seal_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup quarantine")
	warning = append_warning(warning, seal_sync_err)
	local sealed_snapshot, sealed_err = entry_snapshot(parent_fd, parent, quarantined_path, label)
	if not sealed_snapshot or not same_file_after_rename(rechecked, sealed_snapshot) then
		local restored, restore_err = renameat_noreplace(parent_fd, quarantined, name)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		return nil,
			label .. " cleanup quarantined a replacement and preserved it: " .. tostring(
				sealed_err or restore_err or "snapshot mismatch"
			) .. (warning and "; " .. warning or "")
	end
	local removed, remove_err = unlinkat_entry(parent_fd, quarantined)
	if not removed then
		return nil,
			"Could not remove "
				.. label:lower()
				.. "; quarantined entry remains at "
				.. quarantined_path
				.. ": "
				.. tostring(remove_err)
	end
	local _, remove_sync_err = sync_directory_fd(parent_fd, parent, label .. " cleanup unlink")
	warning = append_warning(warning, remove_sync_err)
	return true, warning
end

local function write_all(fd, contents, label)
	local offset = 0
	while offset < #contents do
		local written, write_err = uv.fs_write(fd, contents:sub(offset + 1), offset)
		if not written or written <= 0 then
			return nil, "Could not write " .. label:lower() .. ": " .. tostring(write_err or "short write")
		end
		offset = offset + written
	end
	return true
end

local function atomic_write_contents(path, contents, label)
	if type(contents) ~= "string" or #contents > MAX_STATE_BYTES then
		return nil, label .. " contents are invalid or exceed the 64 KiB limit"
	end
	local parent_fd, parent_or_err, parent_warning = open_parent(path, true, true)
	if not parent_fd then
		return nil, "Could not open " .. label:lower() .. " parent: " .. tostring(parent_or_err)
	end
	local parent = parent_or_err
	local commit_warning = parent_warning
	local original, original_err = exact_entry_snapshot(parent_fd, parent, path, label)
	if original == nil then
		close_fd(parent_fd)
		return nil, original_err
	end

	local basename = vim.fs.basename(path)
	local temporary = (".%s.tmp.%d.%d"):format(basename, uv.os_getpid(), uv.hrtime())
	local flags = OPEN_FLAGS.write_only + OPEN_FLAGS.create + OPEN_FLAGS.exclusive + OPEN_FLAGS.no_follow
	local fd, open_err = openat_file(parent_fd, temporary, flags, FILE_MODE)
	if not fd then
		close_fd(parent_fd)
		return nil, "Could not create temporary " .. label:lower() .. ": " .. tostring(open_err)
	end

	local function fail(message)
		local expected = fd and uv.fs_fstat(fd) or nil
		close_fd(fd)
		fd = nil
		if expected then
			local cleaned, cleanup_err =
				conditional_unlink_identity(parent_fd, parent, temporary, "Temporary " .. label, expected)
			if not cleaned then
				message = message .. "; " .. tostring(cleanup_err)
			end
		end
		local parent_closed, parent_close_err = close_fd(parent_fd)
		if not parent_closed then
			message = append_warning(
				message,
				"Could not close " .. label:lower() .. " parent: " .. tostring(parent_close_err)
			)
		end
		return nil, append_warning(message, commit_warning)
	end

	local created = uv.fs_fstat(fd)
	local temporary_path = vim.fs.joinpath(parent, temporary)
	if not created or created.type ~= "file" or not descriptor_is_bound(fd, temporary_path) then
		return fail("Temporary " .. label:lower() .. " changed while it was created")
	end
	local secured, chmod_err = uv.fs_fchmod(fd, FILE_MODE)
	if not secured then
		return fail("Could not secure temporary " .. label:lower() .. ": " .. tostring(chmod_err))
	end
	local written, write_err = write_all(fd, contents, "temporary " .. label)
	if not written then
		return fail(write_err)
	end
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return fail("Could not flush temporary " .. label:lower() .. ": " .. tostring(sync_err))
	end
	local completed = uv.fs_fstat(fd)
	if
		not same_object(created, completed, "file")
		or completed.size ~= #contents
		or not descriptor_is_bound(fd, temporary_path)
		or not descriptor_is_bound(parent_fd, parent)
	then
		return fail("Temporary " .. label:lower() .. " changed while it was written")
	end
	local closed, close_err = close_fd(fd)
	fd = nil
	if not closed then
		close_fd(parent_fd)
		return nil, "Could not close temporary " .. label:lower() .. ": " .. tostring(close_err)
	end

	local staged, staged_err = exact_entry_snapshot(parent_fd, parent, temporary_path, "Temporary " .. label)
	if not staged then
		close_fd(parent_fd)
		return nil, staged_err
	end
	local intended_stage = { data = contents, stat = completed }
	if staged.data ~= contents or not same_file_snapshot(completed, staged.stat) then
		local cleaned, cleanup_err =
			conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, intended_stage)
		close_fd(parent_fd)
		return nil,
			"Temporary " .. label:lower() .. " bytes changed before publication" .. (cleaned and "" or "; " .. tostring(
				cleanup_err
			))
	end
	local stage_hook_ok, stage_hook_err = run_test_hook("stage_ready", {
		label = label,
		path = path,
		staging_path = temporary_path,
	})
	local staged_after_hook, staged_after_hook_err =
		exact_entry_snapshot(parent_fd, parent, temporary_path, "Temporary " .. label)
	if
		not stage_hook_ok
		or not staged_after_hook
		or not exact_snapshot_matches(staged, staged_after_hook, false)
		or staged_after_hook.data ~= contents
	then
		local cleaned, cleanup_err =
			conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged)
		close_fd(parent_fd)
		return nil,
			"Temporary " .. label:lower() .. " changed at the staging boundary: " .. tostring(
				stage_hook_err or staged_after_hook_err or "snapshot mismatch"
			) .. (cleaned and "" or "; " .. tostring(cleanup_err))
	end
	staged = staged_after_hook

	local current, current_err = exact_entry_snapshot(parent_fd, parent, path, label)
	if current == nil then
		conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged)
		close_fd(parent_fd)
		return nil, current_err
	end
	local target_unchanged = (original == false and current == false)
		or (original ~= false and current ~= false and exact_snapshot_matches(original, current, false))
	if not target_unchanged or not descriptor_is_bound(parent_fd, parent) then
		conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged)
		close_fd(parent_fd)
		return nil, label .. " changed before atomic replacement"
	end

	local hook_ok, hook_err = run_test_hook("target_checked", {
		label = label,
		path = path,
		target_present = original ~= false,
	})
	if not hook_ok then
		conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged)
		close_fd(parent_fd)
		return nil, "Atomic " .. label:lower() .. " hook failed: " .. tostring(hook_err)
	end
	local staged_before_publish, staged_before_publish_err =
		exact_entry_snapshot(parent_fd, parent, temporary_path, "Temporary " .. label)
	if
		not staged_before_publish
		or not exact_snapshot_matches(staged, staged_before_publish, false)
		or not descriptor_is_bound(parent_fd, parent)
	then
		conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged_before_publish or staged)
		close_fd(parent_fd)
		return nil,
			label .. " changed before atomic publication: " .. tostring(
				staged_before_publish_err or "identity mismatch"
			)
	end
	staged = staged_before_publish

	if original == false then
		local published, publish_err = renameat_noreplace(parent_fd, temporary, basename)
		if not published then
			conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged)
			close_fd(parent_fd)
			return nil,
				"Could not publish " .. label:lower() .. " without clobbering a competing target: " .. tostring(
					publish_err
				)
		end
		temporary = nil
		local _, publish_sync_err = sync_directory_fd(parent_fd, parent, label .. " publication")
		commit_warning = append_warning(commit_warning, publish_sync_err)
		local final, final_err = exact_entry_snapshot(parent_fd, parent, path, label)
		local parent_bound = descriptor_is_bound(parent_fd, parent)
		local parent_closed, parent_close_err = close_fd(parent_fd)
		if not parent_closed then
			commit_warning = append_warning(
				commit_warning,
				"Could not close " .. label:lower() .. " parent after publication: " .. tostring(parent_close_err)
			)
		end
		if not final or not exact_snapshot_matches(staged, final, true) or not parent_bound then
			return nil,
				label .. " was published, but commit validation detected drift; no rollback is claimed: " .. tostring(
					final_err or "identity mismatch"
				)
		end
		return true, commit_warning
	end

	local exchanged, exchange_err = renameat_exchange(parent_fd, basename, temporary)
	if not exchanged then
		conditional_unlink_exact(parent_fd, parent, temporary, "Temporary " .. label, staged)
		close_fd(parent_fd)
		return nil, "Could not atomically exchange " .. label:lower() .. ": " .. tostring(exchange_err)
	end
	local _, exchange_sync_err = sync_directory_fd(parent_fd, parent, label .. " exchange")
	commit_warning = append_warning(commit_warning, exchange_sync_err)
	local exchange_hook_ok, exchange_hook_err = run_test_hook("after_exchange", {
		label = label,
		path = path,
		displaced_path = temporary_path,
	})
	local final, final_err = exact_entry_snapshot(parent_fd, parent, path, label)
	local displaced, displaced_err = exact_entry_snapshot(parent_fd, parent, temporary_path, "Displaced " .. label)
	local displaced_any, displaced_any_err =
		any_entry_snapshot(parent_fd, parent, temporary_path, "Displaced " .. label)
	local parent_bound = descriptor_is_bound(parent_fd, parent)
	local committed = exchange_hook_ok
		and final
		and displaced
		and exact_snapshot_matches(staged, final, true)
		and exact_snapshot_matches(original, displaced, true)
		and parent_bound
	if committed then
		if exchange_sync_err then
			local parent_closed, parent_close_err = close_fd(parent_fd)
			if not parent_closed then
				commit_warning = append_warning(
					commit_warning,
					"Could not close " .. label:lower() .. " parent after exchange: " .. tostring(parent_close_err)
				)
			end
			commit_warning = append_warning(
				commit_warning,
				"displaced entry retained at " .. temporary_path .. " because exchange durability is uncertain"
			)
			return true, commit_warning
		end
		local cleaned, cleanup_err = conditional_unlink_exact(
			parent_fd,
			parent,
			temporary,
			"Displaced " .. label,
			displaced,
			"before_displaced_cleanup"
		)
		commit_warning = append_warning(commit_warning, cleanup_err)
		local parent_closed, parent_close_err = close_fd(parent_fd)
		if not parent_closed then
			commit_warning = append_warning(
				commit_warning,
				"Could not close " .. label:lower() .. " parent after exchange: " .. tostring(parent_close_err)
			)
		end
		if not cleaned then
			local warning = label
				.. " committed; deferred cleanup preserved the displaced entry: "
				.. tostring(cleanup_err)
			warning = append_warning(warning, commit_warning)
			return true, warning
		end
		return true, commit_warning
	end

	local detail = exchange_hook_err or final_err or displaced_err or displaced_any_err or "snapshot mismatch"
	if not parent_bound or not final or not displaced_any or not exact_snapshot_matches(staged, final, true) then
		close_fd(parent_fd)
		return nil,
			label
				.. " was exchanged, but commit validation detected drift; no rollback is claimed; displaced entry retained at "
				.. temporary_path
				.. ": "
				.. tostring(detail)
	end

	local rollback_hook_ok, rollback_hook_err = run_test_hook("before_exchange_rollback", {
		label = label,
		path = path,
		displaced_path = temporary_path,
	})
	local final_rechecked = exact_entry_snapshot(parent_fd, parent, path, label)
	local displaced_rechecked = any_entry_snapshot(parent_fd, parent, temporary_path, "Displaced " .. label)
	if
		not rollback_hook_ok
		or not final_rechecked
		or not displaced_rechecked
		or not exact_snapshot_matches(final, final_rechecked, false)
		or not same_entry_snapshot(displaced_any, displaced_rechecked)
	then
		close_fd(parent_fd)
		return nil,
			label .. " conflict could not be rolled back safely; both entries were preserved: " .. tostring(
				rollback_hook_err or "snapshot mismatch"
			)
	end
	local rolled_back, rollback_err = renameat_exchange(parent_fd, basename, temporary)
	if not rolled_back then
		close_fd(parent_fd)
		return nil, label .. " conflict rollback failed; both entries were preserved: " .. tostring(rollback_err)
	end
	local _, rollback_sync_err = sync_directory_fd(parent_fd, parent, label .. " conflict rollback")
	local restored = any_entry_snapshot(parent_fd, parent, path, label)
	local own_staging = exact_entry_snapshot(parent_fd, parent, temporary_path, "Rolled-back " .. label)
	if
		not restored
		or not own_staging
		or not same_entry_after_rename(displaced_rechecked, restored)
		or not exact_snapshot_matches(final_rechecked, own_staging, true)
	then
		close_fd(parent_fd)
		return nil, label .. " conflict rollback drifted; no cleanup is claimed"
	end
	local cleaned, cleanup_err =
		conditional_unlink_exact(parent_fd, parent, temporary, "Rolled-back " .. label, own_staging)
	local parent_closed, parent_close_err = close_fd(parent_fd)
	return nil,
		label .. " changed concurrently; the competing target was restored" .. (cleaned and "" or "; " .. tostring(
			cleanup_err
		)) .. (rollback_sync_err and "; " .. tostring(rollback_sync_err) or "") .. (parent_closed and "" or "; " .. tostring(
			parent_close_err
		))
end

local function atomic_write(name)
	return atomic_write_contents(state.opts.state_path, yaml_contents(name), "Theme state")
end

local function marker_path()
	return vim.fs.joinpath(vim.fs.dirname(state.opts.state_path), ".legacy-migrated")
end

local function delete_file(path, label)
	local parent_fd, parent_or_err = open_parent(path, false, true)
	if parent_fd == false then
		return true
	end
	if not parent_fd then
		return nil, "Could not open " .. label:lower() .. " parent: " .. tostring(parent_or_err)
	end
	local parent = parent_or_err
	local expected, expected_err = exact_entry_snapshot(parent_fd, parent, path, label, true)
	if expected == false then
		close_fd(parent_fd)
		return true
	end
	if not expected then
		close_fd(parent_fd)
		return nil, expected_err
	end
	local hook_ok, hook_err = run_test_hook("delete_target_checked", { label = label, path = path })
	if not hook_ok or not descriptor_is_bound(parent_fd, parent) then
		close_fd(parent_fd)
		return nil,
			hook_ok and (label .. " parent changed before conditional deletion")
				or ("Conditional " .. label:lower() .. " delete hook failed: " .. tostring(hook_err))
	end

	local basename = vim.fs.basename(path)
	local quarantine = (".%s.delete.%d.%d"):format(basename, uv.os_getpid(), uv.hrtime())
	local quarantine_path = vim.fs.joinpath(parent, quarantine)
	local reserved, reserve_err = renameat_noreplace(parent_fd, basename, quarantine)
	if not reserved then
		close_fd(parent_fd)
		return nil, label .. " changed before conditional deletion: " .. tostring(reserve_err)
	end
	local warning
	local _, reserve_sync_err = sync_directory_fd(parent_fd, parent, label .. " deletion reservation")
	warning = append_warning(warning, reserve_sync_err)
	local candidate, candidate_err = exact_entry_snapshot(parent_fd, parent, quarantine_path, "Reserved " .. label)
	if not candidate or not exact_snapshot_matches(expected, candidate, true) then
		local restored, restore_err = renameat_noreplace(parent_fd, quarantine, basename)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " deletion restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		local retained = restored and path or quarantine_path
		close_fd(parent_fd)
		return nil,
			label .. " changed before conditional deletion; replacement preserved at " .. retained .. ": " .. tostring(
				candidate_err or restore_err or "snapshot mismatch"
			) .. (warning and "; " .. warning or "")
	end
	local deleted, delete_warning_or_err = conditional_unlink_exact(
		parent_fd,
		parent,
		quarantine,
		"Reserved " .. label,
		candidate,
		"before_delete_cleanup",
		false
	)
	if not deleted then
		local restored, restore_err = renameat_noreplace(parent_fd, quarantine, basename)
		if restored then
			local _, restore_sync_err = sync_directory_fd(parent_fd, parent, label .. " deletion restoration")
			warning = append_warning(warning, restore_sync_err)
		end
		local retained = restored and path or quarantine_path
		close_fd(parent_fd)
		return nil,
			"Could not conditionally delete "
				.. label:lower()
				.. "; entry preserved at "
				.. retained
				.. ": "
				.. tostring(delete_warning_or_err or restore_err)
	end
	warning = append_warning(warning, delete_warning_or_err)
	local current, current_err = exact_entry_snapshot(parent_fd, parent, path, label)
	local parent_bound = descriptor_is_bound(parent_fd, parent)
	local parent_closed, parent_close_err = close_fd(parent_fd)
	if not parent_closed then
		warning = append_warning(
			warning,
			"Could not close " .. label:lower() .. " parent after deletion: " .. tostring(parent_close_err)
		)
	end
	if current == nil or current ~= false or not parent_bound then
		return nil,
			label .. " was deleted, but a competing target was preserved; no rollback is claimed: " .. tostring(
				current_err or "identity mismatch"
			)
	end
	return true, warning
end

local function read_marker()
	local path = marker_path()
	local info, inspect_err = inspect_target(path, "Theme migration marker")
	if inspect_err then
		return nil, inspect_err
	end
	if not info then
		return false
	end
	local contents, read_err = read_bounded_file(path, info, "Theme migration marker", true)
	if not contents then
		return nil, read_err
	end
	if contents ~= MARKER_CONTENTS then
		return nil, "Theme migration marker is invalid"
	end
	return true
end

local LEGACY_PREFIX = {
	"-- lua/localconfig/theme.lua -- machine-local theme selection.",
	"-- Written by :Theme. NOT under version control; see .gitignore.",
	"-- The versioned starting point lives in lua/config/theme_default.lua,",
	"-- and :ThemeReset deletes this file to come back to it.",
	"",
	"return {",
}

local function parse_legacy(contents)
	local lines = vim.split(contents, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines ~= 8 then
		return nil
	end
	for index, expected in ipairs(LEGACY_PREFIX) do
		if lines[index] ~= expected then
			return nil
		end
	end
	if lines[8] ~= "}" then
		return nil
	end
	local name = lines[7]:match('^\tcolorscheme = "([%w_.@+/%-]+)",$')
	return name and colorscheme_name(name, "legacy colorscheme") or nil
end

local function read_legacy()
	local path = state.opts.legacy_path
	if not path then
		return nil, "absent"
	end
	local info, err = lstat(path)
	if err then
		return nil, "Could not inspect legacy theme state: " .. tostring(err)
	end
	if not info then
		return nil, "absent"
	end
	if info.type ~= "file" or info.nlink ~= 1 then
		return nil, "Legacy theme state is not a single-link regular file and was ignored"
	end
	local contents, read_err = read_bounded_file(path, info, "Legacy theme state", false)
	if not contents then
		return nil, read_err
	end
	local name = parse_legacy(contents)
	if not name then
		return nil, "Legacy theme state did not match the generated format and was ignored"
	end
	return name
end

local function default_selection(validity)
	return {
		colorscheme = state.opts.default,
		source = "default",
		validity = validity or { valid = true },
	}
end

local function load_selection()
	local parent_ok, parent_err = inspect_parent(false)
	if not parent_ok then
		notify(parent_err, vim.log.levels.ERROR)
		return default_selection({ valid = false, error = parent_err })
	end
	local info, target_err = inspect_target(state.opts.state_path, "Theme state")
	if target_err then
		notify(target_err, vim.log.levels.ERROR)
		return default_selection({ valid = false, error = target_err })
	end
	if info then
		local contents, read_err = read_bounded_file(state.opts.state_path, info, "Theme state", true)
		if not contents then
			notify(read_err, vim.log.levels.ERROR)
			return default_selection({ valid = false, error = read_err })
		end
		local parsed, parse_err = parse_yaml(contents)
		if not parsed then
			notify(parse_err, vim.log.levels.WARN)
			return default_selection({ valid = false, error = parse_err })
		end
		return { colorscheme = parsed.colorscheme, source = "local", validity = { valid = true } }
	end
	local migrated, marker_err = read_marker()
	if migrated == nil then
		notify(marker_err, vim.log.levels.ERROR)
		return default_selection({ valid = false, error = marker_err })
	end
	if migrated then
		return default_selection()
	end

	local legacy, legacy_err = read_legacy()
	if legacy then
		local migrated, migration_warning_or_err = atomic_write(legacy)
		if migrated then
			emit("migrated", { colorscheme = legacy, legacy_path = state.opts.legacy_path })
			if migration_warning_or_err then
				notify(
					"Legacy theme state migration committed with a durability warning: "
						.. tostring(migration_warning_or_err),
					vim.log.levels.WARN
				)
				emit("warning", {
					colorscheme = legacy,
					operation = "migrate",
					warning = tostring(migration_warning_or_err),
				})
			end
			return { colorscheme = legacy, source = "local", validity = { valid = true, migrated = true } }
		end
		notify("Could not migrate legacy theme state: " .. tostring(migration_warning_or_err), vim.log.levels.ERROR)
		return default_selection({ valid = false, error = migration_warning_or_err })
	end
	if legacy_err ~= "absent" then
		notify(legacy_err, vim.log.levels.WARN)
	end
	return default_selection()
end

local function report_lock_warning(operation, warning, colorscheme)
	if not warning then
		return
	end
	notify("Theme namespace lock completed with a durability warning: " .. tostring(warning), vim.log.levels.WARN)
	emit("warning", {
		colorscheme = colorscheme,
		operation = operation .. "-lock",
		warning = tostring(warning),
	})
end

local function load_selection_locked()
	local lock, lock_err = acquire_namespace_lock()
	if not lock then
		notify(lock_err, vim.log.levels.ERROR)
		return default_selection({ valid = false, error = lock_err })
	end
	local called, selection_or_err = pcall(load_selection)
	local _, lock_warning = release_namespace_lock(lock)
	if not called then
		local message = "Could not load theme selection while holding its namespace lock: "
			.. tostring(selection_or_err)
		notify(message, vim.log.levels.ERROR)
		report_lock_warning("setup", lock_warning, state.opts.default)
		return default_selection({ valid = false, error = message })
	end
	if lock_warning then
		selection_or_err.validity.warning = tostring(lock_warning)
		report_lock_warning("setup", lock_warning, selection_or_err.colorscheme)
	end
	return selection_or_err
end

local function paint(name, source)
	local painter = state.painters[name] or state.opts.paint
	local context = {}
	if state.opts.context then
		local context_ok, context_or_error = pcall(state.opts.context)
		if not context_ok then
			local message = "Theme context callback failed: " .. tostring(context_or_error)
			notify(message, vim.log.levels.WARN)
			emit("error", { colorscheme = name, error = message })
			return false
		end
		context = context_or_error
	end
	local copy_ok, context_copy = pcall(copy, context)
	if not copy_ok then
		local message = "Theme context could not be copied: " .. tostring(context_copy)
		notify(message, vim.log.levels.WARN)
		emit("error", { colorscheme = name, error = message })
		return false
	end
	local ok, result, detail = pcall(painter, name, context_copy)
	if not ok then
		local message = ("Painter for '%s' failed: %s"):format(name, tostring(result))
		notify(message, vim.log.levels.WARN)
		emit("error", { colorscheme = name, error = message })
		return false
	end
	if result == false then
		local message = ("Painter for '%s' failed: %s"):format(name, tostring(detail or "rejected"))
		notify(message, vim.log.levels.WARN)
		emit("error", { colorscheme = name, error = message })
		return false
	end
	state.active = { colorscheme = name, source = source or "direct" }
	state.last_known_good = copy(state.active)
	emit("applied", { colorscheme = name, source = state.active.source })
	return true
end

function M.setup(opts)
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	local options_ok, options_err = exact_options(opts, SETUP_KEYS, "setup")
	if not options_ok then
		return nil, options_err
	end
	local path, path_err = nonempty_string(opts.state_path, "setup.state_path")
	if not path then
		return nil, path_err
	end
	path = vim.fs.normalize(path)
	if path:sub(1, 1) ~= "/" then
		return nil, "setup.state_path must be absolute"
	end
	local default, default_err = colorscheme_name(opts.default, "setup.default")
	if not default then
		return nil, default_err
	end
	local fallback, fallback_err = colorscheme_name(opts.fallback, "setup.fallback")
	if not fallback then
		return nil, fallback_err
	end
	if opts.legacy_path ~= nil then
		local legacy, legacy_err = nonempty_string(opts.legacy_path, "setup.legacy_path")
		if not legacy then
			return nil, legacy_err
		end
		legacy = vim.fs.normalize(legacy)
		if legacy:sub(1, 1) ~= "/" then
			return nil, "setup.legacy_path must be absolute"
		end
	end
	for _, callback in ipairs({ "notify", "paint" }) do
		if type(opts[callback]) ~= "function" then
			return nil, ("setup.%s must be a function"):format(callback)
		end
	end
	for _, callback in ipairs({ "event", "on_state_change" }) do
		if opts[callback] ~= nil and type(opts[callback]) ~= "function" then
			return nil, ("setup.%s must be a function"):format(callback)
		end
	end
	if opts.context ~= nil and type(opts.context) ~= "function" then
		return nil, "setup.context must be a function"
	end
	state.opts = {
		state_path = path,
		legacy_path = opts.legacy_path and vim.fs.normalize(opts.legacy_path) or nil,
		default = default,
		fallback = fallback,
		notify = opts.notify,
		event = opts.event,
		on_state_change = opts.on_state_change,
		paint = opts.paint,
		context = opts.context,
	}
	state.painters = {}
	state.configured = true
	state.selection = load_selection_locked()
	state.active = nil
	state.last_known_good = nil
	emit("setup", { selected = state.selection })
	return M.selection()
end

function M.register(name, painter)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local normalized, err = colorscheme_name(name, "painter name")
	if not normalized then
		return nil, err
	end
	if type(painter) ~= "function" then
		return nil, "painter must be a function"
	end
	state.painters[normalized] = painter
	return true
end

function M.selection()
	if not state.configured then
		return nil, "setup must be called first"
	end
	return copy(state.selection)
end

function M.effective_config()
	if not state.configured then
		return {}
	end
	return copy({
		state_path = state.opts.state_path,
		legacy_path = state.opts.legacy_path,
		default = state.opts.default,
		fallback = state.opts.fallback,
	})
end

function M.status()
	return copy({
		configured = state.configured,
		selected = state.selection,
		active = state.active,
		validity = state.selection and state.selection.validity or nil,
		last_known_good = state.last_known_good,
	})
end

function M.apply(name)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local requested = name or state.selection.colorscheme
	local normalized, err = colorscheme_name(requested, "colorscheme")
	if not normalized then
		notify(err, vim.log.levels.WARN)
		return false
	end
	return paint(normalized, "direct")
end

function M.repaint()
	if not state.configured then
		return nil, "setup must be called first"
	end
	local selected = state.selection.colorscheme
	if paint(selected, "selected") then
		return true, selected
	end
	if selected ~= state.opts.default and paint(state.opts.default, "default") then
		emit("fallback", { colorscheme = state.opts.default, failed = selected, source = "default" })
		return true, state.opts.default
	end
	if
		state.opts.fallback ~= selected
		and state.opts.fallback ~= state.opts.default
		and paint(state.opts.fallback, "fallback")
	then
		emit("fallback", { colorscheme = state.opts.fallback, failed = selected, source = "fallback" })
		return true, state.opts.fallback
	end
	return false
end

---Paint and persist one selection through the plugin-owned composite lifecycle.
---@param name string
---@return boolean
---@return string|nil
function M.select(name)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local normalized, err = colorscheme_name(name, "colorscheme")
	if not normalized then
		notify(err, vim.log.levels.ERROR)
		return false, err
	end
	if not paint(normalized, "selected") then
		return false, "theme could not be applied"
	end
	local persisted, warning = M.persist(normalized)
	if not persisted then
		return false, "theme could not be persisted"
	end
	emit("selected", { colorscheme = normalized })
	return true, warning
end

---Reload the durable selection and repaint only a valid candidate.
---Invalid state updates validity while preserving selected, active, and LKG.
---@return boolean
---@return string|nil
function M.reload()
	if not state.configured then
		return nil, "setup must be called first"
	end
	local loaded = load_selection_locked()
	if not loaded.validity.valid then
		local previous = state.selection or default_selection()
		state.selection = {
			colorscheme = previous.colorscheme,
			source = previous.source,
			validity = copy(loaded.validity),
		}
		emit("reload-rejected", { selected = state.selection, active = state.active })
		return false, loaded.validity.error
	end
	state.selection = loaded
	local repainted, active_or_err = M.repaint()
	if not repainted then
		emit("reload-failed", { selected = state.selection, active = state.active })
		return false, tostring(active_or_err or "theme could not be applied")
	end
	emit("reloaded", { selected = state.selection, active = state.active })
	return true, active_or_err
end

function M.persist(name)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local normalized, err = colorscheme_name(name, "colorscheme")
	if not normalized then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	local lock, lock_err = acquire_namespace_lock()
	if not lock then
		notify(lock_err, vim.log.levels.ERROR)
		emit("error", { colorscheme = normalized, error = lock_err })
		return false
	end
	local called, written, write_err = pcall(atomic_write, normalized)
	local _, lock_warning = release_namespace_lock(lock)
	if not called then
		write_err = tostring(written)
		written = nil
	end
	if not written then
		local failure = append_warning(write_err, lock_warning)
		notify(failure, vim.log.levels.ERROR)
		emit("error", { colorscheme = normalized, error = failure })
		report_lock_warning("persist", lock_warning, normalized)
		return false
	end
	local warning = append_warning(write_err, lock_warning)
	state.selection = { colorscheme = normalized, source = "local", validity = { valid = true } }
	emit("persisted", { colorscheme = normalized })
	if warning then
		notify("Theme state committed with a durability warning: " .. tostring(warning), vim.log.levels.WARN)
		emit("warning", { colorscheme = normalized, operation = "persist", warning = tostring(warning) })
	end
	return true, warning
end

function M.reset()
	if not state.configured then
		return nil, "setup must be called first"
	end
	local lock, lock_err = acquire_namespace_lock()
	if not lock then
		notify(lock_err, vim.log.levels.ERROR)
		emit("error", { colorscheme = state.opts.default, error = lock_err })
		return false
	end
	local called, reset_ok, reset_warning_or_err, marker_committed, marker_warning = pcall(function()
		local written, marker_warning_or_err =
			atomic_write_contents(marker_path(), MARKER_CONTENTS, "Theme migration marker")
		if not written then
			return false, marker_warning_or_err, false
		end
		local deleted, delete_warning_or_err = delete_file(state.opts.state_path, "Theme state")
		if not deleted then
			return false, delete_warning_or_err, true, marker_warning_or_err
		end
		return true, append_warning(marker_warning_or_err, delete_warning_or_err), true, marker_warning_or_err
	end)
	local _, lock_warning = release_namespace_lock(lock)
	if not called then
		reset_warning_or_err = tostring(reset_ok)
		reset_ok = false
	end
	if not reset_ok then
		if marker_committed and marker_warning then
			notify(
				"Theme reset marker committed with a durability warning: " .. tostring(marker_warning),
				vim.log.levels.WARN
			)
			emit("warning", {
				colorscheme = state.opts.default,
				operation = "reset-marker",
				warning = tostring(marker_warning),
			})
		end
		report_lock_warning("reset", lock_warning, state.opts.default)
		local failure = append_warning(reset_warning_or_err, lock_warning)
		notify(failure, vim.log.levels.ERROR)
		emit("error", { colorscheme = state.opts.default, error = failure })
		return false
	end
	local warning = append_warning(reset_warning_or_err, lock_warning)
	if warning then
		notify("Theme reset committed with a durability warning: " .. warning, vim.log.levels.WARN)
		emit("warning", { colorscheme = state.opts.default, operation = "reset", warning = warning })
	end
	state.selection = { colorscheme = state.opts.default, source = "default", validity = { valid = true } }
	emit("reset", { colorscheme = state.opts.default })
	local repainted, repaint_result = M.repaint()
	return repainted, warning or repaint_result
end

function M.teardown()
	state.configured = false
	state.opts = nil
	state.painters = {}
	state.selection = nil
	state.active = nil
	state.last_known_good = nil
	test_hook = nil
	return true
end

function M._set_test_hook(callback)
	if callback ~= nil and type(callback) ~= "function" then
		error("theme_router test hook must be a function or nil")
	end
	test_hook = callback
end

return M
