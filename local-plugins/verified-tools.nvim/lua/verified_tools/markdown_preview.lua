local M = {}

local uv = vim.uv
local bit = require("bit")
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	ffi_ok = pcall(
		ffi.cdef,
		[[
			int fcntl(int fd, int cmd, ...);
			int openat(int fd, const char *path, int flags, ...);
			int renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int renameatx_np(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int symlinkat(const char *target, int fd, const char *path);
		int unlinkat(int fd, const char *path, int flags);
		long readlinkat(int fd, const char *path, char *buffer, unsigned long size);
	]]
	)
end

local SYSTEM = uv.os_uname().sysname
local DARWIN_F_GETPATH = 50
local DARWIN_PATH_BYTES = 1024
local READLINK_BYTES = 64 * 1024
local MAX_BINARY_BYTES = 256 * 1024 * 1024
local UNSAFE_WRITE_MASK = tonumber("22", 8) -- group/world write
local EXECUTABLE_MASK = tonumber("111", 8)
local STICKY_MASK = tonumber("1000", 8)
local RENAME_NOREPLACE = 1
local RENAME_EXCL = 4
local test_hook
local uid_ok, effective_uid = pcall(uv.getuid)
if not uid_ok or type(effective_uid) ~= "number" then
	effective_uid = nil
end
local OPEN_FLAGS = SYSTEM == "Darwin"
		and {
			at_fdcwd = -2,
			cloexec = 16777216,
			directory = 1048576,
			nonblock = 4,
			no_follow = 256,
			symlink = 2097152,
		}
	or {
		at_fdcwd = -100,
		cloexec = 524288,
		directory = 65536,
		nonblock = 2048,
		no_follow = 131072,
		symlink = 2097152,
	}

function M.expected_name()
	local uname = uv.os_uname()
	if uname.sysname == "Darwin" and (uname.machine == "arm64" or uname.machine == "aarch64") then
		return "markdown-preview-macos-arm64"
	elseif uname.sysname == "Darwin" then
		return "markdown-preview-macos"
	elseif uname.sysname == "Linux" then
		return "markdown-preview-linux"
	end
	return nil
end

function M._set_test_hook(callback)
	assert(callback == nil or type(callback) == "function", "test hook must be a function or nil")
	test_hook = callback
end

local function run_test_hook(phase, details)
	if not test_hook then
		return true
	end
	local ok, err = pcall(test_hook, phase, vim.deepcopy(details or {}))
	if not ok then
		return nil, tostring(err)
	end
	return true
end

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
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

local function same_object(left, right, kind)
	return left
		and right
		and left.type == kind
		and right.type == kind
		and left.dev == right.dev
		and left.ino == right.ino
end

local function trusted_owner(stat)
	return effective_uid ~= nil and stat and (stat.uid == 0 or stat.uid == effective_uid)
end

local function safe_directory_stat(stat)
	local unsafe_write = stat and type(stat.mode) == "number" and bit.band(stat.mode, UNSAFE_WRITE_MASK) ~= 0
	local protected_temporary = unsafe_write and stat.uid == 0 and bit.band(stat.mode, STICKY_MASK) ~= 0
	return stat
		and stat.type == "directory"
		and trusted_owner(stat)
		and type(stat.mode) == "number"
		and (not unsafe_write or protected_temporary)
end

local function safe_directory_chain(path)
	local cursor = path
	while true do
		if not safe_directory_stat(uv.fs_lstat(cursor)) then
			return nil
		end
		if cursor == "/" then
			return true
		end
		local parent = vim.fs.dirname(cursor)
		if parent == cursor then
			return nil
		end
		cursor = parent
	end
end

local function descriptor_path(fd)
	if SYSTEM == "Linux" then
		-- Procfs is the only portable way available here to prove the opened
		-- directory still has the validated pathname; fail closed without it.
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

local function descriptor_relative_ready()
	return ffi_ok and (SYSTEM == "Darwin" or SYSTEM == "Linux")
end

local function directory_is_bound(directory)
	local descriptor_bound = descriptor_is_bound(directory.fd, directory.path)
	local current = uv.fs_lstat(directory.path)
	local opened = uv.fs_fstat(directory.fd)
	return descriptor_bound
		and safe_directory_stat(opened)
		and safe_directory_stat(current)
		and safe_directory_chain(directory.path)
		and same_object(directory.stat, opened, "directory")
		and same_object(opened, current, "directory")
end

local function open_directory(path)
	if not descriptor_relative_ready() then
		return nil, "descriptor-relative filesystem operations are unavailable"
	end
	local before = uv.fs_lstat(path)
	local canonical = before and before.type == "directory" and uv.fs_realpath(path) or nil
	if not canonical or vim.fs.normalize(canonical) ~= path then
		return nil, "directory is missing, moved, or unsafe"
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.cloexec
	local raw_fd = ffi.C.openat(OPEN_FLAGS.at_fdcwd, path, flags)
	if raw_fd < 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	local fd = tonumber(raw_fd)
	local opened = uv.fs_fstat(fd)
	local directory = { fd = fd, path = path, stat = opened }
	if not same_object(before, opened, "directory") or not directory_is_bound(directory) then
		close_fd(fd)
		return nil, "directory changed while it was opened"
	end
	return directory
end

local function read_relative_link(parent_fd, name)
	local buffer = ffi.new("char[?]", READLINK_BYTES)
	local size = ffi.C.readlinkat(parent_fd, name, buffer, READLINK_BYTES)
	if size < 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	if tonumber(size) == READLINK_BYTES then
		return nil, "symlink target is too long"
	end
	return ffi.string(buffer, tonumber(size))
end

local fingerprint

local function relative_entry_once(parent_fd, name)
	local flags = OPEN_FLAGS.symlink + OPEN_FLAGS.cloexec
	if SYSTEM == "Linux" then
		flags = flags + OPEN_FLAGS.no_follow
	end
	local raw_fd = ffi.C.openat(parent_fd, name, flags)
	if raw_fd < 0 then
		local errno = ffi.errno()
		if errno == 2 then
			return false
		end
		return nil, "errno " .. tostring(errno)
	end
	local fd = tonumber(raw_fd)
	local stat, stat_err = uv.fs_fstat(fd)
	local closed, close_err = close_fd(fd)
	if not stat or not closed then
		return nil, tostring(stat_err or close_err or "entry inspection failed")
	end
	local target
	if stat.type == "link" then
		local target_err
		target, target_err = read_relative_link(parent_fd, name)
		if not target then
			return nil, target_err
		end
	end
	return { stat = stat, target = target }
end

local function relative_entry(parent_fd, name)
	local first, first_err = relative_entry_once(parent_fd, name)
	if first == false or first == nil then
		return first, first_err
	end
	local second, second_err = relative_entry_once(parent_fd, name)
	if not second or not same_object(first.stat, second.stat, first.stat.type) or first.target ~= second.target then
		return nil, second_err or "entry changed while it was inspected"
	end
	return second
end

local function renameat_noreplace(source_fd, source, target_fd, target)
	local called, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(source_fd, source, target_fd, target, RENAME_EXCL)
		end
		return ffi.C.renameat2(source_fd, source, target_fd, target, RENAME_NOREPLACE)
	end)
	if not called then
		return nil, tostring(result)
	end
	if result ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function sync_directory(directory)
	local synced, sync_err = uv.fs_fsync(directory.fd)
	if not synced then
		return nil, tostring(sync_err)
	end
	return true
