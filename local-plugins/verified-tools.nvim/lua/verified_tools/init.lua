-- Verified, explicit lifecycle for release and package-manager tools.
local M = {}
local contracts = require("local_plugins.contracts")
local bit = require("bit")

local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	pcall(
		ffi.cdef,
		[[
				int fcntl(int fd, int cmd, ...);
				unsigned int geteuid(void);
				int mkdirat(int fd, const char *path, unsigned int mode);
			int openat(int fd, const char *path, int flags, ...);
			int renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int renameatx_np(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int unlinkat(int fd, const char *path, int flags);
		]]
	)
end

local SYSTEM = uv.os_uname().sysname
local DARWIN_F_GETPATH = 50
local DARWIN_PATH_BYTES = 1024
local RECORD_FFI_ABI_BY_SYSTEM = {
	Darwin = {
		at_removedir = 0x80,
		eexist = 17,
		open = {
			at_fdcwd = -2,
			create = 512,
			directory = 1048576,
			exclusive = 2048,
			nonblock = 4,
			no_follow = 256,
			write_only = 1,
		},
	},
	Linux = {
		at_removedir = 0x200,
		eexist = 17,
		open = {
			at_fdcwd = -100,
			create = 64,
			directory = 65536,
			exclusive = 128,
			nonblock = 2048,
			no_follow = 131072,
			write_only = 1,
		},
	},
}
local RECORD_FFI_ABI = RECORD_FFI_ABI_BY_SYSTEM[SYSTEM]
local RECORD_OPEN_FLAGS = RECORD_FFI_ABI and RECORD_FFI_ABI.open or nil
local configured = {}
local queue = {}
local running = {}
local running_count = 0
local drain_scheduled = false
local generation = 0
local temp_counter = 0
local instance_token
local pinned_pid
local pinned_state_root
local state_root_guard
local state_directory_guards = {}
local runtime_authority = { external_schema = 1 }

local RECORD_SCHEMA = 2
local PLAN_SCHEMA = 1
local MAX_SAFE_INTEGER = 9007199254740991
local LOCK_WAIT_MILLISECONDS = 250
local LOCK_POLL_MILLISECONDS = 5
local MAX_EXECUTABLE_BYTES = 256 * 1024 * 1024
local MAX_PRIVATE_BYTES = 256 * 1024
local MAX_RECORD_TRANSACTION_BYTES = MAX_PRIVATE_BYTES * 5 + 64 * 1024
local MAX_LEGACY_RECORDS = 512
local PRIVATE_FILE_MODE = 384 -- 0600
local PRIVATE_DIRECTORY_MODE = 448 -- 0700
local UNSAFE_WRITE_MASK = tonumber("22", 8) -- group/world write
local RECORD_TRANSACTION_SCHEMA = 1

runtime_authority.max_bundle_entries = 4096
runtime_authority.max_bundle_bytes = 512 * 1024 * 1024

local process_alive
local recover_record_transactions
local acquire_prepared_lock
local release_lock
local resource_lock_base

local STATUSES = {
	planned = true,
	blocked = true,
	claimed = true,
	queued = true,
	running = true,
	succeeded = true,
	failed = true,
	drift = true,
	cancelled = true,
	["repair-required"] = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function exact_keys(value, allowed)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if not allowed[key] then
			return false
		end
	end
	return true
end

local function finite_number(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function now()
	if type(configured.clock) == "function" then
		local ok, value = pcall(configured.clock)
		return ok and finite_number(value) and value or nil
	end
	return os.time()
end

local function pid()
	if pinned_pid then
		return pinned_pid
	end
	local ok, value
	if type(configured.pid) == "function" then
		ok, value = pcall(configured.pid)
	else
		ok, value = true, uv.os_getpid()
	end
	return ok and finite_number(value) and value >= 1 and value % 1 == 0 and value or nil
end

local function schedule_on_main(callback, ...)
	if not vim.in_fast_event() then
		return callback(...)
	end
	local arguments = { n = select("#", ...), ... }
	vim.schedule(function()
		callback(unpack(arguments, 1, arguments.n))
	end)
end

local notify
notify = function(message, level)
	if vim.in_fast_event() then
		schedule_on_main(notify, message, level)
		return
	end
	if type(configured.notify) == "function" then
		pcall(configured.notify, message, level)
	end
end

local function emit(name, value)
	if type(configured.events) == "function" then
		pcall(configured.events, name, copy(value))
	end
	if type(configured.on_state_change) == "function" then
		local event = copy(value)
		event.kind = name
		pcall(configured.on_state_change, event)
	end
end

local function bounded_reason(value, fallback)
	if type(value) ~= "string" or value == "" then
		return fallback
	end
	return value:gsub("[%c]", " "):sub(1, 160)
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

local function root()
	assert(type(pinned_state_root) == "string", "verified_tools.setup requires state_root")
	return pinned_state_root
end

local function contained(path, parent)
	path = vim.fs.normalize(path)
	parent = vim.fs.normalize(parent):gsub("/+$", "")
	return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function canonical_directory(path)
	local stat = uv.fs_lstat(path)
	local canonical = stat and stat.type == "directory" and uv.fs_realpath(path) or nil
	if not stat or stat.type ~= "directory" or not canonical or vim.fs.normalize(canonical) ~= path then
		return nil, "state path is not a canonical real directory"
	end
	return stat
end

local function validate_directory_guard(path, guard)
	local stat, err = canonical_directory(path)
	if not stat then
		return nil, err
	end
	if guard and (stat.dev ~= guard.dev or stat.ino ~= guard.ino) then
		return nil, "state directory identity changed"
	end
	return stat
end

local secure_directory

local function prepare_state()
	local paths = {
		{ root(), vim.fs.dirname(root()) },
		{ vim.fs.joinpath(root(), "records"), root() },
		{ vim.fs.joinpath(root(), "external-records"), root() },
		{ vim.fs.joinpath(root(), "active-slots"), root() },
		{ vim.fs.joinpath(root(), "record-transactions"), root() },
		{ vim.fs.joinpath(root(), "locks"), root() },
		{ vim.fs.joinpath(root(), "locks", "resources"), vim.fs.joinpath(root(), "locks") },
		{ vim.fs.joinpath(root(), "locks", "global"), vim.fs.joinpath(root(), "locks") },
		{ vim.fs.joinpath(root(), "shims"), root() },
		{ vim.fs.joinpath(root(), "shims", "bin"), vim.fs.joinpath(root(), "shims") },
		{ vim.fs.joinpath(root(), "shims", "owners"), vim.fs.joinpath(root(), "shims") },
	}
	local parent_ok, parent_err = validate_directory_guard(state_root_guard.parent, state_root_guard.parent_stat)
	if not parent_ok then
		return nil, parent_err
	end
	for _, entry in ipairs(paths) do
		local path, parent = entry[1], entry[2]
		if path == root() and state_root_guard.state == "present" then
			local current, current_err = validate_directory_guard(path, state_root_guard)
			if not current then
				return nil, current_err
			end
		end
		local expected_parent = parent
		if parent == state_root_guard.parent then
			expected_parent = nil
		end
		local ok, err = secure_directory(path, expected_parent)
		if not ok then
			return nil, err
		end
		if path == root() and state_root_guard.state == "absent" then
			local parent_current, parent_current_err =
				validate_directory_guard(state_root_guard.parent, state_root_guard.parent_stat)
			if not parent_current then
				return nil, parent_current_err
			end
			local current = state_directory_guards[path]
			state_root_guard = {
				state = "present",
				parent = state_root_guard.parent,
				parent_stat = state_root_guard.parent_stat,
				dev = current.dev,
				ino = current.ino,
			}
		end
	end
	if recover_record_transactions then
		return recover_record_transactions()
	end
	return true
end

local function validate_state_parent(path)
	if type(path) ~= "string" or not contained(path, root()) then
		return nil, "state path escapes pinned root"
	end
	local parent = vim.fs.dirname(path)
	local guard = state_directory_guards[parent]
	if not guard then
		return nil, "state parent is not pinned"
	end
	local ok, err = validate_directory_guard(parent, guard)
	if not ok then
		return nil, err
	end
	return true
end

local function resolve_state_root(value)
	if type(value) == "function" then
		local called, resolved = pcall(value)
		if not called then
			return nil, "state_root callback failed: " .. bounded_reason(resolved, "unknown error")
		end
		value = resolved
	end
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, "state_root must resolve to a non-empty string without NUL bytes"
	end
	local expanded_ok, expanded = pcall(vim.fn.fnamemodify, value, ":p")
	if not expanded_ok or type(expanded) ~= "string" then
		return nil, "state_root expansion failed"
	end
	expanded = vim.fs.normalize(expanded)
	if expanded == "/" or expanded:sub(1, 1) ~= "/" then
		return nil, "state_root must be an absolute non-root path"
	end
	local parent = vim.fs.dirname(expanded)
	local parent_stat, parent_err = canonical_directory(parent)
	if not parent_stat then
		return nil, "state_root parent is unsafe: " .. tostring(parent_err)
	end
	local existing = uv.fs_lstat(expanded)
	if existing then
		local current, current_err = canonical_directory(expanded)
		if not current then
			return nil, current_err
		end
		return expanded,
			{
				state = "present",
				parent = parent,
				parent_stat = { dev = parent_stat.dev, ino = parent_stat.ino },
				dev = current.dev,
				ino = current.ino,
			}
	end
	return expanded,
		{
			state = "absent",
			parent = parent,
			parent_stat = { dev = parent_stat.dev, ino = parent_stat.ino },
		}
end

local function unlink_regular(path)
	local stat = uv.fs_lstat(path)
	if stat and stat.type == "file" then
		pcall(uv.fs_unlink, path)
	end
end

local function write_all(fd, data)
	local offset = 0
	while offset < #data do
		local wrote, err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not wrote or wrote <= 0 then
			return nil, "write failed: " .. tostring(err)
		end
		offset = offset + wrote
	end
	return true
end

local function same_private_stat(left, right)
	local left_mtime, right_mtime = left and left.mtime or {}, right and right.mtime or {}
	local left_ctime, right_ctime = left and left.ctime or {}, right and right.ctime or {}
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and left_mtime.sec == right_mtime.sec
		and left_mtime.nsec == right_mtime.nsec
		and left_ctime.sec == right_ctime.sec
		and left_ctime.nsec == right_ctime.nsec
end

local read_private
local unlink_same_file
local run_interleave

local function record_ffi_ready()
	return ffi_ok and RECORD_FFI_ABI ~= nil
end

local function record_descriptor_path(fd)
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

local function record_descriptor_bound(fd, expected)
	local path = record_descriptor_path(fd)
	return type(path) == "string" and vim.fs.normalize(path) == vim.fs.normalize(expected)
end

local function record_openat(parent_fd, name, flags, mode)
	if not record_ffi_ready() then
		return nil, "descriptor-relative record operations are unavailable"
	end
	local raw
	if mode and mode ~= 0 then
		raw = ffi.C.openat(parent_fd, name, flags, ffi.new("unsigned int", mode))
	else
		raw = ffi.C.openat(parent_fd, name, flags)
	end
	if raw < 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return tonumber(raw)
end

local function record_open_directory(path)
	local expected, stat = uv.fs_realpath(path), canonical_directory(path)
	if not expected or vim.fs.normalize(expected) ~= vim.fs.normalize(path) or not stat then
		return nil, "record directory is not canonical"
	end
	local guard = state_directory_guards[path]
	if guard and (stat.dev ~= guard.dev or stat.ino ~= guard.ino) then
		return nil, "record directory identity changed"
	end
	if not record_ffi_ready() then
		return nil, "descriptor-relative record operations are unavailable"
	end
	local flags = RECORD_OPEN_FLAGS.directory + RECORD_OPEN_FLAGS.nonblock + RECORD_OPEN_FLAGS.no_follow
	local fd, open_err = record_openat(RECORD_OPEN_FLAGS.at_fdcwd, path, flags)
	if not fd then
		return nil, open_err
	end
	local opened = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "directory"
		or opened.dev ~= stat.dev
		or opened.ino ~= stat.ino
		or not record_descriptor_bound(fd, expected)
	then
		uv.fs_close(fd)
		return nil, "record directory changed while it was opened"
	end
	return fd, opened
end

local function record_open_directory_at(parent_fd, parent, name, secure, expected_stat)
	if not record_ffi_ready() then
		return nil, "descriptor-relative record operations are unavailable"
	end
	local flags = RECORD_OPEN_FLAGS.directory + RECORD_OPEN_FLAGS.nonblock + RECORD_OPEN_FLAGS.no_follow
	local fd, open_err, open_errno = record_openat(parent_fd, name, flags)
	if not fd then
		return nil, open_err, open_errno
	end
	local expected = vim.fs.joinpath(parent, name)
	local opened = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "directory"
		or not record_descriptor_bound(fd, expected)
		or expected_stat and (opened.dev ~= expected_stat.dev or opened.ino ~= expected_stat.ino)
		or secure and not uv.fs_fchmod(fd, PRIVATE_DIRECTORY_MODE)
	then
		uv.fs_close(fd)
		return nil, "record child directory changed while it was opened"
	end
	local after = uv.fs_fstat(fd)
	if
		not after
		or after.dev ~= opened.dev
		or after.ino ~= opened.ino
		or after.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or not record_descriptor_bound(fd, expected)
	then
		uv.fs_close(fd)
		return nil, "record child directory changed while it was secured"
	end
	return fd, after
end

M._sync_state_directory = function(fd)
	return uv.fs_fsync(fd)
end

secure_directory = function(path, parent)
	if not contained(path, root()) then
		return nil, "state directory escapes pinned root"
	end
	local parent_path = vim.fs.dirname(path)
	local name = vim.fs.basename(path)
	if name == "" or name == "." or name == ".." or name:find("/", 1, true) or name:find("\0", 1, true) then
		return nil, "state directory name is unsafe"
	end
	local expected_parent
	if parent then
		expected_parent = state_directory_guards[parent]
		if not expected_parent then
			return nil, "state parent is not pinned"
		end
	else
		expected_parent = state_root_guard.parent_stat
	end
	local parent_current, parent_err = validate_directory_guard(parent_path, expected_parent)
	if not parent_current then
		return nil, parent_err
	end
	local parent_fd, parent_opened = record_open_directory(parent_path)
	if
		not parent_fd
		or parent_opened.dev ~= parent_current.dev
		or parent_opened.ino ~= parent_current.ino
		or not record_descriptor_bound(parent_fd, parent_path)
	then
		if parent_fd then
			uv.fs_close(parent_fd)
		end
		return nil, "state directory identity changed"
	end
	local before = uv.fs_lstat(path)
	local created = false
	if not before then
		local hook_ok = run_interleave("before-state-directory-create", { parent = parent_path, path = path })
		local parent_after_hook = uv.fs_fstat(parent_fd)
		if
			not hook_ok
			or not parent_after_hook
			or parent_after_hook.dev ~= parent_opened.dev
			or parent_after_hook.ino ~= parent_opened.ino
			or not record_descriptor_bound(parent_fd, parent_path)
		then
			uv.fs_close(parent_fd)
			return nil, "state directory identity changed"
		end
		if ffi.C.mkdirat(parent_fd, name, PRIVATE_DIRECTORY_MODE) ~= 0 then
			local errno = ffi.errno()
			if errno ~= RECORD_FFI_ABI.eexist then
				uv.fs_close(parent_fd)
				return nil, "state directory is unavailable: errno " .. tostring(errno)
			end
		else
			created = true
		end
	elseif before.type ~= "directory" then
		uv.fs_close(parent_fd)
		return nil, "state path is not a real directory"
	end
	local guard = state_directory_guards[path]
	if not guard and path == root() and state_root_guard.state == "present" then
		guard = state_root_guard
	end
	local needs_barrier = created
		or not guard
		or guard.durable ~= true
		or not before
		or before.mode % 512 ~= PRIVATE_DIRECTORY_MODE
	if needs_barrier and guard then
		state_directory_guards[path] = { dev = guard.dev, ino = guard.ino, durable = false }
	end
	local child_fd, child = record_open_directory_at(parent_fd, parent_path, name, true, guard)
	if
		not child_fd
		or guard and (child.dev ~= guard.dev or child.ino ~= guard.ino)
		or uv.getuid and child.uid ~= uv.getuid()
	then
		if child_fd then
			uv.fs_close(child_fd)
		end
		uv.fs_close(parent_fd)
		return nil, "cannot secure state directory: " .. tostring(child)
	end
	if needs_barrier then
		state_directory_guards[path] = { dev = child.dev, ino = child.ino, durable = false }
	end
	local child_synced, child_sync_err = true, nil
	if needs_barrier then
		child_synced, child_sync_err = M._sync_state_directory(child_fd, path, "child", created)
	end
	local child_after = uv.fs_fstat(child_fd)
	local parent_after_child = uv.fs_fstat(parent_fd)
	if
		not child_synced
		or not child_after
		or child_after.dev ~= child.dev
		or child_after.ino ~= child.ino
		or child_after.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or not parent_after_child
		or parent_after_child.dev ~= parent_opened.dev
		or parent_after_child.ino ~= parent_opened.ino
		or not record_descriptor_bound(child_fd, path)
		or not record_descriptor_bound(parent_fd, parent_path)
	then
		uv.fs_close(child_fd)
		uv.fs_close(parent_fd)
		return nil, "state directory fsync failed: " .. tostring(child_sync_err or "identity changed")
	end
	local parent_synced, parent_sync_err = true, nil
	if needs_barrier then
		parent_synced, parent_sync_err = M._sync_state_directory(parent_fd, parent_path, "parent", created)
	end
	local child_final = uv.fs_fstat(child_fd)
	local parent_final = uv.fs_fstat(parent_fd)
	if
		not parent_synced
		or not child_final
		or child_final.dev ~= child.dev
		or child_final.ino ~= child.ino
		or not parent_final
		or parent_final.dev ~= parent_opened.dev
		or parent_final.ino ~= parent_opened.ino
		or not record_descriptor_bound(child_fd, path)
		or not record_descriptor_bound(parent_fd, parent_path)
	then
		uv.fs_close(child_fd)
		uv.fs_close(parent_fd)
		return nil, "state directory parent fsync failed: " .. tostring(parent_sync_err or "identity changed")
	end
	local child_closed, child_close_err = uv.fs_close(child_fd)
	local parent_closed, parent_close_err = uv.fs_close(parent_fd)
	if not child_closed or not parent_closed then
		return nil, "state directory close failed: " .. tostring(child_close_err or parent_close_err)
	end
	state_directory_guards[path] = { dev = child.dev, ino = child.ino, durable = true }
	return true
end

local function record_rename_noreplace(source_fd, source, destination_fd, destination)
	if not record_ffi_ready() then
		return nil, "descriptor-relative no-clobber rename is unavailable"
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(source_fd, source, destination_fd, destination, 4)
		end
		return ffi.C.renameat2(source_fd, source, destination_fd, destination, 1)
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

local function record_rename_exchange(left_fd, left, right_fd, right)
	if not record_ffi_ready() then
		return nil, "descriptor-relative exchange rename is unavailable"
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(left_fd, left, right_fd, right, 2)
		end
		return ffi.C.renameat2(left_fd, left, right_fd, right, 2)
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

local function record_unlinkat(parent_fd, name)
	if not record_ffi_ready() then
		return nil, "descriptor-relative record operations are unavailable"
	end
	if ffi.C.unlinkat(parent_fd, name, 0) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function record_rmdirat(parent_fd, name)
	if not record_ffi_ready() then
		return nil, "descriptor-relative record operations are unavailable"
	end
	if ffi.C.unlinkat(parent_fd, name, RECORD_FFI_ABI.at_removedir) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function same_private_after_rename(left, right)
	local left_mtime, right_mtime = left and left.mtime or {}, right and right.mtime or {}
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and left_mtime.sec == right_mtime.sec
		and left_mtime.nsec == right_mtime.nsec
end

local function same_generic_stat(left, right, renamed)
	local left_mtime, right_mtime = left and left.mtime or {}, right and right.mtime or {}
	local left_ctime, right_ctime = left and left.ctime or {}, right and right.ctime or {}
	return left
		and right
		and left.type == right.type
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and left_mtime.sec == right_mtime.sec
		and left_mtime.nsec == right_mtime.nsec
		and (renamed or left_ctime.sec == right_ctime.sec and left_ctime.nsec == right_ctime.nsec)
end

local function record_generic_snapshot(parent, name)
	local path = vim.fs.joinpath(parent, name)
	local before, before_err = uv.fs_lstat(path)
	if not before then
		if before_err and not tostring(before_err):find("ENOENT", 1, true) then
			return nil, before_err
		end
		return false
	end
	local link_target, link_err
	if before.type == "link" then
		link_target, link_err = uv.fs_readlink(path)
		if not link_target then
			return nil, link_err
		end
	end
	local after = uv.fs_lstat(path)
	if not after or not same_generic_stat(before, after, false) then
		return nil, "entry changed while its generic snapshot was read"
	end
	return { stat = after, link_target = link_target }
end

local function record_generic_matches(expected, current, renamed)
	return type(expected) == "table"
		and type(current) == "table"
		and expected.link_target == current.link_target
		and same_generic_stat(expected.stat, current.stat, renamed)
end

local function record_exact_matches(expected, current, renamed)
	return type(expected) == "table"
		and type(current) == "table"
		and expected.data == current.data
		and (
			renamed and same_private_after_rename(expected.stat, current.stat)
			or not renamed and same_private_stat(expected.stat, current.stat)
		)
end

local function record_stored_matches(expected, current)
	return type(expected) == "table"
		and type(expected.data) == "string"
		and type(current) == "table"
		and current.data == expected.data
		and tostring(current.stat.dev) == expected.dev
		and tostring(current.stat.ino) == expected.ino
		and current.stat.type == "file"
		and current.stat.size == #expected.data
		and current.stat.nlink == 1
		and current.stat.mode % 512 == PRIVATE_FILE_MODE
end

local function record_read_exact(parent_fd, parent, name, label, maximum)
	local flags = RECORD_OPEN_FLAGS.nonblock + RECORD_OPEN_FLAGS.no_follow
	local fd, open_err, errno = record_openat(parent_fd, name, flags)
	if not fd and errno == 2 then
		return false
	end
	if not fd then
		return nil, label .. " could not be opened: " .. tostring(open_err)
	end
	local before = uv.fs_fstat(fd)
	if
		not before
		or before.type ~= "file"
		or before.nlink ~= 1
		or before.mode % 512 ~= PRIVATE_FILE_MODE
		or before.size > maximum
		or not record_descriptor_bound(fd, vim.fs.joinpath(parent, name))
	then
		uv.fs_close(fd)
		return nil, label .. " is unsafe"
	end
	local data, read_err = uv.fs_read(fd, before.size, 0)
	local after = uv.fs_fstat(fd)
	local bound = record_descriptor_bound(fd, vim.fs.joinpath(parent, name))
	local closed, close_err = uv.fs_close(fd)
	if not data or #data ~= before.size or not same_private_stat(before, after) or not bound or not closed then
		return nil, label .. " changed while its exact bytes were read: " .. tostring(read_err or close_err)
	end
	return { data = data, stat = after }
end

local function record_write_exact(parent_fd, parent, name, data, label, maximum)
	if type(data) ~= "string" or #data > maximum then
		return nil, label .. " exceeds its private size limit"
	end
	local flags = RECORD_OPEN_FLAGS.write_only
		+ RECORD_OPEN_FLAGS.create
		+ RECORD_OPEN_FLAGS.exclusive
		+ RECORD_OPEN_FLAGS.no_follow
	local fd, open_err = record_openat(parent_fd, name, flags, PRIVATE_FILE_MODE)
	if not fd then
		return nil, label .. " could not be created: " .. tostring(open_err)
	end
	local created = uv.fs_fstat(fd)
	local secured = created
		and created.type == "file"
		and created.nlink == 1
		and record_descriptor_bound(fd, vim.fs.joinpath(parent, name))
		and uv.fs_fchmod(fd, PRIVATE_FILE_MODE)
	local wrote, write_err = secured and write_all(fd, data) or nil
	local synced, sync_err = wrote and uv.fs_fsync(fd) or nil
	local completed = synced and uv.fs_fstat(fd) or nil
	local closed, close_err = uv.fs_close(fd)
	if
		not secured
		or not wrote
		or not synced
		or not completed
		or not created
		or created.dev ~= completed.dev
		or created.ino ~= completed.ino
		or completed.size ~= #data
		or not closed
	then
		return nil, label .. " could not be persisted: " .. tostring(write_err or sync_err or close_err)
	end
	local exact, exact_err = record_read_exact(parent_fd, parent, name, label, maximum)
	if not exact or exact.data ~= data or not same_private_stat(completed, exact.stat) then
		return nil, label .. " bytes changed after staging: " .. tostring(exact_err or "snapshot mismatch")
	end
	return exact
end

local function record_restore_reserved(parent_fd, parent, name, reserved, label, detail)
	local restored, restore_err = record_rename_noreplace(parent_fd, reserved, parent_fd, name)
	local retained = restored and vim.fs.joinpath(parent, name) or vim.fs.joinpath(parent, reserved)
	return nil, detail .. "; " .. label .. " was preserved at " .. retained .. ": " .. tostring(restore_err or "ok")
end

local function record_conditional_unlink(parent_fd, parent, name, label, expected, hook_phase, missing_ok)
	temp_counter = temp_counter + 1
	local reserved = (".%s.remove.%d.%s.%d"):format(name, pid(), tostring(uv.hrtime()), temp_counter)
	local moved, move_err, move_errno = record_rename_noreplace(parent_fd, name, parent_fd, reserved)
	if not moved and move_errno == 2 then
		if missing_ok then
			return true
		end
		return nil, label .. " disappeared before cleanup"
	end
	if not moved then
		return nil, label .. " cleanup reservation failed: " .. tostring(move_err)
	end
	local current, current_err = record_read_exact(parent_fd, parent, reserved, label, MAX_RECORD_TRANSACTION_BYTES)
	if not current or not record_exact_matches(expected, current, true) then
		return record_restore_reserved(
			parent_fd,
			parent,
			name,
			reserved,
			label,
			label .. " changed before cleanup: " .. tostring(current_err or "snapshot mismatch")
		)
	end
	if hook_phase then
		local hook_ok, hook_err = run_interleave(hook_phase, {
			path = vim.fs.joinpath(parent, name),
			reserved_path = vim.fs.joinpath(parent, reserved),
			label = label,
		})
		if not hook_ok then
			return record_restore_reserved(parent_fd, parent, name, reserved, label, tostring(hook_err))
		end
	end
	local rechecked, recheck_err = record_read_exact(parent_fd, parent, reserved, label, MAX_RECORD_TRANSACTION_BYTES)
	if not rechecked or not record_exact_matches(current, rechecked, false) then
		return record_restore_reserved(
			parent_fd,
			parent,
			name,
			reserved,
			label,
			label .. " changed before reserved unlink: " .. tostring(recheck_err or "snapshot mismatch")
		)
	end
	local removed, remove_err = record_unlinkat(parent_fd, reserved)
	if not removed then
		return nil,
			label
				.. " reserved cleanup failed; entry remains at "
				.. vim.fs.joinpath(parent, reserved)
				.. ": "
				.. tostring(remove_err)
	end
	return true
end

local function stored_record_snapshot(snapshot)
	return {
		data = snapshot.data,
		dev = tostring(snapshot.stat.dev),
		ino = tostring(snapshot.stat.ino),
	}
end

local function encode_record_transaction(value)
	local ok, encoded = pcall(vim.json.encode, value)
	if not ok or type(encoded) ~= "string" then
		return nil, "record transaction is not encodable"
	end
	encoded = encoded .. "\n"
	if #encoded > MAX_RECORD_TRANSACTION_BYTES then
		return nil, "record transaction manifest exceeds its private size limit"
	end
	return encoded
end

local function record_transaction_root()
	return vim.fs.joinpath(root(), "record-transactions")
end

local function close_record_transaction(transaction)
	if transaction.fd then
		pcall(uv.fs_close, transaction.fd)
		transaction.fd = nil
	end
	if transaction.root_fd then
		pcall(uv.fs_close, transaction.root_fd)
		transaction.root_fd = nil
	end
end

local function open_record_transaction(root_fd, root_path, name)
	local path = vim.fs.joinpath(root_path, name)
	local fd, opened_or_err = record_open_directory_at(root_fd, root_path, name, false)
	if not fd then
		return nil, opened_or_err
	end
	local stat = uv.fs_lstat(path)
	if
		not stat
		or stat.type ~= "directory"
		or stat.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or vim.fs.dirname(path) ~= root_path
		or stat.dev ~= opened_or_err.dev
		or stat.ino ~= opened_or_err.ino
	then
		uv.fs_close(fd)
		return nil, "record transaction directory is unsafe"
	end
	return { root_fd = root_fd, root_path = root_path, name = name, path = path, fd = fd, stat = stat }
end

local function create_record_transaction(path, data, original)
	local root_path = record_transaction_root()
	local root_fd, root_err = record_open_directory(root_path)
	if not root_fd then
		return nil, root_err
	end
	local prefix = ("record.%d.%s."):format(pid(), instance_token)
	local name
	for attempt = 1, 8 do
		temp_counter = temp_counter + 1
		local candidate = ("%s%s.%d.%d"):format(prefix, tostring(uv.hrtime()), temp_counter, attempt)
		if ffi.C.mkdirat(root_fd, candidate, PRIVATE_DIRECTORY_MODE) == 0 then
			name = candidate
			break
		end
		if ffi.errno() ~= 17 then
			uv.fs_close(root_fd)
			return nil, "record transaction reservation failed: errno " .. tostring(ffi.errno())
		end
	end
	if not name then
		uv.fs_close(root_fd)
		return nil, "record transaction reservation namespace is exhausted"
	end
	local directory = vim.fs.joinpath(root_path, name)
	local transaction_fd, transaction_stat = record_open_directory_at(root_fd, root_path, name, true)
	local transaction = transaction_fd
			and {
				root_fd = root_fd,
				root_path = root_path,
				name = name,
				path = directory,
				fd = transaction_fd,
				stat = transaction_stat,
			}
		or nil
	if not transaction then
		uv.fs_close(root_fd)
		return nil, "record transaction directory is unsafe: " .. tostring(transaction_stat)
	end
	state_directory_guards[directory] = { dev = transaction.stat.dev, ino = transaction.stat.ino }
	local manifest = {
		schema = RECORD_TRANSACTION_SCHEMA,
		kind = "record-transaction",
		target = vim.fs.basename(path),
		target_namespace = vim.fs.basename(vim.fs.dirname(path)),
		owner_pid = pid(),
		owner_token = instance_token,
		new_data = data,
		old = original and stored_record_snapshot(original) or false,
	}
	local manifest_data, manifest_err = encode_record_transaction(manifest)
	if not manifest_data then
		close_record_transaction(transaction)
		return nil, manifest_err
	end
	local manifest_snapshot, write_err = record_write_exact(
		transaction.fd,
		transaction.path,
		"manifest",
		manifest_data,
		"record transaction manifest",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if not manifest_snapshot then
		close_record_transaction(transaction)
		return nil, write_err
	end
	local staged, stage_err = record_write_exact(
		transaction.fd,
		transaction.path,
		"stage",
		data,
		"record transaction staging",
		MAX_PRIVATE_BYTES
	)
	if not staged then
		close_record_transaction(transaction)
		return nil, stage_err
	end
	local ready = {
		schema = RECORD_TRANSACTION_SCHEMA,
		kind = "record-transaction-ready",
		manifest_sha256 = vim.fn.sha256(manifest_data),
		new_dev = tostring(staged.stat.dev),
		new_ino = tostring(staged.stat.ino),
	}
	local ready_data, ready_err = encode_record_transaction(ready)
	if not ready_data then
		close_record_transaction(transaction)
		return nil, ready_err
	end
	local ready_snapshot
	ready_snapshot, write_err = record_write_exact(
		transaction.fd,
		transaction.path,
		"ready",
		ready_data,
		"record transaction readiness",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if not ready_snapshot or not uv.fs_fsync(transaction.fd) or not uv.fs_fsync(root_fd) then
		close_record_transaction(transaction)
		return nil, write_err or "record transaction readiness could not be synced"
	end
	transaction.manifest = manifest
	transaction.manifest_data = manifest_data
	transaction.manifest_snapshot = manifest_snapshot
	transaction.ready_data = ready_data
	transaction.ready_snapshot = ready_snapshot
	transaction.new = stored_record_snapshot(staged)
	transaction.staged = staged
	transaction.commit_data = encode_record_transaction({
		schema = RECORD_TRANSACTION_SCHEMA,
		kind = "record-transaction-committed",
		ready_sha256 = vim.fn.sha256(ready_data),
	})
	return transaction
end

local function transaction_known_snapshots(transaction, stage_expected)
	local allowed = { manifest = true, ready = true, committed = true }
	if stage_expected then
		allowed.stage = true
	end
	for name in vim.fs.dir(transaction.path) do
		if not allowed[name] then
			return nil, "record transaction contains an unknown entry " .. name
		end
	end
	local expected_data = {
		manifest = transaction.manifest_data,
		ready = transaction.ready_data,
		committed = transaction.commit_data,
	}
	local snapshots = {}
	for _, name in ipairs({ "stage", "committed", "ready", "manifest" }) do
		local snapshot, snapshot_err = record_read_exact(
			transaction.fd,
			transaction.path,
			name,
			"record transaction " .. name,
			MAX_RECORD_TRANSACTION_BYTES
		)
		if snapshot ~= false then
			if not snapshot then
				return nil, snapshot_err
			end
			if name == "stage" then
				if not stage_expected or not record_stored_matches(stage_expected, snapshot) then
					return nil, "record transaction staging changed"
				end
			elseif snapshot.data ~= expected_data[name] then
				return nil, "record transaction " .. name .. " changed"
			end
			snapshots[name] = snapshot
		elseif name == "manifest" or name == "ready" then
			return nil, "record transaction lost " .. name
		end
	end
	return snapshots
end

local function remove_empty_record_transaction(transaction)
	local warning
	if transaction.fd then
		local closed, close_err = uv.fs_close(transaction.fd)
		if not closed then
			warning = append_warning(warning, "record transaction directory close failed: " .. tostring(close_err))
		end
		transaction.fd = nil
	end
	for name in vim.fs.dir(transaction.path) do
		return nil, "record transaction retained unknown entry " .. name
	end
	temp_counter = temp_counter + 1
	local reserved = ("%s.remove.%d.%s.%d"):format(transaction.name, pid(), tostring(uv.hrtime()), temp_counter)
	local moved, move_err =
		record_rename_noreplace(transaction.root_fd, transaction.name, transaction.root_fd, reserved)
	if not moved then
		return nil, "record transaction directory cleanup reservation failed: " .. tostring(move_err)
	end
	local reserved_path = vim.fs.joinpath(transaction.root_path, reserved)
	local reserved_fd, reserved_open_err =
		record_open_directory_at(transaction.root_fd, transaction.root_path, reserved, false)
	local current = reserved_fd and uv.fs_fstat(reserved_fd) or nil
	if
		not reserved_fd
		or not current
		or current.type ~= "directory"
		or current.dev ~= transaction.stat.dev
		or current.ino ~= transaction.stat.ino
	then
		if reserved_fd then
			uv.fs_close(reserved_fd)
		end
		record_rename_noreplace(transaction.root_fd, reserved, transaction.root_fd, transaction.name)
		return nil, "record transaction directory changed before cleanup: " .. tostring(reserved_open_err)
	end
	for name in vim.fs.dir(reserved_path) do
		uv.fs_close(reserved_fd)
		record_rename_noreplace(transaction.root_fd, reserved, transaction.root_fd, transaction.name)
		return nil, "record transaction directory gained unknown entry " .. name
	end
	local rechecked = uv.fs_fstat(reserved_fd)
	if
		not rechecked
		or rechecked.dev ~= transaction.stat.dev
		or rechecked.ino ~= transaction.stat.ino
		or not record_descriptor_bound(reserved_fd, reserved_path)
	then
		uv.fs_close(reserved_fd)
		record_rename_noreplace(transaction.root_fd, reserved, transaction.root_fd, transaction.name)
		return nil, "record transaction directory changed at the cleanup boundary"
	end
	local removed, remove_err = record_rmdirat(transaction.root_fd, reserved)
	if not removed then
		uv.fs_close(reserved_fd)
		return nil, "record transaction empty directory remains at " .. reserved_path .. ": " .. tostring(remove_err)
	end
	local reserved_closed, reserved_close_err = uv.fs_close(reserved_fd)
	if not reserved_closed then
		warning = append_warning(
			warning,
			"removed record transaction directory close failed: " .. tostring(reserved_close_err)
		)
	end
	state_directory_guards[transaction.path] = nil
	local hook_ok, hook_err = run_interleave("record-transaction-cleanup-committed", {
		root_path = transaction.root_path,
		transaction_path = transaction.path,
	})
	if not hook_ok then
		warning = append_warning(warning, "record transaction cleanup hook failed: " .. tostring(hook_err))
	end
	local synced, sync_err = uv.fs_fsync(transaction.root_fd)
	if not synced then
		warning = append_warning(warning, "record transaction root fsync failed: " .. tostring(sync_err))
	end
	local root_closed, root_close_err = uv.fs_close(transaction.root_fd)
	if not root_closed then
		warning = append_warning(warning, "record transaction root close failed: " .. tostring(root_close_err))
	end
	transaction.root_fd = nil
	return true, warning
end

local function cleanup_record_transaction(transaction, stage_expected, cleanup_hook)
	-- Normal callers retain their identity/resource lock until this cleanup
	-- returns. Recovery first claims a dead owner's unique transaction directory,
	-- so two cooperating recoverers cannot clean the same namespace concurrently.
	local snapshots, inspect_err = transaction_known_snapshots(transaction, stage_expected)
	if not snapshots then
		return nil, inspect_err
	end
	for _, name in ipairs({ "stage", "committed", "ready", "manifest" }) do
		local snapshot = snapshots[name]
		if snapshot then
			local cleaned, cleanup_err = record_conditional_unlink(
				transaction.fd,
				transaction.path,
				name,
				"record transaction " .. name,
				snapshot,
				name == "stage" and cleanup_hook or nil,
				false
			)
			if not cleaned then
				return nil, cleanup_err
			end
		end
	end
	local removed, remove_warning_or_err = remove_empty_record_transaction(transaction)
	if removed and remove_warning_or_err then
		notify(
			"record transaction cleanup committed with a durability warning: " .. tostring(remove_warning_or_err),
			vim.log.levels.WARN
		)
	end
	return removed, remove_warning_or_err
end

local function publish_record_commit(transaction)
	local existing, existing_err = record_read_exact(
		transaction.fd,
		transaction.path,
		"committed",
		"record transaction commit",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if existing then
		if existing.data == transaction.commit_data then
			return true
		end
		return nil, "record transaction commit marker changed"
	end
	if existing == nil then
		return nil, existing_err
	end
	local marker, marker_err = record_write_exact(
		transaction.fd,
		transaction.path,
		"committed",
		transaction.commit_data,
		"record transaction commit",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if not marker or not uv.fs_fsync(transaction.fd) then
		return nil, marker_err or "record transaction commit marker could not be synced"
	end
	return true
end

local function committed_record_result(transaction, record_fd, stage_expected)
	local record_synced, transaction_synced = uv.fs_fsync(record_fd), uv.fs_fsync(transaction.fd)
	local marked, marker_err = publish_record_commit(transaction)
	if not record_synced or not transaction_synced or not marked then
		notify(
			"record committed; recovery transaction retained: " .. tostring(marker_err or "directory sync failed"),
			vim.log.levels.WARN
		)
		uv.fs_close(record_fd)
		close_record_transaction(transaction)
		return true
	end
	local cleaned, cleanup_err =
		cleanup_record_transaction(transaction, stage_expected, "before-record-displaced-cleanup")
	uv.fs_close(record_fd)
	if not cleaned then
		notify(
			"record committed; deferred cleanup preserved transaction: " .. tostring(cleanup_err),
			vim.log.levels.WARN
		)
		close_record_transaction(transaction)
	end
	return true
end

local function rollback_record_exchange(transaction, record_fd, record_parent, target, published, displaced, detail)
	if not published or not displaced or not record_stored_matches(transaction.new, published) then
		close_record_transaction(transaction)
		uv.fs_close(record_fd)
		return nil, "record exchange drifted; both sides were preserved: " .. tostring(detail)
	end
	local published_now = record_read_exact(record_fd, record_parent, target, "published record", MAX_PRIVATE_BYTES)
	local displaced_now = record_generic_snapshot(transaction.path, "stage")
	if
		not published_now
		or not displaced_now
		or not record_exact_matches(published, published_now, false)
		or not record_generic_matches(displaced, displaced_now, false)
	then
		close_record_transaction(transaction)
		uv.fs_close(record_fd)
		return nil, "record conflict rollback inputs changed; both sides were preserved"
	end
	local restored, restore_err = record_rename_exchange(record_fd, target, transaction.fd, "stage")
	if not restored then
		close_record_transaction(transaction)
		uv.fs_close(record_fd)
		return nil, "record conflict rollback failed; both sides were preserved: " .. tostring(restore_err)
	end
	local rival = record_generic_snapshot(record_parent, target)
	local own = record_read_exact(transaction.fd, transaction.path, "stage", "rolled-back record", MAX_PRIVATE_BYTES)
	if
		not rival
		or not own
		or not record_generic_matches(displaced_now, rival, true)
		or not record_exact_matches(published_now, own, true)
	then
		close_record_transaction(transaction)
		uv.fs_close(record_fd)
		return nil, "record conflict rollback completed with drift; no cleanup was attempted"
	end
	local cleaned, cleanup_err = cleanup_record_transaction(transaction, transaction.new)
	uv.fs_close(record_fd)
	if not cleaned then
		close_record_transaction(transaction)
	end
	return nil,
		"record changed concurrently; competing record was restored"
			.. (cleaned and "" or "; " .. tostring(cleanup_err))
end

local function atomic_write(path, data)
	if type(data) ~= "string" or #data > MAX_PRIVATE_BYTES then
		return nil, "private record exceeds 256 KiB"
	end
	local record_parent = vim.fs.dirname(path)
	local target = vim.fs.basename(path)
	local allowed_parent = record_parent == vim.fs.joinpath(root(), "records")
		or record_parent == vim.fs.joinpath(root(), "external-records")
		or record_parent == vim.fs.joinpath(root(), "active-slots")
	if not allowed_parent or not target:match("^[0-9a-f]+%.json$") or not validate_state_parent(path) then
		return nil, "record target is outside a pinned record directory"
	end
	local record_fd, record_err = record_open_directory(record_parent)
	if not record_fd then
		return nil, record_err
	end
	local original, original_err =
		record_read_exact(record_fd, record_parent, target, "record target", MAX_PRIVATE_BYTES)
	if original == nil then
		uv.fs_close(record_fd)
		return nil, original_err
	end
	if original and original.data == data then
		uv.fs_close(record_fd)
		return true
	end
	local transaction, transaction_err = create_record_transaction(path, data, original ~= false and original or nil)
	if not transaction then
		uv.fs_close(record_fd)
		return nil, transaction_err
	end
	local hook_ok, hook_err = run_interleave("record-stage-ready", {
		path = path,
		transaction_path = transaction.path,
		staging_path = vim.fs.joinpath(transaction.path, "stage"),
	})
	local staged =
		record_read_exact(transaction.fd, transaction.path, "stage", "record transaction staging", MAX_PRIVATE_BYTES)
	local current = record_read_exact(record_fd, record_parent, target, "record target", MAX_PRIVATE_BYTES)
	local unchanged = original == false and current == false
		or original ~= false and current ~= false and record_exact_matches(original, current, false)
	if not hook_ok or not staged or not record_stored_matches(transaction.new, staged) or not unchanged then
		local cleaned, cleanup_err = cleanup_record_transaction(transaction, transaction.new)
		uv.fs_close(record_fd)
		if not cleaned then
			close_record_transaction(transaction)
		end
		return nil,
			"record changed before atomic publication: "
				.. tostring(hook_err or "snapshot mismatch")
				.. (cleaned and "" or "; " .. tostring(cleanup_err))
	end
	local target_hook_ok, target_hook_err = run_interleave("record-target-checked", {
		path = path,
		transaction_path = transaction.path,
		staging_path = vim.fs.joinpath(transaction.path, "stage"),
		target_present = original ~= false,
	})
	if not target_hook_ok then
		local cleaned, cleanup_err = cleanup_record_transaction(transaction, transaction.new)
		uv.fs_close(record_fd)
		if not cleaned then
			close_record_transaction(transaction)
		end
		return nil,
			"record target-check hook failed: " .. tostring(target_hook_err) .. (cleaned and "" or "; " .. tostring(
				cleanup_err
			))
	end
	if original == false then
		local published, publish_err = record_rename_noreplace(transaction.fd, "stage", record_fd, target)
		if not published then
			local cleaned, cleanup_err = cleanup_record_transaction(transaction, transaction.new)
			uv.fs_close(record_fd)
			if not cleaned then
				close_record_transaction(transaction)
			end
			return nil,
				"record no-clobber publication failed: "
					.. tostring(publish_err)
					.. (cleaned and "" or "; " .. tostring(cleanup_err))
		end
		run_interleave("after-record-exchange", {
			path = path,
			transaction_path = transaction.path,
			staging_path = vim.fs.joinpath(transaction.path, "stage"),
		})
		local final = record_read_exact(record_fd, record_parent, target, "published record", MAX_PRIVATE_BYTES)
		if not final or not record_stored_matches(transaction.new, final) then
			close_record_transaction(transaction)
			uv.fs_close(record_fd)
			return nil, "initial record publication drifted; transaction was preserved"
		end
		return committed_record_result(transaction, record_fd, nil)
	end
	local exchanged, exchange_err = record_rename_exchange(record_fd, target, transaction.fd, "stage")
	if not exchanged then
		local cleaned, cleanup_err = cleanup_record_transaction(transaction, transaction.new)
		uv.fs_close(record_fd)
		if not cleaned then
			close_record_transaction(transaction)
		end
		return nil,
			"record exchange failed: " .. tostring(exchange_err) .. (cleaned and "" or "; " .. tostring(cleanup_err))
	end
	local exchange_hook_ok, exchange_hook_err = run_interleave("after-record-exchange", {
		path = path,
		transaction_path = transaction.path,
		staging_path = vim.fs.joinpath(transaction.path, "stage"),
	})
	local published = record_read_exact(record_fd, record_parent, target, "published record", MAX_PRIVATE_BYTES)
	local displaced = record_generic_snapshot(transaction.path, "stage")
	local displaced_record =
		record_read_exact(transaction.fd, transaction.path, "stage", "displaced record", MAX_PRIVATE_BYTES)
	if
		exchange_hook_ok
		and published
		and displaced_record
		and record_stored_matches(transaction.new, published)
		and record_exact_matches(original, displaced_record, true)
	then
		return committed_record_result(transaction, record_fd, stored_record_snapshot(displaced_record))
	end
	return rollback_record_exchange(
		transaction,
		record_fd,
		record_parent,
		target,
		published,
		displaced,
		exchange_hook_err or "exact record CAS mismatch"
	)
end

local function decode_record_transaction(transaction)
	local manifest_snapshot, manifest_err = record_read_exact(
		transaction.fd,
		transaction.path,
		"manifest",
		"record transaction manifest",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if not manifest_snapshot then
		return nil, manifest_err or "record transaction manifest is absent"
	end
	local decoded_ok, manifest = pcall(vim.json.decode, manifest_snapshot.data)
	if
		not decoded_ok
		or type(manifest) ~= "table"
		or not exact_keys(manifest, {
			schema = true,
			kind = true,
			target = true,
			target_namespace = true,
			owner_pid = true,
			owner_token = true,
			new_data = true,
			old = true,
		})
		or manifest.schema ~= RECORD_TRANSACTION_SCHEMA
		or manifest.kind ~= "record-transaction"
		or type(manifest.target) ~= "string"
		or not manifest.target:match("^[0-9a-f]+%.json$")
		or (manifest.target_namespace ~= nil and manifest.target_namespace ~= "records" and manifest.target_namespace ~= "external-records" and manifest.target_namespace ~= "active-slots")
		or not finite_number(manifest.owner_pid)
		or manifest.owner_pid < 1
		or manifest.owner_pid % 1 ~= 0
		or type(manifest.owner_token) ~= "string"
		or #manifest.owner_token ~= 64
		or not manifest.owner_token:match("^[0-9a-f]+$")
		or type(manifest.new_data) ~= "string"
		or #manifest.new_data > MAX_PRIVATE_BYTES
	then
		return nil, "record transaction manifest is corrupt"
	end
	if
		manifest.old ~= false
		and (
			type(manifest.old) ~= "table"
			or not exact_keys(manifest.old, { data = true, dev = true, ino = true })
			or type(manifest.old.data) ~= "string"
			or #manifest.old.data > MAX_PRIVATE_BYTES
			or type(manifest.old.dev) ~= "string"
			or type(manifest.old.ino) ~= "string"
		)
	then
		return nil, "record transaction old snapshot is corrupt"
	end
	local ready_snapshot, ready_err = record_read_exact(
		transaction.fd,
		transaction.path,
		"ready",
		"record transaction readiness",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if not ready_snapshot then
		return nil, ready_err or "record transaction is not ready"
	end
	local ready_ok, ready = pcall(vim.json.decode, ready_snapshot.data)
	if
		not ready_ok
		or type(ready) ~= "table"
		or not exact_keys(ready, {
			schema = true,
			kind = true,
			manifest_sha256 = true,
			new_dev = true,
			new_ino = true,
		})
		or ready.schema ~= RECORD_TRANSACTION_SCHEMA
		or ready.kind ~= "record-transaction-ready"
		or ready.manifest_sha256 ~= vim.fn.sha256(manifest_snapshot.data)
		or type(ready.new_dev) ~= "string"
		or type(ready.new_ino) ~= "string"
	then
		return nil, "record transaction readiness is corrupt"
	end
	transaction.manifest = manifest
	transaction.manifest_data = manifest_snapshot.data
	transaction.manifest_snapshot = manifest_snapshot
	transaction.ready_data = ready_snapshot.data
	transaction.ready_snapshot = ready_snapshot
	transaction.new = { data = manifest.new_data, dev = ready.new_dev, ino = ready.new_ino }
	transaction.commit_data = assert(encode_record_transaction({
		schema = RECORD_TRANSACTION_SCHEMA,
		kind = "record-transaction-committed",
		ready_sha256 = vim.fn.sha256(ready_snapshot.data),
	}))
	local committed, committed_err = record_read_exact(
		transaction.fd,
		transaction.path,
		"committed",
		"record transaction commit",
		MAX_RECORD_TRANSACTION_BYTES
	)
	if committed == nil then
		return nil, committed_err
	end
	if committed and committed.data ~= transaction.commit_data then
		return nil, "record transaction commit marker is corrupt"
	end
	transaction.committed = committed ~= false
	return transaction
end

local function claim_record_transaction(transaction)
	temp_counter = temp_counter + 1
	local claimed_name = ("recover.%d.%s.%s.%d"):format(pid(), instance_token, tostring(uv.hrtime()), temp_counter)
	if transaction.fd then
		uv.fs_close(transaction.fd)
		transaction.fd = nil
	end
	local moved, move_err, move_errno =
		record_rename_noreplace(transaction.root_fd, transaction.name, transaction.root_fd, claimed_name)
	if not moved then
		close_record_transaction(transaction)
		if move_errno == 2 then
			return false
		end
		return nil, move_err
	end
	local claimed, open_err = open_record_transaction(transaction.root_fd, transaction.root_path, claimed_name)
	if not claimed or claimed.stat.dev ~= transaction.stat.dev or claimed.stat.ino ~= transaction.stat.ino then
		if claimed then
			close_record_transaction(claimed)
		else
			uv.fs_close(transaction.root_fd)
		end
		return nil, "claimed record transaction changed identity: " .. tostring(open_err)
	end
	return claimed
end

local function preserve_recovery_transaction(transaction, message)
	notify(message .. "; transaction preserved at " .. transaction.path, vim.log.levels.WARN)
	close_record_transaction(transaction)
	return true
end

local function recover_record_transaction(transaction)
	local decoded, decode_err = decode_record_transaction(transaction)
	if not decoded then
		return preserve_recovery_transaction(
			transaction,
			"record recovery skipped unsafe state: " .. tostring(decode_err)
		)
	end
	local alive = process_alive(decoded.manifest.owner_pid, decoded.manifest.owner_token)
	if alive ~= false then
		close_record_transaction(transaction)
		return true
	end
	local recovery_lock
	if decoded.manifest.target_namespace == "active-slots" then
		local target_digest = decoded.manifest.target:match("^([0-9a-f]+)%.json$")
		if not target_digest or #target_digest ~= 64 then
			return preserve_recovery_transaction(transaction, "active-slot recovery target is invalid")
		end
		local resource = "active-slot:" .. target_digest
		local lock_err
		recovery_lock, lock_err = acquire_prepared_lock(resource_lock_base(resource), resource, 0)
		if not recovery_lock then
			close_record_transaction(transaction)
			if lock_err == "locked" or lock_err == "lock-owner-unverifiable" then
				return true
			end
			return nil, "active-slot recovery lock failed: " .. tostring(lock_err)
		end
	end
	local function continue_recovery()
		local claimed, claim_err = claim_record_transaction(transaction)
		if claimed == false then
			return true
		end
		if not claimed then
			return nil, "record recovery claim failed: " .. tostring(claim_err)
		end
		decoded, decode_err = decode_record_transaction(claimed)
		if not decoded then
			return preserve_recovery_transaction(claimed, "record recovery claim changed: " .. tostring(decode_err))
		end
		-- Transactions created before external certifications existed omitted the
		-- namespace and continue to recover against the managed records directory.
		local record_parent = vim.fs.joinpath(root(), decoded.manifest.target_namespace or "records")
		local record_fd, record_err = record_open_directory(record_parent)
		if not record_fd then
			close_record_transaction(decoded)
			return nil, record_err
		end
		local target = record_read_exact(
			record_fd,
			record_parent,
			decoded.manifest.target,
			"record recovery target",
			MAX_PRIVATE_BYTES
		)
		local stage = record_read_exact(decoded.fd, decoded.path, "stage", "record recovery staging", MAX_PRIVATE_BYTES)
		local target_entry = record_generic_snapshot(record_parent, decoded.manifest.target)
		local stage_entry = record_generic_snapshot(decoded.path, "stage")
		local target_new = target and record_stored_matches(decoded.new, target)
		local stage_new = stage and record_stored_matches(decoded.new, stage)
		local old = decoded.manifest.old
		local target_old = old ~= false and target and record_stored_matches(old, target)
		local stage_old = old ~= false and stage and record_stored_matches(old, stage)
		if decoded.committed then
			if not target_new then
				uv.fs_close(record_fd)
				return preserve_recovery_transaction(decoded, "committed record recovery target drifted")
			end
			if (old == false and stage_entry ~= false) or (old ~= false and not stage_old) then
				uv.fs_close(record_fd)
				return preserve_recovery_transaction(decoded, "committed record recovery cleanup side changed")
			end
			local cleaned, cleanup_err = cleanup_record_transaction(decoded, old ~= false and old or nil)
			uv.fs_close(record_fd)
			if not cleaned then
				return preserve_recovery_transaction(
					decoded,
					"committed record cleanup deferred: " .. tostring(cleanup_err)
				)
			end
			return true
		end
		if old == false then
			if target_new and stage_entry == false then
				local marked, marker_err = publish_record_commit(decoded)
				if not marked then
					uv.fs_close(record_fd)
					return preserve_recovery_transaction(
						decoded,
						"initial record commit recovery deferred: " .. tostring(marker_err)
					)
				end
				local cleaned, cleanup_err = cleanup_record_transaction(decoded, nil)
				uv.fs_close(record_fd)
				if not cleaned then
					return preserve_recovery_transaction(
						decoded,
						"initial record cleanup deferred: " .. tostring(cleanup_err)
					)
				end
				return true
			end
			if stage_new and not target_new then
				local cleaned, cleanup_err = cleanup_record_transaction(decoded, decoded.new)
				uv.fs_close(record_fd)
				if not cleaned then
					return preserve_recovery_transaction(
						decoded,
						"aborted initial record cleanup deferred: " .. tostring(cleanup_err)
					)
				end
				return true
			end
			uv.fs_close(record_fd)
			return preserve_recovery_transaction(decoded, "initial record recovery state is ambiguous")
		end
		if target_old and stage_new then
			local cleaned, cleanup_err = cleanup_record_transaction(decoded, decoded.new)
			uv.fs_close(record_fd)
			if not cleaned then
				return preserve_recovery_transaction(
					decoded,
					"prepared record cleanup deferred: " .. tostring(cleanup_err)
				)
			end
			return true
		end
		if target_new and stage_old then
			local marked, marker_err = publish_record_commit(decoded)
			if not marked then
				uv.fs_close(record_fd)
				return preserve_recovery_transaction(
					decoded,
					"record commit recovery deferred: " .. tostring(marker_err)
				)
			end
			local cleaned, cleanup_err = cleanup_record_transaction(decoded, old)
			uv.fs_close(record_fd)
			if not cleaned then
				return preserve_recovery_transaction(decoded, "record cleanup deferred: " .. tostring(cleanup_err))
			end
			return true
		end
		if target_new and stage_entry then
			local _, rollback_err = rollback_record_exchange(
				decoded,
				record_fd,
				record_parent,
				decoded.manifest.target,
				target,
				stage_entry,
				"recovering interrupted conflicting exchange"
			)
			notify("record recovery restored an exchanged rival: " .. tostring(rollback_err), vim.log.levels.WARN)
			return true
		end
		if stage_new and target_entry then
			local cleaned, cleanup_err = cleanup_record_transaction(decoded, decoded.new)
			uv.fs_close(record_fd)
			if not cleaned then
				return preserve_recovery_transaction(
					decoded,
					"competing record cleanup deferred: " .. tostring(cleanup_err)
				)
			end
			return true
		end
		uv.fs_close(record_fd)
		return preserve_recovery_transaction(decoded, "record recovery state is ambiguous")
	end
	if not recovery_lock then
		return continue_recovery()
	end
	local call_ok, recovered, recovery_err = pcall(continue_recovery)
	local released, release_err = release_lock(recovery_lock)
	if not released then
		if call_ok and recovered then
			notify(
				"active-slot recovery committed but lock release retained evidence: " .. tostring(release_err),
				vim.log.levels.WARN
			)
			return true
		end
		return nil,
			"active-slot recovery lock release failed: " .. tostring(release_err) .. (call_ok and "; " .. tostring(
				recovery_err
			) or "")
	end
	if not call_ok then
		return nil, "active-slot recovery crashed: " .. tostring(recovered)
	end
	return recovered, recovery_err
end

recover_record_transactions = function()
	local transaction_root = record_transaction_root()
	local entries = {}
	for name in vim.fs.dir(transaction_root) do
		entries[#entries + 1] = name
	end
	table.sort(entries)
	for _, name in ipairs(entries) do
		local recovering_pid, recovering_token = name:match("^recover%.(%d+)%.([0-9a-f]+)%.")
		if recovering_pid and process_alive(tonumber(recovering_pid), recovering_token) ~= false then
			-- A live or unverifiable recovery owner retains its private transaction.
		elseif not name:match("^record%.") and not recovering_pid then
			notify(
				"unknown record transaction entry preserved at " .. vim.fs.joinpath(transaction_root, name),
				vim.log.levels.WARN
			)
		else
			local root_fd, root_err = record_open_directory(transaction_root)
			if not root_fd then
				return nil, root_err
			end
			local transaction, transaction_err = open_record_transaction(root_fd, transaction_root, name)
			if not transaction then
				uv.fs_close(root_fd)
				notify(
					"unsafe record transaction entry preserved at "
						.. vim.fs.joinpath(transaction_root, name)
						.. ": "
						.. tostring(transaction_err or root_err),
					vim.log.levels.WARN
				)
			else
				local recovered, recovery_err = recover_record_transaction(transaction)
				if not recovered then
					return nil, recovery_err
				end
			end
		end
	end
	return true
end

read_private = function(path)
	local before = uv.fs_lstat(path)
	if not before then
		return nil, "absent"
	end
	if
		before.type ~= "file"
		or before.nlink ~= 1
		or before.mode % 512 ~= tonumber("600", 8)
		or before.size > MAX_PRIVATE_BYTES
	then
		return nil, "unsafe"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "unreadable: " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or opened.dev ~= before.dev
		or opened.ino ~= before.ino
		or opened.size ~= before.size
	then
		pcall(uv.fs_close, fd)
		return nil, "changed"
	end
	local data = uv.fs_read(fd, opened.size, 0)
	local after_fd = uv.fs_fstat(fd)
	uv.fs_close(fd)
	local after = uv.fs_lstat(path)
	if not data or not same_private_stat(opened, after_fd) or not after or not same_private_stat(opened, after) then
		return nil, "changed"
	end
	return data, nil, after
end

local function normalize_identity(value)
	local called, identity, identity_err = pcall(contracts.normalize_tool_identity, value)
	if not called then
		return nil, "ToolIdentity validation crashed"
	end
	if not identity then
		return nil, identity_err
	end
	local path_ok, expanded = pcall(vim.fn.fnamemodify, identity.install_root, ":p")
	if not path_ok or type(expanded) ~= "string" then
		return nil, "ToolIdentity.install_root cannot be normalized"
	end
	identity.install_root = vim.fs.normalize(expanded)
	local encoded_ok = pcall(vim.json.encode, {
		identity.backend,
		identity.name,
		identity.version,
		identity.target,
		identity.digest,
		identity.install_root,
	})
	if not encoded_ok then
		return nil, "ToolIdentity contains unencodable text"
	end
	return identity
end

local function safe_basename(value, label)
	if
		type(value) ~= "string"
		or value == ""
		or #value > 128
		or value == "."
		or value == ".."
		or value:find("/", 1, true)
		or value:find("\\", 1, true)
		or value:find("%z")
		or not value:match("^[%w][%w._+%-]*$")
	then
		return nil, label .. " must be a safe command basename"
	end
	return value
end

local function normalize_executables(value)
	if type(value) ~= "table" or next(value) == nil then
		return nil, "spec.executables must be a non-empty map or list"
	end
	local result = {}
	local targets = {}
	local length = #value
	if length > 0 then
		for key in pairs(value) do
			if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then
				return nil, "spec.executables must not mix map and list entries"
			end
		end
		for index = 1, length do
			local command, err = safe_basename(value[index], ("spec.executables[%d]"):format(index))
			if not command then
				return nil, err
			end
			if result[command] then
				return nil, "spec.executables contains duplicate command " .. command
			end
			result[command] = command
			targets[command] = true
		end
	else
		for command, target in pairs(value) do
			local normalized_command, command_err = safe_basename(command, "spec.executables command")
			if not normalized_command then
				return nil, command_err
			end
			local normalized_target, target_err = safe_basename(target, "spec.executables." .. normalized_command)
			if not normalized_target then
				return nil, target_err
			end
			if targets[normalized_target] then
				return nil, "spec.executables contains duplicate target " .. normalized_target
			end
			result[normalized_command] = normalized_target
			targets[normalized_target] = true
		end
	end
	return result
end

local function identity_json(identity)
	-- An array is deliberately used here. Object-key iteration order differs
	-- between fresh Lua processes and would split records and locks.
	return vim.json.encode({
		identity.backend,
		identity.name,
		identity.version,
		identity.target,
		identity.digest,
		identity.install_root,
	})
end

local function hash(value)
	-- Path-producing digests are intentionally not injectable. A callback that
	-- returned traversal text previously escaped the pinned state root.
	return vim.fn.sha256(value)
end

local function same_stat(left, right)
	local left_mtime = left and left.mtime or {}
	local right_mtime = right and right.mtime or {}
	local left_ctime = left and left.ctime or {}
	local right_ctime = right and right.ctime or {}
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.uid == right.uid
		and left.gid == right.gid
		and left.nlink == right.nlink
		and left_mtime.sec == right_mtime.sec
		and left_mtime.nsec == right_mtime.nsec
		and left_ctime.sec == right_ctime.sec
		and left_ctime.nsec == right_ctime.nsec
end

local fingerprint_file

local function safe_tool_stat(stat)
	return stat
		and stat.type == "file"
		and stat.nlink == 1
		and type(stat.mode) == "number"
		and bit.band(stat.mode, UNSAFE_WRITE_MASK) == 0
end

function runtime_authority.effective_uid()
	if ffi_ok then
		local ok, value = pcall(function()
			return tonumber(ffi.C.geteuid())
		end)
		if ok and finite_number(value) and value >= 0 and value % 1 == 0 then
			return value
		end
	end
	local ok, value = pcall(uv.getuid)
	return ok and finite_number(value) and value >= 0 and value % 1 == 0 and value or nil
end

function runtime_authority.trusted_external_owner(owner, euid)
	return type(owner) == "number" and (owner == 0 or owner == euid)
end

function runtime_authority.validate_external_ancestor_chain(path, euid)
	local cursor = vim.fs.dirname(path)
	while true do
		local stat = uv.fs_lstat(cursor)
		if
			not stat
			or (stat.type ~= "directory" and stat.type ~= "link")
			or not runtime_authority.trusted_external_owner(stat.uid, euid)
			or (stat.type == "directory" and bit.band(stat.mode, UNSAFE_WRITE_MASK) ~= 0)
		then
			return nil, "external executable has an untrusted or writable ancestor: " .. cursor
		end
		if cursor == "/" then
			return true
		end
		local parent = vim.fs.dirname(cursor)
		if parent == cursor then
			return nil, "external executable ancestor chain is invalid"
		end
		cursor = parent
	end
end

function runtime_authority.validate_external_path_authority(lexical, expected_canonical)
	local euid = runtime_authority.effective_uid()
	if not euid then
		return nil, "effective UID is unavailable"
	end
	local normalized = type(lexical) == "string" and vim.fs.normalize(lexical) or nil
	local lexical_stat = normalized and uv.fs_lstat(normalized) or nil
	if
		not normalized
		or normalized:sub(1, 1) ~= "/"
		or not lexical_stat
		or not runtime_authority.trusted_external_owner(lexical_stat.uid, euid)
	then
		return nil, "external executable path owner is not root or the effective user"
	end
	local lexical_ok, lexical_err = runtime_authority.validate_external_ancestor_chain(normalized, euid)
	if not lexical_ok then
		return nil, lexical_err
	end
	local canonical = uv.fs_realpath(normalized)
	if
		not canonical
		or (expected_canonical ~= nil and vim.fs.normalize(canonical) ~= vim.fs.normalize(expected_canonical))
	then
		return nil, "external executable canonical path changed"
	end
	canonical = vim.fs.normalize(canonical)
	local canonical_stat = uv.fs_lstat(canonical)
	if not safe_tool_stat(canonical_stat) or not runtime_authority.trusted_external_owner(canonical_stat.uid, euid) then
		return nil, "external executable owner is not root or the effective user"
	end
	local canonical_ok, canonical_err = runtime_authority.validate_external_ancestor_chain(canonical, euid)
	if not canonical_ok then
		return nil, canonical_err
	end
	return canonical
end

function runtime_authority.validate_prerequisite_path_authority(lexical)
	local canonical = runtime_authority.validate_external_path_authority(lexical)
	if canonical then
		return canonical
	end
	local normalized = type(lexical) == "string" and vim.fs.normalize(lexical) or nil
	local euid = runtime_authority.effective_uid()
	local lexical_stat = normalized and uv.fs_lstat(normalized) or nil
	if
		not euid
		or not normalized
		or normalized:sub(1, 1) ~= "/"
		or not lexical_stat
		or lexical_stat.type ~= "file"
		or lexical_stat.uid ~= 0
		or type(lexical_stat.nlink) ~= "number"
		or lexical_stat.nlink <= 1
		or type(lexical_stat.mode) ~= "number"
		or bit.band(lexical_stat.mode, UNSAFE_WRITE_MASK) ~= 0
	then
		return nil, "system prerequisite is not one root-owned safe hardlinked executable"
	end
	local cursor = vim.fs.dirname(normalized)
	while true do
		local stat = uv.fs_lstat(cursor)
		if
			not stat
			or stat.type ~= "directory"
			or stat.uid ~= 0
			or type(stat.mode) ~= "number"
			or bit.band(stat.mode, UNSAFE_WRITE_MASK) ~= 0
		then
			return nil, "system prerequisite has a non-root-owned or writable ancestor: " .. cursor
		end
		if cursor == "/" then
			break
		end
		local parent = vim.fs.dirname(cursor)
		if parent == cursor then
			return nil, "system prerequisite ancestor chain is invalid"
		end
		cursor = parent
	end
	local resolved = uv.fs_realpath(normalized)
	local rechecked = resolved and uv.fs_lstat(normalized) or nil
	if resolved ~= normalized or not same_stat(lexical_stat, rechecked) then
		return nil, "system prerequisite canonical path changed"
	end
	return normalized
end

function runtime_authority.fingerprint_external_file(path)
	local canonical, authority_err = runtime_authority.validate_external_path_authority(path)
	if not canonical then
		return nil, authority_err
	end
	local fingerprint, fingerprint_err = fingerprint_file(path, true)
	if not fingerprint then
		return nil, fingerprint_err
	end
	local rechecked, recheck_err = runtime_authority.validate_external_path_authority(path, fingerprint.path)
	if not rechecked or rechecked ~= canonical then
		return nil, recheck_err or "external executable authority changed while hashing"
	end
	return fingerprint
end

local function fingerprint_from_stat(path, stat, digest)
	local mtime = stat.mtime or {}
	local ctime = stat.ctime or {}
	return {
		path = vim.fs.normalize(path),
		dev = stat.dev,
		ino = stat.ino,
		size = stat.size,
		mode = stat.mode,
		uid = stat.uid,
		gid = stat.gid,
		mtime_sec = mtime.sec or 0,
		mtime_nsec = mtime.nsec or 0,
		ctime_sec = ctime.sec or 0,
		ctime_nsec = ctime.nsec or 0,
		sha256 = digest,
	}
end

local function fingerprint_metadata_matches(expected, path, stat)
	local current = safe_tool_stat(stat) and fingerprint_from_stat(path, stat, expected.sha256) or nil
	return current and vim.deep_equal(current, expected) or false
end

local function valid_sha256(value)
	return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

fingerprint_file = function(path, executable)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
		return nil, "path must be absolute"
	end
	local lexical = vim.fs.normalize(path)
	local canonical = uv.fs_realpath(lexical)
	local before = canonical and uv.fs_lstat(canonical) or nil
	if
		not canonical
		or not safe_tool_stat(before)
		or before.size > MAX_EXECUTABLE_BYTES
		or (executable and vim.fn.executable(canonical) ~= 1)
	then
		return nil,
			executable and "path is not a safe non-writable executable"
				or "path is not a safe non-writable regular file"
	end
	local fd, open_err = uv.fs_open(canonical, "r", 0)
	if not fd then
		return nil, "cannot open file: " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	if not same_stat(before, opened) or opened.nlink ~= 1 then
		uv.fs_close(fd)
		return nil, "file identity changed while opening"
	end
	local chunks = {}
	local offset = 0
	while offset < opened.size do
		local chunk, read_err = uv.fs_read(fd, math.min(1024 * 1024, opened.size - offset), offset)
		if not chunk then
			uv.fs_close(fd)
			return nil, "cannot hash file: " .. tostring(read_err)
		end
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
		if #chunk == 0 and offset < opened.size then
			uv.fs_close(fd)
			return nil, "short read while hashing file"
		end
	end
	local after_fd = uv.fs_fstat(fd)
	local closed = uv.fs_close(fd)
	local after = uv.fs_lstat(canonical)
	if not closed or not same_stat(opened, after_fd) or not same_stat(opened, after) or after.nlink ~= 1 then
		return nil, "file identity changed while hashing"
	end
	local digest = vim.fn.sha256(table.concat(chunks))
	if not valid_sha256(digest) then
		return nil, "file hashing failed"
	end
	return fingerprint_from_stat(canonical, opened, digest)
end

local function validate_fingerprint_metadata(expected, executable)
	local canonical = uv.fs_realpath(expected.path)
	local before = canonical and uv.fs_lstat(expected.path) or nil
	if
		not canonical
		or vim.fs.normalize(canonical) ~= expected.path
		or not safe_tool_stat(before)
		or before.size > MAX_EXECUTABLE_BYTES
		or (executable and vim.fn.executable(expected.path) ~= 1)
	then
		return nil,
			executable and "path is not a safe non-writable executable"
				or "path is not a safe non-writable regular file"
	end
	if not fingerprint_metadata_matches(expected, canonical, before) then
		return nil, "file metadata changed"
	end
	local fd, open_err = uv.fs_open(expected.path, "r", 0)
	if not fd then
		return nil, "cannot open file: " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	local closed, close_err = uv.fs_close(fd)
	local after = uv.fs_lstat(expected.path)
	if
		not fingerprint_metadata_matches(expected, canonical, opened)
		or not fingerprint_metadata_matches(expected, canonical, after)
		or not closed
	then
		return nil, "file metadata changed while validating: " .. tostring(close_err or "drift")
	end
	return expected.path
end

local function identity_key(identity)
	return hash(identity_json(identity))
end

local function canonical_destination(path)
	local expanded = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local existing = uv.fs_lstat(expanded)
	if existing then
		if existing.type ~= "directory" then
			return nil, "install destination must be a real directory; symlinks are rejected"
		end
		local canonical = uv.fs_realpath(expanded)
		if not canonical or vim.fs.normalize(canonical) ~= expanded then
			return nil, "install destination must be canonical"
		end
		return expanded,
			{
				state = "present",
				lexical = expanded,
				canonical = expanded,
				dev = existing.dev,
				ino = existing.ino,
			}
	end
	local suffix = {}
	local cursor = expanded
	while not uv.fs_lstat(cursor) do
		local parent = vim.fs.dirname(cursor)
		if parent == cursor then
			return nil, "install destination has no existing ancestor"
		end
		table.insert(suffix, 1, vim.fs.basename(cursor))
		cursor = parent
	end
	local cursor_stat = uv.fs_lstat(cursor)
	local ancestor = cursor_stat and cursor_stat.type == "directory" and uv.fs_realpath(cursor) or nil
	local ancestor_stat = ancestor and uv.fs_lstat(ancestor) or nil
	if
		not ancestor
		or not ancestor_stat
		or ancestor_stat.type ~= "directory"
		or vim.fs.normalize(ancestor) ~= vim.fs.normalize(cursor)
	then
		return nil, "install destination ancestor is unsafe"
	end
	local canonical = vim.fs.normalize(vim.fs.joinpath(ancestor, unpack(suffix)))
	return canonical,
		{
			state = "absent",
			lexical = expanded,
			canonical = canonical,
			ancestor = vim.fs.normalize(ancestor),
			ancestor_dev = ancestor_stat.dev,
			ancestor_ino = ancestor_stat.ino,
			suffix = suffix,
		}
end

local function validate_destination_guard(guard, require_present)
	if type(guard) ~= "table" or guard.lexical == nil or guard.canonical == nil then
		return nil, "install destination guard is invalid"
	end
	if guard.state == "absent" then
		local ancestor = uv.fs_lstat(guard.ancestor)
		local ancestor_real = ancestor and ancestor.type == "directory" and uv.fs_realpath(guard.ancestor) or nil
		if
			not ancestor
			or ancestor.type ~= "directory"
			or ancestor.dev ~= guard.ancestor_dev
			or ancestor.ino ~= guard.ancestor_ino
			or not ancestor_real
			or vim.fs.normalize(ancestor_real) ~= guard.ancestor
		then
			return nil, "install destination ancestor changed while queued"
		end
	end
	local current = uv.fs_lstat(guard.lexical)
	if not current then
		if require_present then
			return nil, "install destination was not created"
		end
		if guard.state ~= "absent" then
			return nil, "install destination disappeared while queued"
		end
		if type(guard.suffix) ~= "table" or #guard.suffix == 0 then
			return nil, "install destination guard suffix is invalid"
		end
		local cursor = guard.ancestor
		local missing_component = false
		for index, component in ipairs(guard.suffix) do
			if type(component) ~= "string" or component == "" or component == "." or component == ".." then
				return nil, "install destination guard suffix is invalid"
			end
			cursor = vim.fs.joinpath(cursor, component)
			local component_stat = uv.fs_lstat(cursor)
			if component_stat then
				if missing_component or component_stat.type ~= "directory" then
					return nil, "install destination path component is unsafe"
				end
				local component_real = uv.fs_realpath(cursor)
				if not component_real or vim.fs.normalize(component_real) ~= vim.fs.normalize(cursor) then
					return nil, "install destination path component is not canonical"
				end
			elseif index < #guard.suffix then
				missing_component = true
			end
		end
		return true
	end
	if current.type ~= "directory" then
		return nil, "install destination was replaced by a non-directory or symlink"
	end
	if guard.state == "absent" and not require_present then
		return nil, "install destination appeared before backend start"
	end
	local canonical = uv.fs_realpath(guard.lexical)
	if not canonical or vim.fs.normalize(canonical) ~= guard.canonical then
		return nil, "install destination canonical path changed"
	end
	if guard.state == "present" and (current.dev ~= guard.dev or current.ino ~= guard.ino) then
		return nil, "install destination directory identity changed"
	end
	return true
end

local function destination_key(identity)
	return hash(identity.install_root)
end

local function shim_path(command)
	return vim.fs.joinpath(M.shim_bin(), command)
end

local function shim_owner_path(command)
	return vim.fs.joinpath(root(), "shims", "owners", hash(command) .. ".json")
end

local function sorted_keys(value)
	local result = {}
	for key in pairs(value) do
		result[#result + 1] = key
	end
	table.sort(result, function(left, right)
		local left_type, right_type = type(left), type(right)
		if left_type ~= right_type then
			return left_type < right_type
		end
		if left_type == "number" or left_type == "string" then
			return left < right
		end
		return tostring(left) < tostring(right)
	end)
	return result
end

local function canonical_encode(value, seen)
	local kind = type(value)
	if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
		return nil, "plan contains a non-finite number"
	end
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		local ok, encoded = pcall(vim.json.encode, value)
		if not ok then
			return nil, "plan contains an unencodable scalar"
		end
		return encoded
	end
	if kind ~= "table" then
		return nil, "plan contains a non-data value"
	end
	seen = seen or {}
	if seen[value] then
		return nil, "plan contains a cycle"
	end
	seen[value] = true
	local length = #value
	local pieces = {}
	if length > 0 then
		for key in pairs(value) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
				seen[value] = nil
				return nil, "plan contains a mixed or sparse list"
			end
		end
		for index = 1, length do
			local encoded, err = canonical_encode(value[index], seen)
			if not encoded then
				seen[value] = nil
				return nil, err
			end
			pieces[#pieces + 1] = encoded
		end
		seen[value] = nil
		return "[" .. table.concat(pieces, ",") .. "]"
	end
	for key in pairs(value) do
		if type(key) ~= "string" then
			seen[value] = nil
			return nil, "plan object keys must be strings"
		end
	end
	for _, key in ipairs(sorted_keys(value)) do
		local encoded, err = canonical_encode(value[key], seen)
		if not encoded then
			seen[value] = nil
			return nil, err
		end
		local key_ok, encoded_key = pcall(vim.json.encode, key)
		if not key_ok then
			seen[value] = nil
			return nil, "plan contains an unencodable object key"
		end
		pieces[#pieces + 1] = encoded_key .. ":" .. encoded
	end
	seen[value] = nil
	return "{" .. table.concat(pieces, ",") .. "}"
end

local function plan_digest(plan)
	local encoded, err = canonical_encode({
		schema = plan.schema,
		identity = plan.identity,
		identity_key = plan.identity_key,
		destination_key = plan.destination_key,
		backend = plan.backend,
		requires_network = plan.requires_network,
		manifest = plan.manifest,
		executables = plan.executables,
		shims = plan.shims,
		resources = plan.resources,
		destination_guard = plan.destination_guard,
		probe = plan.probe,
		force_managed = plan.force_managed,
		strategy = plan.strategy,
	})
	if encoded and #encoded > 128 * 1024 then
		return nil, "normalized plan exceeds 128 KiB"
	end
	return encoded and hash(encoded) or nil, err
end

local function plan_shims(identity, executables)
	local result = {}
	-- Dynamic npm bundles are selected by an active-slot pointer and resolved
	-- directly. Publishing a global shim before activation could make PATH select
	-- a failed upgrade while the durable pointer still names the prior bundle.
	if identity.backend == "npm-release" then
		return result
	end
	for _, command in ipairs(sorted_keys(executables)) do
		result[command] = shim_path(command)
	end
	return result
end

local function plan_resources(identity, shims)
	local values = {
		"identity:" .. identity_key(identity),
		"destination:" .. destination_key(identity),
	}
	for _, command in ipairs(sorted_keys(shims)) do
		values[#values + 1] = "shim:" .. hash(shims[command])
	end
	table.sort(values)
	return values
end

local function record_path(identity)
	return vim.fs.joinpath(root(), "records", identity_key(identity) .. ".json")
end

function runtime_authority.external_record_path(identity)
	return vim.fs.joinpath(root(), "external-records", identity_key(identity) .. ".json")
end

local function record_value(identity, status, fields)
	generation = generation + 1
	fields = fields or {}
	local updated_at, owner_pid = now(), pid()
	if not finite_number(updated_at) or not owner_pid then
		return nil, "record clock or PID is invalid"
	end
	local value = {
		schema = RECORD_SCHEMA,
		identity = copy(identity),
		identity_key = identity_key(identity),
		status = status,
		generation = generation,
		updated_at = updated_at,
		pid = owner_pid,
		instance_token = instance_token,
		attempt = tonumber(fields.attempt) or 0,
	}
	for name, item in pairs(fields) do
		if name == "detail" and item ~= nil then
			value[name] = tostring(item):gsub("[%c]", " "):sub(1, 160)
		else
			value[name] = item
		end
	end
	return value
end

local function persist(identity, status, fields)
	assert(STATUSES[status], "invalid verified tool status")
	if type(configured.fail_persist) == "function" then
		local called, failure = pcall(configured.fail_persist, status, copy(identity), copy(fields or {}))
		if not called then
			return nil, "persistence fault injector crashed"
		end
		if failure then
			return nil, tostring(failure)
		end
	end
	local ok, err = prepare_state()
	if not ok then
		return nil, err
	end
	local value, value_err = record_value(identity, status, fields)
	if not value then
		return nil, value_err
	end
	local encoded_ok, encoded = pcall(vim.json.encode, value)
	if not encoded_ok or type(encoded) ~= "string" then
		return nil, "record is not JSON encodable"
	end
	encoded = encoded .. "\n"
	if #encoded > MAX_PRIVATE_BYTES then
		return nil, "record exceeds 256 KiB"
	end
	ok, err = atomic_write(record_path(identity), encoded)
	if not ok then
		return nil, err
	end
	emit("status", value)
	return copy(value)
end

local valid_stored_proof
local valid_fingerprint_shape
local normalize_supplied_plan

local function project_legacy_record(identity, value, legacy_path)
	return {
		schema = 1,
		identity = copy(identity),
		identity_key = identity_key(identity),
		status = "repair-required",
		original_status = value.status,
		attempt = finite_number(value.attempt) and value.attempt >= 0 and value.attempt % 1 == 0 and value.attempt or 0,
		generation = finite_number(value.generation)
				and value.generation >= 0
				and value.generation % 1 == 0
				and value.generation
			or 0,
		updated_at = finite_number(value.updated_at) and value.updated_at or 0,
		detail = "legacy-schema-1",
		repair_required = true,
		legacy_record_path = legacy_path,
		legacy_identity_key = value.identity_key,
	}
end

local function schema2_record_shape(value)
	local allowed = {
		schema = true,
		identity = true,
		identity_key = true,
		status = true,
		generation = true,
		updated_at = true,
		pid = true,
		instance_token = true,
		attempt = true,
		plan = true,
		attempt_consumed = true,
		mode = true,
		proof = true,
		detail = true,
		cancel_requested = true,
		legacy = true,
		legacy_status = true,
		legacy_origin = true,
	}
	if not exact_keys(value, allowed) then
		return false
	end
	if
		value.schema ~= RECORD_SCHEMA
		or type(value.identity) ~= "table"
		or type(value.identity_key) ~= "string"
		or not STATUSES[value.status]
		or not finite_number(value.generation)
		or value.generation < 0
		or value.generation % 1 ~= 0
		or not finite_number(value.updated_at)
		or not finite_number(value.pid)
		or value.pid < 1
		or value.pid % 1 ~= 0
		or type(value.instance_token) ~= "string"
		or #value.instance_token ~= 64
		or not value.instance_token:match("^[0-9a-f]+$")
		or not finite_number(value.attempt)
		or value.attempt < 0
		or value.attempt % 1 ~= 0
		or type(value.plan) ~= "table"
		or (value.attempt_consumed ~= nil and type(value.attempt_consumed) ~= "boolean")
		or (value.cancel_requested ~= nil and type(value.cancel_requested) ~= "boolean")
		or (value.detail ~= nil and type(value.detail) ~= "string")
		or (value.mode ~= nil and value.mode ~= "auto" and value.mode ~= "retry" and value.mode ~= "repair")
		or (value.legacy ~= nil and type(value.legacy) ~= "boolean")
		or (value.legacy_status ~= nil and type(value.legacy_status) ~= "string")
		or (value.legacy_origin ~= nil and type(value.legacy_origin) ~= "string")
	then
		return false
	end
	local status_allowed = {
		claimed = { attempt_consumed = true, mode = true },
		queued = { attempt_consumed = true },
		running = {
			attempt_consumed = true,
			cancel_requested = true,
			detail = true,
			legacy = true,
			legacy_origin = true,
		},
		succeeded = { attempt_consumed = true, detail = true, proof = true },
		failed = { attempt_consumed = true, detail = true, proof = true },
		drift = { attempt_consumed = true, detail = true, proof = true },
		cancelled = { attempt_consumed = true, detail = true, proof = true },
		["repair-required"] = {
			attempt_consumed = true,
			detail = true,
			proof = true,
			legacy = true,
			legacy_status = true,
			legacy_origin = true,
		},
		planned = { detail = true },
		blocked = { detail = true },
	}
	local common = {
		schema = true,
		identity = true,
		identity_key = true,
		status = true,
		generation = true,
		updated_at = true,
		pid = true,
		instance_token = true,
		attempt = true,
		plan = true,
	}
	for key in pairs(value) do
		if not common[key] and not status_allowed[value.status][key] then
			return false
		end
	end
	return true
end

local function find_legacy_record(identity)
	local directory = vim.fs.joinpath(root(), "records")
	local candidates = {}
	local seen = 0
	local scan_ok, scan_err = pcall(function()
		for name in vim.fs.dir(directory) do
			seen = seen + 1
			if seen > MAX_LEGACY_RECORDS then
				error("legacy record scan limit exceeded")
			end
			if not name:match("%.json$") then
				error("unexpected legacy record state")
			end
			local path = vim.fs.joinpath(directory, name)
			local data, read_err = read_private(path)
			if not data then
				error("unsafe legacy record candidate: " .. tostring(read_err))
			end
			local decoded_ok, value = pcall(vim.json.decode, data)
			local decoded_identity = decoded_ok and type(value) == "table" and normalize_identity(value.identity)
			if
				value
				and value.schema == 1
				and decoded_identity
				and identity_json(decoded_identity) == identity_json(identity)
			then
				if
					type(value.identity_key) ~= "string"
					or #value.identity_key ~= 64
					or not value.identity_key:match("^[0-9a-f]+$")
					or name ~= value.identity_key .. ".json"
					or not STATUSES[value.status]
				then
					error("legacy record filename or key is invalid")
				end
				candidates[#candidates + 1] = { value = value, path = path }
			end
		end
	end)
	if not scan_ok then
		return nil, tostring(scan_err)
	end
	if #candidates > 1 then
		return nil, "duplicate legacy records"
	end
	if not candidates[1] then
		return nil, "absent"
	end
	return candidates[1]
end

local function decode_record(identity)
	local canonical_path = record_path(identity)
	local data, read_err = read_private(canonical_path)
	if not data then
		if read_err ~= "absent" then
			return nil, read_err
		end
		local legacy, legacy_err = find_legacy_record(identity)
		if not legacy then
			return nil, legacy_err
		end
		return project_legacy_record(identity, legacy.value, legacy.path)
	end
	local ok, value = pcall(vim.json.decode, data)
	if not ok or type(value) ~= "table" then
		return nil, "corrupt"
	end
	local decoded_identity = normalize_identity(value.identity)
	if
		not decoded_identity
		or identity_json(decoded_identity) ~= identity_json(identity)
		or not STATUSES[value.status]
	then
		return nil, "corrupt"
	end
	if value.schema == 1 then
		local legacy, legacy_err = find_legacy_record(identity)
		if not legacy then
			return nil, legacy_err
		end
		return project_legacy_record(identity, legacy.value, legacy.path)
	end
	if value.schema ~= RECORD_SCHEMA then
		return nil, "unsupported-schema"
	end
	if not schema2_record_shape(value) or value.identity_key ~= identity_key(identity) then
		return nil, "corrupt"
	end
	local plan_ok, normalized_plan = pcall(normalize_supplied_plan, value.plan, { skip_destination_state = true })
	if not plan_ok or not normalized_plan or identity_json(normalized_plan.identity) ~= identity_json(identity) then
		return nil, "corrupt"
	end
	if value.status == "claimed" or value.status == "queued" or value.status == "running" then
		local alive = process_alive(value.pid, value.instance_token)
		if alive == nil then
			return nil, "owner-unverifiable"
		end
		if alive == false then
			local projected = copy(value)
			projected.status = "repair-required"
			projected.original_status = value.status
			projected.detail = "dead-owner"
			projected.repair_required = true
			return projected
		end
	end
	local proof_call_ok, proof_valid = pcall(valid_stored_proof, value.plan, value.proof, identity)
	if value.status == "succeeded" and (not proof_call_ok or not proof_valid) then
		local projected = copy(value)
		projected.status = "repair-required"
		projected.original_status = "succeeded"
		projected.detail = "invalid-or-missing-proof"
		projected.repair_required = true
		return projected
	end
	return copy(value)
end

process_alive = function(owner, token)
	if type(configured.process_alive) == "function" then
		local ok, value = pcall(configured.process_alive, owner, token)
		if not ok or (value ~= true and value ~= false and value ~= nil) then
			return nil
		end
		return value
	end
	if type(owner) ~= "number" or owner < 1 then
		return nil
	end
	if owner == pid() then
		return token == instance_token and true or nil
	end
	local ok, result, _, code = pcall(uv.kill, owner, 0)
	if not ok then
		return nil
	end
	if result ~= nil then
		return nil
	end
	if code == "ESRCH" then
		return false
	end
	return nil
end

local function missing(err)
	return err ~= nil and tostring(err):find("ENOENT", 1, true) ~= nil
end

local function same_file(left, right)
	return left and right and left.dev == right.dev and left.ino == right.ino
end

unlink_same_file = function(path, expected)
	local current, inspect_err = uv.fs_lstat(path)
	if not current then
		if not inspect_err or missing(inspect_err) then
			return true
		end
		return nil, "cannot inspect file before unlink: " .. tostring(inspect_err)
	end
	if not same_file(current, expected) then
		return nil, "file identity changed before unlink"
	end
	local removed, remove_err = uv.fs_unlink(path)
	if removed or missing(remove_err) then
		return true
	end
	return nil, tostring(remove_err)
end

local function lock_claim_path(base, kind, token, number)
	if kind == "choosing" then
		return base .. ".choosing." .. token
	end
	return ("%s.ticket.%020d.%s"):format(base, number, token)
end

local function abandon_lock_claim_publication(staging, expected, parent_fd, reason)
	local detail = reason
	local cleaned, cleanup_err = unlink_same_file(staging, expected)
	if not cleaned then
		detail = detail .. "; lock-claim-publish-cleanup-failed: " .. tostring(cleanup_err)
	end
	if parent_fd then
		local closed, close_err = uv.fs_close(parent_fd)
		if not closed then
			detail = detail .. "; lock-claim-parent-close-failed: " .. tostring(close_err)
		end
	end
	return nil, detail
end

local function rollback_lock_claim_publication(path, expected, parent_fd, reason)
	local detail = reason
	local removed, remove_err = unlink_same_file(path, expected)
	if not removed then
		detail = detail .. "; committed claim cleanup failed: " .. tostring(remove_err)
	else
		local synced, sync_err = uv.fs_fsync(parent_fd)
		if not synced then
			detail = detail .. "; committed claim cleanup fsync failed: " .. tostring(sync_err)
		end
	end
	local closed, close_err = uv.fs_close(parent_fd)
	if not closed then
		detail = detail .. "; lock-claim-parent-close-failed: " .. tostring(close_err)
	end
	return nil, detail
end

local function write_lock_claim(path, claim, base)
	local parent_ok, parent_err = validate_state_parent(path)
	if not parent_ok then
		return nil, parent_err
	end
	local encoded_ok, encoded = pcall(vim.json.encode, claim)
	if not encoded_ok or type(encoded) ~= "string" or #encoded + 1 > MAX_PRIVATE_BYTES then
		return nil, "lock claim is not safely encodable"
	end
	local data = encoded .. "\n"
	local staging = path .. ".publish"
	local fd, open_err = uv.fs_open(staging, "wx", tonumber("600", 8))
	if not fd then
		return nil, "lock-claim-reservation-failed: " .. tostring(open_err)
	end
	local created = uv.fs_fstat(fd)
	local secured = created and created.type == "file" and created.nlink == 1 and uv.fs_fchmod(fd, tonumber("600", 8))
	local wrote, write_err = secured and write_all(fd, data) or nil
	local synced, sync_err
	if wrote then
		synced, sync_err = uv.fs_fsync(fd)
	end
	local opened = synced and uv.fs_fstat(fd) or nil
	local closed, close_err = uv.fs_close(fd)
	if
		not wrote
		or not synced
		or not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or not same_file(created, opened)
		or not closed
	then
		local detail = "lock-claim-write-failed: "
			.. tostring(write_err or sync_err or close_err or "unsafe staging file")
		local cleaned, cleanup_err
		if created then
			cleaned, cleanup_err = unlink_same_file(staging, created)
		else
			cleanup_err = "staging inode unavailable"
		end
		if not cleaned then
			detail = detail .. "; lock-claim-publish-cleanup-failed: " .. tostring(cleanup_err)
		end
		return nil, detail
	end
	local staged = uv.fs_lstat(staging)
	if not staged or staged.type ~= "file" or staged.nlink ~= 1 or not same_file(opened, staged) then
		unlink_same_file(staging, opened)
		return nil, "lock-claim-staging-changed"
	end
	local parent = vim.fs.dirname(path)
	local parent_fd, parent_open_err = record_open_directory(parent)
	if not parent_fd then
		return abandon_lock_claim_publication(
			staging,
			opened,
			nil,
			"lock-claim-publish-failed: " .. tostring(parent_open_err)
		)
	end
	parent_ok, parent_err = validate_state_parent(path)
	if not parent_ok or not record_descriptor_bound(parent_fd, parent) then
		return abandon_lock_claim_publication(
			staging,
			opened,
			parent_fd,
			tostring(parent_err or "lock claim parent descriptor changed")
		)
	end
	local context = {
		base = base,
		kind = claim.kind,
		number = claim.number,
		path = path,
		resource = claim.resource,
		staging_path = staging,
		token = claim.token,
	}
	local hook_ok, hook_err = run_interleave("before-lock-claim-publish", context)
	parent_ok, parent_err = validate_state_parent(path)
	if not hook_ok or not parent_ok or not record_descriptor_bound(parent_fd, parent) then
		return abandon_lock_claim_publication(
			staging,
			opened,
			parent_fd,
			tostring(hook_err or parent_err or "lock claim parent descriptor changed")
		)
	end
	local renamed, rename_err, rename_errno =
		record_rename_noreplace(parent_fd, vim.fs.basename(staging), parent_fd, vim.fs.basename(path))
	if not renamed then
		local detail = rename_errno == RECORD_FFI_ABI.eexist and "lock-claim-collision"
			or "lock-claim-publish-failed: " .. tostring(rename_err)
		return abandon_lock_claim_publication(staging, opened, parent_fd, detail)
	end
	local published = uv.fs_lstat(path)
	if not published or published.type ~= "file" or published.nlink ~= 1 or not same_file(opened, published) then
		return rollback_lock_claim_publication(path, opened, parent_fd, "lock-claim-published-identity-changed")
	end
	local warning
	hook_ok, hook_err = run_interleave("after-lock-claim-publish", context)
	if not hook_ok then
		warning = append_warning(warning, "lock claim post-commit hook failed: " .. tostring(hook_err))
	end
	local final = uv.fs_lstat(path)
	if not final or not same_private_stat(published, final) then
		return rollback_lock_claim_publication(path, opened, parent_fd, "lock-claim-published-identity-changed")
	end
	local synced, sync_err = uv.fs_fsync(parent_fd)
	if not synced then
		warning = append_warning(warning, "lock claim parent fsync failed: " .. tostring(sync_err))
	end
	local closed, close_err = uv.fs_close(parent_fd)
	if not closed then
		warning = append_warning(warning, "lock claim parent close failed: " .. tostring(close_err))
	end
	if warning then
		notify(
			"lock claim committed with a durability warning: " .. bounded_reason(warning, "durability warning"),
			vim.log.levels.WARN
		)
	end
	return { path = path, stat = final }
end

local function read_lock_claim(path, kind, token, number, resource)
	local data, err, stat = read_private(path)
	if not data then
		local current, current_err = uv.fs_lstat(path)
		if not current and (not current_err or missing(current_err)) then
			return nil, "missing"
		end
		return nil, err
	end
	local ok, claim = pcall(vim.json.decode, data)
	local allowed = {
		schema = true,
		kind = true,
		pid = true,
		instance_token = true,
		token = true,
		resource = true,
	}
	if kind == "ticket" then
		allowed.number = true
	end
	if
		not ok
		or type(claim) ~= "table"
		or not exact_keys(claim, allowed)
		or claim.schema ~= 1
		or claim.kind ~= kind
		or claim.token ~= token
		or claim.resource ~= resource
		or type(claim.pid) ~= "number"
		or claim.pid < 1
		or claim.pid % 1 ~= 0
		or type(claim.instance_token) ~= "string"
		or #claim.instance_token ~= 64
		or not claim.instance_token:match("^[0-9a-f]+$")
		or (kind == "ticket" and claim.number ~= number)
	then
		return nil, "invalid-lock-claim"
	end
	return claim, nil, stat
end

local function remove_empty_quarantine(path)
	local guard = state_directory_guards[path]
	local safe, safe_err
	if guard then
		safe, safe_err = validate_directory_guard(path, guard)
	else
		safe_err = "unpinned quarantine"
	end
	if not safe then
		return nil, "lock-claim-quarantine-unsafe: " .. tostring(safe_err)
	end
	local removed, err = uv.fs_rmdir(path)
	if removed then
		state_directory_guards[path] = nil
		return true
	end
	return nil, "lock-claim-quarantine-cleanup-failed: " .. tostring(err)
end

local function restore_quarantined_claim(handle, directory, quarantined, moved)
	local parent_ok, parent_err = validate_state_parent(handle.path)
	local directory_ok, directory_err = validate_directory_guard(directory, state_directory_guards[directory])
	if not parent_ok or not directory_ok then
		return nil, tostring(parent_err or directory_err)
	end
	local restored, restore_err = uv.fs_link(quarantined, handle.path)
	if not restored then
		return nil, "lock-claim-restore-failed: " .. tostring(restore_err)
	end
	local source = uv.fs_lstat(quarantined)
	local target = uv.fs_lstat(handle.path)
	if
		not source
		or not target
		or source.type ~= "file"
		or target.type ~= "file"
		or source.nlink ~= 2
		or target.nlink ~= 2
		or not same_file(source, moved)
		or not same_file(source, target)
	then
		return nil, "lock-claim-restore-identity-changed"
	end
	local removed, remove_err = uv.fs_unlink(quarantined)
	if not removed then
		return nil, "lock-claim-restore-cleanup-failed: " .. tostring(remove_err)
	end
	local final = uv.fs_lstat(handle.path)
	if not final or final.type ~= "file" or final.nlink ~= 1 or not same_file(final, moved) then
		return nil, "lock-claim-restored-identity-changed"
	end
	return remove_empty_quarantine(directory)
end

local function remove_unique_claim(handle)
	if
		type(handle) ~= "table"
		or type(handle.path) ~= "string"
		or type(handle.stat) ~= "table"
		or type(handle.stat.dev) ~= "number"
		or type(handle.stat.ino) ~= "number"
	then
		return nil, "invalid-lock-claim-handle"
	end
	local before = uv.fs_lstat(handle.path)
	if not before or not same_private_stat(before, handle.stat) then
		return nil, "lock-claim-identity-changed"
	end
	local parent_ok, parent_err = validate_state_parent(handle.path)
	if not parent_ok then
		return nil, parent_err
	end
	local template = handle.path .. ".quarantine." .. instance_token .. ".XXXXXX"
	local directory, reserve_err = uv.fs_mkdtemp(template)
	if not directory then
		return nil, "lock-claim-quarantine-reservation-failed: " .. tostring(reserve_err)
	end
	local secured = uv.fs_chmod(directory, tonumber("700", 8))
	local directory_stat = secured and uv.fs_lstat(directory) or nil
	if not directory_stat or directory_stat.type ~= "directory" then
		return nil, "lock-claim-quarantine-reservation-unsafe"
	end
	state_directory_guards[directory] = { dev = directory_stat.dev, ino = directory_stat.ino }
	local quarantined = vim.fs.joinpath(directory, "claim")
	local moved_ok, move_err = uv.fs_rename(handle.path, quarantined)
	if not moved_ok then
		local cleaned, cleanup_err = remove_empty_quarantine(directory)
		if not cleaned then
			return nil, cleanup_err
		end
		if missing(move_err) then
			return true
		end
		return nil, "lock-claim-quarantine-failed: " .. tostring(move_err)
	end
	local moved = uv.fs_lstat(quarantined)
	if
		moved
		and moved.type == "file"
		and moved.nlink == 1
		and same_file(moved, handle.stat)
		and moved.size == handle.stat.size
		and moved.mode == handle.stat.mode
		and (moved.mtime or {}).sec == (handle.stat.mtime or {}).sec
		and (moved.mtime or {}).nsec == (handle.stat.mtime or {}).nsec
	then
		local removed, remove_err = uv.fs_unlink(quarantined)
		if not removed then
			return nil, "lock-claim-quarantine-remove-failed: " .. tostring(remove_err)
		end
		return remove_empty_quarantine(directory)
	end
	local restore_err = "quarantined claim is unsafe"
	if moved and moved.type == "file" and moved.nlink == 1 then
		local restored
		restored, restore_err = restore_quarantined_claim(handle, directory, quarantined, moved)
		if restored then
			return nil, "lock-claim-identity-changed"
		end
	end
	return nil, "lock-claim-identity-changed: " .. tostring(restore_err)
end

local function collect_lock_claims(base, resource)
	local legacy, legacy_err = uv.fs_lstat(base)
	if legacy or (legacy_err and not missing(legacy_err)) then
		return nil, legacy and "legacy-lock-requires-manual-repair" or "lock-inspection-failed"
	end
	local directory = vim.fs.dirname(base)
	local basename = vim.fs.basename(base):gsub("([^%w])", "%%%1")
	local claims = {}
	local ok, list_err = pcall(function()
		for name in vim.fs.dir(directory) do
			local related = name:match("^" .. basename .. "%.choosing%.") or name:match("^" .. basename .. "%.ticket%.")
			local token = name:match("^" .. basename .. "%.choosing%.([0-9a-f]+)$")
			local kind = token and "choosing" or nil
			local number
			if not token then
				local encoded
				encoded, token = name:match("^" .. basename .. "%.ticket%.(%d+)%.([0-9a-f]+)$")
				if encoded then
					kind = "ticket"
					number = tonumber(encoded)
				end
			end
			if kind then
				if #token ~= 64 or not token:match("^[0-9a-f]+$") or (kind == "ticket" and not number) then
					error("invalid lock claim filename")
				end
				local path = vim.fs.joinpath(directory, name)
				local claim, claim_err, claim_stat = read_lock_claim(path, kind, token, number, resource)
				if not claim and claim_err ~= "missing" then
					error(claim_err)
				end
				if claim then
					claim.path = path
					claim.handle = { path = path, stat = claim_stat }
					claims[#claims + 1] = claim
				end
			elseif related and not name:match("%.publish$") then
				error("invalid lock claim filename")
			end
		end
	end)
	if not ok then
		return nil, "unsafe-lock-claim: " .. tostring(list_err)
	end
	return claims
end

local function live_lock_claims(base, resource)
	local claims, err = collect_lock_claims(base, resource)
	if not claims then
		return nil, err
	end
	local live = {}
	for _, claim in ipairs(claims) do
		local alive = process_alive(claim.pid, claim.instance_token)
		if alive == false then
			local removed, remove_err = remove_unique_claim(claim.handle)
			if not removed then
				return nil, "dead-lock-reclaim-failed: " .. tostring(remove_err)
			end
		elseif alive == nil then
			return nil, "lock-owner-unverifiable"
		else
			live[#live + 1] = claim
		end
	end
	return live
end

release_lock = function(lock)
	local claim, err, claim_stat = read_lock_claim(lock.path, "ticket", lock.token, lock.number, lock.resource)
	if
		not claim
		or claim.pid ~= pid()
		or claim.instance_token ~= instance_token
		or not same_file(claim_stat, lock.stat)
	then
		return nil, "lock-release-owner-mismatch: " .. tostring(err or "owner changed")
	end
	return remove_unique_claim(lock)
end

acquire_prepared_lock = function(base, resource, requested_wait_ms)
	temp_counter = temp_counter + 1
	local owner_pid = pid()
	local token = hash(table.concat({
		base,
		resource,
		instance_token,
		tostring(owner_pid),
		tostring(uv.hrtime()),
		tostring(temp_counter),
	}, "\0"))
	local choosing_path = lock_claim_path(base, "choosing", token)
	local choosing = {
		schema = 1,
		kind = "choosing",
		pid = owner_pid,
		instance_token = instance_token,
		token = token,
		resource = resource,
	}
	local choosing_handle, create_err = write_lock_claim(choosing_path, choosing, base)
	if not choosing_handle then
		return nil, create_err
	end
	local claims, claims_err = live_lock_claims(base, resource)
	if not claims then
		local removed, remove_err = remove_unique_claim(choosing_handle)
		if not removed then
			return nil, tostring(claims_err) .. "; lock-choice-cleanup-failed: " .. tostring(remove_err)
		end
		return nil, claims_err
	end
	local maximum = 0
	for _, claim in ipairs(claims) do
		if claim.kind == "ticket" then
			maximum = math.max(maximum, claim.number)
		end
	end
	if maximum >= MAX_SAFE_INTEGER then
		local removed, remove_err = remove_unique_claim(choosing_handle)
		if not removed then
			return nil, "lock-ticket-space-exhausted; lock-choice-cleanup-failed: " .. tostring(remove_err)
		end
		return nil, "lock-ticket-space-exhausted"
	end
	local number = maximum + 1
	local ticket_path = lock_claim_path(base, "ticket", token, number)
	local ticket = vim.tbl_extend("force", {}, choosing, { kind = "ticket", number = number })
	local ticket_handle
	ticket_handle, create_err = write_lock_claim(ticket_path, ticket, base)
	if not ticket_handle then
		local removed, remove_err = remove_unique_claim(choosing_handle)
		if not removed then
			return nil, tostring(create_err) .. "; lock-choice-cleanup-failed: " .. tostring(remove_err)
		end
		return nil, create_err
	end
	local removed, remove_err = remove_unique_claim(choosing_handle)
	if not removed then
		local ticket_removed, ticket_remove_err = remove_unique_claim(ticket_handle)
		if not ticket_removed then
			return nil,
				"lock-choice-failed: " .. tostring(remove_err) .. "; lock-ticket-cleanup-failed: " .. tostring(
					ticket_remove_err
				)
		end
		return nil, "lock-choice-failed: " .. tostring(remove_err)
	end
	local wait_ms = requested_wait_ms
	if wait_ms == nil then
		wait_ms = tonumber(configured.lock_wait_ms) or LOCK_WAIT_MILLISECONDS
	end
	local deadline = uv.hrtime() + math.max(0, wait_ms) * 1000000
	while true do
		claims, claims_err = live_lock_claims(base, resource)
		if not claims then
			local ticket_removed, ticket_remove_err = remove_unique_claim(ticket_handle)
			if not ticket_removed then
				return nil, tostring(claims_err) .. "; lock-ticket-cleanup-failed: " .. tostring(ticket_remove_err)
			end
			return nil, claims_err
		end
		local blocker
		for _, claim in ipairs(claims) do
			if claim.token ~= token then
				if
					claim.kind == "choosing"
					or claim.number < number
					or (claim.number == number and claim.token < token)
				then
					blocker = claim
					break
				end
			end
		end
		if not blocker then
			return {
				path = ticket_handle.path,
				stat = ticket_handle.stat,
				token = token,
				number = number,
				resource = resource,
			}
		end
		if blocker.pid == owner_pid or uv.hrtime() >= deadline then
			local ticket_removed, ticket_remove_err = remove_unique_claim(ticket_handle)
			if not ticket_removed then
				return nil, "locked; lock-ticket-cleanup-failed: " .. tostring(ticket_remove_err)
			end
			return nil, "locked"
		end
		vim.wait(LOCK_POLL_MILLISECONDS, function()
			return false
		end, LOCK_POLL_MILLISECONDS)
	end
end

local function acquire_lock(base, resource, requested_wait_ms)
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	return acquire_prepared_lock(base, resource, requested_wait_ms)
end

resource_lock_base = function(resource)
	return vim.fs.joinpath(root(), "locks", "resources", hash(resource) .. ".lock")
end

local function global_lock_base(slot)
	return vim.fs.joinpath(root(), "locks", "global", tostring(slot) .. ".lock")
end

local function lock_contended(err)
	return err == "locked" or err == "lock-owner-unverifiable"
end

local function release_locks(job)
	local first_error
	for index = #(job.locks or {}), 1, -1 do
		local ok, err = release_lock(job.locks[index])
		first_error = first_error or (not ok and err or nil)
	end
	job.locks = {}
	return first_error == nil, first_error
end

local function acquire_operation_locks(plan)
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local holder = { locks = {}, resources = copy(plan.resources) }
	for _, resource in ipairs(holder.resources) do
		local lock, lock_err = acquire_lock(resource_lock_base(resource), resource)
		if not lock then
			local released, release_err = release_locks(holder)
			return nil, released and lock_err or release_err
		end
		holder.locks[#holder.locks + 1] = lock
	end
	local global_lock, global_err
	for slot = 1, 2 do
		local resource = "global-slot:" .. tostring(slot)
		local lock, lock_err = acquire_lock(global_lock_base(slot), resource, 0)
		if lock then
			global_lock = lock
			break
		end
		if not lock_contended(lock_err) then
			global_err = lock_err
			break
		end
	end
	if not global_lock then
		local released, release_err = release_locks(holder)
		return nil, released and (global_err or "locked") or release_err
	end
	holder.locks[#holder.locks + 1] = global_lock
	return holder
end

local function backend_for(identity)
	return configured.backends and configured.backends[identity.backend]
end

local function network_allowed(plan)
	if plan.requires_network == false then
		return true
	end
	if type(configured.network_authorized) == "function" then
		local ok, allowed = pcall(configured.network_authorized, copy(plan.identity), copy(plan))
		return ok and allowed == true
	end
	return false
end

local function acquire_identity_lock(identity)
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local resource = "identity:" .. identity_key(identity)
	return acquire_lock(resource_lock_base(resource), resource)
end

function runtime_authority.acquire_plan_locks(plan)
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local holder = { locks = {}, resources = copy(plan.resources) }
	for _, resource in ipairs(holder.resources) do
		local lock, lock_err = acquire_lock(resource_lock_base(resource), resource)
		if not lock then
			local released, release_err = release_locks(holder)
			return nil, released and lock_err or release_err
		end
		holder.locks[#holder.locks + 1] = lock
	end
	return holder
end

function M.setup(opts)
	if type(opts) ~= "table" then
		error("verified_tools.setup requires options")
	end
	local allowed = {
		state_root = true,
		backends = true,
		probe_external = true,
		network_authorized = true,
		defer = true,
		instance_token = true,
		lock_wait_ms = true,
		lock_retry_ms = true,
		watchdog_ms = true,
		pid = true,
		process_alive = true,
		fail_persist = true,
		clock = true,
		notify = true,
		events = true,
		on_state_change = true,
		interleave = true,
	}
	if not exact_keys(opts, allowed) then
		error("verified_tools.setup received an unknown option")
	end
	if type(opts.state_root) ~= "string" and type(opts.state_root) ~= "function" then
		error("state_root is required")
	end
	if opts.backends ~= nil and type(opts.backends) ~= "table" then
		error("backends must be a table")
	end
	local next_backends
	if opts.backends ~= nil then
		next_backends = {}
		for name, backend in pairs(opts.backends) do
			if type(name) ~= "string" or name == "" or type(backend) ~= "table" then
				error("backends must map non-empty string names to backend tables")
			end
			if backend.run ~= nil and type(backend.run) ~= "function" then
				error("backend.run must be a function")
			end
			if backend.attest ~= nil and type(backend.attest) ~= "function" then
				error("backend.attest must be a function")
			end
			next_backends[name] = backend
		end
	end
	for _, name in ipairs({
		"probe_external",
		"network_authorized",
		"defer",
		"pid",
		"process_alive",
		"fail_persist",
		"clock",
		"notify",
		"events",
		"on_state_change",
		"interleave",
	}) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error(name .. " must be a function")
		end
	end
	for _, name in ipairs({ "lock_wait_ms", "lock_retry_ms", "watchdog_ms" }) do
		local value = opts[name]
		if value ~= nil and (not finite_number(value) or value < 0) then
			error(name .. " must be a finite non-negative number")
		end
	end
	local supplied = opts.instance_token
	if supplied ~= nil and (type(supplied) ~= "string" or not supplied:match("^[0-9a-f]+$") or #supplied ~= 64) then
		error("instance_token must be 64 lowercase hexadecimal characters")
	end
	local resolved_root, root_guard_or_err = resolve_state_root(opts.state_root)
	if not resolved_root then
		error(root_guard_or_err)
	end
	local owner_pid
	if type(opts.pid) == "function" then
		local pid_ok, value = pcall(opts.pid)
		owner_pid = pid_ok and value or nil
	else
		owner_pid = uv.os_getpid()
	end
	if not finite_number(owner_pid) or owner_pid < 1 or owner_pid % 1 ~= 0 then
		error("verified_tools.setup requires a stable positive integer PID")
	end
	local copied_ok, next_config = pcall(vim.tbl_extend, "force", {}, opts)
	if not copied_ok then
		error("verified_tools.setup options cannot be copied")
	end
	if next_backends ~= nil then
		next_config.backends = next_backends
	end
	if pinned_state_root ~= nil then
		if
			resolved_root ~= pinned_state_root
			or owner_pid ~= pinned_pid
			or not vim.deep_equal(configured, next_config)
		then
			error("verified_tools.setup cannot reconfigure a pinned engine; call teardown() first")
		end
		return M
	end
	local next_token = supplied
	if next_token == nil then
		local token_ok, generated = pcall(
			vim.fn.sha256,
			table.concat({ resolved_root, tostring(owner_pid), tostring(uv.hrtime()), tostring({}) }, "\0")
		)
		next_token = token_ok and generated or nil
	end
	if not valid_sha256(next_token) then
		error("verified_tools.setup could not create an instance token")
	end
	local next_directories = {}
	if root_guard_or_err.state == "present" then
		next_directories[resolved_root] = { dev = root_guard_or_err.dev, ino = root_guard_or_err.ino }
	end
	-- Publish only after every fallible validation above has completed.
	configured = next_config
	pinned_state_root = resolved_root
	state_root_guard = root_guard_or_err
	state_directory_guards = next_directories
	pinned_pid = owner_pid
	instance_token = next_token
	return M
end

function M.effective_config()
	if not pinned_state_root then
		return {
			backends = {},
			lock_wait_ms = LOCK_WAIT_MILLISECONDS,
			lock_retry_ms = 25,
			watchdog_ms = 300000,
		}
	end
	local backends = vim.tbl_keys(configured.backends or {})
	table.sort(backends)
	return copy({
		state_root = pinned_state_root,
		backends = backends,
		lock_wait_ms = tonumber(configured.lock_wait_ms) or LOCK_WAIT_MILLISECONDS,
		lock_retry_ms = tonumber(configured.lock_retry_ms) or 25,
		watchdog_ms = tonumber(configured.watchdog_ms) or 300000,
	})
end

function M.identity(value)
	local identity, err = normalize_identity(value)
	if not identity then
		return nil, err
	end
	return copy(identity)
end

---Validate an external executable's lexical and canonical authority before a
---host adapter executes it for an explicit compatibility probe. Certification
---still performs the full fingerprint and locked revalidation.
---@param path string
---@return string? canonical_path
---@return string? error_message
function M.validate_external_candidate(path)
	return runtime_authority.validate_external_path_authority(path)
end

---Validate a process prerequisite. Certified tool candidates retain the
---single-link rule; this separate boundary additionally accepts an immutable,
---root-owned hardlinked system executable below an entirely root-owned,
---non-writable canonical ancestor chain.
---@param path string
---@return string? canonical_path
---@return string? error_message
function M.validate_prerequisite_candidate(path)
	return runtime_authority.validate_prerequisite_path_authority(path)
end

function M.shim_bin()
	return vim.fs.joinpath(root(), "shims", "bin")
end

local function verified_executable(path, allow_link)
	local fingerprint, err = fingerprint_file(path, true)
	if not fingerprint then
		return nil, err
	end
	if not allow_link and vim.fs.normalize(path) ~= fingerprint.path then
		return nil, "managed executable path must be canonical and must not be a symlink"
	end
	return fingerprint.path, nil, fingerprint
end

local function normalize_probe(identity, spec, executables)
	if spec.force_managed == true or type(configured.probe_external) ~= "function" then
		return { outcome = "absent" }
	end
	local copied, identity_copy, spec_copy = pcall(function()
		return copy(identity), copy(spec)
	end)
	if not copied then
		return nil, "external probe input is not safely copyable"
	end
	local called, observed = pcall(configured.probe_external, identity_copy, spec_copy)
	if not called then
		return nil, "external probe crashed: " .. tostring(observed)
	end
	if type(observed) ~= "table" or type(observed.outcome) ~= "string" then
		return nil, "external probe returned an invalid outcome"
	end
	if observed.outcome == "absent" then
		if not exact_keys(observed, { outcome = true }) then
			return nil, "absent probe outcome contains unknown fields"
		end
		return { outcome = "absent" }
	end
	if observed.outcome == "error" then
		if
			not exact_keys(observed, { outcome = true, detail = true })
			or type(observed.detail) ~= "string"
			or observed.detail == ""
		then
			return nil, "error probe outcome is invalid"
		end
		return nil, "external probe error: " .. observed.detail:gsub("[%c]", " "):sub(1, 160)
	end
	if observed.outcome == "incompatible" then
		if
			not exact_keys(observed, { outcome = true, version = true, detail = true })
			or (observed.version ~= nil and type(observed.version) ~= "string")
			or (observed.detail ~= nil and type(observed.detail) ~= "string")
		then
			return nil, "incompatible probe outcome is invalid"
		end
		return {
			outcome = "incompatible",
			version = observed.version,
			detail = observed.detail and observed.detail:gsub("[%c]", " "):sub(1, 160) or nil,
		}
	end
	if observed.outcome ~= "compatible" then
		return nil, "external probe outcome is unknown"
	end
	if
		not exact_keys(observed, { outcome = true, version = true, paths = true })
		or observed.version ~= identity.version
		or type(observed.paths) ~= "table"
	then
		return nil, "compatible probe outcome is invalid"
	end
	local commands = sorted_keys(executables)
	if #sorted_keys(observed.paths) ~= #commands then
		return nil, "compatible probe command set is not exact"
	end
	local paths = {}
	for _, command in ipairs(commands) do
		if type(observed.paths[command]) ~= "string" then
			return nil, "compatible probe is missing command " .. command
		end
		local fingerprint, path_err = runtime_authority.fingerprint_external_file(observed.paths[command])
		if not fingerprint then
			return nil, "compatible probe path is invalid for " .. command .. ": " .. tostring(path_err)
		end
		local lexical = vim.fs.normalize(vim.fn.fnamemodify(observed.paths[command], ":p"))
		paths[command] = { lexical = lexical, fingerprint = fingerprint }
	end
	for command in pairs(observed.paths) do
		if executables[command] == nil then
			return nil, "compatible probe contains unknown command " .. tostring(command)
		end
	end
	return { outcome = "compatible", version = identity.version, paths = paths }
end

local function normalize_relative(value, label)
	if
		type(value) ~= "string"
		or value == ""
		or value:sub(1, 1) == "/"
		or value:find("%z")
		or value:match("^%a:[/\\]")
	then
		return nil, label .. " must be a safe relative path"
	end
	for segment in value:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return nil, label .. " must not contain traversal"
		end
	end
	local normalized = vim.fs.normalize(value)
	if normalized ~= value or normalized:find("\\", 1, true) then
		return nil, label .. " must be normalized"
	end
	return normalized
end

function runtime_authority.normalize_bundle_receipt_header(identity, value)
	if
		type(value) ~= "table"
		or not exact_keys(value, {
			schema = true,
			kind = true,
			name = true,
			package = true,
			version = true,
			target = true,
			source_tarball = true,
			source_integrity = true,
			source_sha256 = true,
			node_version = true,
			node_archive_sha256 = true,
			bin = true,
		})
		or value.schema ~= 1
		or value.kind ~= "verified-npm-bundle-receipt"
		or value.name ~= identity.name
		or value.version ~= identity.version
		or value.target ~= identity.target
		or type(value.package) ~= "string"
		or value.package == ""
		or type(value.source_tarball) ~= "string"
		or not value.source_tarball:match("^https://registry%.npmjs%.org/")
		or type(value.source_integrity) ~= "string"
		or not value.source_integrity:match("^sha512%-%S+$")
		or not valid_sha256(value.source_sha256)
		or identity.digest ~= "sha256:" .. value.source_sha256
		or type(value.node_version) ~= "string"
		or not value.node_version:match("^%d+%.%d+%.%d+$")
		or not valid_sha256(value.node_archive_sha256)
		or not exact_keys(value.bin, { devcontainer = true })
		or value.bin.devcontainer ~= "devcontainer.js"
	then
		return nil, "npm bundle receipt header is invalid"
	end
	return copy(value)
end

local function normalize_integrity(identity, manifest, executables)
	if type(manifest) ~= "table" or type(manifest.integrity) ~= "table" then
		return nil, "manifest.integrity is required"
	end
	local integrity = manifest.integrity
	local commands = {}
	local command_paths = {}
	if type(integrity.commands) ~= "table" or #sorted_keys(integrity.commands) ~= #sorted_keys(executables) then
		return nil, "manifest.integrity.commands must exactly match spec.executables"
	end
	for _, command in ipairs(sorted_keys(executables)) do
		local relative, err = normalize_relative(integrity.commands[command], "manifest.integrity.commands." .. command)
		if not relative then
			return nil, err
		end
		if vim.fs.basename(relative) ~= executables[command] then
			return nil, "manifest.integrity command basename does not match spec.executables." .. command
		end
		if command_paths[relative] then
			return nil, "manifest.integrity.commands contains a duplicate installed path"
		end
		commands[command] = relative
		command_paths[relative] = true
	end
	for command in pairs(integrity.commands) do
		if executables[command] == nil then
			return nil, "manifest.integrity contains unknown command " .. tostring(command)
		end
	end
	if identity.backend == "release" then
		if
			not exact_keys(integrity, {
				kind = true,
				archive_sha256 = true,
				commands = true,
				artifacts = true,
			})
			or integrity.kind ~= "release-sha256"
			or not valid_sha256(integrity.archive_sha256)
			or type(integrity.artifacts) ~= "table"
		then
			return nil, "release integrity manifest is invalid"
		end
		local identity_digest = identity.digest:gsub("^sha256:", "")
		if integrity.archive_sha256 ~= identity_digest then
			return nil, "release archive digest does not match ToolIdentity"
		end
		local artifacts = {}
		for index, relative in ipairs(integrity.artifacts) do
			local normalized, err = normalize_relative(relative, ("manifest.integrity.artifacts[%d]"):format(index))
			if not normalized then
				return nil, err
			end
			if artifacts[normalized] then
				return nil, "manifest.integrity.artifacts contains a duplicate"
			end
			if command_paths[normalized] then
				return nil, "manifest.integrity artifact overlaps a command path"
			end
			artifacts[normalized] = true
		end
		for key in pairs(integrity.artifacts) do
			if type(key) ~= "number" or key < 1 or key > #integrity.artifacts or key % 1 ~= 0 then
				return nil, "manifest.integrity.artifacts must be a dense list"
			end
		end
		return {
			kind = "release-sha256",
			archive_sha256 = integrity.archive_sha256,
			commands = commands,
			artifacts = sorted_keys(artifacts),
		}
	end
	if identity.backend == "npm-release" then
		if
			not exact_keys(integrity, {
				kind = true,
				source_sha256 = true,
				receipt_path = true,
				receipt = true,
				commands = true,
			})
			or integrity.kind ~= "bundle-sha256"
			or not valid_sha256(integrity.source_sha256)
			or identity.digest ~= "sha256:" .. integrity.source_sha256
		then
			return nil, "npm bundle integrity manifest is invalid"
		end
		local receipt = runtime_authority.normalize_bundle_receipt_header(identity, integrity.receipt)
		local receipt_path = type(integrity.receipt_path) == "string" and vim.fs.normalize(integrity.receipt_path)
			or nil
		if
			not receipt
			or receipt.source_sha256 ~= integrity.source_sha256
			or not receipt_path
			or receipt_path:sub(1, 1) ~= "/"
			or receipt_path ~= integrity.receipt_path
			or vim.fs.basename(receipt_path) ~= integrity.source_sha256 .. ".json"
			or contained(receipt_path, identity.install_root)
		then
			return nil, "npm bundle receipt authority is invalid"
		end
		return {
			kind = "bundle-sha256",
			source_sha256 = integrity.source_sha256,
			receipt_path = receipt_path,
			receipt = receipt,
			commands = commands,
		}
	end
	if identity.backend == "mason" then
		if
			not exact_keys(integrity, { kind = true, receipt_path = true, receipt = true, commands = true })
			or integrity.kind ~= "mason-local-integrity"
			or type(integrity.receipt) ~= "table"
			or not exact_keys(integrity.receipt, { package = true, version = true, source_version = true })
			or integrity.receipt.package ~= identity.name
			or integrity.receipt.version ~= identity.version
			or type(integrity.receipt.source_version) ~= "string"
			or integrity.receipt.source_version == ""
		then
			return nil, "Mason integrity manifest is invalid"
		end
		local receipt_path, receipt_err = normalize_relative(integrity.receipt_path, "manifest.integrity.receipt_path")
		if not receipt_path then
			return nil, receipt_err
		end
		if command_paths[receipt_path] then
			return nil, "Mason receipt path overlaps a command path"
		end
		return {
			kind = "mason-local-integrity",
			receipt_path = receipt_path,
			receipt = copy(integrity.receipt),
			commands = commands,
		}
	end
	return nil, "unsupported verified-tools backend integrity kind"
end

function M.plan(spec)
	if type(spec) ~= "table" then
		return nil, "tool spec must be a table"
	end
	if
		not exact_keys(spec, {
			identity = true,
			manifest = true,
			executables = true,
			requires_network = true,
			force_managed = true,
		})
	then
		return nil, "tool spec contains an unknown field"
	end
	if type(spec.identity) ~= "table" then
		return nil, "spec.identity is required"
	end
	local identity, err = normalize_identity(spec.identity)
	if not identity then
		return nil, err
	end
	if spec.requires_network ~= nil and type(spec.requires_network) ~= "boolean" then
		return nil, "spec.requires_network must be a boolean"
	end
	if spec.force_managed ~= nil and type(spec.force_managed) ~= "boolean" then
		return nil, "spec.force_managed must be a boolean"
	end
	local destination, destination_guard = canonical_destination(identity.install_root)
	if not destination then
		return nil, destination_guard
	end
	identity.install_root = destination
	local executables, executable_err = normalize_executables(spec.executables)
	if not executables then
		return nil, executable_err
	end
	local manifest_ok, manifest = pcall(copy, spec.manifest or {})
	if not manifest_ok or type(manifest) ~= "table" then
		return nil, "spec.manifest is not safely copyable"
	end
	local integrity, integrity_err = normalize_integrity(identity, manifest, executables)
	if not integrity then
		return nil, integrity_err
	end
	manifest.integrity = integrity
	local shims = plan_shims(identity, executables)
	local probe, probe_err = normalize_probe(identity, spec, executables)
	if not probe then
		return nil, probe_err
	end
	local strategy = probe.outcome == "compatible" and "external" or "managed"
	-- A previous managed shim has PATH precedence. Never report an external
	-- strategy while that shim would still win execution.
	for _, path in pairs(shims) do
		if uv.fs_lstat(path) then
			strategy = "managed"
			break
		end
	end
	local plan = {
		schema = PLAN_SCHEMA,
		identity = identity,
		identity_key = identity_key(identity),
		destination_key = destination_key(identity),
		backend = identity.backend,
		requires_network = spec.requires_network ~= false,
		manifest = manifest,
		executables = executables,
		shims = shims,
		resources = plan_resources(identity, shims),
		destination_guard = destination_guard,
		probe = probe,
		force_managed = spec.force_managed == true,
		strategy = strategy,
	}
	local digest, digest_err = plan_digest(plan)
	if not digest then
		return nil, digest_err
	end
	plan.plan_digest = digest
	return copy(plan)
end

local function validate_plan_probe(probe, identity, executables, revalidate)
	if type(probe) ~= "table" or type(probe.outcome) ~= "string" then
		return nil, "normalized plan probe is invalid"
	end
	if probe.outcome == "absent" then
		return exact_keys(probe, { outcome = true }) and true or nil, "normalized absent probe is invalid"
	end
	if probe.outcome == "incompatible" then
		if
			not exact_keys(probe, { outcome = true, version = true, detail = true })
			or (probe.version ~= nil and type(probe.version) ~= "string")
			or (probe.detail ~= nil and type(probe.detail) ~= "string")
		then
			return nil, "normalized incompatible probe is invalid"
		end
		return true
	end
	if
		probe.outcome ~= "compatible"
		or not exact_keys(probe, { outcome = true, version = true, paths = true })
		or probe.version ~= identity.version
		or type(probe.paths) ~= "table"
		or #sorted_keys(probe.paths) ~= #sorted_keys(executables)
	then
		return nil, "normalized compatible probe is invalid"
	end
	for _, command in ipairs(sorted_keys(executables)) do
		local entry = probe.paths[command]
		if
			type(entry) ~= "table"
			or not exact_keys(entry, { lexical = true, fingerprint = true })
			or type(entry.lexical) ~= "string"
			or entry.lexical:sub(1, 1) ~= "/"
			or vim.fs.normalize(entry.lexical) ~= entry.lexical
			or type(entry.fingerprint) ~= "table"
			or not valid_fingerprint_shape(entry.fingerprint, vim.fs.dirname(entry.fingerprint.path or "/"))
		then
			return nil, "normalized compatible probe entry is invalid for " .. command
		end
		if revalidate then
			local current = runtime_authority.fingerprint_external_file(entry.lexical)
			if not current or not vim.deep_equal(current, entry.fingerprint) then
				return nil, "external plan executable changed for " .. command
			end
		end
	end
	for command in pairs(probe.paths) do
		if not executables[command] then
			return nil, "normalized compatible probe contains an unknown command"
		end
	end
	return true
end

local function validate_static_destination_guard(guard, install_root)
	if
		type(guard) ~= "table"
		or type(install_root) ~= "string"
		or install_root:sub(1, 1) ~= "/"
		or vim.fs.normalize(install_root) ~= install_root
		or guard.lexical ~= install_root
		or guard.canonical ~= install_root
	then
		return nil, "install destination guard is invalid"
	end
	if guard.state == "present" then
		if
			not exact_keys(guard, {
				state = true,
				lexical = true,
				canonical = true,
				dev = true,
				ino = true,
			})
			or type(guard.dev) ~= "number"
			or guard.dev < 0
			or guard.dev % 1 ~= 0
			or type(guard.ino) ~= "number"
			or guard.ino < 0
			or guard.ino % 1 ~= 0
		then
			return nil, "present install destination guard is invalid"
		end
		return true
	end
	if
		guard.state ~= "absent"
		or not exact_keys(guard, {
			state = true,
			lexical = true,
			canonical = true,
			ancestor = true,
			ancestor_dev = true,
			ancestor_ino = true,
			suffix = true,
		})
		or type(guard.ancestor) ~= "string"
		or guard.ancestor:sub(1, 1) ~= "/"
		or vim.fs.normalize(guard.ancestor) ~= guard.ancestor
		or type(guard.ancestor_dev) ~= "number"
		or guard.ancestor_dev < 0
		or guard.ancestor_dev % 1 ~= 0
		or type(guard.ancestor_ino) ~= "number"
		or guard.ancestor_ino < 0
		or guard.ancestor_ino % 1 ~= 0
		or type(guard.suffix) ~= "table"
		or #guard.suffix == 0
	then
		return nil, "absent install destination guard is invalid"
	end
	local suffix = {}
	for index, component in ipairs(guard.suffix) do
		if
			type(component) ~= "string"
			or component == ""
			or component == "."
			or component == ".."
			or component:find("/", 1, true)
			or component:find("\\", 1, true)
		then
			return nil, "absent install destination guard suffix is invalid"
		end
		suffix[index] = component
	end
	for key in pairs(guard.suffix) do
		if type(key) ~= "number" or key < 1 or key > #guard.suffix or key % 1 ~= 0 then
			return nil, "absent install destination guard suffix is invalid"
		end
	end
	if vim.fs.normalize(vim.fs.joinpath(guard.ancestor, unpack(suffix))) ~= install_root then
		return nil, "absent install destination guard path is invalid"
	end
	return true
end

normalize_supplied_plan = function(plan, options)
	options = options or {}
	if type(plan) ~= "table" or plan.schema ~= PLAN_SCHEMA then
		return nil, "claim requires a normalized plan"
	end
	local allowed = {
		schema = true,
		identity = true,
		identity_key = true,
		destination_key = true,
		backend = true,
		requires_network = true,
		manifest = true,
		executables = true,
		shims = true,
		resources = true,
		destination_guard = true,
		probe = true,
		force_managed = true,
		strategy = true,
		plan_digest = true,
	}
	if not exact_keys(plan, allowed) then
		return nil, "normalized plan contains unknown fields"
	end
	local identity, identity_err = normalize_identity(plan.identity)
	if not identity then
		return nil, identity_err
	end
	local static_guard_ok, static_guard_err =
		validate_static_destination_guard(plan.destination_guard, identity.install_root)
	if not static_guard_ok then
		return nil, static_guard_err
	end
	local destination, destination_guard
	if options.skip_destination_state == true then
		destination = identity.install_root
		destination_guard = copy(plan.destination_guard)
	else
		destination, destination_guard = canonical_destination(identity.install_root)
		if not destination then
			return nil, destination_guard
		end
	end
	identity.install_root = destination
	local executables, executable_err = normalize_executables(plan.executables)
	if not executables then
		return nil, executable_err
	end
	local shims = plan_shims(identity, executables)
	local resources = plan_resources(identity, shims)
	local integrity, integrity_err = normalize_integrity(identity, plan.manifest, executables)
	if not integrity or not vim.deep_equal(integrity, plan.manifest.integrity) then
		return nil, integrity_err or "normalized plan integrity was modified"
	end
	local destination_matches = options.skip_destination_state == true
		or vim.deep_equal(plan.destination_guard, destination_guard)
	if options.installed == true and not options.skip_destination_state then
		destination_matches = validate_destination_guard(plan.destination_guard, true) == true
	end
	if
		plan.identity_key ~= identity_key(identity)
		or plan.destination_key ~= destination_key(identity)
		or plan.backend ~= identity.backend
		or not vim.deep_equal(plan.shims, shims)
		or not vim.deep_equal(plan.resources, resources)
		or (plan.strategy ~= "managed" and plan.strategy ~= "external")
		or type(plan.manifest) ~= "table"
		or type(plan.requires_network) ~= "boolean"
		or type(plan.force_managed) ~= "boolean"
		or not destination_matches
	then
		return nil, "normalized plan was modified"
	end
	local normalized = copy(plan)
	normalized.identity = identity
	normalized.executables = executables
	normalized.shims = shims
	normalized.resources = resources
	local digest, digest_err = plan_digest(normalized)
	if not digest or digest ~= plan.plan_digest then
		return nil, digest_err or "normalized plan was modified"
	end
	local revalidate_external = normalized.strategy == "external" and options.skip_external_revalidation ~= true
	local probe_ok, probe_err = validate_plan_probe(normalized.probe, identity, executables, revalidate_external)
	if not probe_ok then
		return nil, probe_err
	end
	if normalized.force_managed and normalized.probe.outcome ~= "absent" then
		return nil, "force-managed plan must not contain an external probe result"
	end
	if normalized.strategy == "external" and normalized.probe.outcome ~= "compatible" then
		return nil, "external plan has no compatible probe"
	end
	return normalized
end

function M.probe(spec)
	return M.plan(spec)
end

local function normalize_identity_request(request, label)
	if type(request) ~= "table" then
		return nil, label .. " requires a ToolIdentity"
	end
	local source = request
	if request.identity ~= nil then
		if not exact_keys(request, { identity = true }) then
			return nil, label .. " request must contain only identity"
		end
		source = request.identity
	end
	return normalize_identity(source)
end

local function normalize_resolve_request(request)
	if type(request) ~= "table" then
		return nil, "resolve requires a ToolIdentity, tool spec, or normalized plan"
	end
	if request.schema ~= nil or request.plan_digest ~= nil then
		local plan, plan_err = normalize_supplied_plan(request, {
			installed = request.strategy == "managed",
			skip_external_revalidation = request.strategy == "external",
		})
		if not plan then
			return nil, plan_err
		end
		return { kind = "plan", identity = plan.identity, plan = plan }
	end
	if
		request.manifest ~= nil
		or request.executables ~= nil
		or request.requires_network ~= nil
		or request.force_managed ~= nil
	then
		if
			not exact_keys(request, {
				identity = true,
				manifest = true,
				executables = true,
				requires_network = true,
				force_managed = true,
			})
		then
			return nil, "tool spec contains an unknown field"
		end
		local identity, identity_err = normalize_identity(request.identity)
		if not identity then
			return nil, identity_err
		end
		if request.requires_network ~= nil and type(request.requires_network) ~= "boolean" then
			return nil, "spec.requires_network must be a boolean"
		end
		if request.force_managed ~= nil and type(request.force_managed) ~= "boolean" then
			return nil, "spec.force_managed must be a boolean"
		end
		local destination, destination_err = canonical_destination(identity.install_root)
		if not destination then
			return nil, destination_err
		end
		identity.install_root = destination
		local executables, executable_err = normalize_executables(request.executables)
		if not executables then
			return nil, executable_err
		end
		local copied, manifest = pcall(copy, request.manifest or {})
		if not copied or type(manifest) ~= "table" then
			return nil, "spec.manifest is not safely copyable"
		end
		local integrity, integrity_err = normalize_integrity(identity, manifest, executables)
		if not integrity then
			return nil, integrity_err
		end
		manifest.integrity = integrity
		return {
			kind = "spec",
			identity = identity,
			manifest = manifest,
			executables = executables,
			requires_network = request.requires_network ~= false,
			force_managed = request.force_managed == true,
		}
	end
	local identity, identity_err = normalize_identity_request(request, "resolve")
	if not identity then
		return nil, identity_err
	end
	return { kind = "identity", identity = identity }
end

local function resolve_spec_matches_plan(request, plan)
	local manifest_matches = vim.deep_equal(request.manifest, plan.manifest)
	if
		not manifest_matches
		and request.identity.backend == "release"
		and exact_keys(request.manifest, { entry = true, integrity = true })
		and exact_keys(plan.manifest, { entry = true, integrity = true, release_plan = true })
	then
		-- Release prerequisite selection is install-only and may depend on PATH.
		-- Runtime supplies the immutable entry/integrity projection instead.
		manifest_matches = vim.deep_equal(request.manifest.entry, plan.manifest.entry)
			and vim.deep_equal(request.manifest.integrity, plan.manifest.integrity)
	end
	return identity_json(request.identity) == identity_json(plan.identity)
		and manifest_matches
		and vim.deep_equal(request.executables, plan.executables)
		and request.requires_network == plan.requires_network
end

function runtime_authority.normalize_external_certification(value)
	if
		type(value) ~= "table"
		or not exact_keys(value, {
			schema = true,
			kind = true,
			identity = true,
			identity_key = true,
			plan = true,
		})
		or value.schema ~= runtime_authority.external_schema
		or value.kind ~= "external-executable-certification"
	then
		return nil, "external certification schema is invalid"
	end
	local identity, identity_err = normalize_identity(value.identity)
	if not identity then
		return nil, identity_err
	end
	local plan, plan_err = normalize_supplied_plan(value.plan, {
		skip_destination_state = true,
		skip_external_revalidation = true,
	})
	if
		not plan
		or plan.strategy ~= "external"
		or plan.force_managed
		or identity_json(plan.identity) ~= identity_json(identity)
		or value.identity_key ~= identity_key(identity)
	then
		return nil, plan_err or "external certification does not contain an exact external plan"
	end
	return {
		schema = runtime_authority.external_schema,
		kind = "external-executable-certification",
		identity = identity,
		identity_key = value.identity_key,
		plan = plan,
	}
end

function runtime_authority.validate_external_live_proof(plan)
	local commands = {}
	for _, command in ipairs(sorted_keys(plan.executables)) do
		local entry = plan.probe.paths[command]
		local canonical, authority_err
		if entry then
			canonical, authority_err =
				runtime_authority.validate_external_path_authority(entry.lexical, entry.fingerprint.path)
		end
		if not canonical then
			return nil,
				"external executable authority changed for " .. command .. ": " .. tostring(authority_err or "drift")
		end
		local current, current_err = validate_fingerprint_metadata(entry.fingerprint, true)
		if not current then
			return nil, "external executable changed for " .. command .. ": " .. tostring(current_err or "drift")
		end
		local rechecked, recheck_err =
			runtime_authority.validate_external_path_authority(entry.lexical, entry.fingerprint.path)
		if not rechecked then
			return nil,
				"external executable authority changed for " .. command .. ": " .. tostring(recheck_err or "drift")
		end
		commands[command] = current
	end
	return commands
end

function runtime_authority.bundle_entry_path(value)
	local normalized = normalize_relative(value, "bundle receipt entry path")
	if not normalized or #normalized > 512 or not normalized:match("^[%w%._%+%@%-%/]+$") then
		return nil, "bundle receipt entry path is unsafe"
	end
	return normalized
end

function runtime_authority.normalize_bundle_entries(value)
	if type(value) ~= "table" or not vim.islist(value) or #value > runtime_authority.max_bundle_entries then
		return nil, "bundle receipt entries are invalid"
	end
	local entries = {}
	local previous
	local total = 0
	for index, entry in ipairs(value) do
		local path, path_err = runtime_authority.bundle_entry_path(type(entry) == "table" and entry.path or nil)
		if not path then
			return nil, path_err
		end
		if previous and path <= previous then
			return nil, "bundle receipt entries are not uniquely sorted"
		end
		previous = path
		if entry.kind == "directory" then
			if
				not exact_keys(entry, { kind = true, mode = true, path = true })
				or entry.mode ~= PRIVATE_DIRECTORY_MODE
			then
				return nil, "bundle receipt directory entry is invalid"
			end
			entries[#entries + 1] = { kind = "directory", mode = PRIVATE_DIRECTORY_MODE, path = path }
		elseif entry.kind == "file" then
			if
				not exact_keys(entry, { kind = true, mode = true, path = true, sha256 = true, size = true })
				or (entry.mode ~= PRIVATE_FILE_MODE and entry.mode ~= PRIVATE_DIRECTORY_MODE)
				or not finite_number(entry.size)
				or entry.size < 0
				or entry.size % 1 ~= 0
				or entry.size > MAX_EXECUTABLE_BYTES
				or not valid_sha256(entry.sha256)
			then
				return nil, "bundle receipt file entry is invalid"
			end
			total = total + entry.size
			if total > runtime_authority.max_bundle_bytes then
				return nil, "bundle receipt exceeds its byte limit"
			end
			entries[#entries + 1] = {
				kind = "file",
				mode = entry.mode,
				path = path,
				sha256 = entry.sha256,
				size = entry.size,
			}
		else
			return nil, "bundle receipt entry kind is invalid"
		end
	end
	return entries, total
end

function runtime_authority.normalize_bundle_receipt(plan, value)
	if
		type(value) ~= "table"
		or not exact_keys(value, {
			schema = true,
			kind = true,
			name = true,
			package = true,
			version = true,
			target = true,
			source_tarball = true,
			source_integrity = true,
			source_sha256 = true,
			node_version = true,
			node_archive_sha256 = true,
			bin = true,
			bytes = true,
			entries = true,
			closure_sha256 = true,
		})
	then
		return nil, "bundle receipt envelope is invalid"
	end
	local header = copy(value)
	header.bytes = nil
	header.entries = nil
	header.closure_sha256 = nil
	if not vim.deep_equal(header, plan.manifest.integrity.receipt) then
		return nil, "bundle receipt header differs from the manifest"
	end
	local entries, total = runtime_authority.normalize_bundle_entries(value.entries)
	if
		not entries
		or not finite_number(value.bytes)
		or value.bytes < 0
		or value.bytes % 1 ~= 0
		or value.bytes ~= total
		or not valid_sha256(value.closure_sha256)
	then
		return nil, entries and "bundle receipt aggregate is invalid" or total
	end
	local encoded = canonical_encode(entries)
	if not encoded or hash(encoded) ~= value.closure_sha256 then
		return nil, "bundle receipt closure digest is invalid"
	end
	return { bytes = total, entries = entries, sha256 = value.closure_sha256 }
end

function runtime_authority.private_bundle_directory(path, expected)
	local stat = uv.fs_lstat(path)
	local canonical = stat and stat.type == "directory" and uv.fs_realpath(path) or nil
	local euid = runtime_authority.effective_uid()
	if
		not stat
		or not canonical
		or vim.fs.normalize(canonical) ~= vim.fs.normalize(path)
		or stat.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or not euid
		or stat.uid ~= euid
		or expected and not same_generic_stat(expected, stat, false)
	then
		return nil, "bundle directory is unsafe or changed"
	end
	return stat
end

function runtime_authority.scan_bundle_directory(root, relative, entries, aggregate, depth)
	if depth > 64 then
		return nil, "bundle directory nesting exceeds its limit"
	end
	local directory = relative == "" and root or vim.fs.joinpath(root, relative)
	local before, before_err = runtime_authority.private_bundle_directory(directory)
	if not before then
		return nil, before_err
	end
	local request, scan_err = uv.fs_scandir(directory)
	if not request then
		return nil, "bundle directory cannot be read: " .. tostring(scan_err)
	end
	local names = {}
	while true do
		local name = uv.fs_scandir_next(request)
		if not name then
			break
		end
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local child_relative = relative == "" and name or relative .. "/" .. name
		local safe, safe_err = runtime_authority.bundle_entry_path(child_relative)
		if not safe then
			return nil, safe_err
		end
		local child = vim.fs.joinpath(root, safe)
		local stat = uv.fs_lstat(child)
		if stat and stat.type == "directory" then
			local child_stat, child_err = runtime_authority.private_bundle_directory(child)
			if not child_stat then
				return nil, child_err
			end
			entries[#entries + 1] = { kind = "directory", mode = PRIVATE_DIRECTORY_MODE, path = safe }
			if #entries > runtime_authority.max_bundle_entries then
				return nil, "bundle contains too many entries"
			end
			local scanned, scanned_err =
				runtime_authority.scan_bundle_directory(root, safe, entries, aggregate, depth + 1)
			if not scanned then
				return nil, scanned_err
			end
			local rechecked, recheck_err = runtime_authority.private_bundle_directory(child, child_stat)
			if not rechecked then
				return nil, recheck_err
			end
		elseif stat and stat.type == "file" then
			local mode = stat.mode % 512
			local fingerprint, fingerprint_err = fingerprint_file(child, mode == PRIVATE_DIRECTORY_MODE)
			local euid = runtime_authority.effective_uid()
			if
				(mode ~= PRIVATE_FILE_MODE and mode ~= PRIVATE_DIRECTORY_MODE)
				or not fingerprint
				or fingerprint.path ~= vim.fs.normalize(child)
				or not euid
				or fingerprint.uid ~= euid
			then
				return nil, "bundle file is unsafe: " .. tostring(fingerprint_err or safe)
			end
			aggregate.bytes = aggregate.bytes + fingerprint.size
			if aggregate.bytes > runtime_authority.max_bundle_bytes then
				return nil, "bundle exceeds its byte limit"
			end
			entries[#entries + 1] = {
				kind = "file",
				mode = mode,
				path = safe,
				sha256 = fingerprint.sha256,
				size = fingerprint.size,
			}
			if #entries > runtime_authority.max_bundle_entries then
				return nil, "bundle contains too many entries"
			end
		else
			return nil, "bundle contains a link or special entry"
		end
	end
	local after, after_err = runtime_authority.private_bundle_directory(directory, before)
	return after and true or nil, after_err
end

function runtime_authority.fingerprint_bundle(root)
	local root_stat, root_err = runtime_authority.private_bundle_directory(root)
	if not root_stat then
		return nil, root_err
	end
	local entries = {}
	local aggregate = { bytes = 0 }
	local scanned, scan_err = runtime_authority.scan_bundle_directory(root, "", entries, aggregate, 0)
	if not scanned then
		return nil, scan_err
	end
	table.sort(entries, function(left, right)
		return left.path < right.path
	end)
	local encoded, encode_err = canonical_encode(entries)
	if not encoded then
		return nil, encode_err
	end
	local rechecked, recheck_err = runtime_authority.private_bundle_directory(root, root_stat)
	if not rechecked then
		return nil, recheck_err
	end
	return { bytes = aggregate.bytes, entries = entries, sha256 = hash(encoded) }
end

function runtime_authority.validate_bundle_receipt(plan, expected_receipt_sha256)
	local path = plan.manifest.integrity.receipt_path
	local data, read_err = read_private(path)
	if not data then
		return nil, "verified bundle receipt is unsafe: " .. tostring(read_err)
	end
	local decoded_ok, decoded = pcall(vim.json.decode, data)
	local receipt, receipt_err
	if decoded_ok then
		receipt, receipt_err = runtime_authority.normalize_bundle_receipt(plan, decoded)
	end
	if not receipt then
		return nil, receipt_err or "verified bundle receipt is invalid JSON"
	end
	local fingerprint, fingerprint_err = fingerprint_file(path, false)
	if
		not fingerprint
		or fingerprint.path ~= path
		or expected_receipt_sha256 and fingerprint.sha256 ~= expected_receipt_sha256
	then
		return nil, "verified bundle receipt changed: " .. tostring(fingerprint_err or "digest mismatch")
	end
	local closure, closure_err = runtime_authority.fingerprint_bundle(plan.identity.install_root)
	if not closure or not vim.deep_equal(closure, receipt) then
		return nil, "verified bundle closure changed: " .. tostring(closure_err or "receipt mismatch")
	end
	return { closure = closure, fingerprint = fingerprint }
end

local function validate_live_proof(plan, proof)
	local commands = {}
	for _, command in ipairs(sorted_keys(plan.executables)) do
		local expected = proof.commands[command]
		local current, current_err = validate_fingerprint_metadata(expected, true)
		if not current or not contained(current, plan.identity.install_root) then
			return nil, "verified command changed for " .. command .. ": " .. tostring(current_err or "drift")
		end
		commands[command] = current
	end
	if proof.kind == "release-sha256" then
		for _, relative in ipairs(plan.manifest.integrity.artifacts) do
			local expected = proof.artifacts[relative]
			local current, current_err = validate_fingerprint_metadata(expected, false)
			if not current or not contained(current, plan.identity.install_root) then
				return nil, "verified artifact changed for " .. relative .. ": " .. tostring(current_err or "drift")
			end
		end
	elseif proof.kind == "bundle-sha256" then
		local validated, bundle_err = runtime_authority.validate_bundle_receipt(plan, proof.receipt.fingerprint.sha256)
		if
			not validated
			or validated.closure.sha256 ~= proof.closure_sha256
			or not vim.deep_equal(validated.fingerprint, proof.receipt.fingerprint)
		then
			return nil, bundle_err or "verified bundle proof changed"
		end
	elseif proof.kind == "mason-local-integrity" then
		local receipt_data, receipt_err = read_private(proof.receipt.path)
		if not receipt_data then
			return nil, "verified Mason receipt is unsafe: " .. tostring(receipt_err)
		end
		local decoded_ok, receipt = pcall(vim.json.decode, receipt_data)
		if
			not decoded_ok
			or not exact_keys(receipt, { package = true, version = true, source_version = true })
			or not vim.deep_equal(receipt, plan.manifest.integrity.receipt)
		then
			return nil, "verified Mason receipt content changed"
		end
		local current, fingerprint_err = validate_fingerprint_metadata(proof.receipt.fingerprint, false)
		if not current or not contained(current, plan.identity.install_root) then
			return nil, "verified Mason receipt changed: " .. tostring(fingerprint_err or "drift")
		end
	else
		return nil, "verified proof kind is unsupported"
	end
	local destination_ok, destination_err = validate_destination_guard(plan.destination_guard, true)
	if not destination_ok then
		return nil, destination_err
	end
	return commands
end

local function close_resolve_directories(records_fd, root_fd)
	local records_closed, records_close_err = true, nil
	if records_fd then
		records_closed, records_close_err = uv.fs_close(records_fd)
	end
	local root_closed, root_close_err = true, nil
	if root_fd then
		root_closed, root_close_err = uv.fs_close(root_fd)
	end
	if not records_closed or not root_closed then
		return nil, "could not close verified state: " .. tostring(records_close_err or root_close_err)
	end
	return true
end

local function open_resolve_record(identity, namespace, label, key)
	namespace = namespace or "records"
	label = label or "tool record"
	if namespace ~= "records" and namespace ~= "external-records" and namespace ~= "active-slots" then
		return nil, "verified record namespace is invalid"
	end
	if key ~= nil and (type(key) ~= "string" or not key:match("^[0-9a-f]+$") or #key ~= 64) then
		return nil, "verified record key is invalid"
	end
	local parent_ok, parent_err = validate_directory_guard(state_root_guard.parent, state_root_guard.parent_stat)
	if not parent_ok then
		return nil, parent_err
	end
	local root_path = root()
	local root_stat, root_err = uv.fs_lstat(root_path)
	if not root_stat then
		if root_err and not tostring(root_err):find("ENOENT", 1, true) then
			return nil, "could not inspect verified state root: " .. tostring(root_err)
		end
		if state_root_guard.state == "present" then
			return nil, "verified state root was removed after setup"
		end
		return false, "absent"
	end
	if root_stat.type ~= "directory" then
		return nil, "verified state root is not a real directory"
	end
	if
		state_root_guard.state == "present"
		and (root_stat.dev ~= state_root_guard.dev or root_stat.ino ~= state_root_guard.ino)
	then
		return nil, "verified state root identity changed"
	end
	local root_fd, root_opened_or_err = record_open_directory(root_path)
	if not root_fd then
		return nil, root_opened_or_err
	end
	local root_opened = root_opened_or_err
	if root_opened.mode % 512 ~= PRIVATE_DIRECTORY_MODE then
		close_resolve_directories(nil, root_fd)
		return nil, "verified state root permissions must already be 0700"
	end
	local records_path = vim.fs.joinpath(root_path, namespace)
	local records_fd, records_opened_or_err, records_errno =
		record_open_directory_at(root_fd, root_path, namespace, false)
	if not records_fd then
		local closed, close_err = close_resolve_directories(nil, root_fd)
		if not closed then
			return nil, close_err
		end
		if records_errno == 2 and not state_directory_guards[records_path] then
			return false, "absent"
		end
		return nil, records_opened_or_err
	end
	local records_opened = records_opened_or_err
	local records_guard = state_directory_guards[records_path]
	if records_guard and (records_opened.dev ~= records_guard.dev or records_opened.ino ~= records_guard.ino) then
		close_resolve_directories(records_fd, root_fd)
		return nil, "verified " .. namespace .. " directory identity changed"
	end
	local filename = (key or identity_key(identity)) .. ".json"
	local record, record_err = record_read_exact(records_fd, records_path, filename, label, MAX_PRIVATE_BYTES)
	if record == false then
		local closed, close_err = close_resolve_directories(records_fd, root_fd)
		if not closed then
			return nil, close_err
		end
		return false, "absent"
	end
	if not record then
		close_resolve_directories(records_fd, root_fd)
		return nil, record_err
	end
	return {
		root_fd = root_fd,
		root_path = root_path,
		root_stat = root_opened,
		records_fd = records_fd,
		records_path = records_path,
		records_stat = records_opened,
		filename = filename,
		record = record,
		label = label,
		namespace = namespace,
	}
end

local function finish_resolve_record(opened)
	local final_record, record_err =
		record_read_exact(opened.records_fd, opened.records_path, opened.filename, opened.label, MAX_PRIVATE_BYTES)
	local root_current = uv.fs_fstat(opened.root_fd)
	local records_current = uv.fs_fstat(opened.records_fd)
	local root_guard_ok = validate_directory_guard(opened.root_path, {
		dev = opened.root_stat.dev,
		ino = opened.root_stat.ino,
	})
	local records_guard_ok = validate_directory_guard(opened.records_path, {
		dev = opened.records_stat.dev,
		ino = opened.records_stat.ino,
	})
	local parent_ok, parent_err = validate_directory_guard(state_root_guard.parent, state_root_guard.parent_stat)
	local closed, close_err = close_resolve_directories(opened.records_fd, opened.root_fd)
	if not final_record or not record_exact_matches(opened.record, final_record, false) then
		return nil, opened.label .. " changed while it was resolved: " .. tostring(record_err or "snapshot mismatch")
	end
	if
		not root_current
		or not records_current
		or root_current.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or records_current.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or not same_generic_stat(opened.root_stat, root_current, false)
		or not same_generic_stat(opened.records_stat, records_current, false)
		or not root_guard_ok
		or not records_guard_ok
	then
		return nil, "verified state directories changed while the record was resolved"
	end
	if not parent_ok then
		return nil, parent_err
	end
	if not closed then
		return nil, close_err
	end
	return true
end

function runtime_authority.resolve_managed_record(request, opened)
	local decoded_ok, record = pcall(vim.json.decode, opened.record.data)
	local identity = decoded_ok and type(record) == "table" and normalize_identity(record.identity) or nil
	if
		not decoded_ok
		or not schema2_record_shape(record)
		or record.status ~= "succeeded"
		or not identity
		or identity_json(identity) ~= identity_json(request.identity)
		or record.identity_key ~= identity_key(identity)
	then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, "tool record is not an exact succeeded schema-2 record"
	end
	local plan, plan_err = normalize_supplied_plan(record.plan, { installed = true })
	if not plan or plan.strategy ~= "managed" then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, plan_err or "tool record does not contain a managed plan"
	end
	if request.kind == "plan" and not vim.deep_equal(request.plan, plan) then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, "tool record does not match the requested plan"
	end
	if request.kind == "spec" and not resolve_spec_matches_plan(request, plan) then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, "tool record does not match the requested spec"
	end
	if not valid_stored_proof(plan, record.proof, identity) then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, "tool record proof is invalid"
	end
	local commands, proof_err = validate_live_proof(plan, record.proof)
	if not commands then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, proof_err
	end
	local finished, finish_err = finish_resolve_record(opened)
	if not finished then
		return nil, finish_err
	end
	return commands
end

function runtime_authority.resolve_external_record(request, opened)
	local decoded_ok, decoded = pcall(vim.json.decode, opened.record.data)
	local certification, certification_err
	if decoded_ok then
		certification, certification_err = runtime_authority.normalize_external_certification(decoded)
	else
		certification_err = "external certification is not valid JSON"
	end
	if not certification or identity_json(certification.identity) ~= identity_json(request.identity) then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, certification_err or "external certification is corrupt"
	end
	local plan = certification.plan
	if request.kind == "plan" and not vim.deep_equal(request.plan, plan) then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, "external certification does not match the requested plan"
	end
	if request.kind == "spec" and not resolve_spec_matches_plan(request, plan) then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, "external certification does not match the requested spec"
	end
	local commands, proof_err = runtime_authority.validate_external_live_proof(plan)
	if not commands then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, proof_err
	end
	local finished, finish_err = finish_resolve_record(opened)
	if not finished then
		return nil, finish_err
	end
	return commands
end

---Persist an explicitly probed external plan as private runtime authority.
---This is an explicit lifecycle action: it re-hashes the candidate executables,
---takes the plan's identity/destination/shim locks, and atomically replaces only
---the external receipt.
---@param plan table
---@return table? certification
---@return string? error_message
function M.certify_external(plan)
	if not pinned_state_root then
		return nil, "verified_tools.setup must be called first"
	end
	if type(plan) ~= "table" or plan.strategy ~= "external" then
		return nil, "external certification requires a compatible external plan"
	end
	local requested_identity, identity_err = normalize_identity(plan.identity)
	if not requested_identity then
		return nil, identity_err
	end
	local preliminary, preliminary_err = normalize_supplied_plan(plan, { skip_external_revalidation = true })
	if
		not preliminary
		or preliminary.strategy ~= "external"
		or identity_json(preliminary.identity) ~= identity_json(requested_identity)
	then
		return nil, preliminary_err or "external certification requires an exact compatible external plan"
	end
	local certification_locks, lock_err = runtime_authority.acquire_plan_locks(preliminary)
	if not certification_locks then
		return nil, lock_err
	end
	local function finish(value, err)
		local released, release_err = release_locks(certification_locks)
		if not released then
			return nil, release_err
		end
		return value, err
	end
	-- The executable hash belongs inside the complete resource lock set. A
	-- fingerprint made during planning is never published without a locked fresh
	-- revalidation.
	local normalized, normalize_err = normalize_supplied_plan(plan)
	if not normalized then
		return finish(nil, normalize_err)
	end
	if normalized.strategy ~= "external" or identity_json(normalized.identity) ~= identity_json(requested_identity) then
		return finish(nil, "external certification requires an exact compatible external plan")
	end
	for command, path in pairs(normalized.shims) do
		local shim, shim_err = uv.fs_lstat(path)
		if shim or (shim_err and not missing(shim_err)) then
			return finish(
				nil,
				"verified shim could not be ruled out before external certification for "
					.. command
					.. (shim and "" or ": " .. tostring(shim_err))
			)
		end
	end
	local managed, managed_err = decode_record(normalized.identity)
	if managed or managed_err ~= "absent" then
		return finish(
			nil,
			managed and "managed authority already exists; use an explicit managed repair"
				or "managed authority could not be ruled out: " .. tostring(managed_err)
		)
	end
	local certification = {
		schema = runtime_authority.external_schema,
		kind = "external-executable-certification",
		identity = copy(normalized.identity),
		identity_key = normalized.identity_key,
		plan = copy(normalized),
	}
	local encoded_ok, encoded = pcall(vim.json.encode, certification)
	if not encoded_ok or type(encoded) ~= "string" then
		return finish(nil, "external certification is not JSON encodable")
	end
	local persisted, persist_err =
		atomic_write(runtime_authority.external_record_path(normalized.identity), encoded .. "\n")
	if not persisted then
		return finish(nil, persist_err)
	end
	local live, live_err = runtime_authority.validate_external_live_proof(normalized)
	if not live then
		return finish(nil, "external executable changed while certification was published: " .. tostring(live_err))
	end
	for command, path in pairs(normalized.shims) do
		local shim, shim_err = uv.fs_lstat(path)
		if shim or (shim_err and not missing(shim_err)) then
			return finish(
				nil,
				"verified shim could not be ruled out while the external certification was published for "
					.. command
					.. (shim and "" or ": " .. tostring(shim_err))
			)
		end
	end
	managed, managed_err = decode_record(normalized.identity)
	if managed or managed_err ~= "absent" then
		return finish(
			nil,
			managed and "managed authority appeared while the external certification was published"
				or "managed authority could not be rechecked: " .. tostring(managed_err)
		)
	end
	return finish(copy(certification))
end

function M.resolve(spec_or_identity)
	if not pinned_state_root then
		return nil, "verified_tools.setup must be called first"
	end
	local request, request_err = normalize_resolve_request(spec_or_identity)
	if not request then
		return nil, request_err
	end
	local managed, managed_err = open_resolve_record(request.identity, "records", "managed tool record")
	if managed then
		local commands, resolve_err = runtime_authority.resolve_managed_record(request, managed)
		if not commands then
			return nil, "managed authority: " .. tostring(resolve_err)
		end
		return copy(commands)
	end
	if managed == nil or managed_err ~= "absent" then
		return nil, "managed authority: " .. tostring(managed_err)
	end
	if request.kind == "spec" and request.force_managed then
		return nil, "absent"
	end
	local external, external_err = open_resolve_record(request.identity, "external-records", "external certification")
	if not external then
		return nil, external == false and external_err or "external certification: " .. tostring(external_err)
	end
	local commands, resolve_err = runtime_authority.resolve_external_record(request, external)
	if not commands then
		return nil, "external certification: " .. tostring(resolve_err)
	end
	-- Managed state is authoritative even when it appears while an external
	-- receipt is being observed. This second descriptor-relative read closes the
	-- useful race without acquiring or mutating a runtime lock.
	local competing, competing_err = open_resolve_record(request.identity, "records", "managed tool record")
	if competing then
		close_resolve_directories(competing.records_fd, competing.root_fd)
		return nil, "managed authority appeared while external certification was resolved"
	end
	if competing == nil or competing_err ~= "absent" then
		return nil, "managed authority: " .. tostring(competing_err)
	end
	return copy(commands)
end

function runtime_authority.normalize_active_slot(value)
	if type(value) ~= "string" or #value > 64 or not value:match("^[a-z0-9][a-z0-9._%-]*$") then
		return nil, "active slot must be a safe lowercase name"
	end
	return value
end

function runtime_authority.active_pointer_path(slot)
	return vim.fs.joinpath(root(), "active-slots", hash(slot) .. ".json")
end

function runtime_authority.digest_data(value, label)
	local encoded, encode_err = canonical_encode(value)
	if not encoded then
		return nil, label .. " is not canonically encodable: " .. tostring(encode_err)
	end
	return hash(encoded)
end

function runtime_authority.normalize_active_pointer(slot, value)
	if
		type(value) ~= "table"
		or not exact_keys(value, {
			schema = true,
			kind = true,
			slot = true,
			identity = true,
			identity_key = true,
			plan_digest = true,
			proof_sha256 = true,
		})
		or value.schema ~= 1
		or value.kind ~= "verified-tool-active-slot"
		or value.slot ~= slot
		or not valid_sha256(value.identity_key)
		or not valid_sha256(value.plan_digest)
		or not valid_sha256(value.proof_sha256)
	then
		return nil, "active slot pointer is invalid"
	end
	local identity = normalize_identity(value.identity)
	if
		not identity
		or identity.backend ~= "npm-release"
		or identity.name ~= slot
		or identity_key(identity) ~= value.identity_key
	then
		return nil, "active slot identity is invalid"
	end
	local normalized = copy(value)
	normalized.identity = identity
	return normalized
end

function runtime_authority.active_record_matches(pointer)
	local record, record_err = decode_record(pointer.identity)
	if
		not record
		or record.status ~= "succeeded"
		or type(record.plan) ~= "table"
		or record.plan.plan_digest ~= pointer.plan_digest
		or type(record.proof) ~= "table"
	then
		return nil,
			"active managed record is unavailable: " .. tostring(record_err or record and record.status or "invalid")
	end
	local proof_sha256, proof_err = runtime_authority.digest_data(record.proof, "active proof")
	if not proof_sha256 or proof_sha256 ~= pointer.proof_sha256 then
		return nil, proof_err or "active managed proof changed"
	end
	return record
end

---Resolve one explicitly activated immutable managed identity. This path is
---read-only: it never creates state, plans, probes, discovers, or falls back.
---@param slot string
---@return table? result
---@return string? error_message
function M.resolve_active(slot)
	if not pinned_state_root then
		return nil, "verified_tools.setup must be called first"
	end
	slot = runtime_authority.normalize_active_slot(slot)
	if not slot then
		return nil, "active slot must be a safe lowercase name"
	end
	local opened, open_err = open_resolve_record(nil, "active-slots", "active slot pointer", hash(slot))
	if not opened then
		return nil, opened == false and "absent" or tostring(open_err)
	end
	local decoded_ok, decoded = pcall(vim.json.decode, opened.record.data)
	local pointer, pointer_err
	if decoded_ok then
		pointer, pointer_err = runtime_authority.normalize_active_pointer(slot, decoded)
	end
	if not pointer then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, pointer_err or "active slot pointer is not valid JSON"
	end
	local record, record_err = runtime_authority.active_record_matches(pointer)
	if not record then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, record_err
	end
	local commands, resolve_err = M.resolve(pointer.identity)
	if not commands then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, resolve_err
	end
	local rechecked, recheck_err = runtime_authority.active_record_matches(pointer)
	if not rechecked then
		close_resolve_directories(opened.records_fd, opened.root_fd)
		return nil, recheck_err
	end
	local finished, finish_err = finish_resolve_record(opened)
	if not finished then
		return nil, finish_err
	end
	return { identity = copy(pointer.identity), commands = copy(commands) }
end

---Atomically select one already-succeeded, live npm bundle for a logical slot.
---The previous pointer remains byte-for-byte intact on every validation or CAS
---failure, and immutable historical bundle roots are never pruned.
---@param slot string
---@param identity table
---@return table? pointer
---@return string? error_message
function M.activate(slot, identity)
	if not pinned_state_root then
		return nil, "verified_tools.setup must be called first"
	end
	local normalized_slot, slot_err = runtime_authority.normalize_active_slot(slot)
	local normalized_identity, identity_err = normalize_identity(identity)
	if not normalized_slot then
		return nil, slot_err
	end
	if not normalized_identity or normalized_identity.backend ~= "npm-release" then
		return nil, identity_err or "active identities must use the npm-release backend"
	end
	if normalized_slot ~= normalized_identity.name then
		return nil, "active slot must exactly match the npm-release identity name"
	end
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local initial, initial_err = decode_record(normalized_identity)
	if
		not initial
		or initial.status ~= "succeeded"
		or type(initial.plan) ~= "table"
		or type(initial.plan.resources) ~= "table"
	then
		return nil,
			"active identity is not succeeded: " .. tostring(initial_err or initial and initial.status or "invalid")
	end
	local resources = copy(initial.plan.resources)
	resources[#resources + 1] = "active-slot:" .. hash(normalized_slot)
	table.sort(resources)
	local holder = { locks = {} }
	local previous
	for _, resource in ipairs(resources) do
		if resource ~= previous then
			local lock, lock_err = acquire_lock(resource_lock_base(resource), resource)
			if not lock then
				local released, release_err = release_locks(holder)
				return nil, released and lock_err or release_err
			end
			holder.locks[#holder.locks + 1] = lock
			previous = resource
		end
	end
	local function finish(value, err)
		local released, release_err = release_locks(holder)
		if not released then
			return nil, release_err
		end
		return value, err
	end
	local record, record_err = decode_record(normalized_identity)
	if not record or record.status ~= "succeeded" or type(record.plan) ~= "table" or type(record.proof) ~= "table" then
		return finish(
			nil,
			"active identity is not succeeded: " .. tostring(record_err or record and record.status or "invalid")
		)
	end
	if record.plan.plan_digest ~= initial.plan.plan_digest then
		return finish(nil, "active identity changed before its resources were locked")
	end
	local commands, resolve_err = M.resolve(normalized_identity)
	if not commands then
		return finish(nil, resolve_err)
	end
	local stable, stable_err = decode_record(normalized_identity)
	if
		not stable
		or stable.status ~= "succeeded"
		or type(stable.plan) ~= "table"
		or type(stable.proof) ~= "table"
		or stable.plan.plan_digest ~= record.plan.plan_digest
		or not vim.deep_equal(stable.proof, record.proof)
	then
		return finish(nil, "active identity changed while it was validated: " .. tostring(stable_err or "drift"))
	end
	local proof_sha256, proof_err = runtime_authority.digest_data(stable.proof, "active proof")
	if not proof_sha256 then
		return finish(nil, proof_err)
	end
	local pointer = {
		schema = 1,
		kind = "verified-tool-active-slot",
		slot = normalized_slot,
		identity = copy(normalized_identity),
		identity_key = identity_key(normalized_identity),
		plan_digest = stable.plan.plan_digest,
		proof_sha256 = proof_sha256,
	}
	local encoded, encode_err = canonical_encode(pointer)
	if not encoded then
		return finish(nil, encode_err)
	end
	local persisted, persist_err = atomic_write(runtime_authority.active_pointer_path(normalized_slot), encoded .. "\n")
	if not persisted then
		return finish(nil, persist_err)
	end
	local released, release_err = release_locks(holder)
	if not released then
		-- The atomic pointer publication is already committed. Reporting failure
		-- here would invite a retry even though the requested identity is active.
		notify(
			"active slot was committed but lock release retained evidence: "
				.. bounded_reason(release_err, "lock release failed"),
			vim.log.levels.WARN
		)
	end
	return copy(pointer)
end

function M.status(identity)
	if identity == nil then
		return copy({
			configured = pinned_state_root ~= nil,
			jobs = M.jobs(),
		})
	end
	if not pinned_state_root then
		return nil, "verified_tools.setup must be called first"
	end
	local normalized, identity_err = normalize_identity_request(identity, "status")
	if not normalized then
		return nil, identity_err
	end
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	return decode_record(normalized)
end

---Enumerate durable tool records. Unlike status(), this explicitly performs I/O.
---@return table[]|nil
---@return string|nil
function M.records()
	if not pinned_state_root then
		return {}
	end
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local values, identities = {}, {}
	local directory = vim.fs.joinpath(root(), "records")
	local stat = uv.fs_lstat(directory)
	if not stat then
		return values
	end
	if stat.type ~= "directory" then
		return nil, "unsafe"
	end
	for name in vim.fs.dir(directory) do
		if not name:match("^[0-9a-f]+%.json$") then
			return nil, "unexpected record state " .. name
		end
		local path = vim.fs.joinpath(directory, name)
		local data, read_err = read_private(path)
		if not data then
			return nil, "unsafe record " .. name .. ": " .. tostring(read_err)
		end
		local ok, value = pcall(vim.json.decode, data)
		local normalized_identity = ok and type(value) == "table" and normalize_identity(value.identity) or nil
		if
			not normalized_identity
			or type(value.identity_key) ~= "string"
			or name ~= value.identity_key .. ".json"
			or (value.schema == RECORD_SCHEMA and value.identity_key ~= identity_key(normalized_identity))
		then
			return nil, "corrupt record " .. name
		end
		identities[identity_key(normalized_identity)] = normalized_identity
	end
	for _, normalized_identity in pairs(identities) do
		local record, record_err = decode_record(normalized_identity)
		if not record then
			return nil, "invalid record: " .. tostring(record_err)
		end
		values[#values + 1] = record
	end
	table.sort(values, function(left, right)
		return left.identity_key < right.identity_key
	end)
	return values
end

function M.claim(plan, options)
	if options == nil then
		options = {}
	end
	if
		type(options) ~= "table"
		or not exact_keys(options, { mode = true })
		or (options.mode ~= nil and options.mode ~= "auto" and options.mode ~= "retry" and options.mode ~= "repair")
	then
		return nil, "claim options must contain only mode=auto|retry|repair"
	end
	local normalized, err = normalize_supplied_plan(plan)
	if not normalized then
		return nil, err
	end
	if normalized.strategy == "external" then
		return nil, "external plans must be persisted with certify_external()"
	end
	if not network_allowed(normalized) then
		return nil, "blocked/offline", copy(vim.tbl_extend("force", normalized, { status = "blocked" }))
	end
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local identity_resource = "identity:" .. normalized.identity_key
	local claim_lock, lock_err = acquire_lock(resource_lock_base(identity_resource), identity_resource)
	if not claim_lock then
		return nil, lock_err
	end
	local function release_claim_lock()
		return release_lock(claim_lock)
	end
	local current, current_reason = decode_record(normalized.identity)
	local mode = options.mode or "auto"
	if current then
		if mode == "auto" then
			release_claim_lock()
			return nil, "consumed"
		end
		local allowed = mode == "repair"
				and vim.tbl_contains({ "succeeded", "failed", "drift", "cancelled", "repair-required" }, current.status)
			or mode == "retry" and current.status == "failed"
		if not allowed then
			release_claim_lock()
			return nil, "repair-required"
		end
	elseif current_reason ~= "absent" then
		release_claim_lock()
		return nil, current_reason
	end
	local attempt = current and (current.attempt or 0) + 1 or 1
	local record, persist_err = persist(normalized.identity, "claimed", {
		attempt = attempt,
		attempt_consumed = true,
		mode = mode,
		plan = normalized,
	})
	if not record then
		release_claim_lock()
		return nil, persist_err
	end
	local released, release_err = release_claim_lock()
	if not released then
		return nil, release_err
	end
	return { identity = copy(normalized.identity), plan = normalized, record = record, mode = mode }
end

local function expected_artifact_paths(plan)
	local result = {}
	for _, relative in pairs(plan.manifest.integrity.commands) do
		result[relative] = true
	end
	for _, relative in ipairs(plan.manifest.integrity.artifacts or {}) do
		result[relative] = true
	end
	return result
end

local function normalize_install_warnings(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or not vim.islist(value) or #value > 32 then
		return nil, "release install warnings are invalid"
	end
	local result = {}
	for _, warning in ipairs(value) do
		local normalized = bounded_reason(warning)
		if not normalized then
			return nil, "release install warnings are invalid"
		end
		result[#result + 1] = normalized
	end
	return result
end

local function normalize_install_evidence(plan, evidence)
	local integrity = plan.manifest.integrity
	if integrity.kind == "mason-local-integrity" then
		if evidence ~= nil then
			return nil, "Mason install evidence must be absent"
		end
		return true
	end
	if integrity.kind == "bundle-sha256" then
		if
			type(evidence) ~= "table"
			or not exact_keys(evidence, {
				kind = true,
				source_sha256 = true,
				receipt_sha256 = true,
				warnings = true,
			})
			or evidence.kind ~= "bundle-install-evidence"
			or evidence.source_sha256 ~= integrity.source_sha256
			or not valid_sha256(evidence.receipt_sha256)
		then
			return nil, "bundle install evidence is missing or invalid"
		end
		local warnings, warnings_err = normalize_install_warnings(evidence.warnings)
		if not warnings then
			return nil, warnings_err
		end
		return {
			kind = "bundle-install-evidence",
			source_sha256 = evidence.source_sha256,
			receipt_sha256 = evidence.receipt_sha256,
			warnings = warnings,
		}
	end
	if integrity.kind ~= "release-sha256" then
		return nil, "install evidence integrity kind is unsupported"
	end
	if
		type(evidence) ~= "table"
		or not exact_keys(evidence, { kind = true, archive_sha256 = true, artifacts = true, warnings = true })
		or evidence.kind ~= "release-install-evidence"
		or evidence.archive_sha256 ~= plan.manifest.integrity.archive_sha256
		or type(evidence.artifacts) ~= "table"
	then
		return nil, "release install evidence is missing or invalid"
	end
	local warnings, warnings_err = normalize_install_warnings(evidence.warnings)
	if not warnings then
		return nil, warnings_err
	end
	local expected = expected_artifact_paths(plan)
	if #sorted_keys(evidence.artifacts) ~= #sorted_keys(expected) then
		return nil, "release install evidence artifact set is not exact"
	end
	local normalized = {}
	for relative in pairs(expected) do
		local digest = evidence.artifacts[relative]
		if not valid_sha256(digest) then
			return nil, "release install evidence lacks digest for " .. relative
		end
		normalized[relative] = digest
	end
	for relative in pairs(evidence.artifacts) do
		if not expected[relative] then
			return nil, "release install evidence contains unknown artifact " .. tostring(relative)
		end
	end
	return {
		kind = "release-install-evidence",
		archive_sha256 = evidence.archive_sha256,
		artifacts = normalized,
		warnings = warnings,
	}
end

local function exact_observed_paths(observed, expected, label)
	if type(observed) ~= "table" or #sorted_keys(observed) ~= #sorted_keys(expected) then
		return nil, label .. " set is not exact"
	end
	local result = {}
	for key, relative in pairs(expected) do
		local path = observed[key]
		local expected_path = vim.fs.normalize(vim.fs.joinpath(relative.root, relative.path))
		if type(path) ~= "string" or path ~= expected_path then
			return nil, label .. " path is not exact for " .. tostring(key)
		end
		local fingerprint, err = fingerprint_file(path, relative.executable == true)
		if not fingerprint or not contained(fingerprint.path, vim.fs.normalize(relative.root)) then
			return nil, label .. " path is unsafe for " .. tostring(key) .. ": " .. tostring(err)
		end
		result[key] = fingerprint
	end
	for key in pairs(observed) do
		if expected[key] == nil then
			return nil, label .. " contains unknown key " .. tostring(key)
		end
	end
	return result
end

local function normalize_attestation(job, observed, install_evidence)
	local guard_ok, guard_err = validate_destination_guard(job.plan.destination_guard, true)
	if not guard_ok then
		return nil, guard_err
	end
	local integrity = job.plan.manifest.integrity
	local evidence, evidence_err = normalize_install_evidence(job.plan, install_evidence)
	if not evidence then
		return nil, evidence_err
	end
	local command_expected = {}
	for command, relative in pairs(integrity.commands) do
		command_expected[command] = { root = job.identity.install_root, path = relative, executable = true }
	end
	if integrity.kind == "release-sha256" then
		if
			type(observed) ~= "table"
			or not exact_keys(observed, {
				kind = true,
				archive_sha256 = true,
				commands = true,
				artifacts = true,
			})
			or observed.kind ~= "release-sha256"
			or observed.archive_sha256 ~= integrity.archive_sha256
			or type(observed.artifacts) ~= "table"
		then
			return nil, "release attestation observation is invalid"
		end
		local commands, command_err = exact_observed_paths(observed.commands, command_expected, "release commands")
		if not commands then
			return nil, command_err
		end
		local artifact_expected = {}
		for _, relative in ipairs(integrity.artifacts) do
			artifact_expected[relative] = { root = job.identity.install_root, path = relative, executable = false }
		end
		local artifacts, artifact_err = exact_observed_paths(observed.artifacts, artifact_expected, "release artifacts")
		if not artifacts then
			return nil, artifact_err
		end
		for command, fingerprint in pairs(commands) do
			local relative = integrity.commands[command]
			if fingerprint.sha256 ~= evidence.artifacts[relative] then
				return nil, "release command digest differs from install evidence"
			end
		end
		for relative, fingerprint in pairs(artifacts) do
			if fingerprint.sha256 ~= evidence.artifacts[relative] then
				return nil, "release artifact digest differs from install evidence"
			end
		end
		return {
			version = 1,
			kind = "release-sha256",
			archive_sha256 = integrity.archive_sha256,
			commands = commands,
			artifacts = artifacts,
		}
	end
	if integrity.kind == "bundle-sha256" then
		if
			type(observed) ~= "table"
			or not exact_keys(observed, {
				kind = true,
				source_sha256 = true,
				bundle_root = true,
				receipt_path = true,
				commands = true,
			})
			or observed.kind ~= "bundle-sha256"
			or observed.source_sha256 ~= integrity.source_sha256
			or observed.bundle_root ~= job.identity.install_root
			or observed.receipt_path ~= integrity.receipt_path
		then
			return nil, "bundle attestation observation is invalid"
		end
		local commands, command_err = exact_observed_paths(observed.commands, command_expected, "bundle commands")
		if not commands then
			return nil, command_err
		end
		local validated, receipt_err = runtime_authority.validate_bundle_receipt(job.plan, evidence.receipt_sha256)
		if not validated then
			return nil, receipt_err
		end
		return {
			version = 1,
			kind = "bundle-sha256",
			source_sha256 = integrity.source_sha256,
			closure_sha256 = validated.closure.sha256,
			receipt = { path = integrity.receipt_path, fingerprint = validated.fingerprint },
			commands = commands,
		}
	end
	if
		type(observed) ~= "table"
		or not exact_keys(observed, { kind = true, receipt_path = true, commands = true })
		or observed.kind ~= "mason-local-integrity"
	then
		return nil, "Mason attestation observation is invalid"
	end
	local expected_receipt = vim.fs.normalize(vim.fs.joinpath(job.identity.install_root, integrity.receipt_path))
	if type(observed.receipt_path) ~= "string" or observed.receipt_path ~= expected_receipt then
		return nil, "Mason receipt path is not exact"
	end
	local receipt_data, receipt_err = read_private(expected_receipt)
	if not receipt_data then
		return nil, "Mason receipt is unsafe: " .. tostring(receipt_err)
	end
	local decoded_ok, receipt = pcall(vim.json.decode, receipt_data)
	if
		not decoded_ok
		or not exact_keys(receipt, { package = true, version = true, source_version = true })
		or not vim.deep_equal(receipt, integrity.receipt)
	then
		return nil, "Mason on-disk receipt is invalid"
	end
	local receipt_fingerprint, fingerprint_err = fingerprint_file(expected_receipt, false)
	if not receipt_fingerprint then
		return nil, fingerprint_err
	end
	local commands, command_err = exact_observed_paths(observed.commands, command_expected, "Mason commands")
	if not commands then
		return nil, command_err
	end
	return {
		version = 1,
		kind = "mason-local-integrity",
		receipt = {
			path = expected_receipt,
			package = receipt.package,
			version = receipt.version,
			source_version = receipt.source_version,
			fingerprint = receipt_fingerprint,
		},
		commands = commands,
	}
end

valid_fingerprint_shape = function(fingerprint, install_root)
	if
		type(fingerprint) ~= "table"
		or not exact_keys(fingerprint, {
			path = true,
			dev = true,
			ino = true,
			size = true,
			mode = true,
			uid = true,
			gid = true,
			mtime_sec = true,
			mtime_nsec = true,
			ctime_sec = true,
			ctime_nsec = true,
			sha256 = true,
		})
		or type(fingerprint.path) ~= "string"
		or fingerprint.path:sub(1, 1) ~= "/"
		or vim.fs.normalize(fingerprint.path) ~= fingerprint.path
		or not contained(fingerprint.path, install_root)
		or type(fingerprint.dev) ~= "number"
		or fingerprint.dev < 0
		or fingerprint.dev % 1 ~= 0
		or type(fingerprint.ino) ~= "number"
		or fingerprint.ino < 0
		or fingerprint.ino % 1 ~= 0
		or type(fingerprint.size) ~= "number"
		or fingerprint.size < 0
		or fingerprint.size % 1 ~= 0
		or fingerprint.size > MAX_EXECUTABLE_BYTES
		or type(fingerprint.mode) ~= "number"
		or fingerprint.mode < 0
		or fingerprint.mode % 1 ~= 0
		or bit.band(fingerprint.mode, UNSAFE_WRITE_MASK) ~= 0
		or type(fingerprint.uid) ~= "number"
		or fingerprint.uid < 0
		or fingerprint.uid % 1 ~= 0
		or type(fingerprint.gid) ~= "number"
		or fingerprint.gid < 0
		or fingerprint.gid % 1 ~= 0
		or type(fingerprint.mtime_sec) ~= "number"
		or fingerprint.mtime_sec % 1 ~= 0
		or type(fingerprint.mtime_nsec) ~= "number"
		or fingerprint.mtime_nsec % 1 ~= 0
		or type(fingerprint.ctime_sec) ~= "number"
		or fingerprint.ctime_sec % 1 ~= 0
		or type(fingerprint.ctime_nsec) ~= "number"
		or fingerprint.ctime_nsec % 1 ~= 0
		or not valid_sha256(fingerprint.sha256)
	then
		return false
	end
	return true
end

valid_stored_proof = function(plan, proof, identity)
	if type(plan) ~= "table" or type(proof) ~= "table" or type(plan.identity) ~= "table" then
		return false
	end
	local normalized = normalize_supplied_plan(plan, { installed = true })
	if not normalized then
		return false
	end
	plan = normalized
	local digest = plan_digest(plan)
	if identity_json(plan.identity) ~= identity_json(identity) or proof.version ~= 1 or digest ~= plan.plan_digest then
		return false
	end
	local integrity = type(plan.manifest) == "table" and plan.manifest.integrity or nil
	if type(integrity) ~= "table" or proof.kind ~= integrity.kind or type(proof.commands) ~= "table" then
		return false
	end
	if #sorted_keys(proof.commands) ~= #sorted_keys(plan.executables or {}) then
		return false
	end
	for command in pairs(plan.executables or {}) do
		local fingerprint = proof.commands[command]
		local expected = vim.fs.joinpath(identity.install_root, integrity.commands[command])
		local canonical = uv.fs_realpath(expected)
		if
			not valid_fingerprint_shape(fingerprint, identity.install_root)
			or not canonical
			or fingerprint.path ~= vim.fs.normalize(canonical)
		then
			return false
		end
	end
	for command in pairs(proof.commands) do
		if not plan.executables[command] then
			return false
		end
	end
	if proof.kind == "release-sha256" then
		if
			not exact_keys(proof, {
				version = true,
				kind = true,
				archive_sha256 = true,
				commands = true,
				artifacts = true,
			})
			or proof.archive_sha256 ~= integrity.archive_sha256
			or type(proof.artifacts) ~= "table"
			or #sorted_keys(proof.artifacts) ~= #(integrity.artifacts or {})
		then
			return false
		end
		local expected = {}
		for _, relative in ipairs(integrity.artifacts or {}) do
			expected[relative] = true
			local canonical = uv.fs_realpath(vim.fs.joinpath(identity.install_root, relative))
			if
				not valid_fingerprint_shape(proof.artifacts[relative], identity.install_root)
				or not canonical
				or proof.artifacts[relative].path ~= vim.fs.normalize(canonical)
			then
				return false
			end
		end
		for relative in pairs(proof.artifacts) do
			if not expected[relative] then
				return false
			end
		end
		return true
	end
	if proof.kind == "bundle-sha256" then
		if
			not exact_keys(proof, {
				version = true,
				kind = true,
				source_sha256 = true,
				closure_sha256 = true,
				receipt = true,
				commands = true,
			})
			or proof.source_sha256 ~= integrity.source_sha256
			or not valid_sha256(proof.closure_sha256)
			or type(proof.receipt) ~= "table"
			or not exact_keys(proof.receipt, { path = true, fingerprint = true })
			or proof.receipt.path ~= integrity.receipt_path
			or not valid_fingerprint_shape(proof.receipt.fingerprint, vim.fs.dirname(integrity.receipt_path))
			or proof.receipt.fingerprint.path ~= integrity.receipt_path
		then
			return false
		end
		return true
	end
	if
		proof.kind ~= "mason-local-integrity"
		or not exact_keys(proof, { version = true, kind = true, receipt = true, commands = true })
		or type(proof.receipt) ~= "table"
		or not exact_keys(proof.receipt, {
			path = true,
			package = true,
			version = true,
			source_version = true,
			fingerprint = true,
		})
		or proof.receipt.path ~= vim.fs.normalize(vim.fs.joinpath(identity.install_root, integrity.receipt_path))
		or proof.receipt.package ~= integrity.receipt.package
		or proof.receipt.version ~= integrity.receipt.version
		or proof.receipt.source_version ~= integrity.receipt.source_version
		or not valid_fingerprint_shape(proof.receipt.fingerprint, identity.install_root)
		or proof.receipt.fingerprint.path ~= proof.receipt.path
	then
		return false
	end
	return true
end

local function read_shim_owner(command, path)
	local data, err, stat = read_private(shim_owner_path(command))
	if not data then
		return nil, err
	end
	local ok, owner = pcall(vim.json.decode, data)
	if
		not ok
		or type(owner) ~= "table"
		or not exact_keys(owner, {
			schema = true,
			command = true,
			shim_path = true,
			backend = true,
			name = true,
			version = true,
			target = true,
			digest = true,
			identity_key = true,
			target_path = true,
			target_sha256 = true,
			updated_at = true,
		})
		or owner.schema ~= 2
		or owner.command ~= command
		or owner.shim_path ~= path
		or type(owner.backend) ~= "string"
		or type(owner.name) ~= "string"
		or type(owner.version) ~= "string"
		or type(owner.target) ~= "string"
		or type(owner.digest) ~= "string"
		or type(owner.identity_key) ~= "string"
		or type(owner.target_path) ~= "string"
		or owner.target_path:sub(1, 1) ~= "/"
		or vim.fs.normalize(owner.target_path) ~= owner.target_path
		or not valid_sha256(owner.target_sha256)
		or not finite_number(owner.updated_at)
	then
		return nil, "corrupt"
	end
	return owner, nil, stat
end

run_interleave = function(stage, context)
	if type(configured.interleave) ~= "function" then
		return true
	end
	local ok, err = pcall(configured.interleave, stage, copy(context or {}))
	if not ok then
		return nil, "interleave-crashed: " .. tostring(err)
	end
	return true
end

local function restore_quarantined(handle)
	local parent_ok, parent_err = validate_state_parent(handle.path)
	if not parent_ok then
		return nil, parent_err
	end
	local quarantine_guard = state_directory_guards[handle.quarantine_dir]
	local quarantine_ok, quarantine_err =
		quarantine_guard and validate_directory_guard(handle.quarantine_dir, quarantine_guard) or nil,
		"quarantine directory is not pinned"
	if not quarantine_ok then
		return nil, quarantine_err
	end
	if uv.fs_lstat(handle.path) then
		return nil, "restore-target-exists"
	end
	local moved = uv.fs_lstat(handle.quarantine_path)
	if not moved or not same_file(moved, handle.stat) then
		return nil, "quarantine-identity-changed"
	end
	local linked, link_err = uv.fs_link(handle.quarantine_path, handle.path)
	if not linked then
		return nil, "restore-link-failed: " .. tostring(link_err)
	end
	local restored = uv.fs_lstat(handle.path)
	local retained = uv.fs_lstat(handle.quarantine_path)
	if
		not restored
		or not retained
		or not same_file(restored, handle.stat)
		or not same_file(retained, handle.stat)
		or restored.nlink ~= 2
		or retained.nlink ~= 2
	then
		return nil, "restore-link-identity-changed"
	end
	local removed, remove_err = uv.fs_unlink(handle.quarantine_path)
	if not removed then
		return nil, "restore-cleanup-failed: " .. tostring(remove_err)
	end
	local final = uv.fs_lstat(handle.path)
	if not final or not same_file(final, handle.stat) or final.nlink ~= 1 then
		return nil, "restore-final-identity-changed"
	end
	local removed_directory, directory_err = uv.fs_rmdir(handle.quarantine_dir)
	if removed_directory then
		state_directory_guards[handle.quarantine_dir] = nil
		return true
	end
	return nil, tostring(directory_err)
end

local function quarantine_exact(path, expected, label)
	local parent_ok, parent_err = validate_state_parent(path)
	if not parent_ok then
		return nil, parent_err
	end
	local parent, basename = vim.fs.dirname(path), vim.fs.basename(path)
	local prefix = basename .. ".quarantine."
	local scan_ok, remnant = pcall(function()
		for name in vim.fs.dir(parent) do
			if name:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end)
	if not scan_ok then
		return nil, label .. "-quarantine-scan-failed"
	end
	if remnant then
		return nil, label .. "-quarantine-remnant"
	end
	local directory, directory_err = uv.fs_mkdtemp(path .. ".quarantine.XXXXXX")
	if not directory then
		return nil, label .. "-quarantine-failed: " .. tostring(directory_err)
	end
	local directory_secured = uv.fs_chmod(directory, tonumber("700", 8))
	local directory_stat = directory_secured and uv.fs_lstat(directory) or nil
	if not directory_stat or directory_stat.type ~= "directory" then
		return nil, label .. "-quarantine-unsafe"
	end
	state_directory_guards[directory] = { dev = directory_stat.dev, ino = directory_stat.ino }
	local quarantine_path = vim.fs.joinpath(directory, "entry")
	local hook_ok, hook_err = run_interleave("before-quarantine", { path = path, label = label })
	if not hook_ok then
		uv.fs_rmdir(directory)
		state_directory_guards[directory] = nil
		return nil, hook_err
	end
	local moved, move_err = uv.fs_rename(path, quarantine_path)
	if not moved then
		uv.fs_rmdir(directory)
		state_directory_guards[directory] = nil
		return nil, label .. "-quarantine-move-failed: " .. tostring(move_err)
	end
	local observed = uv.fs_lstat(quarantine_path)
	local handle = {
		path = path,
		quarantine_dir = directory,
		quarantine_path = quarantine_path,
		stat = observed or expected,
	}
	if not observed or not same_file(observed, expected) or observed.type ~= expected.type or observed.nlink ~= 1 then
		local restored, restore_err = restore_quarantined(handle)
		return nil, label .. "-identity-changed" .. (restored and "" or ": restore failed: " .. tostring(restore_err))
	end
	return handle
end

local function discard_quarantined(handle)
	local quarantine_guard = state_directory_guards[handle.quarantine_dir]
	local quarantine_ok, quarantine_err =
		quarantine_guard and validate_directory_guard(handle.quarantine_dir, quarantine_guard) or nil,
		"quarantine directory is not pinned"
	if not quarantine_ok then
		return nil, quarantine_err
	end
	local current = uv.fs_lstat(handle.quarantine_path)
	if not current or not same_file(current, handle.stat) then
		return nil, "quarantine-identity-changed"
	end
	local removed, remove_err = uv.fs_unlink(handle.quarantine_path)
	if not removed then
		return nil, tostring(remove_err)
	end
	local removed_directory, directory_err = uv.fs_rmdir(handle.quarantine_dir)
	if removed_directory then
		state_directory_guards[handle.quarantine_dir] = nil
		return true
	end
	return nil, tostring(directory_err)
end

local function write_exclusive_private(path, data)
	if type(data) ~= "string" or #data > MAX_PRIVATE_BYTES then
		return nil, "private state exceeds 256 KiB"
	end
	local parent_ok, parent_err = validate_state_parent(path)
	if not parent_ok then
		return nil, parent_err
	end
	local fd, open_err = uv.fs_open(path, "wx", tonumber("600", 8))
	if not fd then
		return nil, "exclusive-create-failed: " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	local secured = uv.fs_fchmod(fd, tonumber("600", 8))
	local wrote, write_err = secured and write_all(fd, data) or nil
	local synced = wrote and uv.fs_fsync(fd)
	local after = synced and uv.fs_fstat(fd) or nil
	local closed = uv.fs_close(fd)
	local final = uv.fs_lstat(path)
	if
		not wrote
		or not synced
		or not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or not after
		or not closed
		or not final
		or not same_private_stat(after, final)
		or final.nlink ~= 1
		or final.mode % 512 ~= tonumber("600", 8)
	then
		local cleanup_error
		if final and opened and same_file(final, opened) then
			local handle, quarantine_err = quarantine_exact(path, final, "exclusive-private")
			if handle then
				local discarded, discard_err = discard_quarantined(handle)
				cleanup_error = not discarded and discard_err or nil
			else
				cleanup_error = quarantine_err
			end
		end
		return nil,
			"exclusive-private-write-failed: "
				.. tostring(write_err or "unsafe final file")
				.. (cleanup_error and "; cleanup failed: " .. tostring(cleanup_error) or "")
	end
	return final
end

local function quarantine_remnant(path, label)
	local parent_ok, parent_err = validate_state_parent(path)
	if not parent_ok then
		return nil, parent_err
	end
	local parent = vim.fs.dirname(path)
	local prefix = vim.fs.basename(path) .. ".quarantine."
	local scan_ok, remnant = pcall(function()
		for name in vim.fs.dir(parent) do
			if name:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end)
	if not scan_ok then
		return nil, label .. "-quarantine-scan-failed"
	end
	if remnant then
		return nil, label .. "-quarantine-remnant"
	end
	return false
end

local function shim_owner_record(job, command, fingerprint)
	local updated_at = now()
	if not finite_number(updated_at) then
		return nil, "shim owner clock is invalid"
	end
	return {
		schema = 2,
		command = command,
		shim_path = job.plan.shims[command],
		backend = job.identity.backend,
		name = job.identity.name,
		version = job.identity.version,
		target = job.identity.target,
		digest = job.identity.digest,
		identity_key = identity_key(job.identity),
		target_path = fingerprint.path,
		target_sha256 = fingerprint.sha256,
		updated_at = updated_at,
	}
end

local function validate_proof_targets(job, proof)
	for _, command in ipairs(sorted_keys(job.plan.executables)) do
		local expected = proof.commands[command]
		local current, err = validate_fingerprint_metadata(expected, true)
		if not current or current ~= expected.path then
			return nil, "attested executable changed before promotion: " .. command .. ": " .. tostring(err)
		end
	end
	return true
end

local function rollback_shim_transaction(transaction)
	local first_error
	for index = #(transaction.new_entries or {}), 1, -1 do
		local entry = transaction.new_entries[index]
		local current = uv.fs_lstat(entry.path)
		if current and same_file(current, entry.stat) then
			local handle, err = quarantine_exact(entry.path, current, "rollback-new")
			if handle then
				local discarded, discard_err = discard_quarantined(handle)
				first_error = first_error or (not discarded and discard_err or nil)
			else
				first_error = first_error or err
			end
		elseif current then
			first_error = first_error or "rollback-new-identity-changed"
		end
	end
	for index = #(transaction.old_entries or {}), 1, -1 do
		local restored, err = restore_quarantined(transaction.old_entries[index])
		first_error = first_error or (not restored and err or nil)
	end
	transaction.closed = true
	return first_error == nil, first_error
end

local function rollback_or_reason(transaction, reason)
	local rolled_back, rollback_err = rollback_shim_transaction(transaction)
	if not rolled_back then
		return nil, tostring(reason) .. "; shim rollback failed: " .. tostring(rollback_err), true
	end
	return nil, reason, false
end

local function commit_shim_transaction(transaction)
	local first_error
	for _, handle in ipairs(transaction.old_entries or {}) do
		local discarded, err = discard_quarantined(handle)
		first_error = first_error or (not discarded and err or nil)
	end
	transaction.closed = true
	return first_error == nil, first_error
end

local function prepare_shim_entry(job, command)
	local path = job.plan.shims[command]
	local owner_path = shim_owner_path(command)
	local shim_remnant, shim_remnant_err = quarantine_remnant(path, "shim")
	if shim_remnant == nil then
		return nil, shim_remnant_err, true
	end
	local owner_remnant, owner_remnant_err = quarantine_remnant(owner_path, "shim-owner")
	if owner_remnant == nil then
		return nil, owner_remnant_err, true
	end
	local owner, owner_err, owner_stat = read_shim_owner(command, path)
	local shim_stat = uv.fs_lstat(path)
	if not owner and owner_err ~= "absent" then
		return nil, "shim-owner-" .. tostring(owner_err)
	end
	if owner and (owner.backend ~= job.identity.backend or owner.name ~= job.identity.name) then
		return nil, "shim-owned-by-different-tool"
	end
	if shim_stat and (shim_stat.type ~= "link" or shim_stat.nlink ~= 1) then
		return nil, "shim-target-unsafe"
	end
	if (shim_stat == nil) ~= (owner == nil) then
		return nil, owner and "shim-owner-without-shim" or "shim-has-no-owner"
	end
	if not shim_stat then
		shim_remnant, shim_remnant_err = quarantine_remnant(path, "shim")
		owner_remnant, owner_remnant_err = quarantine_remnant(owner_path, "shim-owner")
		if shim_remnant == nil then
			return nil, shim_remnant_err, true
		end
		if owner_remnant == nil then
			return nil, owner_remnant_err, true
		end
	end
	if owner then
		local target = uv.fs_realpath(path)
		local fingerprint = target and fingerprint_file(target, true) or nil
		if target ~= owner.target_path or not fingerprint or fingerprint.sha256 ~= owner.target_sha256 then
			return nil, "owned-shim-target-drift"
		end
	end
	return {
		command = command,
		shim_path = path,
		shim_stat = shim_stat,
		owner_path = owner_path,
		owner_stat = owner_stat,
	}
end

local function promote_shims(job, proof)
	local valid, valid_err = validate_proof_targets(job, proof)
	if not valid then
		return nil, valid_err
	end
	local transaction = { old_entries = {}, new_entries = {} }
	local entries = {}
	for _, command in ipairs(sorted_keys(job.plan.shims)) do
		local entry, err, repair_required = prepare_shim_entry(job, command)
		if not entry then
			return nil, err, repair_required
		end
		entries[#entries + 1] = entry
	end
	for _, entry in ipairs(entries) do
		if entry.shim_stat then
			local old_shim, shim_err = quarantine_exact(entry.shim_path, entry.shim_stat, "shim")
			if not old_shim then
				return rollback_or_reason(transaction, shim_err)
			end
			transaction.old_entries[#transaction.old_entries + 1] = old_shim
			local old_owner, owner_err = quarantine_exact(entry.owner_path, entry.owner_stat, "shim-owner")
			if not old_owner then
				return rollback_or_reason(transaction, owner_err)
			end
			transaction.old_entries[#transaction.old_entries + 1] = old_owner
		end
	end
	for _, entry in ipairs(entries) do
		local fingerprint = proof.commands[entry.command]
		local parent_ok, parent_err = validate_state_parent(entry.shim_path)
		if not parent_ok then
			return rollback_or_reason(transaction, parent_err)
		end
		local linked, link_err = uv.fs_symlink(fingerprint.path, entry.shim_path)
		local linked_stat = linked and uv.fs_lstat(entry.shim_path) or nil
		if
			not linked
			or not linked_stat
			or linked_stat.type ~= "link"
			or linked_stat.nlink ~= 1
			or uv.fs_realpath(entry.shim_path) ~= fingerprint.path
		then
			return rollback_or_reason(
				transaction,
				"shim-promote-failed: " .. tostring(link_err or "invalid promoted link")
			)
		end
		transaction.new_entries[#transaction.new_entries + 1] = { path = entry.shim_path, stat = linked_stat }
	end
	valid, valid_err = validate_proof_targets(job, proof)
	if not valid then
		return rollback_or_reason(transaction, valid_err)
	end
	for _, entry in ipairs(entries) do
		local owner_record, owner_record_err = shim_owner_record(job, entry.command, proof.commands[entry.command])
		if not owner_record then
			return rollback_or_reason(transaction, owner_record_err)
		end
		local owner_ok, owner_json = pcall(vim.json.encode, owner_record)
		if not owner_ok then
			return rollback_or_reason(transaction, "shim owner record is not encodable")
		end
		local data = owner_json .. "\n"
		local owner_stat, owner_err = write_exclusive_private(entry.owner_path, data)
		if not owner_stat then
			return rollback_or_reason(transaction, "shim-owner-promote-failed: " .. tostring(owner_err))
		end
		transaction.new_entries[#transaction.new_entries + 1] = { path = entry.owner_path, stat = owner_stat }
	end
	return transaction
end

local function remove_owned_shims(job, fail_closed)
	local transaction = { old_entries = {}, new_entries = {} }
	local function abort(reason, repair_required)
		if fail_closed then
			return nil, reason, true, transaction
		end
		local _, rollback_reason, rollback_repair = rollback_or_reason(transaction, reason)
		return nil, rollback_reason, repair_required or rollback_repair
	end
	for _, command in ipairs(sorted_keys(job.plan.shims)) do
		local path = job.plan.shims[command]
		local owner_path = shim_owner_path(command)
		local shim_remnant, shim_remnant_err = quarantine_remnant(path, "owned-shim")
		if shim_remnant == nil then
			return abort(shim_remnant_err, true)
		end
		local owner_remnant, owner_remnant_err = quarantine_remnant(owner_path, "owned-shim-owner")
		if owner_remnant == nil then
			return abort(owner_remnant_err, true)
		end
		local owner, owner_err, owner_stat = read_shim_owner(command, path)
		local shim_stat = uv.fs_lstat(path)
		if not owner and owner_err ~= "absent" then
			return abort("shim-owner-" .. tostring(owner_err), true)
		end
		if owner and (owner.backend ~= job.identity.backend or owner.name ~= job.identity.name) then
			if fail_closed then
				return abort("shim-owned-by-different-tool", true)
			end
			-- Different logical owners are outside a final cleanup operation.
		elseif owner then
			if not shim_stat or shim_stat.type ~= "link" or shim_stat.nlink ~= 1 then
				return abort("owned-shim-unsafe", true)
			end
			local old_shim, shim_err = quarantine_exact(path, shim_stat, "owned-shim")
			if not old_shim then
				return abort(shim_err, true)
			end
			transaction.old_entries[#transaction.old_entries + 1] = old_shim
			local old_owner, move_err = quarantine_exact(owner_path, owner_stat, "owned-shim-owner")
			if not old_owner then
				return abort(move_err, true)
			end
			transaction.old_entries[#transaction.old_entries + 1] = old_owner
		elseif shim_stat then
			return abort("unowned-shim-present", true)
		else
			shim_remnant, shim_remnant_err = quarantine_remnant(path, "owned-shim")
			owner_remnant, owner_remnant_err = quarantine_remnant(owner_path, "owned-shim-owner")
			if shim_remnant == nil then
				return abort(shim_remnant_err, true)
			end
			if owner_remnant == nil then
				return abort(owner_remnant_err, true)
			end
		end
	end
	return transaction
end

local function settle(job, ok, reason, attestation)
	if job.settled or job.settling then
		return
	end
	job.settling = true
	if job.cancel_requested then
		ok = false
		reason = job.cancel_reason
		attestation = nil
	end
	local status = ok and "succeeded" or reason == "cancelled" and "cancelled" or job.failure_status or "failed"
	local transaction, shim_err, shim_repair_required
	if ok then
		transaction, shim_err, shim_repair_required = promote_shims(job, attestation)
		if not transaction then
			ok = false
			reason = shim_err
			status = job.failure_status or "failed"
			local cleanup, cleanup_err, cleanup_repair_required = remove_owned_shims(job)
			shim_repair_required = shim_repair_required or cleanup_repair_required
			shim_err = shim_err .. (cleanup_err and "; cleanup failed: " .. tostring(cleanup_err) or "")
			transaction = cleanup
		end
	else
		transaction, shim_err, shim_repair_required = remove_owned_shims(job)
	end
	if not transaction or shim_repair_required then
		status, reason, ok = "repair-required", shim_err or reason, false
	end
	local proof = ok and copy(attestation) or copy(job.baseline)
	local persisted, persist_err = persist(job.identity, status, {
		attempt = job.claim.record.attempt,
		attempt_consumed = true,
		detail = reason,
		proof = proof,
		plan = job.plan,
	})
	if not persisted then
		local rolled_back, rollback_err = true, nil
		if transaction then
			rolled_back, rollback_err = rollback_shim_transaction(transaction)
		end
		local repair_reason = "status-persist-failed: " .. tostring(persist_err)
		if rollback_err then
			repair_reason = repair_reason .. "; " .. rollback_err
		end
		local repair, repair_err = persist(job.identity, "repair-required", {
			attempt = job.claim.record.attempt,
			attempt_consumed = true,
			detail = repair_reason,
			proof = copy(job.baseline),
			plan = job.plan,
		})
		if not repair then
			job.settled = true
			job.settling = false
			job.persistence_blocked = true
			job.persistence_error = repair_reason .. "; repair-persist-failed: " .. tostring(repair_err)
			notify(job.persistence_error, vim.log.levels.ERROR)
			return
		end
		persisted = repair
		status, ok, reason = "repair-required", false, repair_reason
		transaction = nil
	elseif transaction then
		local committed, commit_err = commit_shim_transaction(transaction)
		if not committed then
			local repair_reason = "shim-transaction-cleanup-failed: " .. tostring(commit_err)
			local repair, repair_err = persist(job.identity, "repair-required", {
				attempt = job.claim.record.attempt,
				attempt_consumed = true,
				detail = repair_reason,
				proof = proof,
				plan = job.plan,
			})
			if not repair then
				job.settled = true
				job.settling = false
				job.persistence_blocked = true
				job.persistence_error = repair_reason .. "; repair-persist-failed: " .. tostring(repair_err)
				notify(job.persistence_error, vim.log.levels.ERROR)
				return
			end
			persisted = repair
			status, ok, reason = "repair-required", false, repair_reason
		end
	end
	local released, release_err = release_locks(job)
	if not released then
		job.settled = true
		job.settling = false
		job.persistence_blocked = true
		job.persistence_error = "lock-release-failed: " .. tostring(release_err)
		notify(job.persistence_error, vim.log.levels.ERROR)
		return
	end
	if running[job.key] == job then
		running[job.key] = nil
		running_count = math.max(0, running_count - 1)
	end
	job.settled = true
	job.settling = false
	if type(job.callback) == "function" then
		pcall(job.callback, ok, reason, ok and copy(attestation) or nil)
	end
	emit("finished", { identity = job.identity, ok = ok, reason = reason, status = status })
	M._drain()
end

local function install_evidence_from_baseline(plan, baseline)
	if type(baseline) ~= "table" then
		return nil
	end
	if baseline.kind == "bundle-sha256" and plan.manifest.integrity.kind == "bundle-sha256" then
		return {
			kind = "bundle-install-evidence",
			source_sha256 = baseline.source_sha256,
			receipt_sha256 = baseline.receipt and baseline.receipt.fingerprint.sha256 or nil,
			warnings = {},
		}
	end
	if baseline.kind ~= "release-sha256" or plan.manifest.integrity.kind ~= "release-sha256" then
		return nil
	end
	local artifacts = {}
	for command, fingerprint in pairs(baseline.commands or {}) do
		artifacts[plan.manifest.integrity.commands[command]] = fingerprint.sha256
	end
	for relative, fingerprint in pairs(baseline.artifacts or {}) do
		artifacts[relative] = fingerprint.sha256
	end
	return {
		kind = "release-install-evidence",
		archive_sha256 = baseline.archive_sha256,
		artifacts = artifacts,
	}
end

local function attest_job(job, callback)
	local backend = backend_for(job.identity)
	if not backend or type(backend.attest) ~= "function" then
		callback(false, "attester-unavailable")
		return
	end
	local called = false
	local function done(ok, value)
		if vim.in_fast_event() then
			schedule_on_main(done, ok, value)
			return
		end
		if called then
			return
		end
		called = true
		if ok ~= true then
			callback(false, bounded_reason(value, "attestation-failed"))
			return
		end
		local evidence = job.install_evidence
		if job.baseline and job.plan.manifest.integrity.kind ~= "mason-local-integrity" then
			evidence = install_evidence_from_baseline(job.plan, job.baseline)
		end
		local normalize_call_ok, normalized, normalize_err = pcall(normalize_attestation, job, value, evidence)
		if not normalize_call_ok then
			callback(false, "attestation-validation-crashed")
			return
		end
		if normalized and job.baseline and not vim.deep_equal(normalized, job.baseline) then
			callback(false, "proof-drift")
			return
		end
		callback(normalized ~= nil, normalized or normalize_err)
	end
	local ok, result, reason = pcall(backend.attest, copy(job.plan), done, copy(job.install_evidence), {
		legacy_import = job.legacy_import == true,
		local_mason_adoption = job.local_mason_adoption == true,
	})
	if not ok then
		done(false, "attest-crashed")
	elseif type(result) == "boolean" then
		done(result, reason)
	end
end

local function request_cancel(job, reason)
	if job.settled then
		return false
	end
	if not job.cancel_requested then
		local record, persist_err = persist(job.identity, "running", {
			attempt = job.claim.record.attempt,
			attempt_consumed = true,
			cancel_requested = true,
			detail = reason,
			plan = job.plan,
		})
		if not record then
			return nil, "cancel-persist-failed: " .. tostring(persist_err)
		end
		job.cancel_requested = true
		job.cancel_reason = reason
	end
	if not job.backend_done and type(job.cancel_primitive) == "function" and not job.cancel_signalled then
		job.cancel_signalled = true
		pcall(job.cancel_primitive)
	end
	if job.backend_done then
		settle(job, false, job.cancel_reason)
	end
	return true
end

local function defer_call(callback, delay)
	local defer = configured.defer or vim.defer_fn
	local ok, err = pcall(defer, callback, delay)
	if ok then
		return true
	end
	if defer ~= vim.defer_fn then
		local fallback_ok, fallback_err = pcall(vim.defer_fn, callback, delay)
		if fallback_ok then
			return true
		end
		err = fallback_err
	end
	return nil, tostring(err)
end

local function schedule_drain()
	if drain_scheduled then
		return
	end
	drain_scheduled = true
	local scheduled, schedule_err = defer_call(function()
		drain_scheduled = false
		M._drain()
	end, tonumber(configured.lock_retry_ms) or 25)
	if not scheduled then
		drain_scheduled = false
		notify("lock retry scheduling failed: " .. tostring(schedule_err), vim.log.levels.ERROR)
	end
end

local function requeue_contended(job)
	local released, release_err = release_locks(job)
	if not released then
		job.settled = true
		job.persistence_blocked = true
		job.persistence_error = "contended-lock-release-failed: " .. tostring(release_err)
		notify(job.persistence_error, vim.log.levels.ERROR)
		return "held"
	end
	queue[#queue + 1] = job
	schedule_drain()
	return "requeued"
end

local function prestart_identity_owned(job)
	local resource = "identity:" .. identity_key(job.identity)
	for _, lock in ipairs(job.locks or {}) do
		if lock.resource == resource then
			return true
		end
	end
	local lock, lock_err = acquire_lock(resource_lock_base(resource), resource)
	if not lock then
		return nil, lock_err
	end
	job.locks[#job.locks + 1] = lock
	return true
end

local function fail_before_start(job, reason, repair_required)
	local owned, owner_err = prestart_identity_owned(job)
	if not owned then
		if lock_contended(owner_err) then
			return requeue_contended(job)
		end
		job.settled = true
		job.persistence_blocked = true
		job.persistence_error = "prestart-identity-lock-failed: " .. tostring(owner_err)
		notify(job.persistence_error, vim.log.levels.ERROR)
		return "held"
	end
	local current, current_err = decode_record(job.identity)
	if
		not current
		or current.status ~= "queued"
		or current.pid ~= pid()
		or current.instance_token ~= instance_token
		or current.attempt ~= job.claim.record.attempt
		or type(current.plan) ~= "table"
		or current.plan.plan_digest ~= job.plan.plan_digest
	then
		job.settled = true
		job.persistence_blocked = true
		job.persistence_error = "prestart-record-owner-mismatch: " .. tostring(current_err or "changed")
		notify(job.persistence_error, vim.log.levels.ERROR)
		return "held"
	end
	local final_status = repair_required and "repair-required" or "failed"
	local persisted, persist_err = persist(job.identity, final_status, {
		attempt = job.claim.record.attempt,
		attempt_consumed = true,
		detail = reason,
		plan = job.plan,
	})
	if not persisted then
		local repair_reason = "prestart-status-persist-failed: " .. tostring(persist_err)
		local repair, repair_err = persist(job.identity, "repair-required", {
			attempt = job.claim.record.attempt,
			attempt_consumed = true,
			detail = repair_reason,
			plan = job.plan,
		})
		if not repair then
			job.settled = true
			job.persistence_blocked = true
			job.persistence_error = repair_reason .. "; repair-persist-failed: " .. tostring(repair_err)
			running[job.key] = job
			running_count = running_count + 1
			notify(job.persistence_error, vim.log.levels.ERROR)
			return "held"
		end
		reason = repair_reason
		final_status = "repair-required"
	end
	local released, release_err = release_locks(job)
	if not released then
		job.settled = true
		job.persistence_blocked = true
		job.persistence_error = "prestart-lock-release-failed: " .. tostring(release_err)
		notify(job.persistence_error, vim.log.levels.ERROR)
		return "held"
	end
	job.settled = true
	if type(job.callback) == "function" then
		pcall(job.callback, false, reason)
	end
	emit("finished", { identity = job.identity, ok = false, reason = reason, status = final_status })
	M._drain()
	return "failed"
end

local function start_job(job)
	local guarded, guard_err = validate_destination_guard(job.plan.destination_guard, false)
	if not guarded then
		return fail_before_start(job, guard_err)
	end
	for _, resource in ipairs(job.resources) do
		local lock, lock_err = acquire_lock(resource_lock_base(resource), resource)
		if not lock then
			if lock_contended(lock_err) then
				return requeue_contended(job)
			end
			return fail_before_start(job, "resource-" .. tostring(lock_err))
		end
		job.locks[#job.locks + 1] = lock
	end
	local global_lock, global_error
	for slot = 1, 2 do
		local resource = "global-slot:" .. tostring(slot)
		local lock, lock_err = acquire_lock(global_lock_base(slot), resource, 0)
		global_lock = lock
		if global_lock then
			break
		end
		if not lock_contended(lock_err) then
			global_error = lock_err
			break
		end
	end
	if not global_lock then
		if not global_error then
			return requeue_contended(job)
		end
		return fail_before_start(job, "global-lock-" .. tostring(global_error))
	end
	job.locks[#job.locks + 1] = global_lock
	guarded, guard_err = validate_destination_guard(job.plan.destination_guard, false)
	if not guarded then
		return fail_before_start(job, guard_err)
	end
	local disabled, disable_err, _, retained = remove_owned_shims(job, true)
	if not disabled then
		if retained and #(retained.old_entries or {}) > 0 then
			notify("pre-backend shim invalidation retained private quarantine evidence", vim.log.levels.ERROR)
		end
		return fail_before_start(job, "pre-backend-shim-invalidation-failed: " .. tostring(disable_err), true)
	end
	local invalidation_cleaned, invalidation_cleanup_err = commit_shim_transaction(disabled)
	if not invalidation_cleaned then
		-- Canonical shims and owners are already absent. Quarantine cleanup is
		-- post-commit hygiene and cannot turn the invalidation into a failed job.
		notify(
			"pre-backend shim invalidation committed; deferred cleanup retained evidence: "
				.. tostring(invalidation_cleanup_err),
			vim.log.levels.WARN
		)
	end
	for _, command in ipairs(sorted_keys(job.plan.shims)) do
		if uv.fs_lstat(job.plan.shims[command]) or uv.fs_lstat(shim_owner_path(command)) then
			return fail_before_start(job, "pre-backend-shim-invalidation-drift: " .. command, true)
		end
	end
	running[job.key] = job
	running_count = running_count + 1
	local running_record, running_err = persist(job.identity, "running", {
		attempt = job.claim.record.attempt,
		attempt_consumed = true,
		plan = job.plan,
	})
	if not running_record then
		local reason = "running-status-persist-failed: " .. tostring(running_err)
		local repair, repair_err = persist(job.identity, "repair-required", {
			attempt = job.claim.record.attempt,
			attempt_consumed = true,
			detail = reason,
			plan = job.plan,
		})
		if not repair then
			job.settled = true
			job.persistence_blocked = true
			job.persistence_error = reason .. "; repair-persist-failed: " .. tostring(repair_err)
			notify(job.persistence_error, vim.log.levels.ERROR)
			return
		end
		local released, release_err = release_locks(job)
		if not released then
			job.settled = true
			job.persistence_blocked = true
			job.persistence_error = "lock-release-failed: " .. tostring(release_err)
			notify(job.persistence_error, vim.log.levels.ERROR)
			return
		end
		running[job.key] = nil
		running_count = math.max(0, running_count - 1)
		job.settled = true
		if type(job.callback) == "function" then
			pcall(job.callback, false, reason)
		end
		emit("finished", { identity = job.identity, ok = false, reason = reason, status = "repair-required" })
		M._drain()
		return
	end
	local timeout = tonumber(job.plan.manifest.timeout_ms) or tonumber(configured.watchdog_ms) or 300000
	local scheduled, schedule_err = defer_call(function()
		if not job.settled then
			request_cancel(job, "watchdog-timeout")
		end
	end, timeout)
	if not scheduled then
		settle(job, false, "watchdog-schedule-failed: " .. tostring(schedule_err))
		return
	end
	local backend = backend_for(job.identity)
	if not backend or type(backend.run) ~= "function" then
		settle(job, false, "backend-unavailable")
		return
	end
	local called = false
	local function done(ok, value)
		if vim.in_fast_event() then
			schedule_on_main(done, ok, value)
			return
		end
		if called or job.settled then
			return
		end
		called = true
		job.backend_done = true
		if job.cancel_requested then
			settle(job, false, job.cancel_reason)
			return
		end
		if ok ~= true then
			settle(job, false, bounded_reason(value, "backend-failed"))
			return
		end
		local evidence_call_ok, evidence, evidence_err = pcall(normalize_install_evidence, job.plan, value)
		if not evidence_call_ok or not evidence then
			settle(job, false, evidence_call_ok and evidence_err or "install-evidence-validation-crashed")
			return
		end
		job.install_evidence = evidence ~= true and evidence or nil
		job.attesting = true
		attest_job(job, function(attested, value)
			if job.settled then
				return
			end
			job.attesting = false
			if job.cancel_requested then
				settle(job, false, job.cancel_reason)
				return
			end
			if attested then
				local warning = job.install_evidence
						and #job.install_evidence.warnings > 0
						and table.concat(job.install_evidence.warnings, "; ")
					or nil
				if warning then
					notify("install completed with recovery warnings: " .. warning, vim.log.levels.WARN)
				end
				settle(job, true, warning, value)
			else
				settle(job, false, value or "attestation-failed")
			end
		end)
	end
	local function set_cancel(cancel)
		if vim.in_fast_event() then
			schedule_on_main(set_cancel, cancel)
			return
		end
		if type(cancel) == "function" then
			job.cancel_primitive = cancel
			if job.cancel_requested then
				request_cancel(job, job.cancel_reason)
			end
		end
	end
	local ok, result, result_value = pcall(backend.run, copy(job.plan), done, { set_cancel = set_cancel })
	if not ok then
		done(false, "backend-crashed")
	elseif type(result) == "boolean" then
		if result then
			done(true, result_value)
		else
			done(false, result_value or "backend-start-failed")
		end
	end
	return "started"
end

function M._drain()
	local index = 1
	while running_count < 2 and index <= #queue do
		local job = queue[index]
		local resource_busy = false
		for _, active in pairs(running) do
			for resource in pairs(job.resource_set) do
				if active.resource_set[resource] then
					resource_busy = true
					break
				end
			end
			if resource_busy then
				break
			end
		end
		if running[job.key] or resource_busy then
			index = index + 1
		else
			table.remove(queue, index)
			local outcome = start_job(job)
			if outcome == "requeued" or outcome == "held" then
				break
			end
		end
	end
end

function M.run(claim, callback)
	if callback ~= nil and type(callback) ~= "function" then
		return nil, "run callback must be a function"
	end
	if
		type(claim) ~= "table"
		or not exact_keys(claim, { identity = true, plan = true, record = true, mode = true })
		or type(claim.plan) ~= "table"
		or type(claim.record) ~= "table"
		or not schema2_record_shape(claim.record)
		or claim.record.status ~= "claimed"
		or (claim.mode ~= "auto" and claim.mode ~= "retry" and claim.mode ~= "repair")
		or claim.record.mode ~= claim.mode
	then
		return nil, "invalid claim"
	end
	local plan, plan_err = normalize_supplied_plan(claim.plan)
	local identity = plan and normalize_identity(claim.identity) or nil
	local record_identity = identity and normalize_identity(claim.record.identity) or nil
	local record_plan_ok, record_plan = pcall(normalize_supplied_plan, claim.record.plan)
	record_plan = record_plan_ok and record_plan or nil
	if
		not plan
		or not identity
		or not record_identity
		or not record_plan
		or identity_json(identity) ~= identity_json(plan.identity)
		or identity_json(record_identity) ~= identity_json(identity)
		or claim.record.identity_key ~= identity_key(identity)
		or not vim.deep_equal(record_plan, plan)
		or claim.record.instance_token ~= instance_token
		or claim.record.pid ~= pid()
	then
		return nil, plan_err or "invalid claim"
	end
	local key = identity_key(identity)
	for _, pending in ipairs(queue) do
		if pending.key == key then
			return nil, "already-queued"
		end
	end
	if running[key] then
		return nil, "already-running"
	end
	local job = {
		key = key,
		destination_key = destination_key(identity),
		identity = copy(identity),
		plan = copy(plan),
		claim = copy(claim),
		callback = callback,
		locks = {},
		resources = copy(plan.resources),
		resource_set = {},
	}
	for _, resource in ipairs(job.resources) do
		job.resource_set[resource] = true
	end
	local transition_lock, transition_err = acquire_identity_lock(identity)
	if not transition_lock then
		return nil, transition_err
	end
	local current, current_err = decode_record(identity)
	local same_record_ok, same_record = pcall(vim.deep_equal, current, claim.record)
	if
		not current
		or not same_record_ok
		or not same_record
		or current.status ~= "claimed"
		or current.instance_token ~= instance_token
		or current.pid ~= pid()
		or current.attempt ~= claim.record.attempt
		or current.generation ~= claim.record.generation
		or current.mode ~= claim.mode
		or type(current.plan) ~= "table"
		or current.plan.plan_digest ~= plan.plan_digest
	then
		release_lock(transition_lock)
		return nil, current_err or "stale claim"
	end
	local queued_record, persist_err = persist(job.identity, "queued", {
		attempt = claim.record.attempt,
		attempt_consumed = true,
		plan = job.plan,
	})
	local released, release_err = release_lock(transition_lock)
	if not queued_record then
		return nil, persist_err
	end
	if not released then
		return nil, release_err
	end
	queue[#queue + 1] = job
	M._drain()
	return copy({ identity = job.identity, status = running[key] and "running" or "queued" })
end

function M.attest(identity, callback)
	if callback ~= nil and type(callback) ~= "function" then
		return nil, "attestation callback must be a function"
	end
	local normalized, err = normalize_identity_request(identity, "attestation")
	if not normalized then
		return nil, err
	end
	local recorded, record_err = decode_record(normalized)
	if not recorded then
		return nil, record_err
	end
	if recorded.status ~= "succeeded" then
		return nil, recorded.status == "repair-required" and "repair-required" or "attestation requires succeeded state"
	end
	local plan, plan_err = normalize_supplied_plan(recorded.plan, { installed = true })
	if not plan then
		return nil, plan_err
	end
	if not valid_stored_proof(plan, recorded.proof, normalized) then
		return nil, "repair-required"
	end
	local job = {
		key = identity_key(normalized),
		identity = normalized,
		plan = plan,
		baseline = copy(recorded.proof),
		claim = { record = { attempt = recorded.attempt } },
		failure_status = "drift",
		locks = {},
		resources = copy(plan.resources),
		callback = function(ok, reason, proof)
			if type(callback) == "function" then
				pcall(callback, ok, ok and copy(proof) or reason)
			end
		end,
	}
	for _, resource in ipairs(job.resources) do
		local lock, lock_err = acquire_lock(resource_lock_base(resource), resource)
		if not lock then
			local released, release_err = release_locks(job)
			return nil, released and lock_err or release_err
		end
		job.locks[#job.locks + 1] = lock
	end
	local global_lock, global_err
	for slot = 1, 2 do
		local resource = "global-slot:" .. tostring(slot)
		local lock, lock_err = acquire_lock(global_lock_base(slot), resource, 0)
		if lock then
			global_lock = lock
			break
		end
		if not lock_contended(lock_err) then
			global_err = lock_err
			break
		end
	end
	if not global_lock then
		local released, release_err = release_locks(job)
		return nil, released and (global_err or "locked") or release_err
	end
	job.locks[#job.locks + 1] = global_lock
	local current, current_err = decode_record(normalized)
	if
		not current
		or current.status ~= "succeeded"
		or current.generation ~= recorded.generation
		or current.plan.plan_digest ~= plan.plan_digest
		or not vim.deep_equal(current.proof, recorded.proof)
	then
		local released, release_err = release_locks(job)
		return nil, released and (current_err or "attestation baseline changed") or release_err
	end
	local scheduled, schedule_err = defer_call(function()
		if not job.settled then
			settle(job, false, "attestation-timeout")
		end
	end, tonumber(plan.manifest.timeout_ms) or tonumber(configured.watchdog_ms) or 300000)
	if not scheduled then
		settle(job, false, "watchdog-schedule-failed: " .. tostring(schedule_err))
		return nil, "watchdog-schedule-failed"
	end
	attest_job(job, function(ok, value)
		if ok then
			settle(job, true, nil, value)
		else
			settle(job, false, value)
		end
	end)
	return true
end

function M.retry(spec, callback)
	local plan, err = M.plan(spec)
	if not plan then
		return nil, err
	end
	local claim, claim_err = M.claim(plan, { mode = "retry" })
	if not claim then
		return nil, claim_err
	end
	return M.run(claim, callback)
end

function M.repair(spec, callback)
	local plan, err = M.plan(spec)
	if not plan then
		return nil, err
	end
	local claim, claim_err = M.claim(plan, { mode = "repair" })
	if not claim then
		return nil, claim_err
	end
	return M.run(claim, callback)
end

function M.cancel(identity)
	local normalized, err = normalize_identity_request(identity, "cancel")
	if not normalized then
		return nil, err
	end
	local key = identity_key(normalized)
	for index, job in ipairs(queue) do
		if job.key == key then
			local record, persist_err = persist(job.identity, "cancelled", {
				attempt = job.claim.record.attempt,
				attempt_consumed = true,
				detail = "cancelled",
				plan = job.plan,
			})
			if not record then
				return nil, "cancel-persist-failed: " .. tostring(persist_err)
			end
			table.remove(queue, index)
			if type(job.callback) == "function" then
				pcall(job.callback, false, "cancelled")
			end
			emit("finished", { identity = job.identity, ok = false, reason = "cancelled" })
			M._drain()
			return true
		end
	end
	local job = running[key]
	if not job then
		return nil, "not-running"
	end
	return request_cancel(job, "cancelled")
end

function M.import_legacy(spec, legacy, callback)
	if type(spec) ~= "table" then
		return nil, "tool spec must be a table"
	end
	local managed_spec = copy(spec)
	managed_spec.force_managed = true
	local plan, err = M.plan(managed_spec)
	if not plan then
		return nil, err
	end
	local raw_mason = plan.identity.backend == "mason"
		and type(legacy) == "table"
		and exact_keys(legacy, { status = true, origin = true })
		and legacy.status == "present"
		and legacy.origin == "observed-raw-mason-state-v1"
	local holder, lock_err = acquire_operation_locks(plan)
	if not holder then
		return nil, lock_err
	end
	local existing, existing_err = decode_record(plan.identity)
	local resumable_raw = raw_mason
		and existing
		and existing.status == "repair-required"
		and type(existing.plan) == "table"
		and existing.plan.plan_digest == plan.plan_digest
	if (existing and not resumable_raw) or (not existing and existing_err ~= "absent") then
		local released, release_err = release_locks(holder)
		return nil, released and (existing and "consumed" or existing_err) or release_err
	end
	local function record_repair(detail)
		local legacy_status = type(legacy) == "table" and type(legacy.status) == "string" and legacy.status or "corrupt"
		local legacy_origin = type(legacy) == "table" and type(legacy.origin) == "string" and legacy.origin or nil
		local record, persist_err = persist(plan.identity, "repair-required", {
			attempt = 0,
			legacy = true,
			legacy_status = legacy_status:sub(1, 80),
			legacy_origin = legacy_origin and legacy_origin:sub(1, 80) or nil,
			detail = detail,
			plan = plan,
		})
		if not record then
			notify("legacy repair persistence failed: " .. tostring(persist_err), vim.log.levels.ERROR)
			return nil, persist_err
		end
		local released, release_err = release_locks(holder)
		if not released then
			return nil, release_err
		end
		if type(callback) == "function" then
			pcall(callback, false, detail)
		end
		return record
	end
	if not raw_mason and (type(legacy) ~= "table" or legacy.status ~= "succeeded") then
		return record_repair("legacy-repair-required")
	end
	local evidence
	if plan.manifest.integrity.kind == "release-sha256" then
		if
			not exact_keys(legacy, { status = true, origin = true, install_evidence = true })
			or legacy.origin ~= "verified-private-install-receipt-v1"
		then
			return record_repair("legacy-release-evidence-origin-invalid")
		end
		local evidence_ok
		evidence_ok, evidence, err = pcall(normalize_install_evidence, plan, legacy.install_evidence)
		if not evidence_ok or not evidence then
			return record_repair("legacy-release-evidence-invalid: " .. tostring(evidence_ok and err or evidence))
		end
	elseif plan.manifest.integrity.kind == "bundle-sha256" then
		return record_repair("legacy-bundle-provenance-unsupported")
	elseif
		not raw_mason
		and (
			not exact_keys(legacy, { status = true, origin = true })
			or legacy.origin ~= "verified-private-mason-receipt-v1"
		)
	then
		return record_repair("legacy-Mason-evidence-origin-invalid")
	end
	local attempt = existing and existing.attempt or 0
	local job = {
		key = identity_key(plan.identity),
		identity = plan.identity,
		plan = plan,
		install_evidence = copy(evidence),
		claim = { record = { attempt = attempt } },
		failure_status = "repair-required",
		legacy_import = true,
		local_mason_adoption = raw_mason,
		locks = holder.locks,
		resources = holder.resources,
		resource_set = {},
		callback = function(ok, reason, proof)
			if type(callback) == "function" then
				pcall(callback, ok, ok and copy(proof) or reason)
			end
		end,
	}
	for _, resource in ipairs(job.resources) do
		job.resource_set[resource] = true
	end
	local running_record, running_err = persist(plan.identity, "running", {
		attempt = attempt,
		attempt_consumed = false,
		legacy = true,
		legacy_origin = legacy.origin,
		plan = plan,
	})
	if not running_record then
		return record_repair("legacy-running-persist-failed: " .. tostring(running_err))
	end
	running[job.key] = job
	running_count = running_count + 1
	local scheduled, schedule_err = defer_call(function()
		if not job.settled then
			settle(job, false, "attestation-timeout")
		end
	end, tonumber(plan.manifest.timeout_ms) or tonumber(configured.watchdog_ms) or 300000)
	if not scheduled then
		settle(job, false, "watchdog-schedule-failed: " .. tostring(schedule_err))
		return nil, "watchdog-schedule-failed"
	end
	attest_job(job, function(ok, value)
		if ok then
			settle(job, true, nil, value)
		else
			settle(job, false, value)
		end
	end)
	return true
end

---Return a deterministic, caller-owned snapshot of process-local jobs.
---This function performs no filesystem reads and invokes no callbacks.
---@return table[]
function M.jobs()
	local result = {}
	for index, job in ipairs(queue) do
		result[#result + 1] = {
			identity = copy(job.identity),
			key = job.key,
			status = "queued",
			queue_position = index,
			stage = "queued",
			resources = copy(job.resources),
		}
	end
	local keys = vim.tbl_keys(running)
	table.sort(keys)
	for _, key in ipairs(keys) do
		local job = running[key]
		local stage = "running"
		if job.persistence_blocked then
			stage = "persistence-blocked"
		elseif job.cancel_requested then
			stage = "cancelling"
		elseif job.attesting then
			stage = "attesting"
		end
		result[#result + 1] = {
			identity = copy(job.identity),
			key = job.key,
			status = "running",
			queue_position = nil,
			stage = stage,
			resources = copy(job.resources),
		}
	end
	return copy(result)
end

---Release process-local configuration only when no lifecycle work is active.
---@return boolean|nil
---@return string|nil
function M.teardown()
	if #queue > 0 or running_count > 0 or next(running) ~= nil then
		return nil, "verified tools still has active jobs"
	end
	drain_scheduled = false
	configured = {}
	instance_token = nil
	pinned_pid = nil
	pinned_state_root = nil
	state_root_guard = nil
	state_directory_guards = {}
	return true
end

function M._reset_for_tests()
	queue = {}
	running = {}
	running_count = 0
	drain_scheduled = false
	generation = 0
	temp_counter = 0
	instance_token = nil
	pinned_pid = nil
	pinned_state_root = nil
	state_root_guard = nil
	state_directory_guards = {}
	configured = {}
end

function M._queue_size()
	return #queue, running_count
end

function M._record_ffi_abi_for_tests(system)
	local selected_system = system or SYSTEM
	local abi = type(selected_system) == "string" and RECORD_FFI_ABI_BY_SYSTEM[selected_system] or nil
	if not abi then
		return nil, "unsupported record FFI ABI: " .. tostring(selected_system)
	end
	local result = copy(abi)
	result.system = selected_system
	return result
end

function M._collect_lock_claims_for_tests(base, resource)
	return collect_lock_claims(base, resource)
end

return M
