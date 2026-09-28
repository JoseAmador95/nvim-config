-- Explicit installer for the pinned release artifacts in config.toolchain.
-- Plans are read-only snapshots; runs use private staging and return content
-- evidence for every promoted command and artifact.
local M = {}

local fs = require("config.fs")
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
	pcall(
		ffi.cdef,
		[[
			int fcntl(int fd, int cmd, ...);
			long long lseek(int fd, long long offset, int whence);
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
local OPEN_FLAGS = SYSTEM == "Darwin"
		and {
			at_fdcwd = -2,
			create = 512,
			directory = 1048576,
			exclusive = 2048,
			nonblock = 4,
			no_follow = 256,
			read_write = 2,
			write_only = 1,
		}
	or {
		at_fdcwd = -100,
		create = 64,
		directory = 65536,
		exclusive = 128,
		nonblock = 2048,
		no_follow = 131072,
		read_write = 2,
		write_only = 1,
	}
local REMOVE_DIRECTORY = SYSTEM == "Darwin" and 128 or 512

local test_hook

M._external = function(name)
	return paths.external_executable(name)
end

M._platform = function()
	local uname = uv.os_uname()
	return uname.sysname, uname.machine
end

M._run = function(command, options, callback)
	options = options or {}
	if options.inherited_fd then
		local stdout = uv.new_pipe(false)
		local stderr = uv.new_pipe(false)
		local stdout_chunks = {}
		local stderr_chunks = {}
		local exited
		local stdout_done = false
		local stderr_done = false
		local process
		local function complete()
			if not exited or not stdout_done or not stderr_done then
				return
			end
			stdout:close()
			stderr:close()
			process:close()
			vim.schedule(function()
				callback({
					code = exited.code,
					signal = exited.signal,
					stderr = table.concat(stderr_chunks),
					stdout = table.concat(stdout_chunks),
				})
			end)
		end
		local stdio = { nil, stdout, stderr }
		stdio[options.inherited_fd.child_fd + 1] = options.inherited_fd.fd
		local args = vim.list_slice(command, 2)
		local spawn_err
		process, spawn_err = uv.spawn(command[1], {
			args = args,
			cwd = options.cwd,
			env = options.env,
			stdio = stdio,
		}, function(code, signal)
			exited = { code = code, signal = signal }
			complete()
		end)
		if not process then
			stdout:close()
			stderr:close()
			vim.schedule(function()
				callback({ code = -1, stderr = tostring(spawn_err) })
			end)
			return nil
		end
		stdout:read_start(function(err, data)
			if err then
				stderr_chunks[#stderr_chunks + 1] = tostring(err)
			end
			if data then
				stdout_chunks[#stdout_chunks + 1] = data
			else
				stdout_done = true
				stdout:read_stop()
				complete()
			end
		end)
		stderr:read_start(function(err, data)
			if err then
				stderr_chunks[#stderr_chunks + 1] = tostring(err)
			end
			if data then
				stderr_chunks[#stderr_chunks + 1] = data
			else
				stderr_done = true
				stderr:read_stop()
				complete()
			end
		end)
		return process
	end
	local ok, process = pcall(vim.system, command, options, vim.schedule_wrap(callback))
	if not ok then
		vim.schedule(function()
			callback({ code = -1, stderr = tostring(process) })
		end)
		return nil
	end
	return process
end

function M._set_test_hook(callback)
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

local function bounded_warnings(values)
	local result = {}
	local seen = {}
	for _, value in ipairs(values or {}) do
		local warning = vim.trim(tostring(value):gsub("[%z\1-\31\127]", " ")):sub(1, 512)
		if warning ~= "" and not seen[warning] then
			seen[warning] = true
			result[#result + 1] = warning
			if #result == 32 then
				break
			end
		end
	end
	return result
end

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function safe_relative(path)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("%z") then
		return nil
	end
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return nil
		end
	end
	return vim.fs.normalize(path) == path and not path:find("\\", 1, true) and path or nil
end

local function canonical_leaf(path)
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local stat = uv.fs_lstat(path)
	if stat then
		if stat.type ~= "directory" then
			return nil, "install-root-unsafe"
		end
		return uv.fs_realpath(path) or nil, "install-root-unavailable"
	end
	local parent = uv.fs_realpath(vim.fs.dirname(path))
	if not parent then
		return nil, "install-root-parent-unavailable"
	end
	return vim.fs.joinpath(parent, vim.fs.basename(path))
end

local function required_commands(asset)
	local required = { "curl" }
	if M._external("sha256sum") then
		required[#required + 1] = "sha256sum"
	else
		required[#required + 1] = "shasum"
	end
	if asset.kind == "zip" then
		required[#required + 1] = "unzip"
	elseif asset.kind == "tar.gz" or asset.kind == "tar.xz" then
		required[#required + 1] = "tar"
	elseif asset.kind == "gzip" then
		required[#required + 1] = "gzip"
	end
	for _, name in ipairs(asset.requires_all or {}) do
		required[#required + 1] = name
	end
	return required
end

-- Planning performs no writes and no network access.
function M.plan(name, options)
	options = options or {}
	local entry = manifest.managed_tools[name]
	if not entry then
		return nil, "unknown"
	end
	if not options.force and M._external(entry.executable) then
		return nil, "external"
	end
	local os_name, arch = M._platform()
	local asset, target = manifest.asset_for(entry, os_name, arch)
	if not asset then
		return nil, "unsupported"
	end
	local install_root, root_err = canonical_leaf(paths.managed_root())
	if not install_root then
		return nil, root_err
	end
	return {
		name = name,
		entry = vim.deepcopy(entry),
		asset = vim.deepcopy(asset),
		target = target,
		requirements = required_commands(asset),
		url = manifest.release_url(entry, asset),
		install_root = install_root,
		layout = manifest.release_layout(entry, asset),
	}
end

local function validate_plan(plan)
	if type(plan) ~= "table" or type(plan.name) ~= "string" then
		return nil, "plan-invalid"
	end
	local entry = manifest.managed_tools[plan.name]
	local asset = entry and entry.assets and entry.assets[plan.target]
	if
		not entry
		or not asset
		or not vim.deep_equal(plan.entry, entry)
		or not vim.deep_equal(plan.asset, asset)
		or plan.url ~= manifest.release_url(entry, asset)
		or not vim.deep_equal(plan.layout, manifest.release_layout(entry, asset))
		or not safe_relative(plan.asset.archive)
		or vim.fs.dirname(plan.asset.archive) ~= "."
		or type(plan.install_root) ~= "string"
		or plan.install_root:sub(1, 1) ~= "/"
		or vim.fs.normalize(plan.install_root) ~= plan.install_root
	then
		return nil, "plan-invalid"
	end
	if not vim.deep_equal(plan.requirements, required_commands(asset)) then
		return nil, "plan-requirements-invalid"
	end
	return vim.deepcopy(plan)
end

local function resolve_prerequisites(plan)
	local commands = {}
	for _, command in ipairs(plan.requirements) do
		local path = M._external(command)
		if not path then
			return nil, "missing-prerequisite:" .. command
		end
		path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
		if
			path:sub(1, 1) ~= "/"
			or vim.fn.executable(path) ~= 1
			or paths.is_managed_path(path)
			or paths.is_mason_path(path)
			or paths.is_verified_shim_path(path)
		then
			return nil, "prerequisite-invalid:" .. command
		end
		commands[command] = path
	end
	return commands
end

function M.preflight(supplied)
	local plan, plan_err = validate_plan(supplied)
	if not plan then
		return nil, plan_err
	end
	local commands, command_err = resolve_prerequisites(plan)
	return commands and true or nil, command_err
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function safe_candidate(path, root, executable)
	local stat = uv.fs_lstat(path)
	local canonical = stat and stat.type == "file" and uv.fs_realpath(path) or nil
	if
		not stat
		or stat.type ~= "file"
		or stat.nlink ~= 1
		or not canonical
		or not contained(canonical, root)
		or (executable and vim.fn.executable(path) ~= 1)
	then
		return nil, "candidate-unsafe"
	end
	return true
end

local function same_object(left, right, kind)
	return left
		and right
		and left.type == kind
		and right.type == kind
		and left.dev == right.dev
		and left.ino == right.ino
end

local function same_inode(left, right)
	return same_object(left, right, "file")
end

local function same_time(left, right)
	return left and right and left.sec == right.sec and left.nsec == right.nsec
end

local function same_file_snapshot(left, right)
	return same_inode(left, right)
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and same_time(left.mtime, right.mtime)
		and (left.digest == nil or left.digest == right.digest)
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
		and (left.digest == nil or left.digest == right.digest)
end

local function ffi_ready()
	return ffi_ok and (SYSTEM == "Darwin" or SYSTEM == "Linux")
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

local directory_bound

local function close_fd(fd)
	if fd == nil then
		return true
	end
	return uv.fs_close(fd)
end

local function sync_fd(fd, label, details)
	local hook_ok, hook_err = run_test_hook(
		"before_fd_sync",
		vim.tbl_extend("force", {
			label = label,
		}, details or {})
	)
	if not hook_ok then
		return nil, label .. "-sync-hook-failed:" .. tostring(hook_err)
	end
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return nil, label .. "-sync-failed:" .. tostring(sync_err)
	end
	return true
end

local function sync_directory(directory, label)
	if not directory_bound or not directory_bound(directory) then
		return nil, label .. "-parent-changed"
	end
	return sync_fd(directory.fd, label, { path = directory.path })
end

local function sync_directories(directories, label)
	local seen = {}
	local warnings = {}
	for _, directory in ipairs(directories) do
		if directory and not seen[directory.fd] then
			seen[directory.fd] = true
			local synced, sync_err = sync_directory(directory, label)
			if not synced then
				warnings[#warnings + 1] = tostring(sync_err)
			end
		end
	end
	if #warnings > 0 then
		return nil, table.concat(warnings, "; ")
	end
	return true
end

local function read_all_fd(fd)
	local before = uv.fs_fstat(fd)
	if not before or before.type ~= "file" or before.size < 0 then
		return nil, "file-unsafe"
	end
	local chunks = {}
	local offset = 0
	while offset < before.size do
		local length = math.min(1024 * 1024, before.size - offset)
		local chunk, read_err = uv.fs_read(fd, length, offset)
		if not chunk then
			return nil, "read-failed:" .. tostring(read_err)
		end
		if #chunk == 0 then
			return nil, "short-read"
		end
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
	end
	local after = uv.fs_fstat(fd)
	if not same_file_snapshot(before, after) then
		return nil, "file-changed"
	end
	return table.concat(chunks), before
end

local function content_snapshot_fd(fd)
	local contents, stat_or_err = read_all_fd(fd)
	if not contents then
		return nil, stat_or_err
	end
	local after = uv.fs_fstat(fd)
	if not same_file_snapshot(stat_or_err, after) then
		return nil, "file-changed"
	end
	local snapshot = vim.deepcopy(after)
	snapshot.digest = vim.fn.sha256(contents)
	return snapshot, contents
end

directory_bound = function(directory)
	local opened = uv.fs_fstat(directory.fd)
	local visible = uv.fs_lstat(directory.path)
	return same_object(directory.identity, opened, "directory")
		and same_object(opened, visible, "directory")
		and descriptor_is_bound(directory.fd, directory.path)
end

local function open_directory(path)
	if not ffi_ready() then
		return nil, "descriptor-relative-filesystem-unavailable"
	end
	local inspected = uv.fs_lstat(path)
	if not inspected or inspected.type ~= "directory" then
		return nil, "directory-unsafe"
	end
	local canonical = uv.fs_realpath(path)
	if not canonical then
		return nil, "directory-unavailable"
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow
	local raw_fd = ffi.C.openat(OPEN_FLAGS.at_fdcwd, path, flags)
	if raw_fd < 0 then
		return nil, "directory-open-failed:errno " .. tostring(ffi.errno())
	end
	local directory = {
		fd = tonumber(raw_fd),
		identity = inspected,
		path = canonical,
	}
	local opened = uv.fs_fstat(directory.fd)
	local current = uv.fs_lstat(path)
	if
		not same_object(inspected, opened, "directory")
		or not same_object(opened, current, "directory")
		or not descriptor_is_bound(directory.fd, canonical)
	then
		close_fd(directory.fd)
		return nil, "directory-changed"
	end
	directory.identity = opened
	return directory
end

local function open_child_directory(parent, name, mode, create)
	if vim.fs.basename(name) ~= name or not safe_relative(name) then
		return nil, "directory-name-unsafe"
	end
	if not directory_bound(parent) then
		return nil, "directory-parent-changed"
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow
	local raw_fd = ffi.C.openat(parent.fd, name, flags)
	local made_directory = false
	if raw_fd < 0 and ffi.errno() == 2 and create then
		if not directory_bound(parent) then
			return nil, "directory-parent-changed"
		end
		local made = ffi.C.mkdirat(parent.fd, name, mode)
		local make_errno = ffi.errno()
		if made ~= 0 and make_errno ~= 17 then
			return nil, "mkdir-failed:errno " .. tostring(make_errno)
		end
		made_directory = made == 0
		if made_directory then
			local synced, sync_err = sync_directory(parent, "mkdir-parent")
			if not synced then
				return nil, sync_err
			end
		end
		raw_fd = ffi.C.openat(parent.fd, name, flags)
	end
	if raw_fd < 0 then
		return nil, "directory-unsafe:errno " .. tostring(ffi.errno())
	end
	local directory = {
		fd = tonumber(raw_fd),
		name = name,
		path = vim.fs.joinpath(parent.path, name),
	}
	local opened = uv.fs_fstat(directory.fd)
	local visible = uv.fs_lstat(directory.path)
	if
		not opened
		or opened.type ~= "directory"
		or not same_object(opened, visible, "directory")
		or not descriptor_is_bound(directory.fd, directory.path)
		or not directory_bound(parent)
	then
		close_fd(directory.fd)
		return nil, "directory-changed"
	end
	local needs_chmod = mode ~= nil and opened.mode % 512 ~= mode
	local changed, chmod_err = not needs_chmod or uv.fs_fchmod(directory.fd, mode)
	if changed and needs_chmod then
		changed, chmod_err = sync_fd(directory.fd, "directory-metadata", { path = directory.path })
	end
	local after = changed and uv.fs_fstat(directory.fd) or nil
	if
		not changed
		or not same_object(opened, after, "directory")
		or not descriptor_is_bound(directory.fd, directory.path)
		or not directory_bound(parent)
	then
		close_fd(directory.fd)
		return nil, changed and "directory-changed" or "chmod-failed:" .. tostring(chmod_err)
	end
	directory.identity = after
	return directory
end

local function open_install_root(path, mode)
	local parent, parent_err = open_directory(vim.fs.dirname(path))
	if not parent then
		return nil, "install-root-parent-unsafe:" .. tostring(parent_err)
	end
	local root, root_err = open_child_directory(parent, vim.fs.basename(path), mode, true)
	close_fd(parent.fd)
	if not root then
		return nil, root_err
	end
	if root.path ~= path or not directory_bound(root) then
		close_fd(root.fd)
		return nil, "install-root-changed"
	end
	return root
end

local function ensure_directory_tree(root, relative, mode, hook_phase)
	if relative == "" then
		return root, false
	end
	if not safe_relative(relative) then
		return nil, "directory-path-unsafe"
	end
	local current = root
	local owned = false
	for segment in relative:gmatch("[^/]+") do
		if hook_phase then
			local hook_ok, hook_err = run_test_hook(hook_phase, {
				parent = current.path,
				segment = segment,
			})
			if not hook_ok then
				if owned then
					close_fd(current.fd)
				end
				return nil, "directory-hook-failed:" .. tostring(hook_err)
			end
		end
		if not directory_bound(current) then
			if owned then
				close_fd(current.fd)
			end
			return nil, "target-parent-changed"
		end
		local child, child_err = open_child_directory(current, segment, mode, true)
		if owned then
			close_fd(current.fd)
		end
		if not child then
			return nil, child_err
		end
		current = child
		owned = true
	end
	if not contained(current.path, root.path) then
		close_fd(current.fd)
		return nil, "directory-escaped"
	end
	return current, owned
end

local function openat_file(directory, name)
	if not ffi_ready() then
		return nil, "descriptor-relative-filesystem-unavailable"
	end
	if vim.fs.basename(name) ~= name or not safe_relative(name) then
		return nil, "entry-name-unsafe"
	end
	local flags = OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow
	local raw_fd = ffi.C.openat(directory.fd, name, flags)
	if raw_fd < 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return tonumber(raw_fd)
end

local function createat_file(directory, name, mode)
	if not ffi_ready() then
		return nil, "descriptor-relative-filesystem-unavailable"
	end
	if vim.fs.basename(name) ~= name or not safe_relative(name) then
		return nil, "entry-name-unsafe"
	end
	if not directory_bound(directory) then
		return nil, "directory-parent-changed"
	end
	local flags = OPEN_FLAGS.read_write + OPEN_FLAGS.create + OPEN_FLAGS.exclusive + OPEN_FLAGS.no_follow
	-- Lua numbers become doubles in C varargs. openat(2) expects mode_t when
	-- O_CREAT is set, so pass an explicitly boxed integer.
	local raw_fd = ffi.C.openat(directory.fd, name, flags, ffi.new("unsigned int", mode))
	if raw_fd < 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return tonumber(raw_fd)
end

local function entry_snapshot(directory, name, label, allow_hardlinks)
	local fd, open_err, errno = openat_file(directory, name)
	if not fd and errno == 2 then
		return false
	end
	if not fd then
		return nil, label .. "-open-failed:" .. tostring(open_err)
	end
	local stat, snapshot_err = content_snapshot_fd(fd)
	local expected = vim.fs.joinpath(directory.path, name)
	local bound = stat
		and stat.type == "file"
		and (allow_hardlinks or stat.nlink == 1)
		and descriptor_is_bound(fd, expected)
	local closed, close_err = close_fd(fd)
	if not bound then
		return nil, label .. "-unsafe:" .. tostring(snapshot_err or "identity mismatch")
	end
	if not closed then
		return nil, label .. "-close-failed:" .. tostring(close_err)
	end
	return stat
end

local function sync_entry(directory, name, expected, label)
	local fd, open_err = openat_file(directory, name)
	if not fd then
		return nil, label .. "-open-failed:" .. tostring(open_err)
	end
	local before, before_err = content_snapshot_fd(fd)
	if not before or not same_file_snapshot(expected, before) then
		close_fd(fd)
		return nil, label .. "-changed:" .. tostring(before_err or "identity mismatch")
	end
	local synced, sync_err = sync_fd(fd, label, { path = vim.fs.joinpath(directory.path, name) })
	local after, after_err = synced and content_snapshot_fd(fd) or nil
	local closed, close_err = close_fd(fd)
	if not synced then
		return nil, sync_err
	end
	if not after or not same_file_snapshot(before, after) then
		return nil, label .. "-changed:" .. tostring(after_err or "identity mismatch")
	end
	if not closed then
		return nil, label .. "-close-failed:" .. tostring(close_err)
	end
	return after
end

local function any_entry_snapshot(directory, name, label)
	if not directory_bound(directory) then
		return nil, label .. "-parent-changed"
	end
	local path = vim.fs.joinpath(directory.path, name)
	local stat = uv.fs_lstat(path)
	if not stat then
		return false
	end
	if stat.type == "file" then
		return entry_snapshot(directory, name, label, true)
	end
	if not directory_bound(directory) then
		return nil, label .. "-parent-changed"
	end
	return stat
end

local function renameat_noreplace(source_directory, source, target_directory, target)
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(source_directory.fd, source, target_directory.fd, target, 4) -- RENAME_EXCL
		end
		return ffi.C.renameat2(source_directory.fd, source, target_directory.fd, target, 1) -- RENAME_NOREPLACE
	end)
	if not ok then
		return nil, "descriptor-relative-no-clobber-rename-unavailable:" .. tostring(result)
	end
	if result ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function renameat_exchange(left_directory, left, right_directory, right)
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(left_directory.fd, left, right_directory.fd, right, 2) -- RENAME_SWAP
		end
		return ffi.C.renameat2(left_directory.fd, left, right_directory.fd, right, 2) -- RENAME_EXCHANGE
	end)
	if not ok then
		return nil, "descriptor-relative-exchange-rename-unavailable:" .. tostring(result)
	end
	if result ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function unlinkat_entry(directory, name)
	if ffi.C.unlinkat(directory.fd, name, 0) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function unlinkat_directory(directory, name)
	if ffi.C.unlinkat(directory.fd, name, REMOVE_DIRECTORY) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	return true
end

local function temporary_entry_name(name, purpose)
	return (".%s.%s.%d.%s"):format(name, purpose, uv.os_getpid(), tostring(uv.hrtime()))
end

local function discard_entry(directory, name, expected, label)
	if not name then
		return true
	end
	if not directory_bound(directory) then
		return nil, label .. "-parent-changed"
	end
	local allow_hardlinks = expected and expected.nlink and expected.nlink > 1
	local current, current_err = entry_snapshot(directory, name, label, allow_hardlinks)
	if current == false then
		return true
	end
	if not current or not same_file_snapshot(expected, current) then
		return nil, label .. "-changed:" .. tostring(current_err or "identity mismatch")
	end
	local disposal = temporary_entry_name(name, "discard")
	local moved, move_err = renameat_noreplace(directory, name, directory, disposal)
	if not moved then
		return nil, label .. "-cleanup-reserve-failed:" .. tostring(move_err)
	end
	local reserved, reserve_sync_err = sync_directory(directory, label .. "-cleanup-reserve-parent")
	if not reserved then
		return nil,
			label .. "-cleanup-reserve-retained:" .. vim.fs.joinpath(directory.path, disposal) .. "; " .. tostring(
				reserve_sync_err
			)
	end
	local selected, selected_err = entry_snapshot(directory, disposal, label .. "-discard", allow_hardlinks)
	if not selected or not same_file_snapshot(expected, selected) then
		local restored, restore_err = renameat_noreplace(directory, disposal, directory, name)
		local restored_synced, restore_sync_err = restored
				and sync_directory(directory, label .. "-cleanup-restore-parent")
			or nil
		return nil,
			label
				.. "-cleanup-changed:"
				.. tostring(selected_err or "identity mismatch")
				.. (restored_synced and "" or "; " .. tostring(restore_err or restore_sync_err))
	end
	local hook_ok, hook_err = run_test_hook("before_quarantined_unlink", {
		label = label,
		path = vim.fs.joinpath(directory.path, disposal),
	})
	local rechecked = hook_ok and entry_snapshot(directory, disposal, label .. "-discard", allow_hardlinks) or nil
	local exact = rechecked and same_file_snapshot(selected, rechecked)
	if not hook_ok or not exact then
		return nil,
			label
				.. "-cleanup-quarantine-retained:"
				.. vim.fs.joinpath(directory.path, disposal)
				.. (hook_ok and "" or "; " .. tostring(hook_err))
	end
	-- POSIX has no compare-and-unlink primitive. The exact quarantine snapshot
	-- and unpredictable name prevent cooperative collisions; the owner UID is
	-- the trust boundary for the final unlinkat(2) window.
	local removed, remove_err = unlinkat_entry(directory, disposal)
	if not removed then
		return nil, label .. "-cleanup-failed:" .. tostring(remove_err)
	end
	local synced, sync_err = sync_directory(directory, label .. "-cleanup-parent")
	if not synced then
		return true, tostring(sync_err)
	end
	return true
end

local function write_all(fd, contents)
	local offset = 0
	while offset < #contents do
		local written, write_err = uv.fs_write(fd, contents:sub(offset + 1), offset)
		if not written or written <= 0 then
			return nil, tostring(write_err or "short write")
		end
		offset = offset + written
	end
	return true
end

local function write_staged_file(directory, name, contents, mode)
	if type(contents) ~= "string" then
		return nil, "staged-write-invalid"
	end
	local hook_ok, hook_err = run_test_hook("before_staged_write", {
		parent = directory.path,
		path = vim.fs.joinpath(directory.path, name),
	})
	if not hook_ok then
		return nil, "staged-write-hook-failed:" .. tostring(hook_err)
	end
	if not directory_bound(directory) then
		return nil, "staged-write-parent-changed"
	end
	local fd, open_err = createat_file(directory, name, mode)
	if not fd then
		return nil, "staged-write-create-failed:" .. tostring(open_err)
	end
	local path = vim.fs.joinpath(directory.path, name)
	local created = uv.fs_fstat(fd)
	local function fail(message)
		local snapshot = uv.fs_fstat(fd)
		close_fd(fd)
		if snapshot then
			discard_entry(directory, name, snapshot, "staged-write")
		end
		return nil, message
	end
	if
		not created
		or created.type ~= "file"
		or created.nlink ~= 1
		or not descriptor_is_bound(fd, path)
		or not directory_bound(directory)
	then
		return fail("staged-write-changed")
	end
	local parent_synced, parent_sync_err = sync_directory(directory, "staged-write-parent")
	if not parent_synced then
		return fail(tostring(parent_sync_err))
	end
	local changed, chmod_err = uv.fs_fchmod(fd, mode)
	if not changed then
		return fail("staged-write-chmod-failed:" .. tostring(chmod_err))
	end
	local written, write_err = write_all(fd, contents)
	if not written then
		return fail("staged-write-failed:" .. tostring(write_err))
	end
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return fail("staged-write-sync-failed:" .. tostring(sync_err))
	end
	local completed = uv.fs_fstat(fd)
	if
		not completed
		or not same_inode(created, completed)
		or completed.size ~= #contents
		or completed.nlink ~= 1
		or completed.mode % 512 ~= mode
		or not descriptor_is_bound(fd, path)
		or not directory_bound(directory)
	then
		return fail("staged-write-changed")
	end
	local closed, close_err = close_fd(fd)
	if not closed then
		return nil, "staged-write-close-failed:" .. tostring(close_err)
	end
	return path
end

local function descriptor_child_path(child_fd)
	local dev_fd = uv.fs_stat("/dev/fd")
	if (SYSTEM ~= "Darwin" and SYSTEM ~= "Linux") or not dev_fd or dev_fd.type ~= "directory" then
		return nil, "descriptor-extraction-unavailable"
	end
	return "/dev/fd/" .. tostring(child_fd)
end

local function bind_archive(stage, name)
	local source_fd, source_err = openat_file(stage, name)
	if not source_fd then
		return nil, "archive-open-failed:" .. tostring(source_err)
	end
	local source, contents = content_snapshot_fd(source_fd)
	local source_path = vim.fs.joinpath(stage.path, name)
	if
		not source
		or source.type ~= "file"
		or source.nlink ~= 1
		or not descriptor_is_bound(source_fd, source_path)
		or not directory_bound(stage)
	then
		close_fd(source_fd)
		return nil, "archive-unsafe"
	end
	local source_synced, source_sync_err = sync_fd(source_fd, "archive", { path = source_path })
	local parent_synced, parent_sync_err = sync_directory(stage, "archive-parent")
	if not source_synced or not parent_synced then
		close_fd(source_fd)
		return nil, tostring(source_sync_err or parent_sync_err)
	end

	local anonymous_name = temporary_entry_name(name, "verified")
	local anonymous_fd, create_err = createat_file(stage, anonymous_name, 384)
	if not anonymous_fd then
		close_fd(source_fd)
		return nil, "archive-copy-create-failed:" .. tostring(create_err)
	end
	local function fail(message)
		close_fd(anonymous_fd)
		local current = entry_snapshot(stage, anonymous_name, "archive-copy")
		if current then
			discard_entry(stage, anonymous_name, current, "archive-copy")
		end
		close_fd(source_fd)
		return nil, message
	end
	local created = uv.fs_fstat(anonymous_fd)
	if not created or created.type ~= "file" or created.nlink ~= 1 then
		return fail("archive-copy-unsafe")
	end
	local created_parent, created_parent_err = sync_directory(stage, "archive-copy-parent")
	if not created_parent then
		return fail(tostring(created_parent_err))
	end
	local written, write_err = write_all(anonymous_fd, contents)
	if not written then
		return fail("archive-copy-write-failed:" .. tostring(write_err))
	end
	local synced, sync_err = sync_fd(anonymous_fd, "archive-copy", {
		path = vim.fs.joinpath(stage.path, anonymous_name),
	})
	if not synced then
		return fail(tostring(sync_err))
	end
	local copied, copied_err = content_snapshot_fd(anonymous_fd)
	if
		not copied
		or copied.nlink ~= 1
		or copied.digest ~= source.digest
		or copied.size ~= source.size
		or not descriptor_is_bound(anonymous_fd, vim.fs.joinpath(stage.path, anonymous_name))
	then
		return fail("archive-copy-changed:" .. tostring(copied_err or "digest mismatch"))
	end
	local source_after, source_after_err = content_snapshot_fd(source_fd)
	if not source_after or not same_file_snapshot(source, source_after) then
		return fail("archive-changed:" .. tostring(source_after_err or "identity mismatch"))
	end
	local child_fd = 3
	local child_path, child_path_err = descriptor_child_path(child_fd)
	if not child_path then
		return fail(child_path_err)
	end
	local unlinked, unlink_err = unlinkat_entry(stage, anonymous_name)
	if not unlinked then
		return fail("archive-anonymize-failed:" .. tostring(unlink_err))
	end
	local unlink_synced, unlink_sync_err = sync_directory(stage, "archive-anonymize-parent")
	local anonymous = uv.fs_fstat(anonymous_fd)
	local closed, close_err = close_fd(source_fd)
	if not unlink_synced then
		close_fd(anonymous_fd)
		return nil, tostring(unlink_sync_err)
	end
	if
		not anonymous
		or anonymous.type ~= "file"
		or anonymous.nlink ~= 0
		or anonymous.size ~= copied.size
		or not same_inode(copied, anonymous)
	then
		close_fd(anonymous_fd)
		return nil, "archive-anonymize-changed"
	end
	if not closed then
		close_fd(anonymous_fd)
		return nil, "archive-close-failed:" .. tostring(close_err)
	end
	return {
		child_fd = child_fd,
		child_path = child_path,
		digest = copied.digest,
		fd = anonymous_fd,
		snapshot = copied,
	}
end

local function reset_bound_descriptor(binding)
	local ok, result = pcall(function()
		return ffi.C.lseek(binding.fd, 0, 0)
	end)
	if not ok or tonumber(result) ~= 0 then
		return nil, "archive-seek-failed"
	end
	local current, current_err = content_snapshot_fd(binding.fd)
	if
		not current
		or current.nlink ~= 0
		or current.digest ~= binding.digest
		or not same_inode(binding.snapshot, current)
	then
		return nil, "archive-changed:" .. tostring(current_err or "identity mismatch")
	end
	return true
end

local function materialize_bound_archive(stage, binding, name)
	local current, contents_or_err = content_snapshot_fd(binding.fd)
	if
		not current
		or current.nlink ~= 0
		or current.digest ~= binding.digest
		or not same_inode(binding.snapshot, current)
	then
		return nil, "archive-changed:" .. tostring(contents_or_err or "identity mismatch")
	end
	local candidate_name = temporary_entry_name(name, "candidate")
	return write_staged_file(stage, candidate_name, contents_or_err, 384)
end

local function discard_nonfile_entry(directory, name, expected, label)
	if expected.type == "directory" then
		local selected, selected_err = open_child_directory(directory, name, nil, false)
		if not selected or not same_object(expected, selected.identity, "directory") then
			if selected then
				close_fd(selected.fd)
			end
			return nil, label .. "-cleanup-directory-changed:" .. tostring(selected_err or "identity mismatch")
		end
		local hook_ok, hook_err = run_test_hook("before_quarantined_unlink", {
			label = label,
			path = vim.fs.joinpath(directory.path, name),
		})
		local exact = hook_ok and open_child_directory(directory, name, nil, false) or nil
		local unchanged = exact and same_object(selected.identity, exact.identity, "directory")
		if exact then
			close_fd(exact.fd)
		end
		close_fd(selected.fd)
		if not unchanged then
			return nil,
				label
					.. "-cleanup-directory-retained:"
					.. vim.fs.joinpath(directory.path, name)
					.. (hook_ok and "" or "; " .. tostring(hook_err))
		end
		-- POSIX cannot condition rmdir on inode identity; owner UID remains the
		-- trust boundary after this exact descriptor-relative revalidation.
		local removed, remove_err = unlinkat_directory(directory, name)
		if not removed then
			return nil,
				label .. "-cleanup-directory-retained:" .. vim.fs.joinpath(directory.path, name) .. "; " .. tostring(
					remove_err
				)
		end
		local synced, sync_err = sync_directory(directory, label .. "-cleanup-parent")
		if not synced then
			return true, tostring(sync_err)
		end
		return true
	end
	local quarantine = temporary_entry_name(name, "discard")
	local moved, move_err = renameat_noreplace(directory, name, directory, quarantine)
	if not moved then
		return nil, label .. "-cleanup-reserve-failed:" .. tostring(move_err)
	end
	local synced, sync_err = sync_directory(directory, label .. "-cleanup-reserve-parent")
	local path = vim.fs.joinpath(directory.path, quarantine)
	if not synced then
		return nil, label .. "-cleanup-quarantine-retained:" .. path .. "; " .. tostring(sync_err)
	end
	local selected = uv.fs_lstat(path)
	local hook_ok, hook_err = run_test_hook("before_quarantined_unlink", { label = label, path = path })
	local rechecked = hook_ok and uv.fs_lstat(path) or nil
	if
		not selected
		or not same_entry_snapshot(expected, selected)
		or not rechecked
		or not same_entry_snapshot(selected, rechecked)
	then
		return nil, label .. "-cleanup-quarantine-retained:" .. path .. (hook_ok and "" or "; " .. tostring(hook_err))
	end
	-- As above, the final unlinkat(2) trusts the owner UID after the exact
	-- descriptor-relative quarantine snapshot.
	local removed, remove_err = expected.type == "directory" and unlinkat_directory(directory, quarantine)
		or unlinkat_entry(directory, quarantine)
	if not removed then
		return nil, label .. "-cleanup-quarantine-retained:" .. path .. "; " .. tostring(remove_err)
	end
	local removed_synced, removed_sync_err = sync_directory(directory, label .. "-cleanup-parent")
	if not removed_synced then
		return true, tostring(removed_sync_err)
	end
	return true
end

local function discard_any_entry(directory, name, expected, label)
	if expected.type == "file" then
		return discard_entry(directory, name, expected, label)
	end
	return discard_nonfile_entry(directory, name, expected, label)
end

local function cleanup_relative_path(root, relative)
	local warnings = {}
	if not safe_relative(relative) then
		return { "cleanup-path-unsafe:" .. tostring(relative) }
	end
	local segments = vim.split(relative, "/", { plain = true })
	local directories = { root }
	local current = root
	local complete = true
	for index = 1, #segments - 1 do
		local child, child_err = open_child_directory(current, segments[index], nil, false)
		if not child then
			local replacement = any_entry_snapshot(current, segments[index], "cleanup-entry")
			if replacement then
				local discarded, discard_err = discard_any_entry(current, segments[index], replacement, "cleanup-entry")
				if not discarded or discard_err then
					warnings[#warnings + 1] = tostring(discard_err or child_err)
				end
			end
			complete = false
			break
		end
		directories[#directories + 1] = child
		current = child
	end
	if complete then
		local leaf, leaf_err = any_entry_snapshot(current, segments[#segments], "cleanup-leaf")
		if leaf then
			local discarded, discard_err = discard_any_entry(current, segments[#segments], leaf, "cleanup-leaf")
			if not discarded or discard_err then
				warnings[#warnings + 1] = tostring(discard_err or leaf_err)
			end
		elseif leaf == nil then
			warnings[#warnings + 1] = tostring(leaf_err)
		end
	end
	for index = #directories, 2, -1 do
		local child = directories[index]
		close_fd(child.fd)
		local discarded, discard_err =
			discard_nonfile_entry(directories[index - 1], child.name, child.identity, "cleanup-directory")
		if not discarded or discard_err then
			warnings[#warnings + 1] = tostring(discard_err)
		end
	end
	return warnings
end

local function discard_stage_directory(stage, staging_root)
	local warnings = {}
	if not directory_bound(stage) or not directory_bound(staging_root) then
		return { "stage-cleanup-parent-changed:recovery=" .. stage.path }
	end
	local quarantine = temporary_entry_name(stage.name, "cleanup")
	local moved = renameat_noreplace(staging_root, stage.name, staging_root, quarantine)
	if not moved then
		return { "stage-cleanup-reserve-failed:recovery=" .. stage.path }
	end
	local reserved, reserve_err = sync_directory(staging_root, "stage-cleanup-reserve-parent")
	if not reserved then
		return {
			"stage-cleanup-retained:recovery=" .. vim.fs.joinpath(staging_root.path, quarantine) .. "; " .. tostring(
				reserve_err
			),
		}
	end
	local selected = open_child_directory(staging_root, quarantine, nil, false)
	if not selected or not same_object(stage.identity, selected.identity, "directory") then
		if selected then
			close_fd(selected.fd)
		end
		renameat_noreplace(staging_root, quarantine, staging_root, stage.name)
		sync_directory(staging_root, "stage-cleanup-restore-parent")
		return { "stage-cleanup-changed:recovery=" .. vim.fs.joinpath(staging_root.path, quarantine) }
	end
	close_fd(selected.fd)
	local hook_ok, hook_err = run_test_hook("before_quarantined_unlink", {
		label = "stage-cleanup",
		path = vim.fs.joinpath(staging_root.path, quarantine),
	})
	local exact = hook_ok and open_child_directory(staging_root, quarantine, nil, false) or nil
	if not exact or not same_object(stage.identity, exact.identity, "directory") then
		if exact then
			close_fd(exact.fd)
		end
		return {
			"stage-cleanup-quarantine-retained:recovery="
				.. vim.fs.joinpath(staging_root.path, quarantine)
				.. (hook_ok and "" or "; " .. tostring(hook_err)),
		}
	end
	close_fd(exact.fd)
	local removed = unlinkat_directory(staging_root, quarantine)
	if not removed then
		renameat_noreplace(staging_root, quarantine, staging_root, stage.name)
		sync_directory(staging_root, "stage-cleanup-restore-parent")
		warnings[#warnings + 1] = "stage-cleanup-retained:recovery=" .. stage.path
		return warnings
	end
	local synced, sync_err = sync_directory(staging_root, "stage-cleanup-parent")
	if not synced then
		warnings[#warnings + 1] = tostring(sync_err)
	end
	return warnings
end

local function cleanup(stage, staging_root, plan)
	local warnings = {}
	if not stage or not staging_root or not plan or not contained(stage.path, staging_root.path) then
		return { "stage-cleanup-input-invalid" }
	end
	if plan.retain_stage then
		return { "stage-retained:recovery=" .. stage.path }
	end
	local hook_ok = run_test_hook("before_stage_cleanup", {
		stage = stage.path,
		staging_root = staging_root.path,
	})
	if not hook_ok or not directory_bound(stage) or not directory_bound(staging_root) then
		return { "stage-cleanup-parent-changed:recovery=" .. stage.path }
	end
	local archive = any_entry_snapshot(stage, plan.asset.archive, "archive-cleanup")
	if archive then
		local discarded, discard_err = discard_any_entry(stage, plan.asset.archive, archive, "archive-cleanup")
		if not discarded or discard_err then
			warnings[#warnings + 1] = tostring(discard_err)
		end
	end
	local extract = open_child_directory(stage, "extract", nil, false)
	if extract then
		local extracted_relative = plan.asset.kind == "gzip" and plan.entry.executable or plan.asset.member
		if extracted_relative then
			vim.list_extend(warnings, cleanup_relative_path(extract, extracted_relative))
		end
		close_fd(extract.fd)
		local extract_snapshot = any_entry_snapshot(stage, "extract", "extract-cleanup")
		if extract_snapshot then
			local discarded, discard_err = discard_any_entry(stage, "extract", extract_snapshot, "extract-cleanup")
			if not discarded or discard_err then
				warnings[#warnings + 1] = tostring(discard_err)
			end
		end
	else
		local replacement = any_entry_snapshot(stage, "extract", "extract-cleanup")
		if replacement then
			local discarded, discard_err = discard_any_entry(stage, "extract", replacement, "extract-cleanup")
			if not discarded or discard_err then
				warnings[#warnings + 1] = tostring(discard_err)
			end
		end
	end
	vim.list_extend(warnings, discard_stage_directory(stage, staging_root))
	return warnings
end

-- Move the inspected candidate to an unpredictable name within a pinned
-- staging parent. No later pathname lookup can redirect publication through a
-- swapped staging ancestor.
local function pin_candidate(candidate, root)
	local parent = vim.fs.dirname(candidate)
	local directory, directory_err = open_directory(parent)
	if not directory then
		return nil, "candidate-parent-unsafe:" .. tostring(directory_err)
	end
	if not contained(directory.path, root) then
		close_fd(directory.fd)
		return nil, "candidate-escaped"
	end
	local name = vim.fs.basename(candidate)
	local initial, initial_err = entry_snapshot(directory, name, "candidate")
	if not initial then
		close_fd(directory.fd)
		return nil, initial_err or "candidate-unsafe"
	end
	initial, initial_err = sync_entry(directory, name, initial, "candidate")
	if not initial then
		close_fd(directory.fd)
		return nil, initial_err
	end
	local pinned_name = temporary_entry_name(name, "promote")
	local moved, move_err = renameat_noreplace(directory, name, directory, pinned_name)
	if not moved then
		close_fd(directory.fd)
		return nil, "candidate-pin-failed:" .. tostring(move_err)
	end
	local rename_synced, rename_sync_err = sync_directory(directory, "candidate-pin-parent")
	if not rename_synced then
		local restored = renameat_noreplace(directory, pinned_name, directory, name)
		if restored then
			sync_directory(directory, "candidate-restore-parent")
		end
		close_fd(directory.fd)
		return nil,
			"candidate-pin-sync-failed:"
				.. tostring(rename_sync_err)
				.. (restored and "" or "; retained:" .. vim.fs.joinpath(directory.path, pinned_name))
	end
	local pinned, pinned_err = entry_snapshot(directory, pinned_name, "candidate-pin")
	if not pinned or not same_file_snapshot(initial, pinned) then
		local restored, restore_err = renameat_noreplace(directory, pinned_name, directory, name)
		local restored_synced, restore_sync_err = restored and sync_directory(directory, "candidate-restore-parent")
			or nil
		close_fd(directory.fd)
		return nil,
			"candidate-changed:"
				.. tostring(pinned_err or "identity mismatch")
				.. (restored_synced and "" or "; " .. tostring(restore_err or restore_sync_err))
	end
	return {
		directory = directory,
		identity = initial,
		name = pinned_name,
		path = vim.fs.joinpath(directory.path, pinned_name),
		snapshot = pinned,
	}
end

local function chmod_candidate(candidate, mode)
	local fd, open_err = openat_file(candidate.directory, candidate.name)
	if not fd then
		return nil, "candidate-open-failed:" .. tostring(open_err)
	end
	local before = content_snapshot_fd(fd)
	if not same_file_snapshot(candidate.snapshot, before) or not descriptor_is_bound(fd, candidate.path) then
		close_fd(fd)
		return nil, "candidate-changed"
	end
	local changed, chmod_err = uv.fs_fchmod(fd, mode)
	local synced, sync_err = changed and sync_fd(fd, "candidate-metadata", { path = candidate.path }) or nil
	local after = synced and content_snapshot_fd(fd) or nil
	local bound = changed and descriptor_is_bound(fd, candidate.path)
	local closed, close_err = close_fd(fd)
	if not changed then
		return nil, "chmod-failed:" .. tostring(chmod_err)
	end
	if not synced then
		return nil, tostring(sync_err)
	end
	if
		not after
		or not same_inode(candidate.identity, after)
		or after.nlink ~= 1
		or after.mode % 512 ~= mode
		or after.digest ~= candidate.snapshot.digest
		or not bound
	then
		return nil, "candidate-changed"
	end
	if not closed then
		return nil, "candidate-close-failed:" .. tostring(close_err)
	end
	candidate.snapshot = after
	return true
end

local function safe_target(root, relative)
	if not safe_relative(relative) then
		return nil, "target-path-unsafe"
	end
	local parent_relative = vim.fs.dirname(relative)
	local directory, owned_or_err =
		ensure_directory_tree(root, parent_relative == "." and "" or parent_relative, 493, "before_target_tree_step")
	if not directory then
		return nil, owned_or_err
	end
	local owns_directory = owned_or_err
	local name = vim.fs.basename(relative)
	local target = vim.fs.joinpath(directory.path, name)
	if not contained(directory.path, root.path) or not contained(target, root.path) then
		if owns_directory then
			close_fd(directory.fd)
		end
		return nil, "target-escaped"
	end
	local current, current_err = entry_snapshot(directory, name, "target")
	if current == nil then
		if owns_directory then
			close_fd(directory.fd)
		end
		return nil, current_err
	end
	return {
		directory = directory,
		name = name,
		original = current,
		owns_directory = owns_directory,
		path = target,
	}
end

local function exact_snapshot(directory, name, label, expected)
	local current, current_err = entry_snapshot(directory, name, label)
	if not current or not same_file_snapshot(expected, current) then
		return nil, current_err or "identity mismatch"
	end
	return current
end

local function exact_any_snapshot(directory, name, label, expected)
	local current, current_err = any_entry_snapshot(directory, name, label)
	if not current or not same_entry_snapshot(expected, current) then
		return nil, current_err or "identity mismatch"
	end
	return current
end

local function rollback_exchanged(candidate, target, published, previous)
	local hook_ok, hook_err = run_test_hook("before_target_rollback", {
		parent = target.directory.path,
		target = target.path,
		recovery = candidate.path,
	})
	if not hook_ok then
		return nil, "rollback-hook-failed:" .. tostring(hook_err)
	end
	if not directory_bound(target.directory) or not directory_bound(candidate.directory) then
		return nil, "target-parent-changed-during-rollback"
	end
	local current_target, target_err = exact_snapshot(target.directory, target.name, "rollback-target", published)
	local current_previous, previous_err =
		exact_any_snapshot(candidate.directory, candidate.name, "rollback-previous", previous)
	if not current_target or not current_previous then
		return nil, "rollback-input-changed:" .. tostring(target_err or previous_err or "identity mismatch")
	end
	local exchanged, exchange_err =
		renameat_exchange(target.directory, target.name, candidate.directory, candidate.name)
	if not exchanged then
		return nil, "rollback-exchange-failed:" .. tostring(exchange_err)
	end
	local exchanged_synced, exchange_sync_err =
		sync_directories({ target.directory, candidate.directory }, "rollback-exchange-parent")
	local restored, restored_err = exact_any_snapshot(target.directory, target.name, "restored-target", previous)
	local displaced, displaced_err =
		exact_snapshot(candidate.directory, candidate.name, "rollback-candidate", published)
	if not restored or not displaced then
		return nil, "rollback-exchange-changed:" .. tostring(restored_err or displaced_err or "identity mismatch")
	end
	local discarded, discard_err = discard_entry(candidate.directory, candidate.name, displaced, "rollback-candidate")
	if not discarded then
		return true,
			"rollback-candidate-retained:" .. tostring(discard_err) .. (exchanged_synced and "" or "; " .. tostring(
				exchange_sync_err
			))
	end
	local warning = discard_err
	if not exchanged_synced then
		warning = warning and (tostring(exchange_sync_err) .. "; " .. tostring(warning)) or tostring(exchange_sync_err)
	end
	return true, warning
end

local function cleanup_previous(candidate, target, published, previous)
	local hook_ok, hook_err = run_test_hook("before_previous_cleanup", {
		parent = target.directory.path,
		target = target.path,
		recovery = candidate.path,
	})
	if not directory_bound(target.directory) or not directory_bound(candidate.directory) then
		return nil, "previous-cleanup-parent-changed"
	end
	local current_target, target_err = exact_snapshot(target.directory, target.name, "promoted-target", published)
	if not current_target then
		return nil, "previous-cleanup-target-changed:" .. tostring(target_err or "identity mismatch")
	end
	if not hook_ok then
		return true, "previous-retained:cleanup-hook-failed:" .. tostring(hook_err)
	end
	local current_previous, previous_err =
		exact_snapshot(candidate.directory, candidate.name, "previous-target", previous)
	if not current_previous then
		return true, "previous-retained:" .. tostring(previous_err or "identity mismatch")
	end
	local discarded, discard_err =
		discard_entry(candidate.directory, candidate.name, current_previous, "previous-target")
	if not discarded then
		return true, "previous-retained:" .. tostring(discard_err)
	end
	return true, discard_err
end

local function close_promotion(candidate, target)
	local warnings = {}
	if candidate and candidate.directory then
		local hook_ok, hook_err = run_test_hook("before_promotion_close", {
			label = "candidate-parent",
			path = candidate.directory.path,
		})
		if not hook_ok then
			warnings[#warnings + 1] = "candidate-parent-close-warning:" .. tostring(hook_err)
		end
		local closed, close_err = close_fd(candidate.directory.fd)
		if not closed then
			warnings[#warnings + 1] = "candidate-parent-close-failed:" .. tostring(close_err)
		end
		candidate.directory = nil
	end
	if target and target.directory then
		if target.owns_directory then
			local hook_ok, hook_err = run_test_hook("before_promotion_close", {
				label = "target-parent",
				path = target.directory.path,
			})
			if not hook_ok then
				warnings[#warnings + 1] = "target-parent-close-warning:" .. tostring(hook_err)
			end
			local closed, close_err = close_fd(target.directory.fd)
			if not closed then
				warnings[#warnings + 1] = "target-parent-close-failed:" .. tostring(close_err)
			end
		end
		target.directory = nil
	end
	return warnings
end

local function promote_initial(candidate, target, mode)
	local hook_ok, hook_err = run_test_hook("before_publish_link", {
		source = candidate.path,
		target = target.path,
	})
	if not hook_ok then
		return nil, "promote-hook-failed:" .. tostring(hook_err)
	end
	if not directory_bound(candidate.directory) or not directory_bound(target.directory) then
		return nil, "target-parent-changed"
	end
	local source, source_err = exact_snapshot(candidate.directory, candidate.name, "candidate-pin", candidate.snapshot)
	local current, current_err = entry_snapshot(target.directory, target.name, "target")
	if not source then
		return nil, "candidate-changed:" .. tostring(source_err)
	end
	if current ~= false then
		return nil, current == nil and tostring(current_err) or "target-changed"
	end
	local publish_hook_ok, publish_hook_err = run_test_hook("before_initial_publish", {
		source = candidate.path,
		target = target.path,
	})
	if not publish_hook_ok then
		return nil, "initial-publish-hook-failed:" .. tostring(publish_hook_err)
	end
	if not directory_bound(candidate.directory) or not directory_bound(target.directory) then
		return nil, "target-parent-changed"
	end
	local final_source, final_source_err =
		exact_snapshot(candidate.directory, candidate.name, "candidate-pin", candidate.snapshot)
	local final_current, final_current_err = entry_snapshot(target.directory, target.name, "target")
	if not final_source then
		return nil, "candidate-changed:" .. tostring(final_source_err)
	end
	if final_current ~= false then
		return nil, final_current == nil and tostring(final_current_err) or "target-changed"
	end
	local syscall_hook_ok, syscall_hook_err = run_test_hook("at_initial_publish_syscall", {
		source = candidate.path,
		target = target.path,
	})
	if not syscall_hook_ok then
		return nil, "initial-publish-syscall-hook-failed:" .. tostring(syscall_hook_err)
	end
	local promoted, promote_err = renameat_noreplace(candidate.directory, candidate.name, target.directory, target.name)
	if not promoted then
		return nil, "promote-failed:" .. tostring(promote_err)
	end
	local synced, sync_err = sync_directories({ candidate.directory, target.directory }, "initial-publish-parent")
	local warnings = synced and {}
		or { "publication-sync-uncertain:target=" .. target.path .. "; " .. tostring(sync_err) }
	local hook_after_ok, hook_after_err = run_test_hook("after_initial_publish", {
		target = target.path,
	})
	local final, final_err = exact_snapshot(target.directory, target.name, "promoted-target", candidate.snapshot)
	if not hook_after_ok then
		if final then
			discard_entry(target.directory, target.name, final, "promoted-target")
		end
		return nil, "initial-publish-hook-failed:" .. tostring(hook_after_err)
	end
	if not final or final.mode % 512 ~= mode or not directory_bound(target.directory) then
		if final then
			discard_entry(target.directory, target.name, final, "promoted-target")
		end
		return nil, "promoted-target-unsafe:" .. tostring(final_err or "identity mismatch")
	end
	return target.path, warnings
end

local function promote_existing(candidate, target, previous, mode)
	local reserve_hook_ok, reserve_hook_err = run_test_hook("before_target_reserve", {
		parent = target.directory.path,
		target = target.path,
	})
	if not reserve_hook_ok then
		return nil, "target-reserve-hook-failed:" .. tostring(reserve_hook_err)
	end
	local publish_hook_ok, publish_hook_err = run_test_hook("before_publish_link", {
		source = candidate.path,
		target = target.path,
	})
	if not publish_hook_ok then
		return nil, "promote-hook-failed:" .. tostring(publish_hook_err)
	end
	if not directory_bound(candidate.directory) or not directory_bound(target.directory) then
		return nil, "target-parent-changed"
	end
	local source, source_err = exact_snapshot(candidate.directory, candidate.name, "candidate-pin", candidate.snapshot)
	local incumbent, incumbent_err = exact_snapshot(target.directory, target.name, "target", previous)
	if not source then
		return nil, "candidate-changed:" .. tostring(source_err)
	end
	if not incumbent then
		return nil, "target-changed:" .. tostring(incumbent_err)
	end
	local before_exchange_ok, before_exchange_err = run_test_hook("before_target_exchange", {
		source = candidate.path,
		target = target.path,
	})
	if not before_exchange_ok then
		return nil, "target-exchange-hook-failed:" .. tostring(before_exchange_err)
	end
	if not directory_bound(candidate.directory) or not directory_bound(target.directory) then
		return nil, "target-parent-changed"
	end
	local final_source, final_source_err =
		exact_snapshot(candidate.directory, candidate.name, "candidate-pin", candidate.snapshot)
	local final_incumbent, final_incumbent_err = exact_snapshot(target.directory, target.name, "target", previous)
	if not final_source then
		return nil, "candidate-changed:" .. tostring(final_source_err)
	end
	if not final_incumbent then
		return nil, "target-changed:" .. tostring(final_incumbent_err)
	end
	local syscall_hook_ok, syscall_hook_err = run_test_hook("at_target_exchange_syscall", {
		source = candidate.path,
		target = target.path,
	})
	if not syscall_hook_ok then
		return nil, "target-exchange-syscall-hook-failed:" .. tostring(syscall_hook_err)
	end
	local exchanged, exchange_err =
		renameat_exchange(candidate.directory, candidate.name, target.directory, target.name)
	if not exchanged then
		return nil, "promote-exchange-failed:" .. tostring(exchange_err)
	end
	local synced, sync_err = sync_directories({ candidate.directory, target.directory }, "target-exchange-parent")
	local warnings = synced and {}
		or {
			"publication-sync-uncertain:target=" .. target.path .. "; recovery=" .. candidate.path .. "; " .. tostring(
				sync_err
			),
		}
	local after_exchange_hook_ok, after_exchange_hook_err = run_test_hook("after_target_exchange", {
		source = candidate.path,
		target = target.path,
		recovery = candidate.path,
	})
	local published, published_err =
		exact_snapshot(target.directory, target.name, "promoted-target", candidate.snapshot)
	local recovery, recovery_err = any_entry_snapshot(candidate.directory, candidate.name, "displaced-target")
	local expected_recovery = recovery and same_entry_snapshot(previous, recovery)
	if not after_exchange_hook_ok or not published or not expected_recovery then
		local rolled_back
		local rollback_err
		if published and recovery then
			rolled_back, rollback_err = rollback_exchanged(candidate, target, published, recovery)
		end
		local detail = not after_exchange_hook_ok and ("exchange-hook-failed:" .. tostring(after_exchange_hook_err))
			or tostring(published_err or recovery_err or "exact target CAS mismatch")
		return nil,
			"promoted-target-unsafe:" .. detail .. (rolled_back and "" or "; previous-retained:" .. tostring(
				rollback_err or candidate.path
			))
	end
	if published.mode % 512 ~= mode then
		local rolled_back, rollback_err = rollback_exchanged(candidate, target, published, recovery)
		return nil,
			"promoted-target-unsafe:mode" .. (rolled_back and "" or "; previous-retained:" .. tostring(
				rollback_err or candidate.path
			))
	end
	if not synced then
		return target.path, warnings, true
	end
	local cleaned, cleanup_err = cleanup_previous(candidate, target, published, recovery)
	if not cleaned then
		local rolled_back, rollback_err = rollback_exchanged(candidate, target, published, recovery)
		return nil,
			"promoted-target-unsafe:"
				.. tostring(cleanup_err)
				.. (rolled_back and "" or "; previous-retained:" .. tostring(rollback_err or candidate.path))
	end
	if cleanup_err then
		warnings[#warnings + 1] = tostring(cleanup_err)
	end
	-- Cleanup failure after an exact exchange is not a failed installation: NEW
	-- remains the exact visible target and OLD remains recoverable in staging.
	return target.path, warnings
end

local function promote_file(plan, candidate_path, candidate_root, relative, mode)
	local safe, safe_err = safe_candidate(candidate_path, candidate_root, false)
	if not safe then
		return nil, safe_err
	end
	local candidate, pin_err = pin_candidate(candidate_path, candidate_root)
	if not candidate then
		return nil, pin_err
	end
	local target, target_err = safe_target(plan.install_directory, relative)
	if not target then
		discard_entry(candidate.directory, candidate.name, candidate.snapshot, "candidate-pin")
		close_promotion(candidate)
		return nil, target_err
	end
	local changed, chmod_err = chmod_candidate(candidate, mode)
	if not changed then
		discard_entry(candidate.directory, candidate.name, candidate.snapshot, "candidate-pin")
		close_promotion(candidate, target)
		return nil, chmod_err
	end
	local hook_ok, hook_err = run_test_hook("target_parent_validated", {
		parent = target.directory.path,
		target = target.path,
	})
	if not hook_ok or not directory_bound(target.directory) or not directory_bound(candidate.directory) then
		discard_entry(candidate.directory, candidate.name, candidate.snapshot, "candidate-pin")
		close_promotion(candidate, target)
		return nil, hook_ok and "target-parent-changed" or "target-parent-hook-failed:" .. tostring(hook_err)
	end
	local previous = entry_snapshot(target.directory, target.name, "target")
	if
		previous == nil
		or (target.original == false and previous ~= false)
		or (target.original ~= false and (previous == false or not same_file_snapshot(target.original, previous)))
	then
		discard_entry(candidate.directory, candidate.name, candidate.snapshot, "candidate-pin")
		close_promotion(candidate, target)
		return nil, "target-changed"
	end
	local result, promote_err, warnings, retain_stage
	if previous == false then
		result, warnings, retain_stage = promote_initial(candidate, target, mode)
		if not result then
			promote_err = warnings
		end
	else
		result, warnings, retain_stage = promote_existing(candidate, target, previous, mode)
		if not result then
			promote_err = warnings
		end
	end
	if not result then
		local retained = entry_snapshot(candidate.directory, candidate.name, "candidate-pin")
		if retained and same_file_snapshot(candidate.snapshot, retained) then
			discard_entry(candidate.directory, candidate.name, retained, "candidate-pin")
		end
		close_promotion(candidate, target)
		return nil, promote_err
	end
	local close_warnings = close_promotion(candidate, target)
	warnings = warnings or {}
	vim.list_extend(warnings, close_warnings)
	return {
		digest = candidate.snapshot.digest,
		path = result,
		retain_stage = retain_stage == true,
		warnings = warnings,
	}
end

local function promote(plan, candidate, stage_directory)
	local staging_root = stage_directory.path
	local result = { hashes = {}, paths = {}, warnings = {} }
	local command = plan.entry.executable
	local command_relative = plan.layout.commands[command]
	if plan.asset.kind ~= "jar" then
		local target, err = promote_file(plan, candidate, staging_root, command_relative, 493)
		if not target then
			return nil, err
		end
		result.paths[command_relative] = target.path
		result.hashes[command_relative] = target.digest
		vim.list_extend(result.warnings, target.warnings)
		result.retain_stage = target.retain_stage
		return result
	end

	local artifact_relative = plan.layout.artifacts[1]
	local artifact, artifact_err = promote_file(plan, candidate, staging_root, artifact_relative, 420)
	if not artifact then
		return nil, "artifact-" .. tostring(artifact_err)
	end
	result.paths[artifact_relative] = artifact.path
	result.hashes[artifact_relative] = artifact.digest
	vim.list_extend(result.warnings, artifact.warnings)
	result.retain_stage = result.retain_stage or artifact.retain_stage
	local wrapper = table.concat({
		"#!/bin/sh",
		"exec java -jar " .. shell_quote(artifact.path) .. ' "$@"',
		"",
	}, "\n")
	local wrapper_name = vim.fs.basename(fs.temp_path(vim.fs.joinpath(stage_directory.path, command)))
	local wrapper_candidate, write_err = write_staged_file(stage_directory, wrapper_name, wrapper, 384)
	if not wrapper_candidate then
		return nil, "wrapper-write-failed:" .. tostring(write_err)
	end
	local wrapper_target, wrapper_err = promote_file(plan, wrapper_candidate, staging_root, command_relative, 493)
	if not wrapper_target then
		return nil, "wrapper-promote-failed:" .. tostring(wrapper_err)
	end
	result.paths[command_relative] = wrapper_target.path
	result.hashes[command_relative] = wrapper_target.digest
	vim.list_extend(result.warnings, wrapper_target.warnings)
	result.retain_stage = result.retain_stage or wrapper_target.retain_stage
	return result
end

local function child(controller, command, options, callback)
	if controller.finished then
		return nil
	end
	if controller.cancel_requested then
		controller.finish(false, "cancelled")
		return nil
	end
	controller.signal_sent = false
	controller.child_serial = (controller.child_serial or 0) + 1
	local serial = controller.child_serial
	local completed = false
	local process
	process = M._run(command, options or { text = true }, function(result)
		completed = true
		if controller.child_serial == serial and controller.process == process then
			controller.process = nil
		end
		if controller.finished then
			return
		end
		if controller.cancel_requested then
			controller.finish(false, "cancelled")
			return
		end
		callback(result)
	end)
	if not completed and not controller.finished and controller.child_serial == serial then
		controller.process = process
		if
			controller.cancel_requested
			and process
			and type(process.kill) == "function"
			and not controller.signal_sent
		then
			controller.signal_sent = true
			pcall(process.kill, process, 15)
		end
	end
	return process
end

local function hash_bound_archive(plan, controller, binding, callback)
	local reset, reset_err = reset_bound_descriptor(binding)
	if not reset then
		callback(nil, reset_err)
		return
	end
	local command = plan.commands.sha256sum and { plan.commands.sha256sum, binding.child_path }
		or { plan.commands.shasum, "-a", "256", binding.child_path }
	child(controller, command, {
		bound_archive = true,
		inherited_fd = { child_fd = binding.child_fd, fd = binding.fd },
		text = true,
	}, function(result)
		local digest = type(result.stdout) == "string" and result.stdout:match("^([0-9a-fA-F]+)") or nil
		if result.code ~= 0 or not digest or #digest ~= 64 then
			callback(nil, "hash-failed")
			return
		end
		digest = digest:lower()
		local current, current_err = content_snapshot_fd(binding.fd)
		if
			not current
			or current.nlink ~= 0
			or current.digest ~= binding.digest
			or not same_inode(binding.snapshot, current)
		then
			callback(nil, "archive-changed:" .. tostring(current_err or "identity mismatch"))
			return
		end
		if digest ~= current.digest then
			callback(nil, "hash-disagreement")
			return
		end
		callback(digest)
	end)
end

local function extract(plan, controller, binding, stage_directory, callback)
	if plan.asset.kind == "file" or plan.asset.kind == "jar" then
		local candidate, candidate_err = materialize_bound_archive(stage_directory, binding, plan.asset.archive)
		callback(candidate, candidate_err)
		return
	end
	local extract_directory, root_err = open_child_directory(stage_directory, "extract", 448, true)
	if not extract_directory then
		callback(nil, root_err)
		return
	end
	local extract_root = extract_directory.path
	local function finish(candidate, err)
		close_fd(extract_directory.fd)
		callback(candidate, err)
	end
	if plan.asset.kind == "gzip" then
		local reset, reset_err = reset_bound_descriptor(binding)
		if not reset then
			finish(nil, reset_err)
			return
		end
		child(controller, { plan.commands.gzip, "-dc", binding.child_path }, {
			bound_archive = true,
			inherited_fd = { child_fd = binding.child_fd, fd = binding.fd },
			text = false,
		}, function(result)
			if result.code ~= 0 or type(result.stdout) ~= "string" then
				finish(nil, "extract-failed")
				return
			end
			local candidate, write_err = write_staged_file(extract_directory, plan.entry.executable, result.stdout, 384)
			if not candidate then
				finish(nil, "extract-write-failed:" .. tostring(write_err))
				return
			end
			finish(candidate)
		end)
		return
	end
	if not safe_relative(plan.asset.member) then
		finish(nil, "archive-member-unsafe")
		return
	end
	local command
	if plan.asset.kind == "zip" then
		command = { plan.commands.unzip, "-qq", binding.child_path, plan.asset.member, "-d", extract_root }
	else
		command = { plan.commands.tar, "-xf", binding.child_path, "-C", extract_root, plan.asset.member }
	end
	local reset, reset_err = reset_bound_descriptor(binding)
	if not reset then
		finish(nil, reset_err)
		return
	end
	child(controller, command, {
		bound_archive = true,
		inherited_fd = { child_fd = binding.child_fd, fd = binding.fd },
		text = true,
	}, function(result)
		if result.code ~= 0 then
			finish(nil, "extract-failed")
			return
		end
		if not directory_bound(extract_directory) then
			finish(nil, "extract-parent-changed")
			return
		end
		local candidate = vim.fs.joinpath(extract_root, plan.asset.member)
		local ok, err = safe_candidate(candidate, extract_root, false)
		if not ok then
			finish(nil, err)
			return
		end
		finish(candidate)
	end)
end

-- Cancellation only signals the active child. Completion, cleanup, and the
-- backend ACK happen from that child's exit callback.
function M.install(supplied, callback)
	callback = callback or function() end
	local plan, plan_err = validate_plan(supplied)
	if not plan then
		callback(false, plan_err)
		return false
	end
	local commands, command_err = resolve_prerequisites(plan)
	if not commands then
		callback(false, command_err)
		return false
	end
	plan.commands = commands
	local root, root_err = open_install_root(plan.install_root, 493)
	if not root then
		callback(false, root_err)
		return false
	end
	local staging_root, staging_err = open_child_directory(root, "staging", 448, true)
	if not staging_root then
		close_fd(root.fd)
		callback(false, staging_err)
		return false
	end
	local stage_name = ("job-%d-%s"):format(uv.os_getpid(), tostring(uv.hrtime()))
	local stage, stage_err = open_child_directory(staging_root, stage_name, 448, true)
	if not stage then
		close_fd(staging_root.fd)
		close_fd(root.fd)
		callback(false, "staging-create-failed:" .. tostring(stage_err))
		return false
	end
	plan.install_directory = root
	local controller = { cancel_requested = false, finished = false, process = nil, signal_sent = false }
	function controller.finish(success, value)
		if controller.finished then
			return
		end
		controller.finished = true
		controller.process = nil
		local warnings = cleanup(stage, staging_root, plan) or {}
		if controller.archive_binding then
			local closed, close_err = close_fd(controller.archive_binding.fd)
			if not closed then
				warnings[#warnings + 1] = "archive-descriptor-close-failed:" .. tostring(close_err)
			end
			controller.archive_binding = nil
		end
		for _, item in ipairs({
			{ directory = stage, label = "stage" },
			{ directory = staging_root, label = "staging-root" },
			{ directory = root, label = "install-root" },
		}) do
			local closed, close_err = close_fd(item.directory.fd)
			if not closed then
				warnings[#warnings + 1] = item.label .. "-close-failed:" .. tostring(close_err)
			end
		end
		if success and type(value) == "table" then
			value.warnings = value.warnings or {}
			vim.list_extend(value.warnings, warnings)
			value.warnings = bounded_warnings(value.warnings)
		end
		callback(success, value)
	end
	function controller.cancel()
		if controller.finished or controller.cancel_requested then
			return
		end
		controller.cancel_requested = true
		local process = controller.process
		if process and type(process.kill) == "function" and not controller.signal_sent then
			controller.signal_sent = true
			pcall(process.kill, process, 15)
		end
	end

	local archive = vim.fs.joinpath(stage.path, plan.asset.archive)
	child(controller, {
		plan.commands.curl,
		"--fail",
		"--location",
		"--silent",
		"--show-error",
		"--retry",
		"3",
		"--retry-all-errors",
		"--output",
		archive,
		plan.url,
	}, { text = true }, function(download)
		if download.code ~= 0 or not safe_candidate(archive, stage.path, false) then
			controller.finish(false, "download-failed")
			return
		end
		local binding, binding_err = bind_archive(stage, plan.asset.archive)
		if not binding then
			controller.finish(false, binding_err)
			return
		end
		controller.archive_binding = binding
		hash_bound_archive(plan, controller, binding, function(archive_digest, hash_err)
			if not archive_digest or archive_digest ~= plan.asset.sha256:lower() then
				controller.finish(false, archive_digest and "checksum-mismatch" or hash_err)
				return
			end
			extract(plan, controller, binding, stage, function(candidate, extract_err)
				if not candidate then
					controller.finish(false, extract_err)
					return
				end
				local current, current_err = content_snapshot_fd(binding.fd)
				if
					not current
					or current.nlink ~= 0
					or current.digest ~= binding.digest
					or not same_inode(binding.snapshot, current)
				then
					controller.finish(false, "archive-changed:" .. tostring(current_err or "identity mismatch"))
					return
				end
				local closed, close_err = close_fd(binding.fd)
				controller.archive_binding = nil
				if not closed then
					controller.finish(false, "archive-descriptor-close-failed:" .. tostring(close_err))
					return
				end
				local promoted, promote_err = promote(plan, candidate, stage)
				if not promoted then
					controller.finish(false, promote_err)
					return
				end
				plan.retain_stage = promoted.retain_stage == true
				local evidence_hook_ok, evidence_hook_err = run_test_hook("before_success_evidence", {
					artifacts = promoted.paths,
				})
				if not evidence_hook_ok then
					promoted.warnings[#promoted.warnings + 1] = "success-evidence-hook-failed:"
						.. tostring(evidence_hook_err)
				end
				controller.finish(true, {
					kind = "release-install-evidence",
					archive_sha256 = archive_digest,
					artifacts = promoted.hashes,
					warnings = promoted.warnings,
				})
			end)
		end)
	end)
	return controller
end

return M