end

local function same_regular_object(left, right)
	local left_mtime = left and left.mtime or {}
	local right_mtime = right and right.mtime or {}
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
end

local function same_regular_identity(left, right)
	local left_ctime = left and left.ctime or {}
	local right_ctime = right and right.ctime or {}
	return same_regular_object(left, right)
		and left_ctime.sec == right_ctime.sec
		and left_ctime.nsec == right_ctime.nsec
end

local function safe_regular(stat)
	return stat
		and stat.type == "file"
		and trusted_owner(stat)
		and stat.nlink == 1
		and stat.size >= 0
		and stat.size <= MAX_BINARY_BYTES
		and type(stat.mode) == "number"
		and bit.band(stat.mode, UNSAFE_WRITE_MASK) == 0
		and bit.band(stat.mode, EXECUTABLE_MASK) ~= 0
end

local function fingerprint_relative(directory, name, expected)
	if not same_object(directory.stat, uv.fs_fstat(directory.fd), "directory") or not safe_regular(expected) then
		return nil, "legacy binary is not a safe single-link regular executable"
	end
	local flags = OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.cloexec
	local raw_fd = ffi.C.openat(directory.fd, name, flags)
	if raw_fd < 0 then
		return nil, "could not open legacy binary: errno " .. tostring(ffi.errno())
	end
	local fd = tonumber(raw_fd)
	local opened = uv.fs_fstat(fd)
	if not safe_regular(opened) or not same_regular_identity(expected, opened) then
		close_fd(fd)
		return nil, "legacy binary changed before reading"
	end
	local chunks = {}
	local offset = 0
	while offset < opened.size do
		local chunk, read_err = uv.fs_read(fd, math.min(1024 * 1024, opened.size - offset), offset)
		if type(chunk) ~= "string" or #chunk == 0 then
			close_fd(fd)
			return nil, "could not read legacy binary: " .. tostring(read_err)
		end
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
	end
	local completed = uv.fs_fstat(fd)
	local closed, close_err = close_fd(fd)
	local current, current_err = relative_entry(directory.fd, name)
	if
		not closed
		or not same_regular_identity(opened, completed)
		or not current
		or not same_regular_identity(completed, current.stat)
	then
		return nil, "legacy binary changed while reading: " .. tostring(current_err or close_err or "identity mismatch")
	end
	return { stat = current.stat, sha256 = vim.fn.sha256(table.concat(chunks)) }
