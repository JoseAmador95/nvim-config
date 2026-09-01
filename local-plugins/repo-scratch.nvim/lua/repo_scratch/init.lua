local M = {}

local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")
local descriptor_api
local descriptor_api_error

if ffi_ok and ffi.abi("64bit") then
	local declared, declare_err = pcall(
		ffi.cdef,
		[[
		int openat(int dirfd, const char *pathname, int flags, ...);
		int mkdirat(int dirfd, const char *pathname, unsigned int mode);
		int renameatx_np(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
		int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
		int unlinkat(int dirfd, const char *pathname, int flags);
		int fstatat(int dirfd, const char *pathname, void *status, int flags);
		int dup(int fd);
		int fcntl(int fd, int command, ...);
		void *fdopendir(int fd);
		void *readdir(void *directory);
		int closedir(void *directory);
		char *strerror(int error_number);
		struct repo_scratch_darwin_dirent {
			uint64_t d_ino;
			uint64_t d_seekoff;
			uint16_t d_reclen;
			uint16_t d_namlen;
			uint8_t d_type;
			char d_name[1024];
		};
		struct repo_scratch_linux_dirent {
			uint64_t d_ino;
			int64_t d_off;
			uint16_t d_reclen;
			uint8_t d_type;
			char d_name[256];
		};
		struct repo_scratch_darwin_stat {
			int32_t st_dev_value;
			uint16_t st_mode_value;
			uint16_t st_nlink_value;
			uint64_t st_ino_value;
			uint32_t st_uid_value;
			uint32_t st_gid_value;
			int32_t st_rdev_value;
			int32_t st_padding;
			int64_t st_atime_sec;
			int64_t st_atime_nsec;
			int64_t st_mtime_sec;
			int64_t st_mtime_nsec;
			int64_t st_ctime_sec;
			int64_t st_ctime_nsec;
			int64_t st_birthtime_sec;
			int64_t st_birthtime_nsec;
			int64_t st_size_value;
			int64_t st_blocks_value;
			int32_t st_blksize_value;
			uint32_t st_flags_value;
			uint32_t st_gen_value;
			int32_t st_lspare_value;
			int64_t st_qspare[2];
		};
		struct repo_scratch_statx_timestamp {
			int64_t tv_sec;
			uint32_t tv_nsec;
			int32_t reserved;
		};
		struct repo_scratch_linux_statx {
			uint32_t stx_mask;
			uint32_t stx_blksize;
			uint64_t stx_attributes;
			uint32_t stx_nlink;
			uint32_t stx_uid;
			uint32_t stx_gid;
			uint16_t stx_mode;
			uint16_t spare0[1];
			uint64_t stx_ino;
			uint64_t stx_size;
			uint64_t stx_blocks;
			uint64_t stx_attributes_mask;
			struct repo_scratch_statx_timestamp stx_atime;
			struct repo_scratch_statx_timestamp stx_btime;
			struct repo_scratch_statx_timestamp stx_ctime;
			struct repo_scratch_statx_timestamp stx_mtime;
			uint32_t stx_rdev_major;
			uint32_t stx_rdev_minor;
			uint32_t stx_dev_major;
			uint32_t stx_dev_minor;
			uint64_t spare2[14];
		};
		int statx(int dirfd, const char *pathname, int flags, unsigned int mask,
			struct repo_scratch_linux_statx *status);
	]]
	)
	if not declared and tostring(declare_err):find("redefin", 1, true) then
		-- A module reload sees the process-wide FFI declarations from the first load.
		declared = true
	end
	if declared then
		local sysname = uv.os_uname().sysname
		if sysname == "Darwin" then
			descriptor_api = {
				C = ffi.C,
				O_RDONLY = 0,
				O_WRONLY = 1,
				O_RDWR = 2,
				O_NONBLOCK = 0x00000004,
				O_CREAT = 0x00000200,
				O_EXCL = 0x00000800,
				O_NOFOLLOW = 0x00000100,
				O_DIRECTORY = 0x00100000,
				O_CLOEXEC = 0x01000000,
				AT_REMOVEDIR = 0x0080,
				AT_SYMLINK_NOFOLLOW = 0x0020,
				EEXIST = 17,
				ENOENT = 2,
				ELOOP = 62,
				dirent = "darwin",
				exclusive_rename = "renameatx_np",
				exclusive_rename_flag = 0x00000004,
				exchange_rename_flag = 0x00000002,
			}
		elseif sysname == "Linux" then
			descriptor_api = {
				C = ffi.C,
				O_RDONLY = 0,
				O_WRONLY = 1,
				O_RDWR = 2,
				O_NONBLOCK = 0x00000800,
				O_CREAT = 0x00000040,
				O_EXCL = 0x00000080,
				O_NOFOLLOW = 0x00020000,
				O_DIRECTORY = 0x00010000,
				O_CLOEXEC = 0x00080000,
				AT_REMOVEDIR = 0x0200,
				AT_SYMLINK_NOFOLLOW = 0x0100,
				EEXIST = 17,
				ENOENT = 2,
				ELOOP = 40,
				dirent = "linux",
				exclusive_rename = "renameat2",
				exclusive_rename_flag = 0x00000001,
				exchange_rename_flag = 0x00000002,
			}
		else
			descriptor_api_error = "repo-scratch requires Darwin or Linux descriptor-relative filesystem APIs"
		end
	else
		descriptor_api_error = "could not declare descriptor-relative filesystem APIs: " .. tostring(declare_err)
	end
else
	descriptor_api_error = "repo-scratch requires 64-bit LuaJIT FFI for descriptor-relative filesystem APIs"
end

local options = {
	max_age_seconds = 30 * 24 * 60 * 60,
	lease_seconds = 5 * 60,
	now = os.time,
	root = nil,
	event = nil,
}
local handles = {}
local sequence = 0
local MAX_STATE_BYTES = 1024 * 1024
local MAX_LOCK_BYTES = 4096
local MAX_LEASE_BYTES = 4096
local LOCK_WAIT_MILLISECONDS = 2000
local LOCK_POLL_MILLISECONDS = 5
local test_hook

local function fire_test_hook(event, details)
	if not test_hook then
		return true
	end
	local ok, err = pcall(test_hook, event, details)
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

local function copy(value)
	return vim.deepcopy(value)
end

local function emit(kind, payload)
	if type(options.event) ~= "function" then
		return
	end
	local event = copy(payload or {})
	event.kind = kind
	pcall(options.event, event)
end

local function missing_error(err)
	return err ~= nil and tostring(err):find("ENOENT", 1, true) ~= nil
end

local function same_identity(left, right)
	return left and right and left.dev == right.dev and left.ino == right.ino
end

local function raw_lstat(path)
	local info, err = uv.fs_lstat(path)
	if not info and err and not missing_error(err) then
		return nil, err
	end
	return info
end

local function descriptor_error(operation, number)
	number = number or ffi.errno()
	local name = number == descriptor_api.ENOENT and "ENOENT"
		or number == descriptor_api.EEXIST and "EEXIST"
		or number == descriptor_api.ELOOP and "ELOOP"
		or ("errno " .. tostring(number))
	return ("%s: %s: %s"):format(name, operation, ffi.string(descriptor_api.C.strerror(number)))
end

local function close_fd(fd)
	if fd then
		return uv.fs_close(fd)
	end
	return true
end

local function sync_directory_fd(fd, details)
	local before_ok, before_err = fire_test_hook("before_parent_fsync", details)
	if not before_ok then
		return nil, "directory fsync was skipped by hook: " .. tostring(before_err)
	end
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return nil, "could not fsync state directory: " .. tostring(sync_err)
	end
	local after_ok, after_err = fire_test_hook("after_parent_fsync", details)
	if not after_ok then
		return true, "directory fsync completion hook failed: " .. tostring(after_err)
	end
	return true
end

local function close_mutation_fd(fd, details)
	local closed, close_err = close_fd(fd)
	local hook_ok, hook_err = fire_test_hook("after_mutation_close", details)
	local warning
	if not closed then
		warning = "could not close mutation parent descriptor: " .. tostring(close_err)
	end
	if not hook_ok then
		warning = append_warning(warning, "mutation close hook failed: " .. tostring(hook_err))
	end
	return closed and hook_ok and true or nil, warning
end

local function duplicate_fd(fd)
	local duplicated = tonumber(descriptor_api.C.dup(fd))
	if duplicated < 0 then
		return nil, descriptor_error("could not duplicate state directory descriptor")
	end
	-- F_SETFD and FD_CLOEXEC have the same values on Darwin and Linux.
	if descriptor_api.C.fcntl(duplicated, 2, ffi.new("int", 1)) ~= 0 then
		local err = descriptor_error("could not secure duplicated state directory descriptor")
		close_fd(duplicated)
		return nil, err
	end
	return duplicated
end

local function directory_open_flags()
	return bit.bor(
		descriptor_api.O_RDONLY,
		descriptor_api.O_DIRECTORY,
		descriptor_api.O_NOFOLLOW,
		descriptor_api.O_CLOEXEC
	)
end

local function open_directory_chain(path)
	if not descriptor_api then
		return nil, descriptor_api_error
	end
	path = vim.fs.normalize(vim.fs.abspath(path))
	if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
		return nil, "state directory path must be an absolute path without NUL bytes"
	end
	local fd = tonumber(descriptor_api.C.openat(-2, "/", directory_open_flags()))
	if fd < 0 then
		return nil, descriptor_error("could not open filesystem root")
	end
	for part in path:gmatch("[^/]+") do
		if part == "." or part == ".." then
			close_fd(fd)
			return nil, "state directory path contains an unsafe component"
		end
		local child = tonumber(descriptor_api.C.openat(fd, part, directory_open_flags()))
		if child < 0 then
			local err = descriptor_error("could not open state directory component " .. part)
			close_fd(fd)
			return nil, err
		end
		local child_stat, stat_err = uv.fs_fstat(child)
		close_fd(fd)
		if not child_stat or child_stat.type ~= "directory" then
			close_fd(child)
			return nil, "state directory component is not a directory: " .. tostring(stat_err or part)
		end
		fd = child
	end
	return fd
end

local function close_root()
	if options.root and options.root.fd then
		close_fd(options.root.fd)
	end
	options.root = nil
end

local function verify_root_anchor()
	local root = options.root
	if not root or not root.fd then
		return nil, "state root is not open"
	end
	local pinned, pinned_err = uv.fs_fstat(root.fd)
	if not pinned or pinned.type ~= "directory" or not same_identity(pinned, root.identity) then
		return nil, "pinned state root identity changed: " .. tostring(pinned_err or "identity mismatch")
	end
	local requested, requested_err = raw_lstat(options.state_root)
	if requested_err then
		return nil, "could not inspect configured state root: " .. tostring(requested_err)
	end
	if not requested or requested.type ~= "directory" then
		return nil, "refusing symlinked or non-directory state root: " .. options.state_root
	end
	local resolved = uv.fs_realpath(options.state_root)
	if not resolved or vim.fs.normalize(resolved) ~= root.path then
		return nil, "state root or one of its ancestors changed"
	end
	local reopened, reopen_err = open_directory_chain(root.path)
	if not reopened then
		return nil, reopen_err
	end
	local current, current_err = uv.fs_fstat(reopened)
	local closed, close_err = close_fd(reopened)
	if not current or current.type ~= "directory" or not same_identity(current, root.identity) then
		return nil, "state root or one of its ancestors changed: " .. tostring(current_err or "identity mismatch")
	end
	if not closed then
		return nil, "could not close revalidated state root: " .. tostring(close_err)
	end
	return true
end

local function create_or_open_root(requested)
	local ancestor = requested
	local missing = {}
	local stat, stat_err = raw_lstat(ancestor)
	if stat_err then
		return nil, "could not inspect state directory: " .. tostring(stat_err)
	end
	while not stat do
		table.insert(missing, 1, vim.fs.basename(ancestor))
		local parent = vim.fs.dirname(ancestor)
		if parent == ancestor then
			return nil, "could not resolve state directory parent"
		end
		ancestor = parent
		stat, stat_err = raw_lstat(ancestor)
		if stat_err then
			return nil, "could not inspect state directory parent: " .. tostring(stat_err)
		end
	end
	if stat.type ~= "directory" then
		return nil, "state path is symlinked or not a directory: " .. ancestor
	end
	local current = uv.fs_realpath(ancestor)
	if not current then
		return nil, "could not resolve state directory ancestor"
	end
	current = vim.fs.normalize(current)
	local fd, open_err = open_directory_chain(current)
	if not fd then
		return nil, open_err
	end
	local warning
	for _, part in ipairs(missing) do
		local made = descriptor_api.C.mkdirat(fd, part, tonumber("700", 8)) == 0
		if not made then
			local number = ffi.errno()
			if number ~= descriptor_api.EEXIST then
				local err = descriptor_error("could not create safe state directory " .. part, number)
				close_fd(fd)
				return nil, err
			end
		end
		if made then
			local _, sync_err = sync_directory_fd(fd, {
				operation = "mkdir",
				path = vim.fs.joinpath(current, part),
				role = "parent",
				committed = true,
			})
			warning = append_warning(warning, sync_err)
		end
		local child = tonumber(descriptor_api.C.openat(fd, part, directory_open_flags()))
		if child < 0 then
			local err = descriptor_error("could not open safe state directory " .. part)
			close_fd(fd)
			return nil, err
		end
		local child_stat, child_err = uv.fs_fstat(child)
		local secured, secure_err = child_stat and uv.fs_fchmod(child, tonumber("700", 8)) or nil
		if made then
			local _, close_err = close_mutation_fd(fd, {
				operation = "mkdir",
				path = vim.fs.joinpath(current, part),
				role = "parent",
				committed = true,
			})
			warning = append_warning(warning, close_err)
		else
			close_fd(fd)
		end
		if not child_stat or child_stat.type ~= "directory" or not secured then
			close_fd(child)
			return nil, "could not secure state directory: " .. tostring(child_err or secure_err or "unsafe directory")
		end
		fd = child
		current = vim.fs.joinpath(current, part)
	end
	local identity, identity_err = uv.fs_fstat(fd)
	local secured, secure_err = identity and uv.fs_fchmod(fd, tonumber("700", 8)) or nil
	if not identity or identity.type ~= "directory" or not secured then
		close_fd(fd)
		return nil, "could not secure state root: " .. tostring(identity_err or secure_err or "unsafe directory")
	end
	local resolved = uv.fs_realpath(requested)
	if not resolved or vim.fs.normalize(resolved) ~= current then
		close_fd(fd)
		return nil, "state root or one of its ancestors changed while it was created"
	end
	local reopened, reopen_err = open_directory_chain(current)
	if not reopened then
		close_fd(fd)
		return nil, reopen_err
	end
	local reopened_stat = uv.fs_fstat(reopened)
	close_fd(reopened)
	if not same_identity(identity, reopened_stat) then
		close_fd(fd)
		return nil, "state root or one of its ancestors changed while it was opened"
	end
	return { path = current, fd = fd, identity = { dev = identity.dev, ino = identity.ino } }, warning
end

local function ensure_root()
	if type(options.state_root) ~= "string" or options.state_root == "" then
		return nil, "state_root is required"
	end
	if not descriptor_api then
		return nil, descriptor_api_error
	end
	if options.root then
		local valid, valid_err = verify_root_anchor()
		return valid and options.root.path or nil, valid and nil or valid_err
	end
	local root, root_warning_or_err = create_or_open_root(options.state_root)
	if not root then
		return nil, root_warning_or_err
	end
	options.root = root
	return root.path, root_warning_or_err
end

local function relative_components(path)
	if not options.root then
		return nil, "state root is not open"
	end
	path = vim.fs.normalize(vim.fs.abspath(path))
	local root = options.root.path
	local relative
	if path == root then
		relative = ""
	elseif root == "/" then
		relative = path:sub(2)
	elseif path:sub(1, #root + 1) == root .. "/" then
		relative = path:sub(#root + 2)
	else
		return nil, "path escapes the validated state root: " .. path
	end
	local parts = {}
	for part in relative:gmatch("[^/]+") do
		if part == "." or part == ".." or part:find("\0", 1, true) then
			return nil, "state path contains an unsafe component"
		end
		parts[#parts + 1] = part
	end
	return parts
end

local function anchored_parent(path)
	local parts, parts_err = relative_components(path)
	if not parts then
		return nil, nil, parts_err
	end
	if #parts == 0 then
		return nil, nil, "operation requires a direct or nested child of the state root"
	end
	local fd, duplicate_err = duplicate_fd(options.root.fd)
	if not fd then
		return nil, nil, duplicate_err
	end
	for index = 1, #parts - 1 do
		local child = tonumber(descriptor_api.C.openat(fd, parts[index], directory_open_flags()))
		if child < 0 then
			local err = descriptor_error("could not open anchored state directory " .. parts[index])
			close_fd(fd)
			return nil, nil, err
		end
		local stat, stat_err = uv.fs_fstat(child)
		close_fd(fd)
		if not stat or stat.type ~= "directory" then
			close_fd(child)
			return nil, nil, "anchored state parent is unsafe: " .. tostring(stat_err or parts[index])
		end
		fd = child
	end
	return fd, parts[#parts]
end

local function anchored_open(path, flags, mode)
	local parent, name, parent_err = anchored_parent(path)
	if not parent then
		return nil, parent_err
	end
	flags = bit.bor(flags, descriptor_api.O_NOFOLLOW, descriptor_api.O_CLOEXEC)
	local fd
	if mode then
		fd = tonumber(descriptor_api.C.openat(parent, name, flags, ffi.new("unsigned int", mode)))
	else
		fd = tonumber(descriptor_api.C.openat(parent, name, flags))
	end
	local number = fd < 0 and ffi.errno() or nil
	if fd < 0 then
		close_fd(parent)
		return nil, descriptor_error("could not open anchored state entry " .. name, number), number
	end
	local warning
	if bit.band(flags, descriptor_api.O_CREAT) ~= 0 then
		local _, sync_err = sync_directory_fd(parent, {
			operation = "create",
			path = path,
			role = "parent",
			committed = true,
		})
		warning = append_warning(warning, sync_err)
		local _, close_err = close_mutation_fd(parent, {
			operation = "create",
			path = path,
			role = "parent",
			committed = true,
		})
		warning = append_warning(warning, close_err)
	else
		local closed, close_err = close_fd(parent)
		if not closed then
			warning = "could not close anchored state parent: " .. tostring(close_err)
		end
	end
	return fd, warning
end

local anchored_stat

local function anchored_list(path)
	local normalized = vim.fs.normalize(vim.fs.abspath(path))
	local fd, open_err
	if normalized == options.root.path then
		fd = tonumber(descriptor_api.C.openat(options.root.fd, ".", directory_open_flags()))
		if fd < 0 then
			open_err = descriptor_error("could not open anchored state root for enumeration")
			fd = nil
		end
	else
		fd, open_err = anchored_open(normalized, bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_DIRECTORY))
	end
	if not fd then
		return nil, open_err
	end
	local directory = descriptor_api.C.fdopendir(fd)
	if directory == nil then
		local err = descriptor_error("could not enumerate anchored state directory")
		close_fd(fd)
		return nil, err
	end
	local entries = {}
	while true do
		ffi.errno(0)
		local raw = descriptor_api.C.readdir(directory)
		if raw == nil then
			local number = ffi.errno()
			if descriptor_api.C.closedir(directory) ~= 0 then
				return nil, descriptor_error("could not close anchored state directory enumeration")
			end
			if number ~= 0 then
				return nil, descriptor_error("could not enumerate anchored state directory", number)
			end
			return entries
		end
		local entry = descriptor_api.dirent == "darwin" and ffi.cast("struct repo_scratch_darwin_dirent *", raw)
			or ffi.cast("struct repo_scratch_linux_dirent *", raw)
		local name = ffi.string(entry.d_name)
		if name ~= "." and name ~= ".." then
			local kind = entry.d_type == 8 and "file"
				or entry.d_type == 4 and "directory"
				or entry.d_type == 10 and "link"
				or nil
			if not kind then
				local stat, stat_err = anchored_stat(vim.fs.joinpath(normalized, name))
				if not stat then
					descriptor_api.C.closedir(directory)
					return nil, stat_err or ("state entry disappeared during enumeration: " .. name)
				end
				kind = stat.type
			end
			entries[#entries + 1] = { name = name, kind = kind }
		end
	end
end

anchored_stat = function(path)
	if options.root and vim.fs.normalize(vim.fs.abspath(path)) == options.root.path then
		return uv.fs_fstat(options.root.fd)
	end
	local fd, open_err, number = anchored_open(path, bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_NONBLOCK))
	if not fd then
		if number == descriptor_api.ENOENT then
			return nil
		end
		if number == descriptor_api.ELOOP then
			return { type = "link" }
		end
		return nil, open_err
	end
	local stat, stat_err = uv.fs_fstat(fd)
	local closed, close_err = close_fd(fd)
	if not stat then
		return nil, stat_err
	end
	if not closed then
		return nil, close_err
	end
	return stat
end

local function lstat(path)
	if options.root then
		local normalized = vim.fs.normalize(vim.fs.abspath(path))
		local root = options.root.path
		if normalized == root or root == "/" or normalized:sub(1, #root + 1) == root .. "/" then
			return anchored_stat(normalized)
		end
	end
	return raw_lstat(path)
end

local snapshot_from_parent
local directory_snapshot_from_parent
local any_snapshot_from_parent
local same_any_snapshot

local function anchored_rename_with_flag(from, to, flag, event, details)
	local from_parent, from_name, from_err = anchored_parent(from)
	if not from_parent then
		return nil, from_err
	end
	local to_parent, to_name, to_err = anchored_parent(to)
	if not to_parent then
		close_fd(from_parent)
		return nil, to_err
	end
	details = vim.tbl_extend("force", details or {}, { from = from, to = to })
	local hook_ok, hook_err = fire_test_hook(event, details)
	if not hook_ok then
		close_fd(from_parent)
		close_fd(to_parent)
		return nil, event .. " hook failed: " .. tostring(hook_err)
	end
	for _, candidate in ipairs({
		{ parent = from_parent, name = from_name, expected = details.from_snapshot, label = details.from_label },
		{ parent = to_parent, name = to_name, expected = details.to_snapshot, label = details.to_label },
	}) do
		if candidate.expected then
			local current, current_err
			if candidate.expected.generic then
				current, current_err = any_snapshot_from_parent(
					candidate.parent,
					candidate.name,
					candidate.label or "state entry",
					details.maximum or MAX_STATE_BYTES
				)
			elseif candidate.expected.directory then
				current, current_err = directory_snapshot_from_parent(
					candidate.parent,
					candidate.name,
					candidate.label or "state directory"
				)
			else
				current, current_err = snapshot_from_parent(
					candidate.parent,
					candidate.name,
					candidate.label or "state entry",
					details.maximum or MAX_STATE_BYTES,
					candidate.expected.nlink or 1
				)
			end
			if
				not current
				or (candidate.expected.generic and not same_any_snapshot(current, candidate.expected, false))
				or (not candidate.expected.generic and not candidate.expected.directory and current.data ~= candidate.expected.data)
				or (not candidate.expected.generic and not same_identity(current.stat, candidate.expected.stat))
			then
				close_fd(from_parent)
				close_fd(to_parent)
				return nil,
					(candidate.label or "state entry") .. " changed before descriptor-relative rename: " .. tostring(
						current_err or "identity mismatch"
					)
			end
		end
	end
	if details.reservation then
		local reserve_hook_ok, reserve_hook_err = fire_test_hook("before_unlink_reserve", details)
		if not reserve_hook_ok then
			close_fd(from_parent)
			close_fd(to_parent)
			return nil, "before_unlink_reserve hook failed: " .. tostring(reserve_hook_err)
		end
	end
	local syscall_hook_ok, syscall_hook_err = fire_test_hook("before_rename_syscall", details)
	if not syscall_hook_ok then
		close_fd(from_parent)
		close_fd(to_parent)
		return nil, "before_rename_syscall hook failed: " .. tostring(syscall_hook_err)
	end
	local called, result, number = pcall(function()
		local renamed
		if descriptor_api.exclusive_rename == "renameatx_np" then
			renamed = descriptor_api.C.renameatx_np(from_parent, from_name, to_parent, to_name, flag)
		else
			renamed = descriptor_api.C.renameat2(from_parent, from_name, to_parent, to_name, flag)
		end
		return renamed, renamed ~= 0 and ffi.errno() or nil
	end)
	local renamed = called and result == 0
	local rename_err = not called and ("exclusive descriptor-relative rename is unavailable: " .. tostring(result))
		or (not renamed and descriptor_error("could not rename anchored state entry", number) or nil)
	if not renamed then
		local from_closed, from_close_err = close_fd(from_parent)
		local to_closed, to_close_err = close_fd(to_parent)
		if not from_closed or not to_closed then
			rename_err = append_warning(rename_err, tostring(from_close_err or to_close_err))
		end
		return nil, rename_err
	end

	local operation = details.exchange and "exchange" or "rename"
	local warning
	local post_event = details.exchange and "after_exchange" or "after_rename"
	local post_ok, post_err = fire_test_hook(post_event, details)
	if not post_ok then
		warning = append_warning(warning, post_event .. " hook failed: " .. tostring(post_err))
	end
	for _, parent in ipairs({
		{ fd = from_parent, path = from, role = "source" },
		{ fd = to_parent, path = to, role = "target" },
	}) do
		local _, sync_err = sync_directory_fd(parent.fd, {
			operation = operation,
			path = parent.path,
			from = from,
			to = to,
			role = parent.role,
			rollback = details.rollback == true,
			committed = true,
		})
		warning = append_warning(warning, sync_err)
	end
	for _, parent in ipairs({
		{ fd = from_parent, path = from, role = "source" },
		{ fd = to_parent, path = to, role = "target" },
	}) do
		local _, close_err = close_mutation_fd(parent.fd, {
			operation = operation,
			path = parent.path,
			from = from,
			to = to,
			role = parent.role,
			rollback = details.rollback == true,
			committed = true,
		})
		warning = append_warning(warning, close_err)
	end
	return true, warning
end

local function anchored_rename(from, to, from_snapshot, label, maximum)
	return anchored_rename_with_flag(from, to, descriptor_api.exclusive_rename_flag, "before_rename", {
		exclusive = true,
		exchange = false,
		from_snapshot = from_snapshot,
		from_label = label,
		maximum = maximum,
	})
end

local function anchored_reserve(from, to, from_snapshot, label, maximum, restoring)
	return anchored_rename_with_flag(from, to, descriptor_api.exclusive_rename_flag, "before_rename", {
		exclusive = true,
		exchange = false,
		reservation = not restoring,
		restoring = restoring == true,
		from_snapshot = from_snapshot,
		from_label = label,
		maximum = maximum,
	})
end

local function anchored_exchange(from, to, from_snapshot, to_snapshot, rollback, maximum)
	return anchored_rename_with_flag(from, to, descriptor_api.exchange_rename_flag, "before_exchange", {
		exclusive = false,
		exchange = true,
		rollback = rollback == true,
		from_snapshot = from_snapshot,
		to_snapshot = to_snapshot,
		from_label = rollback and "rollback incumbent" or "staged scratch state",
		to_label = rollback and "rollback proposal" or "scratch target",
		maximum = maximum,
	})
end

snapshot_from_parent = function(parent, name, label, maximum, link_count)
	link_count = link_count or 1
	local flags =
		bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_NONBLOCK, descriptor_api.O_NOFOLLOW, descriptor_api.O_CLOEXEC)
	local fd = tonumber(descriptor_api.C.openat(parent, name, flags))
	if fd < 0 then
		return nil, descriptor_error("could not open " .. label .. " for conditional removal")
	end
	local before, before_err = uv.fs_fstat(fd)
	if not before or before.type ~= "file" or before.nlink ~= link_count or before.size > maximum then
		close_fd(fd)
		return nil,
			label .. " became unsafe before conditional removal: " .. tostring(before_err or "identity mismatch")
	end
	local chunks = {}
	local offset = 0
	while offset < before.size do
		local chunk, read_err = uv.fs_read(fd, before.size - offset, offset)
		if not chunk or #chunk == 0 then
			close_fd(fd)
			return nil, "could not read complete " .. label .. ": " .. tostring(read_err or "short read")
		end
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
	end
	local after, after_err = uv.fs_fstat(fd)
	local closed, close_err = close_fd(fd)
	if
		not after
		or after.type ~= "file"
		or after.nlink ~= link_count
		or after.size ~= before.size
		or not same_identity(before, after)
	then
		return nil,
			label .. " changed during conditional removal validation: " .. tostring(after_err or "identity mismatch")
	end
	if not closed then
		return nil, "could not close " .. label .. ": " .. tostring(close_err)
	end
	return { data = table.concat(chunks), stat = after }
end

directory_snapshot_from_parent = function(parent, name, label)
	local fd = tonumber(descriptor_api.C.openat(parent, name, directory_open_flags()))
	if fd < 0 then
		return nil, descriptor_error("could not open " .. label .. " for conditional removal")
	end
	local before, before_err = uv.fs_fstat(fd)
	if not before or before.type ~= "directory" then
		close_fd(fd)
		return nil,
			label .. " became unsafe before conditional removal: " .. tostring(before_err or "identity mismatch")
	end
	local directory = descriptor_api.C.fdopendir(fd)
	if directory == nil then
		local err = descriptor_error("could not enumerate " .. label .. " for conditional removal")
		close_fd(fd)
		return nil, err
	end
	while true do
		ffi.errno(0)
		local raw = descriptor_api.C.readdir(directory)
		if raw == nil then
			local number = ffi.errno()
			local after, after_err = uv.fs_fstat(fd)
			local closed = descriptor_api.C.closedir(directory) == 0
			if number ~= 0 then
				return nil, descriptor_error("could not enumerate " .. label, number)
			end
			if not after or after.type ~= "directory" or not same_identity(before, after) then
				return nil,
					label .. " changed during conditional removal validation: " .. tostring(
						after_err or "identity mismatch"
					)
			end
			if not closed then
				return nil, descriptor_error("could not close " .. label .. " enumeration")
			end
			return { directory = true, stat = after }
		end
		local entry = descriptor_api.dirent == "darwin" and ffi.cast("struct repo_scratch_darwin_dirent *", raw)
			or ffi.cast("struct repo_scratch_linux_dirent *", raw)
		local entry_name = ffi.string(entry.d_name)
		if entry_name ~= "." and entry_name ~= ".." then
			descriptor_api.C.closedir(directory)
			return nil, label .. " is not empty"
		end
	end
end

local function integer_key(value)
	return tostring(value):gsub("ULL$", ""):gsub("LL$", "")
end

local function entry_kind(mode)
	local kind = bit.band(mode, 0xF000)
	return kind == 0x8000 and "file"
		or kind == 0x4000 and "directory"
		or kind == 0xA000 and "link"
		or kind == 0x1000 and "fifo"
		or kind == 0x2000 and "char"
		or kind == 0x6000 and "block"
		or kind == 0xC000 and "socket"
		or "unknown"
end

local function anchored_entry_stat(parent, name, label)
	if descriptor_api.dirent == "darwin" then
		local raw = ffi.new("struct repo_scratch_darwin_stat")
		local result = descriptor_api.C.fstatat(parent, name, raw, descriptor_api.AT_SYMLINK_NOFOLLOW)
		if result ~= 0 then
			local number = ffi.errno()
			if number == descriptor_api.ENOENT then
				return false
			end
			return nil, descriptor_error("could not inspect " .. label, number)
		end
		local mode = tonumber(raw.st_mode_value)
		return {
			type = entry_kind(mode),
			dev = integer_key(raw.st_dev_value),
			ino = integer_key(raw.st_ino_value),
			mode = mode,
			nlink = tonumber(raw.st_nlink_value),
			size = tonumber(raw.st_size_value),
			mtime = { sec = integer_key(raw.st_mtime_sec), nsec = tonumber(raw.st_mtime_nsec) },
			ctime = { sec = integer_key(raw.st_ctime_sec), nsec = tonumber(raw.st_ctime_nsec) },
		}
	end

	local raw = ffi.new("struct repo_scratch_linux_statx")
	local called, result =
		pcall(descriptor_api.C.statx, parent, name, descriptor_api.AT_SYMLINK_NOFOLLOW, 0x000007FF, raw)
	if not called then
		return nil, "descriptor-relative statx is unavailable: " .. tostring(result)
	end
	if result ~= 0 then
		local number = ffi.errno()
		if number == descriptor_api.ENOENT then
			return false
		end
		return nil, descriptor_error("could not inspect " .. label, number)
	end
	local mode = tonumber(raw.stx_mode)
	return {
		type = entry_kind(mode),
		dev = integer_key(raw.stx_dev_major) .. ":" .. integer_key(raw.stx_dev_minor),
		ino = integer_key(raw.stx_ino),
		mode = mode,
		nlink = tonumber(raw.stx_nlink),
		size = tonumber(raw.stx_size),
		mtime = { sec = integer_key(raw.stx_mtime.tv_sec), nsec = tonumber(raw.stx_mtime.tv_nsec) },
		ctime = { sec = integer_key(raw.stx_ctime.tv_sec), nsec = tonumber(raw.stx_ctime.tv_nsec) },
	}
end

local function same_entry_time(left, right)
	return left and right and left.sec == right.sec and left.nsec == right.nsec
end

local function same_entry_stat(left, right, renamed)
	return left
		and right
		and left.type == right.type
		and left.dev == right.dev
		and left.ino == right.ino
		and left.mode == right.mode
		and left.nlink == right.nlink
		and left.size == right.size
		and same_entry_time(left.mtime, right.mtime)
		and (renamed or same_entry_time(left.ctime, right.ctime))
end

local function opened_matches_entry(opened, entry)
	return opened
		and entry
		and opened.type == "file"
		and entry.type == "file"
		and integer_key(opened.ino) == entry.ino
		and opened.nlink == entry.nlink
		and opened.size == entry.size
end

any_snapshot_from_parent = function(parent, name, label, maximum)
	local before, before_err = anchored_entry_stat(parent, name, label)
	if before == false then
		return false
	end
	if not before then
		return nil, before_err
	end
	local snapshot = { generic = true, entry = before }
	if before.type == "file" and before.size <= maximum then
		local exact, exact_err = snapshot_from_parent(parent, name, label, maximum, before.nlink)
		if not exact then
			return nil, exact_err
		end
		if not opened_matches_entry(exact.stat, before) then
			return nil, label .. " changed while its generic snapshot was read"
		end
		snapshot.data = exact.data
		snapshot.stat = exact.stat
	end
	local after, after_err = anchored_entry_stat(parent, name, label)
	if not after or not same_entry_stat(before, after, false) then
		return nil,
			label .. " changed while its descriptor-relative snapshot was read: " .. tostring(
				after_err or "identity mismatch"
			)
	end
	snapshot.entry = after
	return snapshot
end

same_any_snapshot = function(left, right, renamed)
	if not left or not right or not same_entry_stat(left.entry, right.entry, renamed) then
		return false
	end
	if left.data ~= nil or right.data ~= nil then
		return left.data ~= nil and right.data ~= nil and left.data == right.data
	end
	return true
end

local function current_entry_snapshot(path, label, maximum)
	local parent, name, parent_err = anchored_parent(path)
	if not parent then
		return nil, parent_err
	end
	local snapshot, snapshot_err = any_snapshot_from_parent(parent, name, label, maximum or MAX_STATE_BYTES)
	local closed, close_err = close_fd(parent)
	if not snapshot then
		return nil, snapshot_err
	end
	if not closed then
		return nil, "could not close generic snapshot parent: " .. tostring(close_err)
	end
	return snapshot
end

local function unlink_snapshot(path, directory, label, maximum)
	local parent, name, parent_err = anchored_parent(path)
	if not parent then
		return nil, parent_err
	end
	local snapshot, snapshot_err
	if directory then
		snapshot, snapshot_err = directory_snapshot_from_parent(parent, name, label)
	else
		snapshot, snapshot_err = snapshot_from_parent(parent, name, label, maximum or MAX_STATE_BYTES, 1)
	end
	local closed, close_err = close_fd(parent)
	if not snapshot then
		return nil, snapshot_err
	end
	if not closed then
		return nil, "could not close conditional removal parent: " .. tostring(close_err)
	end
	return snapshot
end

local function unlink_snapshot_matches(current, expected, directory)
	local expected_stat = expected.stat or expected
	return current and same_identity(current.stat, expected_stat) and (directory or current.data == expected.data)
end

local function anchored_unlink(path, directory, expected, label, maximum)
	label = label or (directory and "state directory" or "state entry")
	maximum = maximum or MAX_STATE_BYTES
	if not expected then
		return nil, "conditional removal requires an exact snapshot"
	end
	local hook_ok, hook_err = fire_test_hook("before_unlink", {
		path = path,
		directory = directory == true,
		conditional = true,
	})
	if not hook_ok then
		return nil, "before_unlink hook failed: " .. tostring(hook_err)
	end
	local current, current_err = unlink_snapshot(path, directory, label, maximum)
	if not unlink_snapshot_matches(current, expected, directory) then
		return nil, label .. " changed before conditional removal: " .. tostring(current_err or "identity mismatch")
	end

	local reserved
	local reserve_warning
	local reserved_moved = false
	for _ = 1, 64 do
		sequence = sequence + 1
		local token = vim.fn.sha256(table.concat({ path, uv.os_getpid(), uv.hrtime(), sequence, "unlink" }, "\0"))
		reserved = path .. ".remove." .. token
		local reserved_snapshot = directory and { directory = true, stat = current.stat } or current
		local moved, move_warning_or_err = anchored_reserve(path, reserved, reserved_snapshot, label, maximum, false)
		if moved then
			reserved_moved = true
			reserve_warning = move_warning_or_err
			break
		end
		if not tostring(move_warning_or_err):find("EEXIST", 1, true) then
			return nil, "could not reserve " .. label .. " for conditional removal: " .. tostring(move_warning_or_err)
		end
	end
	if not reserved_moved then
		return nil, "could not allocate a unique conditional removal reservation"
	end

	local reserve_hook_ok, reserve_hook_err = fire_test_hook("after_unlink_reserve", {
		path = path,
		reserved = reserved,
		directory = directory == true,
		committed = true,
	})
	if not reserve_hook_ok then
		reserve_warning =
			append_warning(reserve_warning, "after_unlink_reserve hook failed: " .. tostring(reserve_hook_err))
	end
	local function restore_reserved_entry(recovery_label)
		local recovery, recovery_err =
			current_entry_snapshot(reserved, recovery_label .. " reservation", math.max(maximum, MAX_STATE_BYTES))
		if not recovery then
			return nil,
				"recovery entry could not be proven and remains at " .. reserved .. ": " .. tostring(
					recovery_err or "missing"
				)
		end
		local restored, restore_warning_or_err =
			anchored_reserve(reserved, path, recovery, recovery_label, math.max(maximum, MAX_STATE_BYTES), true)
		if not restored then
			return nil, "recovery entry remains at " .. reserved .. ": " .. tostring(restore_warning_or_err)
		end
		local rechecked, recheck_err =
			current_entry_snapshot(path, "restored " .. recovery_label, math.max(maximum, MAX_STATE_BYTES))
		if not rechecked or not same_any_snapshot(rechecked, recovery, true) then
			return nil, "restored recovery entry changed: " .. tostring(recheck_err or "identity mismatch")
		end
		return true, restore_warning_or_err
	end
	local reserved_current, reserved_err = unlink_snapshot(reserved, directory, label .. " reservation", maximum)
	if not unlink_snapshot_matches(reserved_current, expected, directory) then
		local restored, restore_warning_or_err = restore_reserved_entry(label .. " replacement")
		if not restored then
			return nil,
				label
					.. " changed during conditional removal: "
					.. tostring(reserved_err or "identity mismatch")
					.. "; "
					.. tostring(restore_warning_or_err)
		end
		local warning = append_warning(reserve_warning, restore_warning_or_err)
		return nil,
			label
				.. " changed during conditional removal; replacement was restored"
				.. (warning and "; " .. warning or "")
	end

	local parent, name, parent_err = anchored_parent(reserved)
	if not parent then
		return nil, "could not reopen reserved " .. label .. ": " .. tostring(parent_err)
	end
	local final_hook_ok, final_hook_err = fire_test_hook("before_reserved_unlink", {
		path = path,
		reserved = reserved,
		directory = directory == true,
	})
	if not final_hook_ok then
		close_fd(parent)
		local restored, restore_err = restore_reserved_entry(label)
		return nil,
			"before_reserved_unlink hook failed: "
				.. tostring(final_hook_err)
				.. (restored and "" or "; recovery entry remains at " .. reserved .. ": " .. tostring(restore_err))
	end
	local final_current, final_err
	if directory then
		final_current, final_err = directory_snapshot_from_parent(parent, name, label .. " reservation")
	else
		final_current, final_err = snapshot_from_parent(parent, name, label .. " reservation", maximum, 1)
	end
	if not unlink_snapshot_matches(final_current, expected, directory) then
		close_fd(parent)
		local restored, restore_warning_or_err = restore_reserved_entry(label .. " replacement")
		return nil,
			label
				.. " changed immediately before conditional removal"
				.. (restored and "; replacement was restored" or "; replacement remains at " .. reserved)
				.. (restore_warning_or_err and ": " .. tostring(restore_warning_or_err) or "")
	end
	local removed = descriptor_api.C.unlinkat(parent, name, directory and descriptor_api.AT_REMOVEDIR or 0) == 0
	local remove_err = not removed and descriptor_error("could not remove reserved state entry") or nil
	if not removed then
		close_fd(parent)
		local restored, restore_err = restore_reserved_entry(label)
		return nil,
			"could not remove reserved "
				.. label
				.. ": "
				.. tostring(remove_err)
				.. (restored and "" or "; recovery entry remains at " .. reserved .. ": " .. tostring(restore_err))
	end
	local warning = reserve_warning
	local after_ok, after_err = fire_test_hook("after_unlink", {
		path = path,
		reserved = reserved,
		directory = directory == true,
		committed = true,
	})
	if not after_ok then
		warning = append_warning(warning, "after_unlink hook failed: " .. tostring(after_err))
	end
	local _, sync_err = sync_directory_fd(parent, {
		operation = "unlink",
		path = path,
		reserved = reserved,
		role = "parent",
		committed = true,
	})
	warning = append_warning(warning, sync_err)
	local _, close_err = close_mutation_fd(parent, {
		operation = "unlink",
		path = path,
		reserved = reserved,
		role = "parent",
		committed = true,
	})
	warning = append_warning(warning, close_err)
	return true, warning
end

local function anchored_mkdir(path, mode)
	local parent, name, parent_err = anchored_parent(path)
	if not parent then
		return nil, parent_err
	end
	local made = descriptor_api.C.mkdirat(parent, name, mode) == 0
	local number = not made and ffi.errno() or nil
	local make_err = not made and descriptor_error("could not create anchored state directory", number) or nil
	if not made then
		close_fd(parent)
		return nil, make_err, number
	end
	local _, sync_err = sync_directory_fd(parent, {
		operation = "mkdir",
		path = path,
		role = "parent",
		committed = true,
	})
	local _, close_err = close_mutation_fd(parent, {
		operation = "mkdir",
		path = path,
		role = "parent",
		committed = true,
	})
	return true, append_warning(sync_err, close_err)
end

local secure_directory

local function make_cas_directory(path)
	for _ = 1, 64 do
		sequence = sequence + 1
		local suffix = vim.fn.sha256(table.concat({ path, uv.os_getpid(), uv.hrtime(), sequence }, "\0")):sub(1, 12)
		local directory = path .. ".cas." .. suffix
		local made, make_warning_or_err, number = anchored_mkdir(directory, tonumber("700", 8))
		if made then
			local created, created_err = lstat(directory)
			if not created or created.type ~= "directory" then
				return nil, "new CAS quarantine changed: " .. tostring(created_err or "identity mismatch")
			end
			local identity, secure_err = secure_directory(directory, created)
			if not identity then
				anchored_unlink(directory, true, created)
				return nil, secure_err
			end
			return directory, identity, make_warning_or_err
		end
		if number ~= descriptor_api.EEXIST then
			return nil, make_warning_or_err
		end
	end
	return nil, "could not allocate a unique CAS quarantine"
end

local function publication_barrier(kind, path)
	local valid, valid_err = verify_root_anchor()
	if not valid then
		return nil, valid_err
	end
	local hook_ok, hook_err = fire_test_hook("after_root_validation", { kind = kind, path = path })
	if not hook_ok then
		return nil, "after_root_validation hook failed: " .. tostring(hook_err)
	end
	-- Recheck the pathname for fail-closed diagnostics. The publication itself is
	-- still relative to the pinned descriptor, so a later swap cannot redirect it.
	return verify_root_anchor()
end

secure_directory = function(path, expected)
	local before, before_err = lstat(path)
	if before_err then
		return nil, "could not inspect state directory: " .. tostring(before_err)
	end
	if not before or before.type ~= "directory" then
		return nil, "refusing symlinked or non-directory state root: " .. path
	end
	if expected and not same_identity(before, expected) then
		return nil, "state directory identity changed"
	end
	local fd, open_err = anchored_open(path, bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_DIRECTORY))
	if not fd then
		return nil, "could not open state directory: " .. tostring(open_err)
	end
	local opened, inspect_err = uv.fs_fstat(fd)
	if not opened or opened.type ~= "directory" or not same_identity(before, opened) then
		close_fd(fd)
		return nil, "state directory changed while it was opened: " .. tostring(inspect_err or "identity mismatch")
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("700", 8))
	local after, after_err = lstat(path)
	local closed, close_err = close_fd(fd)
	if not secured then
		return nil, "could not secure state directory: " .. tostring(secure_err)
	end
	if not after or not same_identity(opened, after) then
		return nil, "state directory changed while it was secured: " .. tostring(after_err or "identity mismatch")
	end
	if not closed then
		return nil, "could not close state directory: " .. tostring(close_err)
	end
	return after
end

local function inspect_private_file(path, label)
	local stat, stat_err = lstat(path)
	if stat_err then
		return nil, "could not inspect " .. label .. ": " .. tostring(stat_err)
	end
	if not stat then
		return false
	end
	if stat.type ~= "file" or stat.nlink ~= 1 then
		return nil, "refusing symlinked, non-regular, or hard-linked " .. label .. ": " .. path
	end
	return stat
end

local function private_file(path, label)
	local before, inspect_err = inspect_private_file(path, label)
	if inspect_err then
		return nil, inspect_err
	end
	if not before then
		return true
	end
	local fd, open_err = anchored_open(path, bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_NONBLOCK))
	if not fd then
		return nil, "could not open " .. label .. ": " .. tostring(open_err)
	end
	local opened, opened_err = uv.fs_fstat(fd)
	if not opened or opened.type ~= "file" or opened.nlink ~= 1 or not same_identity(before, opened) then
		close_fd(fd)
		return nil,
			label .. " changed or became unsafe while it was opened: " .. tostring(opened_err or "identity mismatch")
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("600", 8))
	local after, after_err = lstat(path)
	local closed, close_err = close_fd(fd)
	if not secured then
		return nil, "could not secure " .. label .. ": " .. tostring(secure_err)
	end
	if not after or after.nlink ~= 1 or not same_identity(opened, after) then
		return nil, label .. " changed while it was secured: " .. tostring(after_err or "identity mismatch")
	end
	return closed and true or nil, closed and nil or "could not close " .. label .. ": " .. tostring(close_err)
