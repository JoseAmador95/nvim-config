-- Descriptor-relative private staging and atomic publication for GumTree.
local M = {}
local uv = vim.uv
local ffi = require("ffi")

pcall(
	ffi.cdef,
	[[
int openat(int fd, const char *path, int flags, ...);
int mkdirat(int fd, const char *path, unsigned int mode);
int unlinkat(int fd, const char *path, int flags);
int renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
int renameatx_np(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
]]
)

local darwin = uv.os_uname().sysname == "Darwin"
local flags = darwin
		and {
			at = -2,
			directory = 1048576,
			nofollow = 256,
			nonblock = 4,
			create = 512,
			exclusive = 2048,
			cloexec = 16777216,
			removedir = 128,
		}
	or {
		at = -100,
		directory = 65536,
		nofollow = 131072,
		nonblock = 2048,
		create = 64,
		exclusive = 128,
		cloexec = 524288,
		removedir = 512,
	}
local read_flags = flags.nofollow + flags.nonblock + flags.cloexec

M._interleave = function() end

local function name_ok(name)
	return type(name) == "string"
		and name ~= ""
		and #name <= 255
		and name ~= "."
		and name ~= ".."
		and not name:find("[/%z]")
end

local function same(a, b)
	return a
		and b
		and a.type == b.type
		and a.dev == b.dev
		and a.ino == b.ino
		and a.mode == b.mode
		and a.uid == b.uid
		and a.gid == b.gid
end

function M.bound(directory)
	return directory
		and directory.fd
		and same(uv.fs_fstat(directory.fd), directory.stat)
		and same(uv.fs_lstat(directory.path), directory.stat)
		and uv.fs_realpath(directory.path) == directory.path
end

function M.close(directory)
	if directory and directory.fd then
		local ok, err = uv.fs_close(directory.fd)
		directory.fd = nil
		return ok, err
	end
	return true
end

local function opened(fd, path, private)
	local stat = uv.fs_fstat(fd)
	local directory = { fd = fd, path = path, stat = stat }
	if
		not stat
		or stat.type ~= "directory"
		or (private and (stat.mode % 512 ~= 448 or stat.uid ~= uv.getuid()))
		or not M.bound(directory)
	then
		M.close(directory)
		return nil, "directory is unsafe or changed: " .. path
	end
	return directory
end

function M.open(path, private)
	if path ~= vim.fs.normalize(path) or uv.fs_realpath(path) ~= path then
		return nil, "directory is not canonical"
	end
	local fd = ffi.C.openat(flags.at, path, read_flags + flags.directory)
	if fd < 0 then
		return nil, "directory open failed: " .. tostring(ffi.errno())
	end
	return opened(tonumber(fd), path, private ~= false)
end

function M.child(parent, name, create)
	if not name_ok(name) or not M.bound(parent) then
		return nil, "directory parent or name is unsafe"
	end
	if create and ffi.C.mkdirat(parent.fd, name, 448) ~= 0 and ffi.errno() ~= 17 then
		return nil, "directory creation failed: " .. tostring(ffi.errno())
	end
	local fd = ffi.C.openat(parent.fd, name, read_flags + flags.directory)
	if fd < 0 then
		return nil, "directory child open failed: " .. tostring(ffi.errno())
	end
	local result, err = opened(tonumber(fd), parent.path .. "/" .. name, true)
	if result and (not M.bound(parent) or not uv.fs_fsync(parent.fd)) then
		M.close(result)
		return nil, "directory parent changed or could not sync"
	end
	return result, err
end

-- The managed root itself may predate this installer with mode 0755. Only that
-- exact owner-held directory is secured; unrelated ancestors are never chmodded.
function M.ensure(path, root)
	path, root = vim.fs.normalize(path), vim.fs.normalize(root)
	if path ~= root and path:sub(1, #root + 1) ~= root .. "/" then
		return nil, "directory escapes managed root"
	end
	local parent, err = M.open(vim.fs.dirname(root), false)
	if not parent then
		return nil, err
	end
	local root_name = vim.fs.basename(root)
	if ffi.C.mkdirat(parent.fd, root_name, 448) ~= 0 and ffi.errno() ~= 17 then
		M.close(parent)
		return nil, "managed root creation failed"
	end
	local fd = ffi.C.openat(parent.fd, root_name, read_flags + flags.directory)
	local stat = fd >= 0 and uv.fs_fstat(tonumber(fd)) or nil
	if not stat or stat.type ~= "directory" or stat.uid ~= uv.getuid() or not M.bound(parent) then
		if fd >= 0 then
			uv.fs_close(tonumber(fd))
		end
		M.close(parent)
		return nil, "managed root is unsafe"
	end
	local secured = uv.fs_fchmod(tonumber(fd), 448)
	local directory, open_err = opened(tonumber(fd), root, true)
	local synced = uv.fs_fsync(parent.fd)
	M.close(parent)
	if not secured or not directory or not synced then
		M.close(directory)
		return nil, open_err or "managed root could not be secured"
	end
	for name in path:sub(#root + 2):gmatch("[^/]+") do
		local child, child_err = M.child(directory, name, true)
		M.close(directory)
		if not child then
			return nil, child_err
		end
		directory = child
	end
	return directory
end

function M.write(directory, name, data, mode)
	if not name_ok(name) or not M.bound(directory) then
		return nil, "write parent is unsafe"
	end
	local fd = ffi.C.openat(
		directory.fd,
		name,
		read_flags + 1 + flags.create + flags.exclusive,
		ffi.cast("unsigned int", mode)
	)
	if fd < 0 then
		return nil, "exclusive file creation failed: " .. tostring(ffi.errno())
	end
	fd = tonumber(fd)
	local offset, err = 0, nil
	while offset < #data do
		local n, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not n or n < 1 then
			err = write_err or "short write"
			break
		end
		offset = offset + n
	end
	local stat = uv.fs_fstat(fd)
	local synced = not err and uv.fs_fchmod(fd, mode) and uv.fs_fsync(fd)
	local closed = uv.fs_close(fd)
	if not synced or not closed or not stat or stat.nlink ~= 1 or not M.bound(directory) then
		return nil, err or "file changed or could not sync"
	end
	return true
end

function M.write_path(root, relative, data, mode)
	local directory, err = M.open(root.path)
	if not directory or not M.bound(root) then
		M.close(directory)
		return nil, err or "bundle root changed"
	end
	local pieces = vim.split(relative, "/", { plain = true })
	local name = table.remove(pieces)
	for _, part in ipairs(pieces) do
		local child, child_err = M.child(directory, part, true)
		M.close(directory)
		if not child then
			return nil, child_err
		end
		directory = child
	end
	local ok, write_err = M.write(directory, name, data, mode)
	local synced = ok and uv.fs_fsync(directory.fd)
	M.close(directory)
	return ok and synced or nil, write_err
end

local function rename(source, source_name, target, target_name, exchange)
	local called, result = pcall(function()
		if darwin then
			return ffi.C.renameatx_np(source.fd, source_name, target.fd, target_name, exchange and 2 or 4)
		end
		return ffi.C.renameat2(source.fd, source_name, target.fd, target_name, exchange and 2 or 1)
	end)
	return called and result == 0 or nil, called and ffi.errno() or result
end

local function entry(parent, name)
	local path = parent.path .. "/" .. name
	local stat = uv.fs_lstat(path)
	if not stat then
		return false
	end
	if
		(stat.type ~= "file" and stat.type ~= "directory")
		or stat.uid ~= uv.getuid()
		or (stat.type == "file" and (stat.nlink ~= 1 or stat.mode % 512 ~= 384))
		or (stat.type == "directory" and stat.mode % 512 ~= 448)
	then
		return nil, "publication entry is unsafe"
	end
	return stat
end

-- Existing payloads/receipts are exchanged only during an explicit repair.
-- The displaced tree stays in private staging until publication is verified.
function M.publish(source, source_name, target, target_name)
	if not name_ok(source_name) or not name_ok(target_name) or not M.bound(source) or not M.bound(target) then
		return nil, "publication parent or name changed"
	end
	local candidate, candidate_err = entry(source, source_name)
	local previous, previous_err = entry(target, target_name)
	if not candidate or previous == nil then
		return nil, candidate_err or previous_err or "candidate is absent"
	end
	local source_path, target_path = source.path .. "/" .. source_name, target.path .. "/" .. target_name
	M._interleave("before-publish", { source = source_path, target = target_path })
	if
		not M.bound(source)
		or not M.bound(target)
		or not same(candidate, uv.fs_lstat(source_path))
		or (previous and not same(previous, uv.fs_lstat(target_path)))
	then
		return nil, "publication identity changed"
	end
	local ok, err = rename(source, source_name, target, target_name, previous ~= false)
	if not ok then
		return nil, "atomic publication failed: " .. tostring(err)
	end
	local published = uv.fs_lstat(target_path)
	local displaced = previous and uv.fs_lstat(source_path) or nil
	if
		not M.bound(source)
		or not M.bound(target)
		or not same(candidate, published)
		or (previous and not same(previous, displaced))
	then
		if M.bound(source) and M.bound(target) and same(candidate, published) and displaced then
			rename(source, source_name, target, target_name, true)
		end
		return nil, "published entry changed"
	end
	if not uv.fs_fsync(source.fd) or not uv.fs_fsync(target.fd) then
		return nil, "publication directory sync failed"
	end
	return true
end

-- Cleanup never follows links. A renamed/replaced parent is retained for
-- inspection instead of turning a failed installation into arbitrary deletion.
function M.clean(directory)
	if not M.bound(directory) then
		return nil, "cleanup parent changed"
	end
	local scan = uv.fs_scandir(directory.path)
	if not scan then
		return nil, "cleanup scan failed"
	end
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if not name_ok(name) or not M.bound(directory) then
			return nil, "cleanup parent changed"
		end
		local before = uv.fs_lstat(directory.path .. "/" .. name)
		if not before then
			return nil, "cleanup entry changed"
		end
		if before.type == "directory" then
			local child, err = M.child(directory, name, false)
			if not child then
				return nil, err
			end
			local ok, clean_err = M.clean(child)
			M.close(child)
			if not ok then
				return nil, clean_err
			end
		end
		if not M.bound(directory) or not same(before, uv.fs_lstat(directory.path .. "/" .. name)) then
			return nil, "cleanup entry changed"
		end
		if ffi.C.unlinkat(directory.fd, name, before.type == "directory" and flags.removedir or 0) ~= 0 then
			return nil, "cleanup unlink failed"
		end
	end
	return true
end

function M.canonical(value)
	if type(value) ~= "table" then
		return vim.json.encode(value)
	end
	local list, result = vim.islist(value), {}
	if list then
		for _, item in ipairs(value) do
			result[#result + 1] = M.canonical(item)
		end
		return "[" .. table.concat(result, ",") .. "]"
	end
	local keys = vim.tbl_keys(value)
	table.sort(keys)
	for _, key in ipairs(keys) do
		result[#result + 1] = vim.json.encode(key) .. ":" .. M.canonical(value[key])
	end
	return "{" .. table.concat(result, ",") .. "}"
end

return M