end

local function rollback_link(directory, name, published)
	local current, current_err = relative_entry(directory.fd, name)
	if not current or not same_object(current.stat, published.stat, "link") or current.target ~= published.target then
		return nil, current_err or "published symlink changed before rollback"
	end
	if ffi.C.unlinkat(directory.fd, name, 0) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	local remaining, remaining_err = relative_entry(directory.fd, name)
	if remaining ~= false then
		return nil, remaining_err or "published symlink remained after rollback"
	end
	local synced, sync_err = sync_directory(directory)
	if not synced then
		return nil, "rollback directory sync failed: " .. tostring(sync_err)
	end
	return true
end

local function restore_quarantined(directory, name, quarantine, expected, published)
	if not same_object(directory.stat, uv.fs_fstat(directory.fd), "directory") then
		return nil, "pinned markdown-preview bin directory changed identity"
	end
	local current, current_err = relative_entry(directory.fd, quarantine)
	if not current or not same_regular_identity(expected, current.stat) then
		return nil, current_err or "legacy quarantine changed before rollback"
	end
	if published then
		local rolled_back, rollback_err = rollback_link(directory, name, published)
		if not rolled_back then
			return nil, "published symlink rollback failed: " .. tostring(rollback_err)
		end
	else
		local target, target_err = relative_entry(directory.fd, name)
		if target ~= false then
			return nil, target_err or "legacy restore target is occupied"
		end
	end
	local rechecked, recheck_err = relative_entry(directory.fd, quarantine)
	if not rechecked or not same_regular_identity(current.stat, rechecked.stat) then
		return nil, recheck_err or "legacy quarantine changed before rollback"
	end
	local restored, restore_err = renameat_noreplace(directory.fd, quarantine, directory.fd, name)
	if not restored then
		return nil, "legacy rollback rename failed: " .. tostring(restore_err)
	end
	local synced, sync_err = sync_directory(directory)
	local final, final_err = relative_entry(directory.fd, name)
	if not synced or not final or not same_regular_object(rechecked.stat, final.stat) then
		return nil, "legacy rollback could not be verified: " .. tostring(sync_err or final_err or "identity mismatch")
	end
	return true