end

local function read(path, label, maximum)
	label = label or "scratch state"
	maximum = maximum or MAX_STATE_BYTES
	local before, inspect_err = inspect_private_file(path, label)
	if inspect_err then
		return nil, inspect_err
	end
	if not before then
		return nil, "missing"
	end
	if before.size > maximum then
		return nil, label .. " exceeds the size limit"
	end
	local fd, open_err = anchored_open(path, bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_NONBLOCK))
	if not fd then
		return nil, "could not open " .. label .. ": " .. tostring(open_err)
	end
	local opened, opened_err = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or opened.size > maximum
		or not same_identity(before, opened)
	then
		close_fd(fd)
		return nil,
			label .. " changed or became unsafe while it was opened: " .. tostring(opened_err or "identity mismatch")
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("600", 8))
	local data, data_err = secured and uv.fs_read(fd, opened.size, 0) or nil
	local after, after_err = lstat(path)
	local closed, close_err = close_fd(fd)
	if not secured then
		return nil, "could not secure " .. label .. ": " .. tostring(secure_err)
	end
	if not data or #data ~= opened.size then
		return nil, "could not read complete " .. label .. ": " .. tostring(data_err or "short read")
	end
	if not after or after.nlink ~= 1 or not same_identity(opened, after) then
		return nil, label .. " changed while it was read: " .. tostring(after_err or "identity mismatch")
	end
	return closed and data or nil,
		closed and nil or "could not close " .. label .. ": " .. tostring(close_err),
		closed and after or nil
