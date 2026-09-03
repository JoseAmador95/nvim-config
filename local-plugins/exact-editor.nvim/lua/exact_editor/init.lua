-- Exact editor registry and request bridge.
local M = {}
local contracts = require("local_plugins.contracts")
local bit = require("bit")
local ffi = require("ffi")

local uv = vim.uv
local active
local deferred = false
local deferred_generation = 0
local configured = {}
local temp_counter = 0
local wait_controllers = {}
local test_hook
local heartbeat_generation = 0
local default_timer_factory = function()
	return uv.new_timer()
end
local timer_factory = default_timer_factory

local declared, declare_err = pcall(
	ffi.cdef,
	[[
		int openat(int dirfd, const char *pathname, int flags, ...);
		int unlinkat(int dirfd, const char *pathname, int flags);
		int fstatat(int dirfd, const char *pathname, void *status, int flags);
		int renameatx_np(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
		int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
		char *strerror(int error_number);
		struct exact_editor_darwin_stat {
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
		struct exact_editor_statx_timestamp {
			int64_t tv_sec;
			uint32_t tv_nsec;
			int32_t reserved;
		};
		struct exact_editor_linux_statx {
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
			struct exact_editor_statx_timestamp stx_atime;
			struct exact_editor_statx_timestamp stx_btime;
			struct exact_editor_statx_timestamp stx_ctime;
			struct exact_editor_statx_timestamp stx_mtime;
			uint32_t stx_rdev_major;
			uint32_t stx_rdev_minor;
			uint32_t stx_dev_major;
			uint32_t stx_dev_minor;
			uint64_t spare2[14];
		};
		int statx(int dirfd, const char *pathname, int flags, unsigned int mask,
			struct exact_editor_linux_statx *status);
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
			symlink_no_follow = 0x00000020,
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
			symlink_no_follow = 0x00000100,
			rename = "renameat2",
			rename_noreplace_flag = 0x00000001,
			eexist = 17,
			noent = 2,
		}
	end
end

local SETUP_KEYS = {
	state_root = true,
	resolve_workspace = true,
	open = true,
	resolve_relative = true,
	clock = true,
	pid = true,
	uuid = true,
	server_start = true,
	server_stop = true,
	notify = true,
	install_finish_mapping = true,
	workspace_retention = true,
	registry_heartbeat_seconds = true,
	on_state_change = true,
}

local RECORD_KEYS = {
	version = true,
	instance_id = true,
	pid = true,
	socket = true,
	workspaces = true,
	TMUX_PANE = true,
	updated_at = true,
}
local REQUEST_KEYS = {
	version = true,
	request_id = true,
	instance_id = true,
	repo_root = true,
	path = true,
	line = true,
	column = true,
	created_at = true,
}
local WAIT_REQUEST_KEYS = {
	version = true,
	request_id = true,
	instance_id = true,
	repo_root = true,
	path = true,
	created_at = true,
}
local WAIT_STATE_KEYS = {
	version = true,
	request_id = true,
	instance_id = true,
	status = true,
	updated_at = true,
}

local function notify(message, level)
	local report = configured.notify or vim.notify
	pcall(report, message, level or vim.log.levels.INFO, { title = "Exact Editor" })
end

local function copy(value)
	return vim.deepcopy(value)
end

local function emit(kind, details)
	if type(configured.on_state_change) ~= "function" then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	pcall(configured.on_state_change, event)
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

local function same_identity(left, right)
	return left and right and left.type == right.type and left.dev == right.dev and left.ino == right.ino
end

local function uuid()
	if type(configured.uuid) == "function" then
		return configured.uuid()
	end
	local bytes = assert(uv.random(16))
	local values = { bytes:byte(1, 16) }
	values[7] = values[7] % 16 + 64
	values[9] = values[9] % 64 + 128
	return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", unpack(values))
end

local function is_uuid(value)
	return type(value) == "string"
		and value:match(
				"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
			)
			~= nil
end

local function canonical_timestamp(value)
	if type(value) ~= "string" then
		return false
	end
	local year, month, day, hour, minute, second = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if not year then
		return false
	end
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
	if year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then
		return false
	end
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
		days[2] = 29
	end
	return day >= 1 and day <= days[month]
end

local function timestamp(source)
	local selected = source or configured
	local clock = selected.clock or function()
		return os.date("!%Y-%m-%dT%H:%M:%SZ")
	end
	local ok, value = pcall(clock)
	if not ok then
		return nil, "clock callback failed: " .. tostring(value)
	end
	if not canonical_timestamp(value) then
		return nil, "clock callback must return a canonical UTC timestamp"
	end
	return value
end

function M.state_root()
	local root = configured.state_root
	if type(root) == "function" then
		root = root()
	end
	if type(root) ~= "string" or root == "" then
		if vim.env.NVIM_EXACT_EDITOR_STATE_HOME and vim.env.NVIM_EXACT_EDITOR_STATE_HOME ~= "" then
			root = vim.env.NVIM_EXACT_EDITOR_STATE_HOME
		elseif vim.env.XDG_STATE_HOME and vim.env.XDG_STATE_HOME ~= "" then
			root = vim.fs.joinpath(vim.env.XDG_STATE_HOME, "exact-editor")
		else
			root = vim.fs.joinpath(vim.env.HOME, ".local", "state", "exact-editor")
		end
	end
	return vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
end

local function run_test_hook(event, details)
	if type(test_hook) ~= "function" then
		return true
	end
	local ok, err = pcall(test_hook, event, copy(details))
	return ok and true or nil, ok and nil or tostring(err)
end

local function descriptor_error(label, number)
	number = number or ffi.errno()
	local ok, message = pcall(function()
		return ffi.string(ffi.C.strerror(number))
	end)
	return ("%s: errno %d%s"):format(label, number, ok and " (" .. message .. ")" or "")
end

local function close_descriptor(fd)
	if not fd then
		return true
	end
	local closed, close_err = uv.fs_close(fd)
	return closed and true or nil, closed and nil or tostring(close_err)
end

local function private_name(name)
	return type(name) == "string"
		and name ~= ""
		and name ~= "."
		and name ~= ".."
		and not name:find("/", 1, true)
		and not name:find("\0", 1, true)
end

local function anchor_valid(anchor)
	local opened = anchor and anchor.fd and uv.fs_fstat(anchor.fd) or nil
	local current = anchor and anchor.path and uv.fs_lstat(anchor.path) or nil
	return same_identity(opened, anchor and anchor.identity) and same_identity(current, anchor and anchor.identity)
end

local function open_parent_anchor(path)
	if not descriptor_api then
		return nil, "descriptor-relative cleanup requires 64-bit Darwin or Linux"
	end
	local parent = vim.fs.dirname(path)
	local name = vim.fs.basename(path)
	if not private_name(name) then
		return nil, "cleanup path has an invalid basename"
	end
	local before = uv.fs_lstat(parent)
	if not before or before.type ~= "directory" or before.mode % 512 ~= tonumber("700", 8) then
		return nil, "cleanup parent must be a real owner-only directory: " .. parent
	end
	local flags = bit.bor(
		descriptor_api.directory,
		descriptor_api.nonblock,
		descriptor_api.no_follow,
		descriptor_api.close_on_exec
	)
	ffi.errno(0)
	local raw_fd = ffi.C.openat(descriptor_api.at_fdcwd, parent, flags)
	if raw_fd < 0 then
		return nil, descriptor_error("could not pin cleanup parent")
	end
	local fd = tonumber(raw_fd)
	local opened = uv.fs_fstat(fd)
	local anchor = { fd = fd, path = parent, identity = opened }
	if not opened or opened.type ~= "directory" or not same_identity(before, opened) or not anchor_valid(anchor) then
		close_descriptor(fd)
		return nil, "cleanup parent changed while it was pinned"
	end
	return anchor, name
end

local function integer_key(value)
	return tostring(value):gsub("ULL$", ""):gsub("LL$", "")
end

local function entry_kind(mode)
	local kind = bit.band(mode, 0xF000)
	return kind == 0x8000 and "file"
		or kind == 0x4000 and "directory"
		or kind == 0xA000 and "link"
		or kind == 0xC000 and "socket"
		or "other"
end

local function anchored_entry_stat(anchor, name, label)
	if not anchor_valid(anchor) then
		return nil, "cleanup parent changed before inspecting " .. label
	end
	if descriptor_api.rename == "renameatx_np" then
		local raw = ffi.new("struct exact_editor_darwin_stat")
		if ffi.C.fstatat(anchor.fd, name, raw, descriptor_api.symlink_no_follow) ~= 0 then
			local number = ffi.errno()
			if number == descriptor_api.noent then
				return false
			end
			return nil, descriptor_error("could not inspect " .. label, number)
		end
		local mode = tonumber(raw.st_mode_value)
		return {
			type = entry_kind(mode),
			ino = integer_key(raw.st_ino_value),
			mode = mode,
			nlink = tonumber(raw.st_nlink_value),
			size = tonumber(raw.st_size_value),
		}
	end
	local raw = ffi.new("struct exact_editor_linux_statx")
	local called, result = pcall(ffi.C.statx, anchor.fd, name, descriptor_api.symlink_no_follow, 0x000007FF, raw)
	if not called then
		return nil, "descriptor-relative statx is unavailable: " .. tostring(result)
	end
	if result ~= 0 then
		local number = ffi.errno()
		if number == descriptor_api.noent then
			return false
		end
		return nil, descriptor_error("could not inspect " .. label, number)
	end
	local mode = tonumber(raw.stx_mode)
	return {
		type = entry_kind(mode),
		ino = integer_key(raw.stx_ino),
		mode = mode,
		nlink = tonumber(raw.stx_nlink),
		size = tonumber(raw.stx_size),
	}
end

local function matches_expected(actual, expected, kind)
	if not actual or not expected or actual.type ~= kind or expected.type ~= kind then
		return false
	end
	if actual.ino ~= integer_key(expected.ino) or actual.nlink ~= 1 or expected.nlink ~= 1 then
		return false
	end
	if kind == "file" then
		return actual.mode == expected.mode and actual.size == expected.size
	end
	return true
end

local function exclusive_rename(anchor, source, destination)
	if not private_name(source) or not private_name(destination) or not anchor_valid(anchor) then
		return nil, "anchored cleanup rename is invalid", -1
	end
	ffi.errno(0)
	local called, result = pcall(function()
		if descriptor_api.rename == "renameatx_np" then
			return ffi.C.renameatx_np(anchor.fd, source, anchor.fd, destination, descriptor_api.rename_noreplace_flag)
		end
		return ffi.C.renameat2(anchor.fd, source, anchor.fd, destination, descriptor_api.rename_noreplace_flag)
	end)
	if not called then
		return nil, "descriptor-relative exclusive rename is unavailable: " .. tostring(result), -1
	end
	if result == 0 then
		return true
	end
	local number = ffi.errno()
	return nil, descriptor_error("could not reserve cleanup entry", number), number
end

local function sync_and_close(anchor, warning)
	if anchor_valid(anchor) then
		local synced, sync_err = uv.fs_fsync(anchor.fd)
		if not synced then
			warning = warning or "cleanup directory fsync failed: " .. tostring(sync_err)
		end
	else
		warning = warning or "cleanup parent changed before directory fsync"
	end
	local closed, close_err = close_descriptor(anchor.fd)
	anchor.fd = nil
	if not closed then
		warning = warning or "cleanup directory close failed: " .. tostring(close_err)
	end
	return warning == nil and true or nil, warning
end

local function restore_reserved_entry(anchor, name, reserved, reserved_path, reason)
	local restored, restore_err = exclusive_rename(anchor, reserved, name)
	if not restored then
		sync_and_close(anchor)
		return nil,
			tostring(reason) .. "; replacement remains preserved at " .. reserved_path .. ": " .. tostring(restore_err)
	end
	local _, warning = sync_and_close(anchor)
	return nil, tostring(reason) .. "; replacement was restored" .. (warning and "; " .. warning or "")
end

local function reserve_cleanup(path, expected, kind, options)
	if expected == nil and not (options and options.allow_unowned == true) then
		return nil, "conditional cleanup requires an exact owned identity"
	end
	local anchor, name_or_err = open_parent_anchor(path)
	if not anchor then
		return nil, name_or_err
	end
	local name = name_or_err
	local current, current_err = anchored_entry_stat(anchor, name, kind .. " cleanup entry")
	if current == false then
		close_descriptor(anchor.fd)
		return false
	end
	if not current then
		close_descriptor(anchor.fd)
		return nil, current_err
	end
	if current.type ~= kind or current.nlink ~= 1 then
		close_descriptor(anchor.fd)
		return nil, "cleanup entry is not one owned " .. kind .. ": " .. path
	end
	if expected and not matches_expected(current, expected, kind) then
		close_descriptor(anchor.fd)
		return nil, "cleanup entry identity changed before reservation: " .. path
	end
	local hook_ok, hook_err = run_test_hook("before_cleanup_reserve", {
		kind = kind,
		path = path,
	})
	if not hook_ok then
		close_descriptor(anchor.fd)
		return nil, "cleanup reserve hook failed: " .. tostring(hook_err)
	end
	local reserved
	for _ = 1, 64 do
		temp_counter = temp_counter + 1
		reserved = (".%s.%d.%d.retire"):format(name, uv.os_getpid(), temp_counter)
		local moved, move_err, number = exclusive_rename(anchor, name, reserved)
		if moved then
			break
		end
		if number == descriptor_api.noent then
			close_descriptor(anchor.fd)
			return false
		end
		if number ~= descriptor_api.eexist then
			close_descriptor(anchor.fd)
			return nil, move_err
		end
		reserved = nil
	end
	if not reserved then
		close_descriptor(anchor.fd)
		return nil, "cleanup reservation namespace is exhausted"
	end
	local reserved_path = vim.fs.joinpath(anchor.path, reserved)
	local reservation = {
		anchor = anchor,
		name = name,
		path = path,
		reserved = reserved,
		reserved_path = reserved_path,
		expected = expected,
		kind = kind,
		owned = false,
	}
	local hook_ok, hook_err = run_test_hook("after_cleanup_reserve", {
		kind = kind,
		path = path,
		reserved = reserved_path,
	})
	if not hook_ok then
		return restore_reserved_entry(
			anchor,
			name,
			reserved,
			reserved_path,
			"cleanup post-reserve hook failed: " .. tostring(hook_err)
		)
	end
	local reserved_stat, reserved_err = anchored_entry_stat(anchor, reserved, "reserved " .. kind)
	if not reserved_stat then
		return restore_reserved_entry(
			anchor,
			name,
			reserved,
			reserved_path,
			"reserved cleanup entry could not be inspected: " .. tostring(reserved_err)
		)
	end
	reservation.owned = matches_expected(reserved_stat, expected, kind)
	return reservation
end

local function restore_reservation(reservation, reason)
	return restore_reserved_entry(
		reservation.anchor,
		reservation.name,
		reservation.reserved,
		reservation.reserved_path,
		reason
	)
end

local function retire_reservation(reservation)
	if not reservation.owned then
		return restore_reservation(reservation, "cleanup entry identity changed during reservation")
	end
	local hook_ok, hook_err = run_test_hook("before_cleanup_unlink", {
		kind = reservation.kind,
		path = reservation.path,
		reserved = reservation.reserved_path,
	})
	if not hook_ok then
		return restore_reservation(reservation, "cleanup unlink hook failed: " .. tostring(hook_err))
	end
	local final, final_err =
		anchored_entry_stat(reservation.anchor, reservation.reserved, "final reserved " .. reservation.kind)
	if not matches_expected(final, reservation.expected, reservation.kind) then
		return restore_reservation(
			reservation,
			"cleanup entry changed immediately before unlink: " .. tostring(final_err or "identity mismatch")
		)
	end
	if ffi.C.unlinkat(reservation.anchor.fd, reservation.reserved, 0) ~= 0 then
		return restore_reservation(reservation, descriptor_error("could not unlink reserved cleanup entry"))
	end
	local _, warning = sync_and_close(reservation.anchor)
	return true, warning
end

local function unlink_regular(path, expected)
	local reservation, reserve_err = reserve_cleanup(path, expected, "file")
	if reservation == false then
		return true
	end
	if not reservation then
		return nil, reserve_err
	end
	return retire_reservation(reservation)
end

local function atomic_write(path, data)
	local current = uv.fs_lstat(path)
	if current and current.type ~= "file" then
		return nil, "target is not a regular file: " .. path
	end
	temp_counter = temp_counter + 1
	local temp = ("%s.tmp.%d.%s.%d"):format(path, uv.os_getpid(), tostring(uv.hrtime()), temp_counter)
	local fd, open_err = uv.fs_open(temp, "wx", tonumber("600", 8))
	if not fd then
		return nil, "cannot open temporary file: " .. tostring(open_err)
	end
	local temp_identity = uv.fs_fstat(fd)
	if not temp_identity or temp_identity.type ~= "file" or temp_identity.nlink ~= 1 then
		pcall(uv.fs_close, fd)
		return nil, "temporary file identity is unsafe; staging was preserved"
	end
	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, fd)
			unlink_regular(temp, temp_identity)
			return nil, "cannot write temporary file: " .. tostring(write_err or "zero-byte write")
		end
		offset = offset + written
	end
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if not synced or not closed then
		unlink_regular(temp, temp_identity)
		return nil, "cannot persist temporary file: " .. tostring(sync_err or close_err)
	end
	local renamed, rename_err = uv.fs_rename(temp, path)
	if not renamed then
		unlink_regular(temp, temp_identity)
		return nil, "cannot replace target file: " .. tostring(rename_err)
	end
	local published = uv.fs_lstat(path)
	if
		not published
		or published.type ~= "file"
		or published.nlink ~= 1
		or published.mode % 512 ~= tonumber("600", 8)
		or not same_identity(published, temp_identity)
	then
		return nil, "published target identity changed; replacement was preserved"
	end
	return true, nil, published
end

local function secure_read(path, label, maximum)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" or before.nlink ~= 1 then
		return nil, label .. " is missing or is not a regular non-symlink file"
	end
	if before.mode % 512 ~= tonumber("600", 8) then
		return nil, label .. " is not owner-only"
	end
	if before.size > maximum then
		return nil, label .. " exceeds 64 KiB"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "cannot open " .. label .. ": " .. tostring(open_err)
	end
	local opened, stat_err = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or opened.dev ~= before.dev
		or opened.ino ~= before.ino
		or opened.size ~= before.size
	then
		pcall(uv.fs_close, fd)
		return nil, label .. " changed while opening: " .. tostring(stat_err or "identity mismatch")
	end
	local data, read_err = uv.fs_read(fd, opened.size, 0)
	local closed, close_err = uv.fs_close(fd)
	if data == nil or not closed then
		return nil, "cannot read " .. label .. ": " .. tostring(read_err or close_err)
	end
	local after = uv.fs_lstat(path)
	if
		not after
		or after.type ~= "file"
		or after.nlink ~= 1
		or after.dev ~= opened.dev
		or after.ino ~= opened.ino
		or after.size ~= opened.size
		or after.mode ~= opened.mode
	then
		return nil, label .. " changed while validating"
	end
	return data,
		nil,
		{
			type = opened.type,
			dev = opened.dev,
			ino = opened.ino,
			size = opened.size,
			mode = opened.mode,
			nlink = opened.nlink,
		}
end

local function normalize_workspace(value)
	local workspace, workspace_err = contracts.normalize_workspace_key(value)
	if not workspace then
		return nil, workspace_err
	end
	local normalized = vim.fs.normalize(workspace.root)
	local canonical = uv.fs_realpath(normalized)
	if not canonical or vim.fs.normalize(canonical) ~= normalized then
		return nil, "workspace root must exist and be canonical"
	end
	return {
		runtime = workspace.runtime,
		root = normalized,
		repo_identity = workspace.repo_identity,
	}
end

local function workspace_identity(value)
	return table.concat({ value.runtime, value.root, value.repo_identity }, "\0")
end

local function workspace_list(instance)
	local values = {}
	for _, workspace in pairs(instance.workspaces or {}) do
		local normalized, err = normalize_workspace(workspace)
		if not normalized then
			return nil, err
		end
		values[#values + 1] = normalized
	end
	table.sort(values, function(left, right)
		return workspace_identity(left) < workspace_identity(right)
	end)
	return values
end

local function workspace_for_root(instance, root)
	for _, workspace in pairs(instance.workspaces or {}) do
		if workspace.root == root then
			return workspace
		end
	end
	return nil
end

local function contained(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function resolve_relative(root, relative)
	if type(relative) ~= "string" or relative == "" or relative:sub(1, 1) == "/" or relative:find("%z") then
		return nil, "request path must be a non-empty relative path"
	end
	for part in relative:gmatch("[^/]+") do
		if part == ".." then
			return nil, "request path traversal is not allowed"
		end
	end
	local canonical_root = uv.fs_realpath(root)
	local target = uv.fs_realpath(vim.fs.joinpath(root, relative))
	if not canonical_root or not target or not contained(canonical_root, target) then
		return nil, "request path resolves outside the workspace"
	end
	local stat = uv.fs_lstat(target)
	if not stat or stat.type ~= "file" then
		return nil, "request path is not a regular file"
	end
	return target
end

local function ensure_directory(path)
	if vim.fn.mkdir(path, "p", tonumber("700", 8)) == 0 then
		local stat = uv.fs_lstat(path)
		if not stat or stat.type ~= "directory" then
			return nil, "state path is not a real directory: " .. path
		end
	end
	local stat = uv.fs_lstat(path)
	if not stat or stat.type ~= "directory" then
		return nil, "state path is not a real directory: " .. path
	end
	local ok, err = uv.fs_chmod(path, tonumber("700", 8))
	if not ok then
		return nil, "cannot secure state directory: " .. tostring(err)
	end
	return true
end

local function prepare_state(root)
	for _, path in ipairs({
		root,
		vim.fs.joinpath(root, "editors"),
		vim.fs.joinpath(root, "requests"),
		vim.fs.joinpath(root, "waits"),
		vim.fs.joinpath(root, "sockets"),
	}) do
		local ok, err = ensure_directory(path)
		if not ok then
			return nil, err
		end
	end
	return true
end

local function record_path(instance)
	return vim.fs.joinpath(instance.root, "editors", instance.instance_id .. ".json")
end

local function request_path(instance, request_id)
	return vim.fs.joinpath(instance.root, "requests", request_id .. ".json")
end

local function wait_path(instance, request_id)
	return vim.fs.joinpath(instance.root, "waits", request_id .. ".json")
end

function M.write_registry(instance)
	local workspaces, workspace_err = workspace_list(instance)
	if not workspaces then
		return nil, workspace_err
	end
	local updated_at, timestamp_err = timestamp()
	if not updated_at then
		return nil, timestamp_err
	end
	local record = {
		version = 2,
		instance_id = instance.instance_id,
		pid = instance.pid or (configured.pid and configured.pid() or uv.os_getpid()),
		socket = instance.socket,
		workspaces = workspaces,
		TMUX_PANE = vim.env.TMUX_PANE or vim.NIL,
		updated_at = updated_at,
	}
	local encoded = vim.json.encode(record) .. "\n"
	local ok, err, identity = atomic_write(record_path(instance), encoded)
	if not ok then
		return nil, err
	end
	instance.registry_identity = identity
	return copy(record)
end

local function exact_keys(value, allowed, label)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains an unknown key"
		end
	end
	return true
end

local function positive_integer(value)
	return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function write_wait_state(instance, request_id, status)
	if status ~= "waiting" and status ~= "completed" and status ~= "aborted" then
		return nil, "wait state status is invalid"
	end
	local updated_at, timestamp_err = timestamp()
	if not updated_at then
		return nil, timestamp_err
	end
	local state = {
		version = 1,
		request_id = request_id,
		instance_id = instance.instance_id,
		status = status,
		updated_at = updated_at,
	}
	local path = wait_path(instance, request_id)
	local ok, err = atomic_write(path, vim.json.encode(state) .. "\n")
	if not ok then
		return nil, err
	end
	return state
end

local function canonical_editor_file(path)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
		return nil, "editor path must be an absolute path"
	end
	local normalized = vim.fs.normalize(path)
	local resolved = uv.fs_realpath(normalized)
	if not resolved or vim.fs.normalize(resolved) ~= normalized then
		return nil, "editor path is missing or is not canonical"
	end
	local stat = uv.fs_lstat(normalized)
	if not stat or stat.type ~= "file" then
		return nil, "editor path is not a regular non-symlink file"
	end
	local fd, open_err = uv.fs_open(normalized, "r", 0)
	if not fd then
		return nil, "cannot open editor path: " .. tostring(open_err)
	end
	local opened_stat, opened_stat_err = uv.fs_fstat(fd)
	if not opened_stat or opened_stat.type ~= "file" or opened_stat.dev ~= stat.dev or opened_stat.ino ~= stat.ino then
		pcall(uv.fs_close, fd)
		return nil, "editor path changed while opening: " .. tostring(opened_stat_err or "identity mismatch")
	end
	local offset = 0
	local read_err
	while offset < opened_stat.size do
		local chunk
		chunk, read_err = uv.fs_read(fd, math.min(64 * 1024, opened_stat.size - offset), offset)
		if chunk == nil or chunk == "" then
			break
		end
		if chunk:find("\0", 1, true) then
			pcall(uv.fs_close, fd)
			return nil, "editor path is not a text file"
		end
		offset = offset + #chunk
	end
	local closed, close_err = uv.fs_close(fd)
	if offset ~= opened_stat.size then
		return nil, "cannot inspect editor path: " .. tostring(read_err)
	end
	if not closed then
		return nil, "cannot close editor path: " .. tostring(close_err)
	end
	local final_stat = uv.fs_lstat(normalized)
	if
		not final_stat
		or final_stat.type ~= "file"
		or final_stat.dev ~= opened_stat.dev
		or final_stat.ino ~= opened_stat.ino
	then
		return nil, "editor path changed while validating"
	end
	return normalized
end

local function preserve_modified_buffer(buf, target)
	if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
		return
	end
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
	if not ok then
		return
	end
	local filetype = vim.bo[buf].filetype
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local recovery = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_lines(recovery, 0, -1, false, lines)
		vim.bo[recovery].filetype = filetype
		vim.bo[recovery].modified = true
		vim.b[recovery].nvim_editor_recovery_target = target
		if not vim.api.nvim_buf_is_valid(recovery) then
			return
		end
		if vim.fn.bufnr(target) == -1 then
			pcall(vim.api.nvim_buf_set_name, recovery, target)
		end
		notify(("Unsaved external-editor text was preserved in buffer %d"):format(recovery), vim.log.levels.WARN)
	end)
end

local function cleanup_wait_controller(controller)
	pcall(vim.api.nvim_del_augroup_by_id, controller.group)
	if type(controller.remove_finish_mapping) == "function" then
		pcall(controller.remove_finish_mapping)
	end
	wait_controllers[controller.buf] = nil
end

local function finish_wait_controller(controller, requested_status)
	if wait_controllers[controller.buf] ~= controller then
		return true
	end
	local status = requested_status
	if status ~= "aborted" and vim.api.nvim_buf_is_valid(controller.buf) and vim.bo[controller.buf].modified then
		status = "aborted"
	end
	local ids = vim.tbl_keys(controller.requests)
	table.sort(ids)
	local failures = {}
	for _, request_id in ipairs(ids) do
		local request = controller.requests[request_id]
		local persisted, err = write_wait_state(request.instance, request_id, status)
		if persisted then
			controller.requests[request_id] = nil
			emit("wait-finished", { request_id = request_id, buf = controller.buf, status = status })
		else
			failures[#failures + 1] = request_id .. ": " .. tostring(err)
		end
	end
	if next(controller.requests) == nil then
		cleanup_wait_controller(controller)
	end
	if #failures > 0 then
		local message = "Could not update editor wait state: " .. table.concat(failures, "; ")
		notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	return true
end

local function create_wait_controller(buf, dependencies)
	local controller = {
		buf = buf,
		requests = {},
		windows = {},
		recovery_created = false,
	}
	controller.group = vim.api.nvim_create_augroup("exact_editor_wait_buf_" .. tostring(buf), { clear = true })

	local function first_target()
		local ids = vim.tbl_keys(controller.requests)
		table.sort(ids)
		return ids[1] and controller.requests[ids[1]].target or nil
	end
	local function preserve_if_modified()
		if not controller.recovery_created and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
			controller.recovery_created = true
			preserve_modified_buffer(buf, first_target() or "")
		end
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = controller.group,
		callback = function(args)
			local win = tonumber(args.match)
			if not win or not controller.windows[win] then
				return
			end
			local completed = not (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified)
			preserve_if_modified()
			finish_wait_controller(controller, "completed")
			if completed then
				vim.schedule(function()
					if
						vim.api.nvim_buf_is_valid(buf)
						and not vim.bo[buf].modified
						and #vim.fn.win_findbuf(buf) == 0
					then
						pcall(vim.api.nvim_buf_delete, buf, { force = false })
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = controller.group,
		buffer = buf,
		callback = function()
			preserve_if_modified()
			finish_wait_controller(controller, "completed")
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = controller.group,
		callback = function()
			finish_wait_controller(controller, "completed")
		end,
	})

	local function save_and_finish()
		local wrote, write_err = pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd.write()
		end)
		if not wrote or (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified) then
			finish_wait_controller(controller, "aborted")
			notify("Could not save external-editor text: " .. tostring(write_err), vim.log.levels.ERROR)
			return
		end
		local finished = finish_wait_controller(controller, "completed")
		if not finished then
			return
		end
		local current = vim.api.nvim_get_current_win()
		if controller.windows[current] and vim.api.nvim_win_is_valid(current) then
			local closed, close_window_err = pcall(vim.api.nvim_win_close, current, false)
			if not closed then
				notify("Could not close external-editor window: " .. tostring(close_window_err), vim.log.levels.ERROR)
			end
		end
	end
	local install_finish_mapping = (dependencies and dependencies.install_finish_mapping)
		or configured.install_finish_mapping
	if type(install_finish_mapping) == "function" then
		local installed, remover_or_err = pcall(install_finish_mapping, buf, save_and_finish)
		if not installed or (remover_or_err ~= nil and type(remover_or_err) ~= "function") then
			cleanup_wait_controller(controller)
			return nil, "could not install external-editor finish action: " .. tostring(remover_or_err)
		end
		controller.remove_finish_mapping = remover_or_err
	end
	wait_controllers[buf] = controller
	return controller
end

local function arm_editor_wait(instance, request_id, target, win, buf, dependencies)
	local controller = wait_controllers[buf]
	if not controller then
		local controller_err
		controller, controller_err = create_wait_controller(buf, dependencies)
		if not controller then
			return nil, controller_err
		end
	end
	if controller.requests[request_id] then
		return nil, "editor wait request is already armed"
	end
	controller.requests[request_id] = {
		instance = instance,
		target = target,
		win = win,
	}
	controller.windows[win] = true
	local durable, state_err = write_wait_state(instance, request_id, "waiting")
	if not durable then
		controller.requests[request_id] = nil
		if next(controller.requests) == nil then
			cleanup_wait_controller(controller)
		end
		return nil, state_err
	end
	emit("wait-armed", { request_id = request_id, buf = buf, win = win, target = target, status = "waiting" })
	return true
end

local function consume(request_id, instance, dependencies, expected_version)
	if not is_uuid(request_id) then
		return nil, "request id must be a lowercase UUID"
	end
	local path = request_path(instance, request_id)
	local encoded, read_err, request_identity = secure_read(path, "request", 64 * 1024)
	if not encoded then
		return nil, read_err
	end
	local removed, remove_err = unlink_regular(path, request_identity)
	if not removed then
		return nil, "request was replaced before identity-bound cleanup: " .. tostring(remove_err)
	end
	local ok, value = pcall(vim.json.decode, encoded)
	if not ok or type(value) ~= "table" or vim.islist(value) then
		return nil, "request must be one JSON object"
	end
	local request_keys = value.version == 2 and WAIT_REQUEST_KEYS or REQUEST_KEYS
	local keys_ok, keys_err = exact_keys(value, request_keys, "request")
	if not keys_ok then
		return nil, keys_err
	end
	for key in pairs(request_keys) do
		if value[key] == nil then
			return nil, "request is missing " .. key
		end
	end
	if
		(value.version ~= 1 and value.version ~= 2)
		or value.request_id ~= request_id
		or value.instance_id ~= instance.instance_id
	then
		return nil, "request identity does not match the selected editor"
	end
	if expected_version and value.version ~= expected_version then
		return nil, expected_version == 1 and "request is not normal" or "request is not blocking"
	end
	if type(value.created_at) ~= "string" or value.created_at == "" then
		return nil, "request created_at is invalid"
	end
	if value.version == 1 and (not positive_integer(value.line) or not positive_integer(value.column)) then
		return nil, "request line and column must be positive integers"
	end
	if type(value.repo_root) ~= "string" or not workspace_for_root(instance, value.repo_root) then
		return nil, "request repository is not registered by this editor"
	end
	local canonical = uv.fs_realpath(value.repo_root)
	if not canonical or vim.fs.normalize(canonical) ~= value.repo_root then
		return nil, "request repository is not canonical"
	end
	local open_file = (dependencies and dependencies.open_file) or configured.open
	if type(open_file) ~= "function" then
		return nil, "open callback is not configured"
	end
	if value.version == 1 then
		local resolver = (dependencies and dependencies.resolve_relative)
			or configured.resolve_relative
			or resolve_relative
		local target, target_err = resolver(canonical, value.path)
		if not target then
			return nil, target_err
		end
		open_file(target, { lnum = value.line, col = value.column })
		return 1
	end

	local target, target_err = canonical_editor_file(value.path)
	if not target then
		return nil, target_err
	end
	open_file(target, { lnum = 1, col = 1 })
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
		return nil, "editor did not leave one observable current window"
	end
	local opened = uv.fs_realpath(vim.api.nvim_buf_get_name(buf))
	if not opened or vim.fs.normalize(opened) ~= target then
		return nil, "editor opened a different target"
	end
	local revalidated, revalidate_err = canonical_editor_file(target)
	if not revalidated then
		return nil, revalidate_err
	end
	local armed, arm_err = arm_editor_wait(instance, request_id, target, win, buf, dependencies)
	if not armed then
		return nil, arm_err
	end
	return 1
end

function M.consume_request(request_id, instance, dependencies)
	local selected = instance or active
	if not selected then
		return nil, "no active exact editor instance"
	end
	return consume(request_id, selected, dependencies)
end

function M.consume_normal(request_id, instance, dependencies)
	local selected = instance or active
	if not selected then
		return nil, "no active exact editor instance"
	end
	return consume(request_id, selected, dependencies, 1)
end

function M.consume_blocking(request_id, instance, dependencies)
	local selected = instance or active
	if not selected then
		return nil, "no active exact editor instance"
	end
	return consume(request_id, selected, dependencies, 2)
end

local function discover(instance, path)
	local candidate = path
	if not candidate or candidate == "" then
		candidate = uv.cwd()
	end
	local absolute = vim.fn.fnamemodify(candidate, ":p")
	for _, workspace in pairs(instance.workspaces) do
		if contained(workspace.root, absolute) then
			return true
		end
	end
	local resolver = configured.resolve_workspace
	if type(resolver) ~= "function" then
		return nil, "workspace resolver is not configured"
	end
	local workspace, resolve_err = resolver(absolute)
	if workspace then
		local normalized, normalize_err = normalize_workspace(workspace)
		if not normalized then
			return nil, normalize_err
		end
		local identity = workspace_identity(normalized)
		if instance.workspaces[identity] ~= nil then
			return true
		end
		instance.workspaces[identity] = normalized
		local record, write_err = M.write_registry(instance)
		if not record then
			instance.workspaces[identity] = nil
			return nil, write_err
		end
		emit("workspace-visited", { instance_id = instance.instance_id, workspace = normalized })
		return record
	elseif resolve_err then
		return nil, resolve_err
	end
	if instance.registry_identity then
		return true
	end
	return M.write_registry(instance)
end

local function append_warning(current, warning)
	if not warning or warning == "" then
		return current
	end
	return current and (current .. "; " .. tostring(warning)) or tostring(warning)
end

local function heartbeat_is_current(instance, timer, generation)
	return active == instance
		and instance.registry_heartbeat == timer
		and instance.registry_heartbeat_generation == generation
		and heartbeat_generation == generation
end

local function stop_heartbeat(instance)
	local timer = instance.registry_heartbeat
	heartbeat_generation = heartbeat_generation + 1
	instance.registry_heartbeat = nil
	instance.registry_heartbeat_generation = nil
	if not timer then
		return true
	end
	local warning
	local stopped, stop_err = pcall(timer.stop, timer)
	if not stopped then
		warning = append_warning(warning, "registry heartbeat stop failed: " .. tostring(stop_err))
	end
	local closing = false
	if type(timer.is_closing) == "function" then
		local inspected, result = pcall(timer.is_closing, timer)
		closing = inspected and result == true
	end
	if not closing then
		local closed, close_err = pcall(timer.close, timer)
		if not closed then
			warning = append_warning(warning, "registry heartbeat close failed: " .. tostring(close_err))
		end
	end
	return true, warning
end

local function start_heartbeat(instance)
	if instance.registry_heartbeat then
		return true
	end
	local created, timer_or_err = pcall(timer_factory)
	if not created or not timer_or_err then
		return nil, "could not create registry heartbeat timer: " .. tostring(timer_or_err)
	end
	local timer = timer_or_err
	heartbeat_generation = heartbeat_generation + 1
	local generation = heartbeat_generation
	instance.registry_heartbeat = timer
	instance.registry_heartbeat_generation = generation
	local interval = configured.registry_heartbeat_seconds * 1000
	local started, start_err = pcall(timer.start, timer, interval, interval, function()
		if not heartbeat_is_current(instance, timer, generation) then
			return
		end
		vim.schedule(function()
			if not heartbeat_is_current(instance, timer, generation) then
				return
			end
			local record, write_err = M.write_registry(instance)
			if not record then
				notify(
					"Could not refresh exact editor registry heartbeat: " .. tostring(write_err),
					vim.log.levels.WARN
				)
			end
		end)
	end)
	if not started then
		stop_heartbeat(instance)
		return nil, "could not start registry heartbeat timer: " .. tostring(start_err)
	end
	local unreferenced, unref_err = pcall(timer.unref, timer)
	if not unreferenced then
		stop_heartbeat(instance)
		return nil, "could not unreference registry heartbeat timer: " .. tostring(unref_err)
	end
	return true
end

local function stop_server(path)
	local callback = configured.server_stop
	local called, result = pcall(callback or vim.fn.serverstop, path)
	if not called then
		return nil, tostring(result)
	end
	local stopped = callback and result == true or callback == nil and result == 1
	if not stopped then
		return nil, "server_stop reported failure: " .. tostring(result)
	end
	return true
end

local function reserve_socket_replacement(path)
	return reserve_cleanup(path, nil, "socket", { allow_unowned = true })
end

local function cleanup_socket(instance)
	if not instance.owns_socket then
		return true
	end
	local reservation, reserve_err = reserve_cleanup(instance.socket, instance.socket_identity, "socket")
	if reservation == nil then
		return nil, "could not reserve the exact editor socket safely; server remains active: " .. tostring(reserve_err)
	end
	local late_reservation
	if reservation ~= false then
		local hook_ok, hook_err = run_test_hook("before_cleanup_server_stop", {
			kind = "socket",
			path = instance.socket,
			reserved = reservation.reserved_path,
		})
		if not hook_ok then
			local _, restore_err = restore_reservation(reservation, "socket stop hook failed: " .. tostring(hook_err))
			return nil, restore_err
		end
		local late, late_err = reserve_socket_replacement(instance.socket)
		if late == nil then
			local _, restore_err = restore_reservation(
				reservation,
				"late socket replacement could not be preserved: " .. tostring(late_err)
			)
			return nil, restore_err
		end
		if late ~= false then
			late_reservation = late
		end
	end

	local stopped, stop_err = stop_server(instance.socket)
	if not stopped then
		local warning = "exact editor server stop failed: " .. tostring(stop_err)
		if reservation ~= false then
			local _, restore_err = restore_reservation(reservation, warning)
			warning = append_warning(warning, restore_err)
		end
		if late_reservation then
			local _, restore_err = restore_reservation(late_reservation, "late socket replacement was preserved")
			warning = append_warning(warning, restore_err)
		end
		return nil, warning
	end

	local warning
	if reservation ~= false then
		if reservation.owned then
			local removed, remove_warning_or_err = retire_reservation(reservation)
			warning = append_warning(warning, remove_warning_or_err)
			if not removed then
				warning = append_warning(warning, "owned socket entry was preserved after the server stopped")
			end
		else
			local _, restore_err = restore_reservation(reservation, "socket replacement was preserved")
			warning = append_warning(warning, restore_err)
		end
	end
	if late_reservation then
		local _, restore_err = restore_reservation(late_reservation, "late socket replacement was preserved")
		warning = append_warning(warning, restore_err)
	end
	return true, warning
end

local function cleanup(instance)
	if not instance then
		return true
	end
	local socket_stopped, socket_warning_or_err = cleanup_socket(instance)
	if not socket_stopped then
		notify(tostring(socket_warning_or_err), vim.log.levels.WARN)
		return nil, socket_warning_or_err
	end
	if socket_warning_or_err then
		notify("Exact editor socket cleanup: " .. tostring(socket_warning_or_err), vim.log.levels.WARN)
	end
	local _, heartbeat_warning = stop_heartbeat(instance)
	if heartbeat_warning then
		notify("Exact editor heartbeat cleanup: " .. tostring(heartbeat_warning), vim.log.levels.WARN)
	end

	local registry_removed, registry_err = unlink_regular(record_path(instance), instance.registry_identity)
	if not registry_removed then
		notify("Could not remove exact editor registry safely: " .. tostring(registry_err), vim.log.levels.WARN)
	elseif registry_err then
		notify(
			"Exact editor registry cleanup committed with a warning: " .. tostring(registry_err),
			vim.log.levels.WARN
		)
	end
	if active == instance then
		active = nil
		_G.ExactEditorRequest = nil
	end
	emit("instance-stopped", { instance_id = instance.instance_id })
	return true, append_warning(append_warning(socket_warning_or_err, heartbeat_warning), registry_err)
end

local function start_server(root, instance_id)
	local socket = vim.fs.joinpath(root, "sockets", instance_id:gsub("%-", ""):sub(1, 12) .. ".sock")
	if uv.fs_lstat(socket) then
		return nil, "refusing existing Neovim socket path: " .. socket
	end
	local starter = configured.server_start or vim.fn.serverstart
	local ok, result = pcall(starter, socket)
	if not ok or type(result) ~= "string" or result == "" then
		return nil, "could not start a Unix Neovim server: " .. tostring(result)
	end
	local socket_stat = uv.fs_lstat(result)
	if not socket_stat or socket_stat.type ~= "socket" then
		local stopped, stop_err = stop_server(result)
		return nil,
			"Neovim server path is not a Unix socket" .. (stopped and "" or "; server stop failed: " .. tostring(
				stop_err
			))
	end
	local secured, secure_err = uv.fs_chmod(result, tonumber("600", 8))
	if not secured then
		local reservation, reserve_err = reserve_cleanup(result, socket_stat, "socket")
		if reservation == nil then
			return nil,
				"could not secure the Neovim socket: "
					.. tostring(secure_err)
					.. "; unsafe cleanup was refused: "
					.. tostring(reserve_err)
		end
		local stopped, stop_err = stop_server(result)
		if not stopped then
			if reservation ~= false then
				local _, restore_err = restore_reservation(
					reservation,
					"socket permissions failed and the server remains active: " .. tostring(stop_err)
				)
				return nil,
					"could not secure the Neovim socket: " .. tostring(secure_err) .. "; " .. tostring(restore_err)
			end
			return nil,
				"could not secure the Neovim socket: "
					.. tostring(secure_err)
					.. "; server remains active: "
					.. tostring(stop_err)
		end
		if reservation ~= false then
			if reservation.owned then
				retire_reservation(reservation)
			else
				restore_reservation(reservation, "socket changed after failed permission setup")
			end
		end
		return nil, "could not secure the Neovim socket: " .. tostring(secure_err)
	end
	return result, nil, socket_stat
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local options_ok, options_err = exact_options(opts, SETUP_KEYS, "setup")
	if not options_ok then
		error(options_err)
	end
	if type(opts.state_root) ~= "string" and type(opts.state_root) ~= "function" then
		error("exact_editor.setup requires state_root as a string or function")
	end
	if type(opts.resolve_workspace) ~= "function" then
		error("exact_editor.setup requires resolve_workspace")
	end
	if type(opts.open) ~= "function" then
		error("exact_editor.setup requires open")
	end
	for _, name in ipairs({
		"state_root",
		"resolve_workspace",
		"open",
		"resolve_relative",
		"clock",
		"pid",
		"uuid",
		"server_start",
		"server_stop",
		"notify",
		"install_finish_mapping",
		"on_state_change",
	}) do
		if opts[name] ~= nil and name ~= "state_root" and type(opts[name]) ~= "function" then
			error("setup." .. name .. " must be a function")
		end
	end
	local retention = opts.workspace_retention
	if retention == nil then
		retention = "visited"
	end
	if retention ~= "visited" then
		error("setup.workspace_retention must be visited")
	end
	local heartbeat_seconds = opts.registry_heartbeat_seconds
	if heartbeat_seconds == nil then
		heartbeat_seconds = 21600
	end
	if
		type(heartbeat_seconds) ~= "number"
		or heartbeat_seconds % 1 ~= 0
		or heartbeat_seconds < 60
		or heartbeat_seconds > 604800
	then
		error("setup.registry_heartbeat_seconds must be an integer between 60 and 604800")
	end
	if active then
		return active
	end
	local next_configured = vim.tbl_extend("force", {}, opts, {
		workspace_retention = retention,
		registry_heartbeat_seconds = heartbeat_seconds,
	})
	local clock_value, clock_err = timestamp(next_configured)
	if not clock_value then
		local report = opts.notify or vim.notify
		pcall(report, "Could not snapshot exact editor clock: " .. tostring(clock_err), vim.log.levels.ERROR)
		return nil
	end
	local previous_configured = configured
	configured = next_configured
	local function setup_failure(message)
		notify(message, vim.log.levels.ERROR)
		configured = previous_configured
		return nil
	end
	local root_ok, root = pcall(M.state_root)
	if not root_ok then
		return setup_failure("Could not resolve exact editor state root: " .. tostring(root))
	end
	local prepared, prepare_err = prepare_state(root)
	if not prepared then
		return setup_failure(prepare_err)
	end
	local uuid_ok, instance_id = pcall(uuid)
	if not uuid_ok then
		return setup_failure("UUID provider failed: " .. tostring(instance_id))
	end
	if not is_uuid(instance_id) then
		return setup_failure("UUID provider returned an invalid identifier")
	end
	local owner_pid = uv.os_getpid()
	if type(configured.pid) == "function" then
		local pid_ok, resolved_pid = pcall(configured.pid)
		if not pid_ok or not positive_integer(resolved_pid) then
			return setup_failure("PID provider returned an invalid identifier")
		end
		owner_pid = resolved_pid
	end
	local socket, server_err, socket_identity = start_server(root, instance_id)
	if not socket then
		return setup_failure(server_err)
	end
	local instance = {
		root = root,
		instance_id = instance_id,
		pid = owner_pid,
		socket = socket,
		socket_identity = socket_identity,
		owns_socket = true,
		workspaces = {},
	}
	active = instance
	emit("instance-started", { instance_id = instance_id, socket = socket })

	_G.ExactEditorRequest = function(request_id)
		local handled, err = consume(request_id, instance)
		if not handled then
			error(err)
		end
		return handled
	end

	local group = vim.api.nvim_create_augroup("exact_editor_rpc", { clear = true })
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function(args)
			local ok, err = discover(instance, vim.api.nvim_buf_get_name(args.buf))
			if not ok then
				notify("Could not update editor registry: " .. tostring(err), vim.log.levels.ERROR)
			end
		end,
	})
	vim.api.nvim_create_autocmd("DirChanged", {
		group = group,
		callback = function()
			local ok, err = discover(instance, uv.cwd())
			if not ok then
				notify("Could not update editor registry: " .. tostring(err), vim.log.levels.ERROR)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		once = true,
		callback = function()
			cleanup(instance)
		end,
	})

	local discovered, ok, err = pcall(discover, instance, vim.api.nvim_buf_get_name(0))
	if not discovered then
		err = ok
		ok = nil
	end
	if not ok then
		local cleaned, cleanup_err = cleanup(instance)
		notify(
			"Could not create editor registry: "
				.. tostring(err)
				.. (cleaned and "" or "; cleanup failed: " .. tostring(cleanup_err)),
			vim.log.levels.ERROR
		)
		if cleaned then
			pcall(vim.api.nvim_del_augroup_by_name, "exact_editor_rpc")
			configured = previous_configured
		end
		return nil
	end
	local heartbeat_started, heartbeat_err = start_heartbeat(instance)
	if not heartbeat_started then
		local cleaned, cleanup_err = cleanup(instance)
		notify(
			"Could not start editor registry heartbeat: "
				.. tostring(heartbeat_err)
				.. (cleaned and "" or "; cleanup failed: " .. tostring(cleanup_err)),
			vim.log.levels.ERROR
		)
		if cleaned then
			pcall(vim.api.nvim_del_augroup_by_name, "exact_editor_rpc")
			configured = previous_configured
		end
		return nil
	end
	return instance
end

function M.effective_config()
	return {
		workspace_retention = configured.workspace_retention or "visited",
		registry_heartbeat_seconds = configured.registry_heartbeat_seconds or 21600,
	}
end

function M.status()
	local result = {
		configured = active ~= nil,
		instance = nil,
		workspace_retention = configured.workspace_retention or "visited",
		registry_heartbeat_seconds = configured.registry_heartbeat_seconds or 21600,
		workspaces = {},
		waits = {},
	}
	if active then
		result.instance = {
			instance_id = active.instance_id,
			pid = active.pid,
			root = active.root,
			socket = active.socket,
		}
		for _, workspace in pairs(active.workspaces or {}) do
			result.workspaces[#result.workspaces + 1] = copy(workspace)
		end
		table.sort(result.workspaces, function(left, right)
			return workspace_identity(left) < workspace_identity(right)
		end)
	end
	for buf, controller in pairs(wait_controllers) do
		for request_id, request in pairs(controller.requests) do
			result.waits[#result.waits + 1] = {
				request_id = request_id,
				instance_id = request.instance.instance_id,
				buf = buf,
				win = request.win,
				target = request.target,
				status = "waiting",
			}
		end
	end
	table.sort(result.waits, function(left, right)
		return left.request_id < right.request_id
	end)
	return copy(result)
end

function M.teardown()
	deferred_generation = deferred_generation + 1
	deferred = false
	pcall(vim.api.nvim_del_augroup_by_name, "exact_editor_rpc_deferred")
	local buffers = vim.tbl_keys(wait_controllers)
	table.sort(buffers)
	local complete = true
	for _, buf in ipairs(buffers) do
		local controller = wait_controllers[buf]
		if controller then
			complete = finish_wait_controller(controller, "aborted") and complete
		end
	end
	if active then
		local cleaned = cleanup(active)
		complete = cleaned and complete or false
		if not cleaned then
			return false
		end
	end
	pcall(vim.api.nvim_del_augroup_by_name, "exact_editor_rpc")
	configured = {}
	return complete
end

-- A headless validation process is not a user-owned editor target. Register
-- only after a UI exists, and schedule the synchronous socket/Git work beyond
-- init.lua so it does not extend the measured startup critical path.
function M.setup_deferred(dependencies)
	local deps = dependencies or {}
	local ui_count = deps.ui_count or function()
		return #vim.api.nvim_list_uis()
	end
	local schedule = deps.schedule or vim.schedule
	local setup = deps.setup or function()
		return M.setup(deps.options or {})
	end

	local function queue()
		if deferred or active then
			return
		end
		deferred = true
		local generation = deferred_generation
		schedule(function()
			if generation ~= deferred_generation then
				return
			end
			deferred = false
			if not active and ui_count() > 0 then
				setup()
			end
		end)
	end

	if ui_count() > 0 then
		queue()
		return
	end
	local group = vim.api.nvim_create_augroup("exact_editor_rpc_deferred", { clear = true })
	vim.api.nvim_create_autocmd("UIEnter", { group = group, once = true, callback = queue })
end

M._cleanup = cleanup
M._record_keys = RECORD_KEYS
M._wait_request_keys = WAIT_REQUEST_KEYS
M._wait_state_keys = WAIT_STATE_KEYS
M._prepare_state = prepare_state
M._normalize_workspace = normalize_workspace
M._workspace_identity = workspace_identity
M._discover = discover
M._set_timer_factory_for_tests = function(factory)
	assert(factory == nil or type(factory) == "function", "exact editor timer factory must be a function or nil")
	timer_factory = factory or default_timer_factory
end
M._set_test_hook = function(callback)
	assert(callback == nil or type(callback) == "function", "exact editor test hook must be a function or nil")
	test_hook = callback
end

return M