end

local function adopt_legacy(directory, name, managed, baseline, existing)
	local inspected, inspect_err = fingerprint_relative(directory, name, existing.stat)
	if not inspected then
		return nil, inspect_err
	end
	if inspected.sha256 ~= baseline.sha256 or inspected.stat.size ~= baseline.size then
		return nil, "refusing to replace a non-identical legacy markdown-preview binary"
	end
	local hook_ok, hook_err = run_test_hook("before_legacy_quarantine", {
		path = vim.fs.joinpath(directory.path, name),
	})
	if not hook_ok then
		return nil, "legacy quarantine hook failed: " .. tostring(hook_err)
	end
	local rechecked, recheck_err = fingerprint_relative(directory, name, inspected.stat)
	if not rechecked or rechecked.sha256 ~= baseline.sha256 then
		return nil, recheck_err or "legacy binary changed before quarantine"
	end
	local quarantine = (".%s.verified-tools-quarantine.%d.%s"):format(name, uv.os_getpid(), tostring(uv.hrtime()))
	local moved, move_err = renameat_noreplace(directory.fd, name, directory.fd, quarantine)
	if not moved then
		return nil, "legacy quarantine failed without clobbering: " .. tostring(move_err)
	end
	local moved_sync, moved_sync_err = sync_directory(directory)
	local quarantined, quarantine_err = relative_entry(directory.fd, quarantine)
	if not moved_sync or not quarantined or not same_regular_object(rechecked.stat, quarantined.stat) then
		local rollback_expected = rechecked.stat
		if quarantined and same_regular_object(rechecked.stat, quarantined.stat) then
			rollback_expected = quarantined.stat
		end
		local restored, restore_err = restore_quarantined(directory, name, quarantine, rollback_expected)
		return nil,
			"legacy quarantine could not be verified: " .. tostring(
				moved_sync_err or quarantine_err or "identity mismatch"
			) .. (restored and "" or "; rollback failed: " .. tostring(restore_err))
	end
	local function fail(message, published)
		local restored, restore_err = restore_quarantined(directory, name, quarantine, quarantined.stat, published)
		return nil,
			message .. (restored and "" or "; rollback failed; quarantine retained at " .. vim.fs.joinpath(
				directory.path,
				quarantine
			) .. ": " .. tostring(restore_err))
	end
	local target, target_err = relative_entry(directory.fd, name)
	if target ~= false then
		return fail("legacy publication target was occupied: " .. tostring(target_err or "racing entry"))
	end
	hook_ok, hook_err = run_test_hook("before_legacy_publish", {
		path = vim.fs.joinpath(directory.path, name),
		quarantine = vim.fs.joinpath(directory.path, quarantine),
	})
	if not hook_ok then
		return fail("legacy publication hook failed: " .. tostring(hook_err))
	end
	if ffi.C.symlinkat(managed, directory.fd, name) ~= 0 then
		return fail(
			"could not publish managed markdown-preview symlink without clobbering: errno " .. tostring(ffi.errno())
		)
	end
	local published, published_err = relative_entry(directory.fd, name)
	if not published or published.stat.type ~= "link" or published.target ~= managed then
		return fail("managed symlink publication was not exact: " .. tostring(published_err or "identity mismatch"))
	end
	local published_sync, published_sync_err = sync_directory(directory)
	hook_ok, hook_err = run_test_hook("after_legacy_publish", {
		path = vim.fs.joinpath(directory.path, name),
		quarantine = vim.fs.joinpath(directory.path, quarantine),
	})
	local managed_after = fingerprint(managed)
	local legacy_after, legacy_err = fingerprint_relative(directory, quarantine, quarantined.stat)
	local final, final_err = relative_entry(directory.fd, name)
	if
		not published_sync
		or not hook_ok
		or not managed_after
		or not vim.deep_equal(managed_after, baseline)
		or not legacy_after
		or legacy_after.sha256 ~= baseline.sha256
		or not final
		or not same_object(published.stat, final.stat, "link")
		or final.target ~= managed
		or not directory_is_bound(directory)
	then
		return fail(
			"legacy adoption changed during publication: "
				.. tostring(published_sync_err or hook_err or legacy_err or final_err or "identity mismatch"),
			published
		)
	end
	hook_ok, hook_err = run_test_hook("before_legacy_cleanup", {
		path = vim.fs.joinpath(directory.path, name),
		quarantine = vim.fs.joinpath(directory.path, quarantine),
	})
	legacy_after, legacy_err = fingerprint_relative(directory, quarantine, legacy_after.stat)
	local managed_cleanup, managed_cleanup_err = fingerprint(managed)
	local published_cleanup, published_cleanup_err = relative_entry(directory.fd, name)
	if
		not hook_ok
		or not legacy_after
		or legacy_after.sha256 ~= baseline.sha256
		or not managed_cleanup
		or not vim.deep_equal(managed_cleanup, baseline)
		or not published_cleanup
		or not same_object(published.stat, published_cleanup.stat, "link")
		or published_cleanup.target ~= managed
		or not directory_is_bound(directory)
	then
		return fail(
			"legacy adoption changed before cleanup: "
				.. tostring(
					hook_err or legacy_err or managed_cleanup_err or published_cleanup_err or "identity mismatch"
				),
			published
		)
	end
	if ffi.C.unlinkat(directory.fd, quarantine, 0) ~= 0 then
		return fail("legacy quarantine cleanup failed: errno " .. tostring(ffi.errno()), published)
	end
	local cleanup_sync, cleanup_sync_err = sync_directory(directory)
	local cleanup_bound = directory_is_bound(directory)
	local managed_final = fingerprint(managed)
	local published_final, published_final_err = relative_entry(directory.fd, name)
	local quarantine_final, quarantine_final_err = relative_entry(directory.fd, quarantine)
	if
		not cleanup_bound
		or not managed_final
		or not vim.deep_equal(managed_final, baseline)
		or not published_final
		or not same_object(published.stat, published_final.stat, "link")
		or published_final.target ~= managed
		or quarantine_final ~= false
	then
		return nil,
			"legacy cleanup committed but final adoption revalidation failed: " .. tostring(
				cleanup_sync_err or published_final_err or quarantine_final_err or "identity mismatch"
			)
	end
	if not cleanup_sync then
		return true, "legacy cleanup committed with a durability warning: " .. tostring(cleanup_sync_err)
	end
	return true