end

local function write_all(fd, data)
	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			return nil, write_err or "short write"
		end
		offset = offset + written
	end
	return true
end

local function cleanup_cas_directory(directory, record, identity, record_snapshot, label, maximum)
	local current, current_err = lstat(directory)
	if not current or current.type ~= "directory" or not same_identity(current, identity) then
		return nil, "CAS quarantine identity changed: " .. tostring(current_err or "identity mismatch")
	end
	local warning
	local incumbent, incumbent_err = inspect_private_file(record, "CAS incumbent")
	if incumbent_err then
		return nil, incumbent_err
	end
	if incumbent then
		if not record_snapshot then
			return nil, "refusing to remove an unowned CAS record: " .. record
		end
		local removed, remove_warning_or_err =
			anchored_unlink(record, false, record_snapshot, label or "CAS incumbent", maximum or MAX_STATE_BYTES)
		if not removed then
			return nil, "could not remove CAS incumbent: " .. tostring(remove_warning_or_err)
		end
		warning = append_warning(warning, remove_warning_or_err)
	end
	local removed, remove_warning_or_err = anchored_unlink(directory, true, identity)
	if not removed then
		return true,
			append_warning(
				warning,
				"conditional removal committed; CAS quarantine was retained: " .. tostring(remove_warning_or_err)
			)
	end
	return true, append_warning(warning, remove_warning_or_err)
