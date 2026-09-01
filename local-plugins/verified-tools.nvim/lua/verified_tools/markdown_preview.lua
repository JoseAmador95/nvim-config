local M = {}

local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	ffi_ok = pcall(
		ffi.cdef,
		[[
		int fcntl(int fd, int cmd, ...);
		int openat(int fd, const char *path, int flags, ...);
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

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function same_stat(left, right)
	return left
		and right
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mtime.sec == right.mtime.sec
		and left.mtime.nsec == right.mtime.nsec
end

local function same_object(left, right, kind)
	return left
		and right
		and left.type == kind
		and right.type == kind
		and left.dev == right.dev
		and left.ino == right.ino
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
	return true
end

local function fingerprint(path)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" or before.nlink ~= 1 or vim.fn.executable(path) ~= 1 then
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
		mtime_sec = first.mtime.sec,
		mtime_nsec = first.mtime.nsec,
		sha256 = vim.fn.sha256(table.concat(chunks)),
	}
end

local function exact_directory(path, expected_parent)
	local stat = uv.fs_lstat(path)
	local canonical = stat and stat.type == "directory" and uv.fs_realpath(path) or nil
	if not canonical or (expected_parent and not contained(canonical, expected_parent)) then
		return nil
	end
	return vim.fs.normalize(canonical)
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
		local current_parent = directory_is_bound(directory)
		close_fd(directory.fd)
		if existing.stat.type == "link" and existing.target == managed and current_parent then
			return true
		end
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