end

fingerprint = function(path)
	local before = uv.fs_lstat(path)
	if
		not before
		or before.type ~= "file"
		or not trusted_owner(before)
		or before.nlink ~= 1
		or before.size > MAX_BINARY_BYTES
		or type(before.mode) ~= "number"
		or bit.band(before.mode, UNSAFE_WRITE_MASK) ~= 0
		or vim.fn.executable(path) ~= 1
	then
		return nil, "attested binary is not a private regular executable"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "could not open attested binary: " .. tostring(open_err)
	end
	local first = uv.fs_fstat(fd)
	if not first or not same_stat(before, first) then
		uv.fs_close(fd)
		return nil, "attested binary changed before reading"
	end
	local chunks = {}
	local offset = 0
	while offset < first.size do
		local chunk, read_err = uv.fs_read(fd, math.min(1024 * 1024, first.size - offset), offset)
		if type(chunk) ~= "string" or #chunk == 0 then
			uv.fs_close(fd)
			return nil, "could not read attested binary: " .. tostring(read_err)
		end
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
	end
	local last = uv.fs_fstat(fd)
	uv.fs_close(fd)
	local after = uv.fs_lstat(path)
	if not same_stat(first, last) or not same_stat(first, after) or after.nlink ~= 1 then
		return nil, "attested binary changed while reading"
	end
	local canonical = uv.fs_realpath(path)
	if not canonical then
		return nil, "attested binary cannot be resolved"
	end
	return {
		path = vim.fs.normalize(canonical),
		dev = first.dev,
		ino = first.ino,
		size = first.size,
		mode = first.mode,
		uid = first.uid,
		gid = first.gid,
		mtime_sec = first.mtime.sec,
		mtime_nsec = first.mtime.nsec,
		ctime_sec = first.ctime.sec,
		ctime_nsec = first.ctime.nsec,
		sha256 = vim.fn.sha256(table.concat(chunks)),
	}