end

local function cleanup_empty_cas_directory(directory, identity)
	local current, current_err = lstat(directory)
	if not current or current.type ~= "directory" or not same_identity(current, identity) then
		return nil, "CAS quarantine identity changed: " .. tostring(current_err or "identity mismatch")
	end
	local removed, remove_warning_or_err = anchored_unlink(directory, true, identity)
	return removed and true or nil,
		removed and remove_warning_or_err or "CAS quarantine is not empty: " .. tostring(remove_warning_or_err)
end

local function restore_cas_incumbent(path, directory, record, identity, record_snapshot, label, maximum)
	local current, current_err = lstat(directory)
	if not current or current.type ~= "directory" or not same_identity(current, identity) then
		return nil, "CAS quarantine identity changed: " .. tostring(current_err or "identity mismatch")
	end
	if not record_snapshot then
		return nil, "CAS incumbent ownership is unknown; recovery copy remains at " .. record
	end
	local incumbent_data, incumbent_err, incumbent_stat =
		read(record, label or "CAS incumbent", maximum or MAX_STATE_BYTES)
	if
		not incumbent_data
		or incumbent_data ~= record_snapshot.data
		or not same_identity(incumbent_stat, record_snapshot.stat)
	then
		return nil,
			"CAS incumbent changed; recovery copy remains at " .. record .. ": " .. tostring(
				incumbent_err or "identity mismatch"
			)
	end
	local restored, restore_warning_or_err =
		anchored_rename(record, path, record_snapshot, label or "CAS incumbent", maximum or MAX_STATE_BYTES)
	if not restored then
		return nil,
			"could not restore CAS incumbent; recovery copy remains at " .. record .. ": " .. tostring(
				restore_warning_or_err
			)
	end
	local restored_data, restored_err, restored_stat =
		read(path, "restored " .. (label or "CAS incumbent"), maximum or MAX_STATE_BYTES)
	if
		not restored_data
		or restored_data ~= record_snapshot.data
		or not same_identity(restored_stat, record_snapshot.stat)
	then
		return nil, "restored CAS incumbent changed: " .. tostring(restored_err or "identity mismatch")
	end
	return true, restore_warning_or_err