end

local function exact_directory(path, expected_parent)
	local stat = uv.fs_lstat(path)
	local canonical = safe_directory_stat(stat) and uv.fs_realpath(path) or nil
	if
		not canonical
		or vim.fs.normalize(canonical) ~= vim.fs.normalize(path)
		or not safe_directory_chain(canonical)
		or (expected_parent and not contained(canonical, expected_parent))
	then
		return nil
	end
	return vim.fs.normalize(canonical)
end

local function revalidate_existing_link(directory, name, managed, baseline, existing)
	local hook_ok, hook_err = run_test_hook("before_existing_link_revalidate", {
		path = vim.fs.joinpath(directory.path, name),
		target = managed,
	})
	if not hook_ok then
		return nil, "existing markdown-preview link revalidation hook failed: " .. tostring(hook_err)
	end
	local rechecked, recheck_err = relative_entry(directory.fd, name)
	if not rechecked or not same_object(existing.stat, rechecked.stat, "link") or rechecked.target ~= managed then
		return nil,
			"existing markdown-preview link changed before revalidation: " .. tostring(
				recheck_err or "identity mismatch"
			)
	end
	local managed_after, managed_err = fingerprint(managed)
	if not managed_after or not vim.deep_equal(managed_after, baseline) then
		return nil, managed_err or "attested binary fingerprint drifted during link revalidation"
	end
	local final, final_err = relative_entry(directory.fd, name)
	if
		not final
		or not same_object(rechecked.stat, final.stat, "link")
		or final.target ~= managed
		or not directory_is_bound(directory)
	then
		return nil,
			"existing markdown-preview link or bin directory changed during revalidation: " .. tostring(
				final_err or "identity mismatch"
			)
	end
	return true
end