end

local function exact_snapshot(path, expected, label, maximum)
	local data, read_err, stat = read(path, label, maximum)
	if not data then
		return nil, read_err
	end
	if data ~= expected.data or not same_identity(stat, expected.stat) then
		return nil, label .. " changed: identity or bytes mismatch"
	end
	return { exists = true, data = data, stat = stat }
end

local function same_any_exact(current, exact)
	return current
		and current.generic
		and current.entry.type == "file"
		and current.data == exact.data
		and same_identity(current.stat, exact.stat)
		and current.entry.nlink == exact.stat.nlink
		and current.entry.size == exact.stat.size
end

local function cleanup_exact_file(path, expected, label, maximum)
	local current, current_err = inspect_private_file(path, label)
	if current_err then
		return nil, current_err
	end
	if not current then
		return true
	end
	return anchored_unlink(path, false, expected, label, maximum)
end

local function cas_conflict(path, data, fallback, detail)
	local current, current_err = read(path)
	current = current or fallback or ""
	return nil,
		{
			kind = "conflict",
			current = current,
			proposed = data,
			revision = vim.fn.sha256(current),
			detail = detail or current_err,
		}
end

local function rollback_exchange(path, temporary, path_snapshot, temporary_snapshot, staged, data, detail)
	if not path_snapshot or not temporary_snapshot then
		return cas_conflict(
			path,
			data,
			temporary_snapshot and temporary_snapshot.data or "",
			tostring(detail) .. "; exchange sides could not be proven exact; recovery state was retained"
		)
	end
	local rolled_back, rollback_warning_or_err =
		anchored_exchange(temporary, path, temporary_snapshot, path_snapshot, true, MAX_STATE_BYTES)
	if not rolled_back then
		return cas_conflict(
			path,
			data,
			temporary_snapshot.data,
			tostring(detail) .. "; rollback refused: " .. tostring(rollback_warning_or_err)
		)
	end
	local restored, restored_err = current_entry_snapshot(path, "restored scratch target", MAX_STATE_BYTES)
	local rejected, rejected_err = current_entry_snapshot(temporary, "rejected scratch proposal", MAX_STATE_BYTES)
	if
		not restored
		or not rejected
		or not same_any_snapshot(restored, temporary_snapshot, true)
		or not same_any_snapshot(rejected, path_snapshot, true)
	then
		return cas_conflict(
			path,
			data,
			temporary_snapshot.data or "",
			tostring(detail)
				.. "; rollback result changed: "
				.. tostring(restored_err or rejected_err or "identity mismatch")
				.. (rollback_warning_or_err and "; " .. tostring(rollback_warning_or_err) or "")
		)
	end
	local cleaned, cleanup_warning_or_err
	if same_any_exact(path_snapshot, staged) then
		cleaned, cleanup_warning_or_err =
			cleanup_exact_file(temporary, rejected, "rejected scratch proposal", MAX_STATE_BYTES)
	else
		cleaned = true
		cleanup_warning_or_err = "observed exchanged entry was retained because it was not the owned staging file"
	end
	local warning = append_warning(rollback_warning_or_err, cleanup_warning_or_err)
	return cas_conflict(
		path,
		data,
		temporary_snapshot.data or "",
		tostring(detail)
			.. (cleaned and "" or "; rejected proposal retained: " .. tostring(cleanup_warning_or_err))
			.. (warning and "; " .. warning or "")
	)
end

local function publish_cas(path, data, temporary, temporary_stat, expected)
	local staged_snapshot = { exists = true, data = data, stat = temporary_stat }
	if type(expected) ~= "table" then
		cleanup_exact_file(temporary, staged_snapshot, "staged scratch state", MAX_STATE_BYTES)
		return nil, "CAS publication requires the exact prior snapshot"
	end
	local staged, staged_err = exact_snapshot(temporary, staged_snapshot, "staged scratch state", MAX_STATE_BYTES)
	if not staged then
		return nil, staged_err
	end
	local anchored, anchor_err = publication_barrier("cas", path)
	if not anchored then
		cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
		return nil, "state root changed before CAS publication: " .. tostring(anchor_err)
	end

	if expected.exists == false then
		local current, current_err = inspect_private_file(path, "scratch target")
		if current_err then
			cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
			return nil, current_err
		end
		if current then
			cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
			return cas_conflict(path, data, "")
		end
		local renamed, rename_warning_or_err =
			anchored_rename(temporary, path, staged, "staged scratch state", MAX_STATE_BYTES)
		if not renamed then
			cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
			if lstat(path) then
				return cas_conflict(path, data, "", rename_warning_or_err)
			end
			return nil, "could not publish absent-target CAS result: " .. tostring(rename_warning_or_err)
		end
		local published, published_err = exact_snapshot(path, staged, "published scratch state", MAX_STATE_BYTES)
		if not published then
			return cas_conflict(
				path,
				data,
				"",
				tostring(published_err) .. (rename_warning_or_err and "; " .. tostring(rename_warning_or_err) or "")
			)
		end
		local valid, valid_err = verify_root_anchor()
		if not valid then
			return true,
				append_warning(
					rename_warning_or_err,
					"state root changed after committed initial CAS publication: " .. tostring(valid_err)
				)
		end
		return true, rename_warning_or_err
	end

	if type(expected.data) ~= "string" or type(expected.stat) ~= "table" then
		cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
		return nil, "CAS publication requires the prior bytes and identity"
	end
	local expected_snapshot = { exists = true, data = expected.data, stat = expected.stat }
	local incumbent, incumbent_err = exact_snapshot(path, expected_snapshot, "scratch target", MAX_STATE_BYTES)
	if not incumbent then
		cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
		return cas_conflict(path, data, expected.data, incumbent_err)
	end
	local exchanged, exchange_warning_or_err =
		anchored_exchange(temporary, path, staged, incumbent, false, MAX_STATE_BYTES)
	if not exchanged then
		cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
		return cas_conflict(path, data, expected.data, exchange_warning_or_err)
	end

	local path_after, path_after_err = current_entry_snapshot(path, "published scratch state", MAX_STATE_BYTES)
	local temporary_after, temporary_after_err =
		current_entry_snapshot(temporary, "displaced scratch target", MAX_STATE_BYTES)
	if not path_after or not temporary_after then
		return cas_conflict(
			path,
			data,
			expected.data,
			"exchange result could not be proven exact; recovery state was retained: "
				.. tostring(path_after_err or temporary_after_err)
				.. (exchange_warning_or_err and "; " .. tostring(exchange_warning_or_err) or "")
		)
	end
	if not same_any_exact(path_after, staged) or not same_any_exact(temporary_after, incumbent) then
		return rollback_exchange(
			path,
			temporary,
			path_after,
			temporary_after,
			staged,
			data,
			"exchange captured a changed side"
				.. (exchange_warning_or_err and "; " .. tostring(exchange_warning_or_err) or "")
		)
	end
	local valid, valid_err = verify_root_anchor()
	if not valid then
		return rollback_exchange(
			path,
			temporary,
			path_after,
			temporary_after,
			staged,
			data,
			"state root changed: "
				.. tostring(valid_err)
				.. (exchange_warning_or_err and "; " .. tostring(exchange_warning_or_err) or "")
		)
	end
	local cleaned, cleanup_warning_or_err =
		cleanup_exact_file(temporary, temporary_after, "displaced scratch target", MAX_STATE_BYTES)
	if not cleaned then
		local committed, committed_err = exact_snapshot(path, path_after, "published scratch state", MAX_STATE_BYTES)
		if not committed then
			return nil,
				"published scratch state changed while displaced cleanup failed: " .. tostring(
					committed_err or cleanup_warning_or_err
				)
		end
		-- Publication is already durable. Keep the unproven displaced artifact for
		-- recovery, but report success so the caller advances its revision.
		return true,
			append_warning(
				exchange_warning_or_err,
				"displaced incumbent was retained for recovery: " .. tostring(cleanup_warning_or_err)
			)
	end
	local final, final_err = exact_snapshot(path, path_after, "published scratch state", MAX_STATE_BYTES)
	if not final then
		return nil, "published scratch state changed after commit: " .. tostring(final_err)
	end
	return true, append_warning(exchange_warning_or_err, cleanup_warning_or_err)
end

local function write_atomic(path, data, expected)
	local valid, valid_err = private_file(path, "scratch target")
	if not valid then
		return nil, valid_err
	end
	sequence = sequence + 1
	local temporary = ("%s.tmp.%d.%d"):format(path, uv.os_getpid(), sequence)
	local fd, create_warning_or_err = anchored_open(
		temporary,
		bit.bor(descriptor_api.O_RDWR, descriptor_api.O_CREAT, descriptor_api.O_EXCL),
		tonumber("600", 8)
	)
	if not fd then
		return nil, tostring(create_warning_or_err)
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("600", 8))
	local wrote, write_err = secured and write_all(fd, data) or nil
	local synced, sync_err = wrote and uv.fs_fsync(fd) or nil
	local temporary_stat, temporary_err = synced and uv.fs_fstat(fd) or nil
	local closed, close_err = close_fd(fd)
	if
		not wrote
		or not synced
		or not temporary_stat
		or temporary_stat.type ~= "file"
		or temporary_stat.nlink ~= 1
		or not closed
	then
		return nil,
			"could not stage scratch state; unproven staging data was retained: " .. tostring(
				secure_err or write_err or sync_err or temporary_err or close_err or "unsafe staging file"
			) .. (create_warning_or_err and "; " .. tostring(create_warning_or_err) or "")
	end
	local staged, staged_err =
		exact_snapshot(temporary, { data = data, stat = temporary_stat }, "staged scratch state", MAX_STATE_BYTES)
	if not staged then
		return nil, "temporary scratch state changed; recovery data was retained: " .. tostring(staged_err)
	end
	local _, recheck_err = inspect_private_file(path, "scratch target")
	if recheck_err then
		local _, cleanup_err = cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
		return nil,
			recheck_err .. (cleanup_err and "; staged scratch state was retained: " .. tostring(cleanup_err) or "")
	end
	if not expected then
		local _, cleanup_err = cleanup_exact_file(temporary, staged, "staged scratch state", MAX_STATE_BYTES)
		return nil,
			"atomic publication requires the exact prior snapshot"
				.. (cleanup_err and "; staged scratch state was retained: " .. tostring(cleanup_err) or "")
	end
	local published, publish_warning_or_err = publish_cas(path, data, temporary, staged.stat, expected)
	if not published then
		return nil, publish_warning_or_err
	end
	return true, append_warning(create_warning_or_err, publish_warning_or_err)
end

local function remove_cas(path, expected, label, maximum, pinned_cleanup)
	if
		type(expected) ~= "table"
		or expected.exists ~= true
		or type(expected.data) ~= "string"
		or type(expected.stat) ~= "table"
	then
		return nil, "conditional removal requires the exact prior snapshot"
	end
	local anchored, anchor_err = true, nil
	if not pinned_cleanup then
		anchored, anchor_err = publication_barrier("remove", path)
		if not anchored then
			return nil, "state root changed before conditional removal: " .. tostring(anchor_err)
		end
	end
	local directory, directory_identity_or_err, quarantine_warning = make_cas_directory(path)
	if not directory then
		return nil, "could not create removal quarantine: " .. tostring(directory_identity_or_err)
	end
	local directory_identity = directory_identity_or_err
	local record = vim.fs.joinpath(directory, "record")
	local expected_snapshot = { exists = true, data = expected.data, stat = expected.stat }
	local incumbent, incumbent_err = exact_snapshot(path, expected_snapshot, label, maximum)
	if not incumbent then
		cleanup_empty_cas_directory(directory, directory_identity)
		return nil, incumbent_err or (label .. " changed before conditional removal")
	end
	if not pinned_cleanup then
		anchored, anchor_err = publication_barrier("remove-reserve", path)
		if not anchored then
			cleanup_empty_cas_directory(directory, directory_identity)
			return nil, "state root changed before conditional removal reservation: " .. tostring(anchor_err)
		end
	end
	local moved, move_warning_or_err = anchored_rename(path, record, incumbent, label, maximum)
	if not moved then
		local _, cleanup_err = cleanup_empty_cas_directory(directory, directory_identity)
		return nil,
			"could not reserve "
				.. label
				.. " for removal: "
				.. tostring(move_warning_or_err)
				.. (cleanup_err and "; " .. cleanup_err or "")
	end
	local moved_snapshot, moved_err = exact_snapshot(record, incumbent, label, maximum)
	if not moved_snapshot then
		local replacement_data, replacement_err, replacement_stat = read(record, label, maximum)
		local restore_err
		if replacement_data and replacement_stat then
			local replacement = { exists = true, data = replacement_data, stat = replacement_stat }
			local restored, restore_warning
			restored, restore_err =
				restore_cas_incumbent(path, directory, record, directory_identity, replacement, label, maximum)
			if restored then
				restore_warning = restore_err
				local cleaned, cleanup_err = cleanup_empty_cas_directory(directory, directory_identity)
				if not cleaned then
					restore_err = "replacement was restored but quarantine cleanup failed: " .. tostring(cleanup_err)
				else
					restore_err = append_warning(restore_warning, cleanup_err)
				end
			end
		else
			restore_err = "unproven recovery entry was retained at " .. record .. ": " .. tostring(replacement_err)
		end
		return nil,
			label
				.. " changed before conditional removal: "
				.. tostring(moved_err or "identity mismatch")
				.. (restore_err and "; " .. tostring(restore_err) or "")
	end
	local cleaned, cleanup_warning_or_err =
		cleanup_cas_directory(directory, record, directory_identity, moved_snapshot, label, maximum)
	if not cleaned then
		return nil, cleanup_warning_or_err
	end
	return true, append_warning(append_warning(quarantine_warning, move_warning_or_err), cleanup_warning_or_err)
end

local function file_snapshot(path, label, maximum)
	local info, inspect_err = inspect_private_file(path, label)
	if inspect_err then
		return nil, inspect_err
	end
	if not info then
		return { exists = false }
	end
	local data, read_err, stat = read(path, label, maximum)
	if not data then
		return nil, read_err
	end
	return { exists = true, data = data, stat = stat }
end

local function decode(path, label, maximum)
	local raw, err, stat = read(path, label, maximum)
	if not raw then
		return nil, err
	end
	local ok, value = pcall(vim.json.decode, raw)
	if not ok then
		return nil, "invalid JSON state"
	end
	if type(value) ~= "table" then
		return nil, "JSON state must be an object"
	end
	return value, nil, { exists = true, data = raw, stat = stat }
end

local function key_id(key)
	if type(key) ~= "table" or type(key.repo_identity) ~= "string" or key.repo_identity == "" then
		return nil, "repo_identity is required"
	end
	if type(key.ref) ~= "string" or key.ref == "" then
		return nil, "full ref or detached OID is required"
	end
	return vim.fn.sha256(key.repo_identity .. "\0" .. key.ref)
end

local function paths(root, id)
	local path = vim.fs.joinpath(root, id .. ".md")
	return path, path .. ".meta", path .. ".lease"
end

local function process_alive(pid)
	if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then
		return nil
	end
	local called, result, _, code = pcall(uv.kill, pid, 0)
	if not called then
		return nil
	end
	if result ~= nil then
		return true
	end
	if code == "ESRCH" then
		return false
	end
	return nil
end

local function exact_fields(value, fields)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if not fields[key] then
			return false
		end
	end
	return true
end

local function lock_claim_path(base, kind, token, number)
	if kind == "choosing" then
		return base .. ".choosing." .. token
	end
	return ("%s.ticket.%020d.%s"):format(base, number, token)
end

local function write_lock_claim(path, claim)
	local data = vim.json.encode(claim) .. "\n"
	-- This deterministic O_EXCL staging path reserves the claim's unique token.
	-- Cooperative publishers therefore cannot race on the final rename.
	local temporary = path .. ".publish"
	local fd, create_warning_or_err = anchored_open(
		temporary,
		bit.bor(descriptor_api.O_RDWR, descriptor_api.O_CREAT, descriptor_api.O_EXCL),
		tonumber("600", 8)
	)
	if not fd then
		return nil, "could not create scratch arbiter staging file: " .. tostring(create_warning_or_err)
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("600", 8))
	local wrote, write_err = secured and write_all(fd, data) or nil
	local synced, sync_err = wrote and uv.fs_fsync(fd) or nil
	local opened, inspect_err = synced and uv.fs_fstat(fd) or nil
	local closed, close_err = close_fd(fd)
	if not wrote or not synced or not opened or opened.type ~= "file" or opened.nlink ~= 1 or not closed then
		return nil,
			"could not stage scratch arbiter claim; unproven staging data was retained: " .. tostring(
				secure_err or write_err or sync_err or inspect_err or close_err or "unsafe claim"
			) .. (create_warning_or_err and "; " .. tostring(create_warning_or_err) or "")
	end
	local staged, staged_err = exact_snapshot(
		temporary,
		{ exists = true, data = data, stat = opened },
		"staged scratch arbiter claim",
		MAX_LOCK_BYTES
	)
	if not staged then
		return nil, "staged scratch arbiter claim changed; recovery data was retained: " .. tostring(staged_err)
	end
	local collision, collision_err = lstat(path)
	if collision_err then
		local _, cleanup_err = cleanup_exact_file(temporary, staged, "staged scratch arbiter claim", MAX_LOCK_BYTES)
		return nil,
			"could not inspect final scratch arbiter claim path: "
				.. tostring(collision_err)
				.. (cleanup_err and "; staging claim was retained: " .. tostring(cleanup_err) or "")
	end
	if collision then
		local _, cleanup_err = cleanup_exact_file(temporary, staged, "staged scratch arbiter claim", MAX_LOCK_BYTES)
		return nil,
			"scratch arbiter claim path collision" .. (cleanup_err and "; staging claim was retained: " .. tostring(
				cleanup_err
			) or "")
	end
	local anchored, anchor_err = publication_barrier("arbiter", path)
	if not anchored then
		local _, cleanup_err = cleanup_exact_file(temporary, staged, "staged scratch arbiter claim", MAX_LOCK_BYTES)
		return nil,
			"state root changed before scratch arbiter publication: "
				.. tostring(anchor_err)
				.. (cleanup_err and "; staging claim was retained: " .. tostring(cleanup_err) or "")
	end
	local published, publish_warning_or_err =
		anchored_rename(temporary, path, staged, "staged scratch arbiter claim", MAX_LOCK_BYTES)
	if not published then
		local _, cleanup_err = cleanup_exact_file(temporary, staged, "staged scratch arbiter claim", MAX_LOCK_BYTES)
		return nil,
			"could not publish scratch arbiter claim: "
				.. tostring(publish_warning_or_err)
				.. (cleanup_err and "; staging claim was retained: " .. tostring(cleanup_err) or "")
	end
	local final, final_err = exact_snapshot(path, staged, "published scratch arbiter claim", MAX_LOCK_BYTES)
	if not final then
		return nil, "published scratch arbiter claim changed; recovery data was retained: " .. tostring(final_err)
	end
	final.warning = append_warning(create_warning_or_err, publish_warning_or_err)
	return true, final
end

local function read_lock_claim(path, expected_kind, expected_token, expected_number)
	local data, read_err, stat = read(path, "scratch arbiter claim", MAX_LOCK_BYTES)
	if not data then
		local current, current_err = lstat(path)
		if not current and not current_err then
			return nil, "missing"
		end
		return nil, read_err
	end
	local decoded_ok, claim = pcall(vim.json.decode, data)
	local fields = expected_kind == "ticket"
			and { version = true, kind = true, pid = true, token = true, number = true }
		or { version = true, kind = true, pid = true, token = true }
	if
		not decoded_ok
		or not exact_fields(claim, fields)
		or claim.version ~= 1
		or claim.kind ~= expected_kind
		or type(claim.pid) ~= "number"
		or claim.pid < 1
		or claim.pid % 1 ~= 0
		or claim.token ~= expected_token
		or #claim.token ~= 64
		or not claim.token:match("^[0-9a-f]+$")
		or (expected_kind == "ticket" and claim.number ~= expected_number)
	then
		return nil, "scratch arbiter claim metadata is invalid"
	end
	return claim, nil, { exists = true, data = data, stat = stat }
end

local function remove_unique_claim(path, snapshot)
	local removed, remove_warning_or_err = remove_cas(path, snapshot, "scratch arbiter claim", MAX_LOCK_BYTES, true)
	if removed then
		return true, remove_warning_or_err
	end
	local current, current_err = lstat(path)
	if not current and not current_err then
		-- Another cooperative reclaimer reserved the same exact dead claim.
		return true,
			"scratch arbiter claim removal completed with retained recovery state: " .. tostring(remove_warning_or_err)
	end
	return nil, tostring(remove_warning_or_err)
end

local function remove_owned_claim(path, snapshot)
	if
		type(snapshot) ~= "table"
		or snapshot.exists ~= true
		or type(snapshot.data) ~= "string"
		or type(snapshot.stat) ~= "table"
	then
		return nil, "owned scratch arbiter claim snapshot is missing"
	end
	return remove_unique_claim(path, snapshot)
end