function M.repair(plugin_root, record)
	local platform_name = M.expected_name()
	if not platform_name or type(record) ~= "table" or record.status ~= "succeeded" then
		return nil, "attested tool is unavailable"
	end
	local identity = record.identity
	local plan = record.plan
	local proof = record.proof
	if
		type(identity) ~= "table"
		or identity.backend ~= "release"
		or identity.name ~= "markdown-preview"
		or type(plan) ~= "table"
		or type(plan.manifest) ~= "table"
		or type(plan.manifest.integrity) ~= "table"
		or type(proof) ~= "table"
		or proof.kind ~= "release-sha256"
		or type(proof.commands) ~= "table"
	then
		return nil, "attested tool proof is invalid"
	end
	local command = "markdown-preview"
	local relative = plan.manifest.integrity.commands and plan.manifest.integrity.commands[command]
	local baseline = proof.commands[command]
	if type(relative) ~= "string" or type(baseline) ~= "table" then
		return nil, "attested command proof is missing"
	end
	local root = exact_directory(identity.install_root)
	if not root or root ~= vim.fs.normalize(identity.install_root) then
		return nil, "attested install root is unsafe"
	end
	local managed = vim.fs.normalize(vim.fs.joinpath(root, relative))
	if not contained(managed, root) then
		return nil, "attested binary escaped its install root"
	end
	local current, fingerprint_err = fingerprint(managed)
	if not current or not vim.deep_equal(current, baseline) then
		return nil, fingerprint_err or "attested binary fingerprint drifted"
	end

	local canonical_root = exact_directory(plugin_root)
	if not canonical_root then
		return nil, "markdown-preview plugin root is unavailable"
	end
	local app = exact_directory(vim.fs.joinpath(canonical_root, "app"), canonical_root)
	local bin = app and exact_directory(vim.fs.joinpath(app, "bin"), canonical_root) or nil
	if not app or not bin then
		return nil, "markdown-preview bin directory is unsafe"
	end
	local link = vim.fs.joinpath(bin, platform_name)
	if not contained(link, canonical_root) then
		return nil, "markdown-preview link escaped the plugin root"
	end
	local directory, directory_err = open_directory(bin)
	if not directory then
		return nil, "could not pin markdown-preview bin directory: " .. tostring(directory_err)
	end
	local existing, existing_err = relative_entry(directory.fd, platform_name)
	if existing == nil then
		close_fd(directory.fd)
		return nil, "could not inspect markdown-preview binary: " .. tostring(existing_err)
	end
	if existing then
		if existing.stat.type == "link" then
			local valid, validation_err
			if existing.target == managed then
				valid, validation_err = revalidate_existing_link(directory, platform_name, managed, baseline, existing)
			end
			close_fd(directory.fd)
			if valid then
				return true
			end
			if validation_err then
				return nil, validation_err
			end
			return nil, "refusing to replace an existing markdown-preview binary"
		end
		if existing.stat.type == "file" then
			local adopted, adopt_err = adopt_legacy(directory, platform_name, managed, baseline, existing)
			close_fd(directory.fd)
			return adopted, adopt_err
		end
		close_fd(directory.fd)
		return nil, "refusing to replace an existing markdown-preview binary"
	end
	if not directory_is_bound(directory) then
		close_fd(directory.fd)
		return nil, "markdown-preview bin directory changed before symlink publication"
	end
	-- POSIX does not lock a directory against rename. Keep creation and rollback
	-- bound to the validated inode, then reject any pathname-identity drift.
	if ffi.C.symlinkat(managed, directory.fd, platform_name) ~= 0 then
		local create_err = "errno " .. tostring(ffi.errno())
		close_fd(directory.fd)
		return nil, "could not create markdown-preview symlink without clobbering: " .. create_err
	end
	local published, published_err = relative_entry(directory.fd, platform_name)
	if not published or published.stat.type ~= "link" or published.target ~= managed then
		close_fd(directory.fd)
		return nil,
			"markdown-preview symlink publication was not exact; no safe rollback identity was available: " .. tostring(
				published_err or "identity mismatch"
			)
	end
	local function fail_published(message)
		local rolled_back, rollback_err = rollback_link(directory, platform_name, published)
		close_fd(directory.fd)
		if not rolled_back then
			return nil, message .. "; descriptor-relative rollback failed: " .. tostring(rollback_err)
		end
		return nil, message
	end
	if not directory_is_bound(directory) then
		return fail_published("markdown-preview bin directory changed during symlink publication")
	end
	local after = fingerprint(managed)
	if not after or not vim.deep_equal(after, baseline) then
		return fail_published("attested binary changed during symlink publication")
	end
	local final, final_err = relative_entry(directory.fd, platform_name)
	if
		not final
		or not same_object(published.stat, final.stat, "link")
		or final.target ~= managed
		or not directory_is_bound(directory)
	then
		return fail_published(
			"markdown-preview symlink or bin directory changed after publication: "
				.. tostring(final_err or "identity mismatch")
		)
	end
	close_fd(directory.fd)
	return true
end

return M