local function collect_lock_claims(base)
	local legacy, legacy_err = lstat(base)
	if legacy_err then
		return nil, "could not inspect legacy scratch arbiter: " .. tostring(legacy_err)
	end
	if legacy then
		return nil, "legacy scratch arbiter is unsafe and must be removed manually"
	end
	local directory = vim.fs.dirname(base)
	local basename = vim.fs.basename(base):gsub("([^%w])", "%%%1")
	local claims = {}
	local entries, entries_err = anchored_list(directory)
	if not entries then
		return nil, "could not enumerate scratch arbiter claims: " .. tostring(entries_err)
	end
	local listed, list_err = pcall(function()
		for _, entry in ipairs(entries) do
			local name = entry.name
			local token = name:match("^" .. basename .. "%.choosing%.([0-9a-f]+)$")
			local number
			local kind
			if token then
				kind = "choosing"
			else
				local encoded
				encoded, token = name:match("^" .. basename .. "%.ticket%.(%d+)%.([0-9a-f]+)$")
				if encoded then
					number = tonumber(encoded)
					kind = "ticket"
				end
			end
			if kind then
				if #token ~= 64 or (kind == "ticket" and (not number or number < 1 or number % 1 ~= 0)) then
					error("scratch arbiter claim filename is invalid: " .. name)
				end
				local claim_path = vim.fs.joinpath(directory, name)
				local claim, claim_err, snapshot = read_lock_claim(claim_path, kind, token, number)
				if not claim and claim_err ~= "missing" then
					error("unsafe scratch arbiter claim " .. name .. ": " .. tostring(claim_err))
				end
				if claim then
					claim.path = claim_path
					claim.snapshot = snapshot
					claims[#claims + 1] = claim
				end
			end
		end
	end)
	if not listed then
		return nil, tostring(list_err)
	end
	return claims
end

local function live_lock_claims(base, owned)
	local claims, claims_err = collect_lock_claims(base)
	if not claims then
		return nil, claims_err
	end
	local live = {}
	local owned_found = owned == nil
	for _, claim in ipairs(claims) do
		if owned and claim.path == owned.path then
			owned_found = true
			if
				claim.snapshot.data ~= owned.snapshot.data
				or not same_identity(claim.snapshot.stat, owned.snapshot.stat)
			then
				return nil, "owned scratch arbiter claim was replaced"
			end
		end
		local alive = process_alive(claim.pid)
		if alive == false then
			local removed, remove_err = remove_unique_claim(claim.path, claim.snapshot)
			if not removed then
				return nil, "could not reclaim dead scratch arbiter claim: " .. tostring(remove_err)
			end
		elseif alive == nil then
			return nil, "could not determine scratch arbiter owner liveness for process " .. tostring(claim.pid)
		else
			live[#live + 1] = claim
		end
	end
	if not owned_found then
		return nil, "owned scratch arbiter claim disappeared"
	end
	return live
end

local function release_arbiter(lock)
	return remove_owned_claim(lock.path, lock.snapshot)
end

local function acquire_arbiter(path)
	local base = path .. ".lock"
	local pid = uv.os_getpid()
	local token = vim.fn.sha256(table.concat({ base, tostring(pid), tostring(uv.hrtime()), tostring({}) }, "\0"))
	local choosing_path = lock_claim_path(base, "choosing", token)
	local created, choosing_snapshot_or_err = write_lock_claim(choosing_path, {
		version = 1,
		kind = "choosing",
		pid = pid,
		token = token,
	})
	if not created then
		return nil, choosing_snapshot_or_err
	end
	local choosing_snapshot = choosing_snapshot_or_err
	local lock_warning = choosing_snapshot.warning
	local scan_ok, scan_err = fire_test_hook("before_claim_scan", {
		phase = "choosing",
		path = choosing_path,
	})
	if not scan_ok then
		remove_owned_claim(choosing_path, choosing_snapshot)
		return nil, "before_claim_scan hook failed: " .. tostring(scan_err)
	end
	local claims, claims_err = live_lock_claims(base, { path = choosing_path, snapshot = choosing_snapshot })
	if not claims then
		remove_owned_claim(choosing_path, choosing_snapshot)
		return nil, claims_err
	end
	local maximum = 0
	for _, claim in ipairs(claims) do
		if claim.kind == "ticket" then
			maximum = math.max(maximum, claim.number)
		end
	end
	if maximum >= 9007199254740991 then
		remove_owned_claim(choosing_path, choosing_snapshot)
		return nil, "scratch arbiter ticket space is exhausted"
	end
	local number = maximum + 1
	local ticket_path = lock_claim_path(base, "ticket", token, number)
	local ticket_snapshot_or_err
	created, ticket_snapshot_or_err = write_lock_claim(ticket_path, {
		version = 1,
		kind = "ticket",
		pid = pid,
		token = token,
		number = number,
	})
	if not created then
		remove_owned_claim(choosing_path, choosing_snapshot)
		return nil, ticket_snapshot_or_err
	end
	local ticket_snapshot = ticket_snapshot_or_err
	lock_warning = append_warning(lock_warning, ticket_snapshot.warning)
	local removed, remove_warning_or_err = remove_owned_claim(choosing_path, choosing_snapshot)
	if not removed then
		remove_owned_claim(ticket_path, ticket_snapshot)
		return nil, "could not finish scratch arbiter choice: " .. tostring(remove_warning_or_err)
	end
	lock_warning = append_warning(lock_warning, remove_warning_or_err)

	local deadline = uv.hrtime() + LOCK_WAIT_MILLISECONDS * 1000000
	while true do
		claims, claims_err = live_lock_claims(base, { path = ticket_path, snapshot = ticket_snapshot })
		if not claims then
			remove_owned_claim(ticket_path, ticket_snapshot)
			return nil, claims_err
		end
		local blocking
		for _, claim in ipairs(claims) do
			if claim.token ~= token then
				if claim.kind == "choosing" then
					blocking = claim
					break
				end
				if claim.number < number or (claim.number == number and claim.token < token) then
					blocking = claim
					break
				end
			end
		end
		if not blocking then
			return {
				path = ticket_path,
				token = token,
				number = number,
				snapshot = ticket_snapshot,
				warning = lock_warning,
			}
		end
		if blocking.pid == pid or uv.hrtime() >= deadline then
			remove_owned_claim(ticket_path, ticket_snapshot)
			return nil, "busy"
		end
		vim.wait(LOCK_POLL_MILLISECONDS, function()
			return false
		end, LOCK_POLL_MILLISECONDS)
	end
end

local function with_arbiter(path, callback)
	local lock, lock_err = acquire_arbiter(path)
	if not lock then
		return nil, lock_err
	end
	local called, first, second = pcall(callback)
	local released, release_warning_or_err = release_arbiter(lock)
	local warning = lock.warning
	if released then
		warning = append_warning(warning, release_warning_or_err)
	else
		warning = append_warning(warning, "could not release scratch arbiter: " .. tostring(release_warning_or_err))
	end
	if not called then
		return nil, append_warning(tostring(first), warning)
	end
	if first ~= nil and first ~= false then
		return first, append_warning(second, warning)
	end
	if first == false then
		return false, append_warning(second, warning)
	end
	return nil, second
end

local function lease_owner(path)
	local lease, lease_err, snapshot = decode(path, "scratch lease", MAX_LEASE_BYTES)
	if not lease then
		return nil, lease_err
	end
	if
		not exact_fields(lease, { token = true, pid = true, expires_at = true })
		or type(lease.token) ~= "string"
		or #lease.token ~= 64
		or not lease.token:match("^[0-9a-f]+$")
		or type(lease.pid) ~= "number"
		or lease.pid < 1
		or lease.pid % 1 ~= 0
		or type(lease.expires_at) ~= "number"
		or lease.expires_at ~= lease.expires_at
		or lease.expires_at == math.huge
		or lease.expires_at == -math.huge
		or lease.expires_at % 1 ~= 0
	then
		return nil, "invalid scratch lease"
	end
	return lease, nil, snapshot
end

local function lease_status(path)
	local lease, lease_err, snapshot = lease_owner(path)
	if not lease then
		if lease_err == "missing" then
			return { kind = "missing", snapshot = { exists = false } }
		end
		return nil, lease_err
	end
	return {
		kind = lease.expires_at >= options.now() and "active" or "expired",
		lease = lease,
		snapshot = snapshot,
	}
end

local function claim_lease_unlocked(path)
	local status, status_err = lease_status(path)
	if not status then
		return nil, status_err
	end
	if status.kind == "active" then
		return nil, { kind = "leased", lease = copy(status.lease) }
	end
	local token = vim.fn.sha256(table.concat({ path, uv.os_getpid(), uv.hrtime() }, "\0"))
	local value = { token = token, pid = uv.os_getpid(), expires_at = options.now() + options.lease_seconds }
	local ok, warning_or_err = write_atomic(path, vim.json.encode(value) .. "\n", status.snapshot)
	if ok then
		return value, warning_or_err
	end
	if type(warning_or_err) == "table" and warning_or_err.kind == "conflict" then
		local latest = lease_status(path)
		if latest and latest.kind == "active" then
			return nil, { kind = "leased", lease = copy(latest.lease) }
		end
		return nil, { kind = "lease-conflict" }
	end
	return nil, warning_or_err
end

local function legacy_path(root, ids)
	for _, id in ipairs(ids or {}) do
		if type(id) == "string" and id:match("^[0-9a-f]+$") then
			local path = vim.fs.joinpath(root, id .. ".md")
			if lstat(path) then
				return path
			end
		end
	end
end

local function direct_scratch_path(root, path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
		return nil, "scratch path is invalid"
	end
	path = vim.fs.normalize(vim.fs.abspath(path))
	if vim.fs.dirname(path) ~= root or not vim.fs.basename(path):match("^[0-9a-f]+%.md$") then
		return nil, "scratch path must be a direct managed child of the state root"
	end
	return path
end

local function handle_paths(handle)
	if type(handle) ~= "table" then
		return nil, "scratch handle is required"
	end
	local root, root_err = ensure_root()
	if not root then
		return nil, root_err
	end
	local path, path_err = direct_scratch_path(root, handle.path)
	if not path then
		return nil, path_err
	end
	local meta = path .. ".meta"
	local lease = path .. ".lease"
	if handle.meta_path ~= meta or handle.lease_path ~= lease then
		return nil, "scratch handle paths do not match the managed scratch"
	end
	return { root = root, path = path, meta = meta, lease = lease }
end

local function renewed_lease(handle)
	local status, status_err = lease_status(handle.lease_path)
	if not status then
		return nil, "scratch lease is unsafe: " .. tostring(status_err)
	end
	if status.kind ~= "active" or not status.lease or status.lease.token ~= handle.lease_token then
		return nil, "scratch lease was lost"
	end
	local value = {
		token = handle.lease_token,
		pid = uv.os_getpid(),
		expires_at = options.now() + options.lease_seconds,
	}
	local wrote, write_warning_or_err = write_atomic(handle.lease_path, vim.json.encode(value) .. "\n", status.snapshot)
	if not wrote and type(write_warning_or_err) == "table" and write_warning_or_err.kind == "conflict" then
		return nil, "scratch lease changed during renewal"
	end
	return wrote and value or nil, write_warning_or_err
end

function M.open(request)
	request = request or {}
	local id, id_err = key_id(request.key)
	if not id then
		return nil, id_err
	end
	local root, root_err = ensure_root()
	if not root then
		return nil, root_err
	end
	local path, meta, lease_path = paths(root, id)
	local adopted = false
	if not lstat(path) then
		local legacy = legacy_path(root, request.legacy_ids)
		if legacy then
			path = legacy
			meta = path .. ".meta"
			lease_path = path .. ".lease"
			adopted = true
		end
	end
	return with_arbiter(path, function()
		local warning
		if not lstat(path) then
			local created, create_warning_or_err = write_atomic(path, "", { exists = false })
			if not created then
				return nil, create_warning_or_err
			end
			warning = append_warning(warning, create_warning_or_err)
		end
		local content, content_err = read(path)
		if not content then
			return nil, content_err
		end
		local lease, lease_warning_or_err = claim_lease_unlocked(lease_path)
		if not lease then
			return nil, lease_warning_or_err
		end
		warning = append_warning(warning, lease_warning_or_err)
		local metadata = {
			version = 2,
			managed = true,
			id = id,
			key = copy(request.key),
			path = path,
			adopted = adopted,
			updated_at = options.now(),
		}
		local meta_snapshot, snapshot_err = file_snapshot(meta, "scratch metadata", MAX_STATE_BYTES)
		if not meta_snapshot then
			local lease_status_after = lease_status(lease_path)
			if lease_status_after and lease_status_after.lease and lease_status_after.lease.token == lease.token then
				remove_cas(lease_path, lease_status_after.snapshot, "scratch lease", MAX_LEASE_BYTES)
			end
			return nil, snapshot_err
		end
		local wrote_meta, meta_warning_or_err = write_atomic(meta, vim.json.encode(metadata) .. "\n", meta_snapshot)
		if not wrote_meta then
			local lease_status_after = lease_status(lease_path)
			if lease_status_after and lease_status_after.lease and lease_status_after.lease.token == lease.token then
				local cleaned, cleanup_err =
					remove_cas(lease_path, lease_status_after.snapshot, "scratch lease", MAX_LEASE_BYTES)
				if not cleaned and cleanup_err then
					return nil, tostring(meta_warning_or_err) .. "; lease cleanup failed: " .. tostring(cleanup_err)
				end
			end
			return nil, meta_warning_or_err
		end
		warning = append_warning(warning, meta_warning_or_err)
		local handle = {
			key = copy(request.key),
			path = path,
			meta_path = meta,
			lease_path = lease_path,
			lease_token = lease.token,
			content = content,
			revision = vim.fn.sha256(content),
			adopted = adopted,
		}
		handles[handle.lease_token] = handle
		emit("opened", { path = handle.path, key = handle.key })
		return handle, warning
	end)
end

function M.renew(handle)
	local managed, handle_err = handle_paths(handle)
	if not managed then
		return nil, handle_err
	end
	local renewed, renew_err = with_arbiter(managed.path, function()
		local renewed, renew_warning_or_err = renewed_lease(handle)
		return renewed and true or nil, renew_warning_or_err
	end)
	if renewed then
		emit("renewed", { path = managed.path })
	else
		emit("lease_lost", { path = managed.path, error = tostring(renew_err) })
	end
	return renewed, renew_err
end

function M.save(handle, content)
	if type(content) ~= "string" then
		return nil, "scratch content must be a string"
	end
	if #content > MAX_STATE_BYTES then
		return nil, "scratch content exceeds the 1 MiB limit"
	end
	local managed, handle_err = handle_paths(handle)
	if not managed then
		return nil, handle_err
	end
	-- The arbiter makes the separate lease and content CAS publications sound for
	-- cooperating clients; exact snapshots still detect non-cooperative writers.
	return with_arbiter(managed.path, function()
		local status, status_err = lease_status(managed.lease)
		if not status then
			return nil, { kind = "lease-unsafe", detail = status_err }
		end
		if status.kind ~= "active" or status.lease.token ~= handle.lease_token then
			return nil, { kind = "lease-lost" }
		end
		local current, current_err, current_stat = read(managed.path)
		if not current then
			return nil, current_err
		end
		local revision = vim.fn.sha256(current)
		if revision ~= handle.revision then
			return nil, { kind = "conflict", current = current, proposed = content, revision = revision }
		end
		local renewed, renew_warning_or_err = renewed_lease(handle)
		if not renewed then
			return nil,
				{
					kind = renew_warning_or_err:find("unsafe", 1, true) and "lease-unsafe" or "lease-lost",
					detail = renew_warning_or_err,
				}
		end
		local ok, write_warning_or_err = write_atomic(managed.path, content, { data = current, stat = current_stat })
		if not ok then
			return nil, write_warning_or_err
		end
		handle.content = content
		handle.revision = vim.fn.sha256(content)
		handles[handle.lease_token] = handle
		emit("saved", { path = managed.path, revision = handle.revision })
		return copy(handle), append_warning(renew_warning_or_err, write_warning_or_err)
	end)
end

function M.release(handle)
	-- Relinquish process-local authority first. Durable lease cleanup may fail
	-- closed (for example after hostile replacement), but that must not leave an
	-- unreleasable RAM handle that blocks teardown or safe reconfiguration.
	if type(handle) == "table" and type(handle.lease_token) == "string" then
		handles[handle.lease_token] = nil
	end
	local managed, handle_err = handle_paths(handle)
	if not managed then
		return nil, handle_err
	end
	local released, release_err = with_arbiter(managed.path, function()
		local status, status_err = lease_status(managed.lease)
		if not status then
			return nil, status_err
		end
		if status.kind == "missing" then
			return false
		end
		if status.lease.token ~= handle.lease_token then
			return false
		end
		local removed, remove_warning_or_err =
			remove_cas(managed.lease, status.snapshot, "scratch lease", MAX_LEASE_BYTES)
		return removed and true or false, remove_warning_or_err
	end)
	emit("released", { path = managed.path, released = released == true })
	return released, release_err
end

local function managed_meta(path, scratch)
	local value, value_err, snapshot = decode(path, "scratch metadata", MAX_STATE_BYTES)
	if not value then
		return nil, value_err
	end
	if
		not exact_fields(value, {
			version = true,
			managed = true,
			id = true,
			key = true,
			path = true,
			adopted = true,
			updated_at = true,
		})
		or value.version ~= 2
		or value.managed ~= true
		or type(value.id) ~= "string"
		or #value.id ~= 64
		or not value.id:match("^[0-9a-f]+$")
		or not exact_fields(value.key, { repo_identity = true, ref = true })
		or type(value.path) ~= "string"
		or vim.fs.normalize(vim.fs.abspath(value.path)) ~= scratch
		or type(value.adopted) ~= "boolean"
		or type(value.updated_at) ~= "number"
		or value.updated_at ~= value.updated_at
		or value.updated_at == math.huge
		or value.updated_at == -math.huge
		or value.updated_at % 1 ~= 0
	then
		return nil, "invalid scratch metadata"
	end
	local id = key_id(value.key)
	if not id or value.id ~= id then
		return nil, "scratch metadata identity mismatch"
	end
	if not value.adopted and vim.fs.basename(scratch) ~= value.id .. ".md" then
		return nil, "scratch metadata filename identity mismatch"
	end
	return value, nil, snapshot
end

function M.prune(preserve)
	local root, root_err = ensure_root()
	if not root then
		return nil, root_err
	end
	local kept = {}
	for _, path in ipairs(preserve or {}) do
		kept[vim.fs.normalize(path)] = true
	end
	local removed = {}
	local warning
	local entries, entries_err = anchored_list(root)
	if not entries then
		return nil, entries_err
	end
	for _, entry in ipairs(entries) do
		local name = entry.name
		local kind = entry.kind
		if kind == "file" and name:sub(-5) == ".meta" then
			local meta_path = vim.fs.joinpath(root, name)
			local scratch_name = name:sub(1, -6)
			local scratch = scratch_name:match("^[0-9a-f]+%.md$") and vim.fs.joinpath(root, scratch_name) or nil
			if scratch then
				-- The per-scratch arbiter remains held through lease, metadata, and
				-- content reservation/unlink cleanup; release happens only below.
				local lock, lock_err = acquire_arbiter(scratch)
				if lock then
					warning = append_warning(warning, lock.warning)
					local removed_before = #removed
					local metadata, _, meta_snapshot = managed_meta(meta_path, scratch)
					local scratch_data
					local scratch_stat
					if metadata then
						local scratch_err
						scratch_data, scratch_err, scratch_stat = read(scratch, "managed scratch", MAX_STATE_BYTES)
						if not scratch_data then
							release_arbiter(lock)
							return nil, scratch_err
						end
					end
					local lease_path = scratch .. ".lease"
					local lease, lease_err
					if metadata then
						lease, lease_err = lease_status(lease_path)
					else
						lease = { kind = "missing" }
					end
					if metadata and not lease then
						release_arbiter(lock)
						return nil, "unsafe scratch lease blocks pruning: " .. tostring(lease_err)
					end
					if
						scratch_stat
						and scratch_stat.mtime.sec < options.now() - options.max_age_seconds
						and not kept[scratch]
						and lease.kind ~= "active"
					then
						if lease.kind == "expired" then
							local lease_removed, lease_remove_warning_or_err =
								remove_cas(lease_path, lease.snapshot, "scratch lease", MAX_LEASE_BYTES)
							if not lease_removed then
								release_arbiter(lock)
								return nil, lease_remove_warning_or_err
							end
							warning = append_warning(warning, lease_remove_warning_or_err)
						end
						if lstat(lease_path) then
							release_arbiter(lock)
							return nil, "scratch lease appeared while pruning"
						end
						local meta_removed, meta_warning_or_err =
							remove_cas(meta_path, meta_snapshot, "scratch metadata", MAX_STATE_BYTES)
						if not meta_removed then
							release_arbiter(lock)
							return nil, meta_warning_or_err
						end
						warning = append_warning(warning, meta_warning_or_err)
						if lstat(lease_path) then
							release_arbiter(lock)
							return nil, "scratch lease appeared while pruning"
						end
						local scratch_removed, scratch_warning_or_err = remove_cas(
							scratch,
							{ exists = true, data = scratch_data, stat = scratch_stat },
							"managed scratch",
							MAX_STATE_BYTES
						)
						if not scratch_removed then
							release_arbiter(lock)
							return nil, scratch_warning_or_err
						end
						warning = append_warning(warning, scratch_warning_or_err)
						removed[#removed + 1] = scratch
					end
					local released, release_warning_or_err = release_arbiter(lock)
					if not released then
						local release_warning = "could not release scratch arbiter: "
							.. tostring(release_warning_or_err)
						if #removed > removed_before then
							return removed, append_warning(warning, release_warning)
						end
						return nil, release_warning
					end
					warning = append_warning(warning, release_warning_or_err)
				elseif lock_err ~= "busy" then
					return nil, lock_err
				end
			end
		elseif kind == "link" then
			return nil, "refusing symlinked scratch state: " .. vim.fs.joinpath(root, name)
		end
	end
	return removed, warning
end

function M.setup(config)
	config = config or {}
	if type(config) ~= "table" or (next(config) ~= nil and vim.islist(config)) then
		return nil, "repo_scratch.setup options must be an object"
	end
	for key in pairs(config) do
		if
			key ~= "state_root"
			and key ~= "max_age_seconds"
			and key ~= "lease_seconds"
			and key ~= "now"
			and key ~= "event"
		then
			return nil, "repo_scratch.setup contains an unknown option: " .. tostring(key)
		end
	end
	if type(config.state_root) ~= "string" or config.state_root == "" or config.state_root:find("\0", 1, true) then
		return nil, "repo_scratch.setup requires state_root without NUL bytes"
	end
	for _, key in ipairs({ "max_age_seconds", "lease_seconds" }) do
		if config[key] ~= nil and (type(config[key]) ~= "number" or config[key] % 1 ~= 0 or config[key] < 1) then
			return nil, "repo_scratch.setup " .. key .. " must be a positive integer"
		end
	end
	if config.now ~= nil and type(config.now) ~= "function" then
		return nil, "repo_scratch.setup now must be a function"
	end
	if config.event ~= nil and type(config.event) ~= "function" then
		return nil, "repo_scratch.setup event must be a function"
	end
	local requested = vim.fs.normalize(vim.fs.abspath(config.state_root))
	if options.state_root and options.state_root ~= requested and next(handles) ~= nil then
		return nil, "repo_scratch.setup cannot change state_root while scratch handles are active"
	end
	local previous = options
	local candidate = {
		state_root = requested,
		max_age_seconds = config.max_age_seconds or 30 * 24 * 60 * 60,
		lease_seconds = config.lease_seconds or 5 * 60,
		now = config.now or os.time,
		root = nil,
		event = config.event,
	}
	options = candidate
	local root, root_warning_or_err = ensure_root()
	if not root then
		close_root()
		options = previous
		return nil, root_warning_or_err
	end
	if previous.root and previous.root.fd then
		local closed, close_err = close_fd(previous.root.fd)
		if not closed then
			close_root()
			options = previous
			return nil, "could not close prior state root: " .. tostring(close_err)
		end
		previous.root = nil
	end
	return root, root_warning_or_err
end

function M.effective_config()
	return {
		state_root = options.state_root,
		max_age_seconds = options.max_age_seconds,
		lease_seconds = options.lease_seconds,
	}
end

function M.status(handle)
	local function one(value)
		local status, status_err = lease_status(value.lease_path)
		return {
			path = value.path,
			key = copy(value.key),
			owned = status ~= nil
				and status.kind == "active"
				and status.lease ~= nil
				and status.lease.token == value.lease_token,
			lease = status and status.kind or "unsafe",
			expires_at = status and status.lease and status.lease.expires_at or nil,
			error = status_err,
		}
	end
	if handle then
		return copy(one(handle))
	end
	local result = {}
	for _, value in pairs(handles) do
		result[#result + 1] = one(value)
	end
	table.sort(result, function(left, right)
		return left.path < right.path
	end)
	return copy({ configured = options.state_root ~= nil, config = M.effective_config(), handles = result })
end

function M.teardown()
	local active = {}
	for _, handle in pairs(handles) do
		active[#active + 1] = handle
	end
	for _, handle in ipairs(active) do
		pcall(M.release, handle)
	end
	handles = {}
	close_root()
	options = {
		max_age_seconds = 30 * 24 * 60 * 60,
		lease_seconds = 5 * 60,
		now = os.time,
		root = nil,
		event = nil,
	}
	return true
end

M._private_file = private_file
M._set_test_hook = function(hook)
	assert(hook == nil or type(hook) == "function", "repo-scratch test hook must be a function or nil")
	test_hook = hook
end

return M
