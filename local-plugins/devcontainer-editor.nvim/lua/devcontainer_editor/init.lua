-- Dev Container lifecycle and authenticated editor transport core.
local M = {}
local contracts = require("local_plugins.contracts")
local bit = require("bit")
local ffi = require("ffi")

local uv = vim.uv
local configured = {}
local is_configured = false
local watcher
local watcher_failures = 0
local watcher_generation = 0
local transport_generation = 0
local transport_status = {
	generation = 0,
	state = "idle",
	processed = 0,
	succeeded = 0,
	failed = 0,
	remaining = 0,
	records = {},
}
local temp_counter = 0
local test_hook

local MAX_MESSAGE = 64 * 1024
local MAX_WARNING = 512
local DEFAULT_ACK_TIMEOUT_MS = 5000
local DEFAULT_MAX_MESSAGES_PER_TICK = 32
local DEFAULT_POLL_INTERVAL_MS = 100

local function public_defaults()
	return {
		ack_timeout_ms = DEFAULT_ACK_TIMEOUT_MS,
		claim_timeout_ms = 2000,
		cli = "devcontainer",
		lockfile_policy = "preserve",
		max_messages_per_tick = DEFAULT_MAX_MESSAGES_PER_TICK,
		poll_interval_ms = DEFAULT_POLL_INTERVAL_MS,
		ssh_agent = "auto",
		watch = true,
	}
end

local SETUP_KEYS = {
	ack_timeout_ms = true,
	claim_timeout_ms = true,
	cli = true,
	event = true,
	launcher = true,
	lockfile_policy = true,
	max_messages_per_tick = true,
	notify = true,
	open = true,
	poll_interval_ms = true,
	spool_root = true,
	ssh_agent = true,
	state_root = true,
	uuid = true,
	watch = true,
}

local declared, declare_err = pcall(
	ffi.cdef,
	[[
	int openat(int dirfd, const char *pathname, int flags, ...);
	int mkdirat(int dirfd, const char *pathname, unsigned int mode);
	int unlinkat(int dirfd, const char *pathname, int flags);
	int renameatx_np(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
	int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
	int dup(int fd);
	void *fdopendir(int fd);
	void *readdir(void *directory);
	int closedir(void *directory);
	char *strerror(int error_number);
	struct devcontainer_darwin_dirent {
		uint64_t d_ino;
		uint64_t d_seekoff;
		uint16_t d_reclen;
		uint16_t d_namlen;
		uint8_t d_type;
		char d_name[1024];
	};
	struct devcontainer_linux_dirent {
		uint64_t d_ino;
		int64_t d_off;
		uint16_t d_reclen;
		uint8_t d_type;
		char d_name[256];
	};
	]]
)
if not declared and tostring(declare_err):find("redefin", 1, true) then
	declared = true
end

local descriptor_api
if declared and ffi.abi("64bit") then
	local sysname = uv.os_uname().sysname
	if sysname == "Darwin" then
		descriptor_api = {
			O_RDONLY = 0,
			O_WRONLY = 1,
			O_CREAT = 0x00000200,
			O_EXCL = 0x00000800,
			O_NOFOLLOW = 0x00000100,
			O_DIRECTORY = 0x00100000,
			O_CLOEXEC = 0x01000000,
			EEXIST = 17,
			ENOENT = 2,
			dirent = "darwin",
			rename = "renameatx_np",
			rename_noreplace_flag = 0x00000004, -- RENAME_EXCL
		}
	elseif sysname == "Linux" then
		descriptor_api = {
			O_RDONLY = 0,
			O_WRONLY = 1,
			O_CREAT = 0x00000040,
			O_EXCL = 0x00000080,
			O_NOFOLLOW = 0x00020000,
			O_DIRECTORY = 0x00010000,
			O_CLOEXEC = 0x00080000,
			EEXIST = 17,
			ENOENT = 2,
			dirent = "linux",
			rename = "renameat2",
			rename_noreplace_flag = 0x00000001, -- RENAME_NOREPLACE
		}
	end
end
local HOST_ACTIONS = {
	container_log = true,
	host_editor = true,
	lazygit = true,
	tmux_dev_refresh = true,
	tmux_dev_refresh_check = true,
}
local RECORD_KEYS = {
	version = true,
	host_root = true,
	config_path = true,
	container_root = true,
	container_id = true,
	claim_id = true,
	workspace_key = true,
	pid = true,
	status = true,
	network_authorized = true,
	ssh_agent_forwarding = true,
	tmux_pane = true,
	pane_pid = true,
	log_path = true,
	updated_at = true,
	exit_code = true,
	error = true,
}
local REQUEST_KEYS = {
	version = true,
	auth = true,
	request_id = true,
	action = true,
	path = true,
	line = true,
	column = true,
	created_at = true,
}
local ACK_KEYS = {
	version = true,
	auth = true,
	request_id = true,
	ok = true,
	action = true,
	error = true,
}
local AUTH_KEYS = {
	version = true,
	token = true,
}
local MESSAGE_FIELDS = {
	open_location = { "version", "request_id", "action", "path", "line", "column", "created_at" },
	host_request = { "version", "request_id", "action", "created_at" },
	ack = { "version", "request_id", "ok", "action", "error" },
}

local function copy(value)
	return vim.deepcopy(value)
end

local function reject_unknown(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains unknown key: " .. tostring(key)
		end
	end
	return true
end

local function positive_integer(value, label)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		return nil, label .. " must be a positive integer"
	end
	return value
end

local function emit(kind, details)
	if type(configured.event) ~= "function" then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	pcall(configured.event, event)
end

local function publish_transport(state, fields)
	transport_generation = transport_generation + 1
	transport_status = vim.tbl_extend("force", {
		generation = transport_generation,
		state = state,
		processed = 0,
		succeeded = 0,
		failed = 0,
		remaining = 0,
		records = {},
	}, copy(fields or {}))
	emit("transport", { status = transport_status })
	return copy(transport_status)
end

local function bounded_warning(value, maximum)
	local detail = tostring(value):gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if #detail > maximum then
		detail = detail:sub(1, math.max(maximum - 3, 0)) .. "..."
	end
	return detail
end

local function append_warning(current, warning)
	if warning == nil or warning == "" then
		return current
	end
	local combined = current and (tostring(current) .. "; " .. tostring(warning)) or tostring(warning)
	return bounded_warning(combined, MAX_WARNING)
end

local function fire_test_hook(event, details)
	if not test_hook then
		return true
	end
	local ok, err = pcall(test_hook, event, vim.deepcopy(details or {}))
	return ok and true or nil, ok and nil or tostring(err)
end

local function validate_setup(opts)
	local known, known_err = reject_unknown(opts, SETUP_KEYS, "devcontainer_editor setup")
	if not known then
		return nil, known_err
	end
	local candidate = copy(opts)
	for field, fallback in pairs({
		cli = "devcontainer",
		lockfile_policy = "preserve",
		ssh_agent = "auto",
		claim_timeout_ms = 2000,
		ack_timeout_ms = DEFAULT_ACK_TIMEOUT_MS,
		max_messages_per_tick = DEFAULT_MAX_MESSAGES_PER_TICK,
		poll_interval_ms = DEFAULT_POLL_INTERVAL_MS,
	}) do
		if candidate[field] == nil then
			candidate[field] = fallback
		end
	end
	for _, field in ipairs({
		"claim_timeout_ms",
		"ack_timeout_ms",
		"max_messages_per_tick",
		"poll_interval_ms",
	}) do
		local _, value_err = positive_integer(candidate[field], "devcontainer_editor " .. field)
		if value_err then
			return nil, value_err
		end
	end
	if type(candidate.cli) ~= "string" or candidate.cli == "" or candidate.cli:find("%z") then
		return nil, "devcontainer_editor cli must be a non-empty string"
	end
	if candidate.lockfile_policy ~= "preserve" then
		return nil, "devcontainer_editor lockfile_policy must be preserve"
	end
	if candidate.ssh_agent ~= "auto" and candidate.ssh_agent ~= "off" then
		return nil, "devcontainer_editor ssh_agent must be auto or off"
	end
	if
		candidate.launcher ~= nil
		and (type(candidate.launcher) ~= "string" or candidate.launcher == "" or candidate.launcher:find("\0", 1, true))
	then
		return nil, "devcontainer_editor launcher must be a non-empty string without NUL bytes"
	end
	for _, field in ipairs({ "event", "notify", "open", "uuid" }) do
		if candidate[field] ~= nil and type(candidate[field]) ~= "function" then
			return nil, "devcontainer_editor " .. field .. " must be a function"
		end
	end
	for _, field in ipairs({ "spool_root", "state_root" }) do
		local value = candidate[field]
		if value ~= nil and type(value) ~= "string" and type(value) ~= "function" then
			return nil, "devcontainer_editor " .. field .. " must be a string or function"
		end
		if type(value) == "string" and (value == "" or value:find("\0", 1, true)) then
			return nil, "devcontainer_editor " .. field .. " must be non-empty and without NUL bytes"
		end
	end
	if candidate.watch ~= nil and type(candidate.watch) ~= "boolean" then
		return nil, "devcontainer_editor watch must be boolean"
	end
	return candidate
end

local function report_warning(dependencies, label, warning)
	if warning == nil or warning == "" then
		return
	end
	local detail = bounded_warning(warning, MAX_WARNING)
	local prefix = label .. ": "
	local available = MAX_WARNING - #prefix
	if #detail > available then
		detail = detail:sub(1, math.max(available - 3, 0)) .. "..."
	end
	local report = (dependencies or {}).notify or configured.notify
	if type(report) == "function" then
		pcall(report, prefix .. detail, vim.log.levels.WARN)
	end
end

local function report_commit_warning(dependencies, label, warning)
	report_warning(dependencies, label .. " committed with a durability warning", warning)
end

local function append_cleanup_failure(primary, cleanup)
	if cleanup == nil or cleanup == "" then
		return primary
	end
	if primary == nil or primary == "" then
		return tostring(cleanup)
	end
	return tostring(primary) .. "; cleanup failed: " .. tostring(cleanup)
end

local function exact_keys(value, allowed, label)
	if type(value) ~= "table" or vim.islist(value) then
		return nil, label .. " must be one object"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains an unknown field"
		end
	end
	for key in pairs(allowed) do
		if value[key] == nil then
			return nil, label .. " is missing a required field"
		end
	end
	return true
end

local function state_root()
	local root = configured.state_root
	if type(root) == "function" then
		local ok, resolved = pcall(root)
		if not ok then
			return nil, "state_root callback failed: " .. tostring(resolved)
		end
		if type(resolved) ~= "string" or resolved == "" or resolved:find("\0", 1, true) then
			return nil, "state_root callback must return a non-empty string without NUL bytes"
		end
		root = resolved
	end
	if root == nil then
		root = vim.env.NVIM_DEVCONTAINER_STATE_HOME
	end
	if root == nil or root == "" then
		local state = vim.env.XDG_STATE_HOME or (vim.env.HOME and vim.fs.joinpath(vim.env.HOME, ".local", "state"))
		root = state and vim.fs.joinpath(state, "nvim-devcontainer") or nil
	end
	if root == nil then
		return nil, "state root is unavailable"
	end
	if type(root) ~= "string" or root == "" or root:find("\0", 1, true) then
		return nil, "state root must be a non-empty string without NUL bytes"
	end
	local ok, normalized = pcall(function()
		return vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
	end)
	return ok and normalized or nil, ok and nil or "state root is invalid: " .. tostring(normalized)
end

local function ensure_directory(path)
	local before = uv.fs_lstat(path)
	if before and before.type ~= "directory" then
		return nil, "state path is not a real directory: " .. path
	end
	if not before and vim.fn.mkdir(path, "p", tonumber("700", 8)) == 0 then
		return nil, "could not create state directory: " .. path
	end
	local stat = uv.fs_lstat(path)
	if not stat or stat.type ~= "directory" or (uv.getuid and stat.uid ~= uv.getuid()) then
		return nil, "state path is not a real directory: " .. path
	end
	local ok, err = uv.fs_chmod(path, tonumber("700", 8))
	return ok and true or nil, ok and nil or "could not secure state directory: " .. tostring(err)
end

local function descriptor_error(label, number)
	number = number or ffi.errno()
	return label .. ": " .. ffi.string(ffi.C.strerror(number))
end

local function private_name(name)
	if
		type(name) ~= "string"
		or name == ""
		or name == "."
		or name == ".."
		or name:find("/", 1, true)
		or name:find("%z")
	then
		return nil, "private spool entry is not one basename"
	end
	return name
end

local function close_fd(fd)
	if not fd then
		return true
	end
	local closed, close_err = uv.fs_close(fd)
	if not closed then
		return nil, tostring(close_err)
	end
	return true
end

local function private_snapshot(stat)
	if
		not stat
		or stat.type ~= "file"
		or stat.nlink ~= 1
		or stat.mode % 512 ~= tonumber("600", 8)
		or (uv.getuid and stat.uid ~= uv.getuid())
		or stat.size > MAX_MESSAGE
	then
		return nil
	end
	return {
		dev = stat.dev,
		ino = stat.ino,
		size = stat.size,
		mode = stat.mode,
		nlink = stat.nlink,
		uid = stat.uid,
	}
end

local function same_snapshot(left, right)
	return left
		and right
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and left.uid == right.uid
end

local function openat(parent_fd, name, flags, mode)
	local valid, valid_err = private_name(name)
	if not valid then
		return nil, valid_err
	end
	ffi.errno(0)
	local fd
	if mode then
		fd = ffi.C.openat(parent_fd, name, flags, ffi.cast("unsigned int", mode))
	else
		fd = ffi.C.openat(parent_fd, name, flags)
	end
	if fd < 0 then
		return nil, descriptor_error("could not open anchored spool entry"), ffi.errno()
	end
	return tonumber(fd)
end

local function open_root_directory(path)
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "could not open spool root: " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	local lexical = uv.fs_lstat(path)
	if
		not opened
		or not lexical
		or opened.type ~= "directory"
		or lexical.type ~= "directory"
		or opened.dev ~= lexical.dev
		or opened.ino ~= lexical.ino
		or opened.mode % 512 ~= tonumber("700", 8)
		or (uv.getuid and opened.uid ~= uv.getuid())
	then
		close_fd(fd)
		return nil, "spool root changed while opening"
	end
	return fd
end

local function open_child_directory(parent_fd, name)
	ffi.errno(0)
	if ffi.C.mkdirat(parent_fd, name, ffi.cast("unsigned int", tonumber("700", 8))) ~= 0 then
		local number = ffi.errno()
		if number ~= descriptor_api.EEXIST then
			return nil, descriptor_error("could not create anchored spool directory", number)
		end
	end
	local flags = bit.bor(
		descriptor_api.O_RDONLY,
		descriptor_api.O_DIRECTORY,
		descriptor_api.O_NOFOLLOW,
		descriptor_api.O_CLOEXEC
	)
	local fd, open_err = openat(parent_fd, name, flags)
	if not fd then
		return nil, open_err
	end
	local stat = uv.fs_fstat(fd)
	if
		not stat
		or stat.type ~= "directory"
		or stat.mode % 512 ~= tonumber("700", 8)
		or (uv.getuid and stat.uid ~= uv.getuid())
	then
		close_fd(fd)
		return nil, "anchored spool child is not one owner-only directory"
	end
	return fd
end

local function close_spool(spool)
	local first_err
	for _, name in ipairs({ "acks_fd", "outbox_fd", "inbox_fd", "root_fd" }) do
		local _, close_err = close_fd(spool and spool[name])
		first_err = first_err or close_err
		if spool then
			spool[name] = nil
		end
	end
	return first_err and nil or true, first_err
end

local function prepare_spool_descriptors(root)
	if not descriptor_api then
		return nil, "descriptor-relative spool APIs require 64-bit Darwin or Linux"
	end
	local prepared, prepare_err = ensure_directory(root)
	if not prepared then
		return nil, prepare_err
	end
	local spool = { root = root }
	spool.root_fd, prepare_err = open_root_directory(root)
	if not spool.root_fd then
		return nil, prepare_err
	end
	for _, item in ipairs({ { "inbox_fd", "inbox" }, { "outbox_fd", "outbox" }, { "acks_fd", "acks" } }) do
		spool[item[1]], prepare_err = open_child_directory(spool.root_fd, item[2])
		if not spool[item[1]] then
			close_spool(spool)
			return nil, prepare_err
		end
	end
	return spool
end

local function snapshot_at(parent_fd, name)
	local flags = bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_NOFOLLOW, descriptor_api.O_CLOEXEC)
	local fd, open_err, number = openat(parent_fd, name, flags)
	if not fd then
		return nil, open_err, number
	end
	local stat, stat_err = uv.fs_fstat(fd)
	local snapshot = private_snapshot(stat)
	local closed, close_err = close_fd(fd)
	if not snapshot then
		return nil, "private spool entry is not one owner-only single-link file", -1
	end
	if not closed then
		return nil, "could not close private spool entry: " .. tostring(close_err), -1
	end
	return snapshot, stat_err
end

local function fsync_directory_fd(fd)
	local synced, sync_err = uv.fs_fsync(fd)
	if not synced then
		return nil, "could not persist anchored spool directory: " .. tostring(sync_err)
	end
	return true
end

local function exclusive_rename_at(parent_fd, source, destination, error_label)
	local source_valid, source_err = private_name(source)
	local destination_valid, destination_err = private_name(destination)
	if not source_valid or not destination_valid then
		return nil, source_err or destination_err
	end
	ffi.errno(0)
	local called, result = pcall(function()
		if descriptor_api.rename == "renameatx_np" then
			return ffi.C.renameatx_np(parent_fd, source, parent_fd, destination, descriptor_api.rename_noreplace_flag)
		end
		return ffi.C.renameat2(parent_fd, source, parent_fd, destination, descriptor_api.rename_noreplace_flag)
	end)
	if not called then
		return nil, "descriptor-relative exclusive rename is unavailable: " .. tostring(result), -1
	end
	if result == 0 then
		return true
	end
	local number = ffi.errno()
	return nil, descriptor_error(error_label or "could not reserve anchored spool entry", number), number
end

local function conditional_unlink_at(parent_fd, name, expected)
	if not expected then
		return nil, "conditional spool retirement requires an exact snapshot"
	end
	local reserved
	for _ = 1, 64 do
		temp_counter = temp_counter + 1
		reserved = (".%s.%d.%d.retire"):format(name, uv.os_getpid(), temp_counter)
		local moved, move_err, number = exclusive_rename_at(parent_fd, name, reserved)
		if moved then
			break
		end
		if number == descriptor_api.ENOENT then
			return nil, "spool entry disappeared before conditional retirement"
		end
		if number ~= descriptor_api.EEXIST then
			return nil, move_err
		end
		reserved = nil
	end
	if not reserved then
		return nil, "could not allocate conditional spool retirement reservation"
	end
	local actual = snapshot_at(parent_fd, reserved)
	if not same_snapshot(actual, expected) then
		local restored, restore_err = exclusive_rename_at(parent_fd, reserved, name)
		if not restored then
			return nil, "spool replacement remains preserved at " .. reserved .. ": " .. tostring(restore_err)
		end
		return nil, "spool entry changed during conditional retirement; replacement was restored"
	end
	if ffi.C.unlinkat(parent_fd, reserved, 0) ~= 0 then
		return nil, descriptor_error("could not retire anchored spool entry")
	end
	local _, sync_err = fsync_directory_fd(parent_fd)
	return true, sync_err
end

local function secure_read_at(parent_fd, name, label)
	local flags = bit.bor(descriptor_api.O_RDONLY, descriptor_api.O_NOFOLLOW, descriptor_api.O_CLOEXEC)
	local fd, open_err = openat(parent_fd, name, flags)
	if not fd then
		return nil, "could not open " .. label .. ": " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	local snapshot = private_snapshot(opened)
	if not snapshot then
		close_fd(fd)
		return nil, label .. " is missing or not one owner-only single-link file"
	end
	local data, read_err = uv.fs_read(fd, opened.size, 0)
	local closed, close_err = close_fd(fd)
	if data == nil or not closed then
		return nil, "could not read " .. label .. ": " .. tostring(read_err or close_err)
	end
	local after, after_err = snapshot_at(parent_fd, name)
	if not same_snapshot(after, snapshot) then
		return nil, label .. " changed while validating: " .. tostring(after_err or "identity mismatch")
	end
	return data, snapshot
end

local function write_all(fd, payload)
	local offset = 0
	local write_err
	while offset < #payload do
		local written
		written, write_err = uv.fs_write(fd, payload:sub(offset + 1), offset)
		if not written or written <= 0 then
			break
		end
		offset = offset + written
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("600", 8))
	local synced, sync_err = uv.fs_fsync(fd)
	return offset == #payload and secured and synced and true or nil,
		"could not persist private file: " .. tostring(write_err or secure_err or sync_err)
end

local function atomic_create_at(parent_fd, name, payload, opts)
	local valid, valid_err = private_name(name)
	if not valid then
		return nil, valid_err
	end
	temp_counter = temp_counter + 1
	local temporary = (".%s.%d.%d.tmp"):format(name, uv.os_getpid(), temp_counter)
	local flags = bit.bor(
		descriptor_api.O_WRONLY,
		descriptor_api.O_CREAT,
		descriptor_api.O_EXCL,
		descriptor_api.O_NOFOLLOW,
		descriptor_api.O_CLOEXEC
	)
	local fd, open_err = openat(parent_fd, temporary, flags, tonumber("600", 8))
	if not fd then
		return nil, open_err
	end
	local written, write_err = write_all(fd, payload)
	local staged = private_snapshot(uv.fs_fstat(fd))
	local closed, close_err = close_fd(fd)
	if not written or not staged or not closed then
		ffi.C.unlinkat(parent_fd, temporary, 0)
		return nil, write_err or (not staged and "private message staging file is invalid") or close_err
	end
	local published, publish_err =
		exclusive_rename_at(parent_fd, temporary, name, "could not publish private message without clobbering")
	if not published then
		ffi.errno(0)
		local cleaned = ffi.C.unlinkat(parent_fd, temporary, 0) == 0
		local cleanup_number = ffi.errno()
		if not cleaned then
			publish_err = append_cleanup_failure(
				publish_err,
				descriptor_error("could not retire unpublished private message staging file", cleanup_number)
			)
		else
			local _, cleanup_sync_err = fsync_directory_fd(parent_fd)
			publish_err = append_cleanup_failure(publish_err, cleanup_sync_err)
		end
		return nil, publish_err
	end
	local warning
	if not opts or opts.fire_test_hook ~= false then
		local hook_ok, hook_err = fire_test_hook("after_message_publish", { name = name })
		if not hook_ok then
			warning = append_warning(warning, "after_message_publish hook failed: " .. tostring(hook_err))
		end
	end
	local persisted, persist_err, persist_number = snapshot_at(parent_fd, name)
	if persisted and not same_snapshot(persisted, staged) then
		warning = append_warning(warning, "published private message identity changed before post-commit validation")
		persisted = nil
	elseif not persisted and persist_number == descriptor_api.ENOENT then
		warning = append_warning(warning, "published private message was consumed before post-commit validation")
	elseif not persisted then
		warning = append_warning(
			warning,
			"could not revalidate published private message: " .. tostring(persist_err or "identity is anomalous")
		)
	end
	local _, sync_err = fsync_directory_fd(parent_fd)
	warning = append_warning(warning, sync_err)
	return true, warning, persisted
end

local function list_json_at(parent_fd)
	local flags = bit.bor(
		descriptor_api.O_RDONLY,
		descriptor_api.O_DIRECTORY,
		descriptor_api.O_NOFOLLOW,
		descriptor_api.O_CLOEXEC
	)
	local enumerated = ffi.C.openat(parent_fd, ".", flags)
	if enumerated < 0 then
		return nil, descriptor_error("could not reopen anchored inbox descriptor")
	end
	local directory = ffi.C.fdopendir(enumerated)
	if directory == nil then
		uv.fs_close(tonumber(enumerated))
		return nil, descriptor_error("could not enumerate anchored inbox")
	end
	local names = {}
	while true do
		ffi.errno(0)
		local raw = ffi.C.readdir(directory)
		if raw == nil then
			local number = ffi.errno()
			ffi.C.closedir(directory)
			if number ~= 0 then
				return nil, descriptor_error("could not enumerate anchored inbox", number)
			end
			break
		end
		local entry = descriptor_api.dirent == "darwin" and ffi.cast("struct devcontainer_darwin_dirent *", raw)
			or ffi.cast("struct devcontainer_linux_dirent *", raw)
		local name = ffi.string(entry.d_name)
		if not name:match("^%.") and name:match("%.json$") then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

local function unlink_regular(path)
	local stat = uv.fs_lstat(path)
	if stat and stat.type == "file" then
		pcall(uv.fs_unlink, path)
	end
end

local function fsync_parent(path)
	local fd, open_err = uv.fs_open(vim.fs.dirname(path), "r", 0)
	if not fd then
		return nil, "could not open private parent directory: " .. tostring(open_err)
	end
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if not synced or not closed then
		return nil, "could not persist private parent directory: " .. tostring(sync_err or close_err)
	end
	return true
end

local function atomic_write(path, payload)
	local current = uv.fs_lstat(path)
	if current and current.type ~= "file" then
		return nil, "target is not a regular file"
	end
	temp_counter = temp_counter + 1
	local temporary = ("%s.tmp.%d.%d"):format(path, uv.os_getpid(), temp_counter)
	local fd, open_err = uv.fs_open(temporary, "wx", tonumber("600", 8))
	if not fd then
		return nil, "could not create private temporary file: " .. tostring(open_err)
	end
	local offset = 0
	local write_err
	while offset < #payload do
		local written
		written, write_err = uv.fs_write(fd, payload:sub(offset + 1), offset)
		if not written or written <= 0 then
			break
		end
		offset = offset + written
	end
	local secured, secure_err = uv.fs_fchmod(fd, tonumber("600", 8))
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if offset ~= #payload or not secured or not synced or not closed then
		unlink_regular(temporary)
		return nil, "could not persist private file: " .. tostring(write_err or secure_err or sync_err or close_err)
	end
	local renamed, rename_err = uv.fs_rename(temporary, path)
	if not renamed then
		unlink_regular(temporary)
		return nil, "could not replace private file: " .. tostring(rename_err)
	end
	return fsync_parent(path)
end

local function atomic_create(path, payload)
	local parent_fd, open_err = open_root_directory(vim.fs.dirname(path))
	if not parent_fd then
		return nil, open_err
	end
	local committed, warning_or_err, snapshot =
		atomic_create_at(parent_fd, vim.fs.basename(path), payload, { fire_test_hook = false })
	local closed, close_err = close_fd(parent_fd)
	if not committed then
		if not closed then
			warning_or_err = append_cleanup_failure(warning_or_err, close_err)
		end
		return nil, warning_or_err
	end
	if not closed then
		warning_or_err =
			append_warning(warning_or_err, "could not close private message parent: " .. tostring(close_err))
	end
	return true, warning_or_err, snapshot
end

local function secure_read(path, label)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" or before.nlink ~= 1 or (uv.getuid and before.uid ~= uv.getuid()) then
		return nil, label .. " is missing or not a regular file"
	end
	if before.mode % 512 ~= tonumber("600", 8) then
		return nil, label .. " is not owner-only"
	end
	if before.size > MAX_MESSAGE then
		return nil, label .. " exceeds 64 KiB"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "could not open " .. label .. ": " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "file"
		or opened.dev ~= before.dev
		or opened.ino ~= before.ino
		or opened.size ~= before.size
		or opened.nlink ~= before.nlink
	then
		pcall(uv.fs_close, fd)
		return nil, label .. " changed while opening"
	end
	local data, read_err = uv.fs_read(fd, opened.size, 0)
	local closed, close_err = uv.fs_close(fd)
	if data == nil or not closed then
		return nil, "could not read " .. label .. ": " .. tostring(read_err or close_err)
	end
	local after = uv.fs_lstat(path)
	if
		not after
		or after.type ~= "file"
		or after.dev ~= opened.dev
		or after.ino ~= opened.ino
		or after.size ~= opened.size
		or after.mode ~= opened.mode
		or after.nlink ~= opened.nlink
	then
		return nil, label .. " changed while validating"
	end
	return data
end

local function canonical_directory(path, label)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" or path:find("%z") then
		return nil, label .. " must be an absolute path"
	end
	local normalized = vim.fs.normalize(path)
	local resolved = uv.fs_realpath(normalized)
	local stat = resolved and uv.fs_lstat(resolved) or nil
	if not resolved or normalized ~= resolved or not stat or stat.type ~= "directory" then
		return nil, label .. " must be a canonical real directory"
	end
	return normalized
end

local function contained(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function positive_integer(value)
	return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function valid_id(value)
	if type(value) ~= "string" or #value ~= 36 or value:lower() ~= value then
		return false
	end
	if value:sub(9, 9) ~= "-" or value:sub(14, 14) ~= "-" or value:sub(19, 19) ~= "-" or value:sub(24, 24) ~= "-" then
		return false
	end
	if value:sub(15, 15) ~= "4" or not value:sub(20, 20):match("[89ab]") then
		return false
	end
	return value:gsub("%-", ""):match("^[0-9a-f]+$") ~= nil
end

local function recent_timestamp(value)
	if type(value) ~= "string" then
		return false
	end
	local parsed = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", value)
	if type(parsed) ~= "number" or parsed < 0 then
		return false
	end
	local now = type(configured.epoch) == "function" and configured.epoch() or os.time()
	if type(configured.epoch) ~= "function" then
		local sign, hours, minutes = os.date("%z", now):match("^([+-])(%d%d)(%d%d)$")
		if sign then
			local offset = tonumber(hours) * 3600 + tonumber(minutes) * 60
			parsed = parsed + (sign == "+" and offset or -offset)
		end
	end
	return parsed <= now + 300 and now - parsed <= 600
end

local function scalar(value)
	if value == nil or value == vim.NIL then
		return ""
	end
	if value == true then
		return "1"
	end
	if value == false then
		return "0"
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "number" and value % 1 == 0 then
		return tostring(value)
	end
	return nil
end

local function message_payload(kind, value)
	local fields = MESSAGE_FIELDS[kind]
	if not fields then
		return nil, "authenticated message kind is invalid"
	end
	local parts = { kind }
	for _, field in ipairs(fields) do
		local encoded = scalar(value[field])
		if encoded == nil then
			return nil, "authenticated message contains an invalid scalar"
		end
		parts[#parts + 1] = tostring(#encoded) .. ":" .. encoded
	end
	return table.concat(parts, "|")
end

local function hex_bytes(value)
	return (value:gsub("..", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

local function xor_pad(key, pad)
	local bytes = {}
	for index = 1, 64 do
		bytes[index] = string.char(bit.bxor(key:byte(index) or 0, pad))
	end
	return table.concat(bytes)
end

local function hmac_sha256(token, payload)
	local key = #token > 64 and hex_bytes(vim.fn.sha256(token)) or token
	local inner = hex_bytes(vim.fn.sha256(xor_pad(key, 0x36) .. payload))
	return vim.fn.sha256(xor_pad(key, 0x5C) .. inner)
end

local function authenticate(token, kind, value)
	local payload, payload_err = message_payload(kind, value)
	return payload and hmac_sha256(token, payload) or nil, payload_err
end

local function constant_time_equal(left, right)
	if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then
		return false
	end
	local difference = 0
	for index = 1, #left do
		difference = bit.bor(difference, bit.bxor(left:byte(index), right:byte(index)))
	end
	return difference == 0
end

local function valid_auth(token, kind, value)
	local expected = authenticate(token, kind, value)
	return expected ~= nil and constant_time_equal(value.auth, expected)
end

local function prepare_spool(root)
	for _, path in ipairs({
		root,
		vim.fs.joinpath(root, "inbox"),
		vim.fs.joinpath(root, "outbox"),
		vim.fs.joinpath(root, "acks"),
	}) do
		local ok, err = ensure_directory(path)
		if not ok then
			return nil, err
		end
	end
	return true
end

local function decode_secure(path, label, keys)
	local payload, read_err = secure_read(path, label)
	if not payload then
		return nil, read_err
	end
	local decoded, value = pcall(vim.json.decode, payload)
	if not decoded then
		return nil, label .. " is not JSON"
	end
	local exact, exact_err = exact_keys(value, keys, label)
	return exact and value or nil, exact and nil or exact_err
end

local function decode_secure_at(parent_fd, name, label, keys)
	local payload, snapshot_or_err = secure_read_at(parent_fd, name, label)
	if not payload then
		return nil, nil, snapshot_or_err
	end
	local snapshot = snapshot_or_err
	local decoded, value = pcall(vim.json.decode, payload)
	if not decoded then
		return nil, snapshot, label .. " is not JSON"
	end
	local exact, exact_err = exact_keys(value, keys, label)
	return exact and value or nil, snapshot, exact and nil or exact_err
end

function M.workspace_key(value)
	local workspace, workspace_err = contracts.normalize_workspace_key(value)
	if not workspace then
		return nil, workspace_err
	end
	if workspace.root:sub(1, 2) == "//" then
		return nil, "workspace root must be absolute"
	end
	local root = vim.fs.normalize(workspace.root)
	if root ~= workspace.root then
		return nil, "workspace root must be lexically canonical"
	end
	return { runtime = workspace.runtime, root = root, repo_identity = workspace.repo_identity }
end

function M.route(path, from_root, to_root, kind)
	local source, source_err = canonical_directory(from_root, "source root")
	if not source then
		return nil, source_err
	end
	if type(to_root) ~= "string" or to_root == "" or to_root:sub(1, 1) ~= "/" or to_root:find("%z") then
		return nil, "destination root must be absolute"
	end
	if type(path) ~= "string" or path == "" or path:find("%z") then
		return nil, "path must be non-empty"
	end
	local absolute = path:sub(1, 1) == "/" and vim.fs.normalize(path) or vim.fs.normalize(vim.fs.joinpath(source, path))
	local resolved = uv.fs_realpath(absolute)
	if not resolved or not contained(source, resolved) then
		return nil, "path resolves outside the source root"
	end
	local stat = uv.fs_lstat(resolved)
	if not stat or (kind and stat.type ~= kind) then
		return nil, "path has the wrong type"
	end
	local relative = resolved == source and "." or resolved:sub(#source + 2)
	return relative == "." and vim.fs.normalize(to_root) or vim.fs.joinpath(to_root, relative)
end

function M.in_workspace()
	return vim.env.NVIM_DEVCONTAINER == "1"
end

function M.network_authorized()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end

local function workspace_record_path(host_root)
	if type(host_root) ~= "string" or host_root == "" or host_root:find("%z") then
		return nil, "host root must be a non-empty string"
	end
	local root, root_err = state_root()
	if not root then
		return nil, root_err or "state root is unavailable"
	end
	return vim.fs.joinpath(root, "workspaces", vim.fn.sha256(host_root) .. ".json")
end

function M.status(host_root)
	if host_root == nil then
		return copy({
			configured = is_configured,
			transport = transport_status,
			watcher = {
				active = watcher ~= nil,
				failures = watcher_failures,
			},
		})
	end
	local path, path_err = workspace_record_path(host_root)
	if not path then
		return nil, path_err
	end
	local value, err = decode_secure(path, "workspace record", RECORD_KEYS)
	if not value then
		return nil, err
	end
	if value.version ~= 2 or value.host_root ~= host_root then
		return nil, "workspace record identity does not match"
	end
	if not ({ starting = true, running = true, stopped = true, error = true, dead = true })[value.status] then
		return nil, "workspace record status is invalid"
	end
	if
		not positive_integer(value.pid)
		or not positive_integer(value.pane_pid)
		or not valid_id(value.claim_id)
		or type(value.tmux_pane) ~= "string"
		or not value.tmux_pane:match("^%%%d+$")
		or type(value.network_authorized) ~= "boolean"
		or type(value.ssh_agent_forwarding) ~= "boolean"
	then
		return nil, "workspace record lifecycle fields are invalid"
	end
	if
		type(value.container_root) ~= "string"
		or value.container_root:sub(1, 1) ~= "/"
		or value.container_root:find("%z")
	then
		return nil, "workspace record container root is invalid"
	end
	local workspace, workspace_err = M.workspace_key(value.workspace_key)
	if not workspace then
		return nil, workspace_err
	end
	if
		workspace.runtime ~= "container"
		or workspace.repo_identity ~= host_root
		or workspace.root ~= value.container_root
	then
		return nil, "workspace record workspace identity does not match"
	end
	value.workspace_key = workspace
	return copy(value)
end

local function spool_root()
	local value = configured.spool_root
	if type(value) == "function" then
		local ok, resolved = pcall(value)
		if not ok then
			return nil, "spool_root callback failed: " .. tostring(resolved)
		end
		if type(resolved) ~= "string" or resolved == "" or resolved:find("\0", 1, true) then
			return nil, "spool_root callback must return a non-empty string without NUL bytes"
		end
		value = resolved
	end
	if value == nil then
		value = vim.env.NVIM_DEVCONTAINER_SPOOL_ROOT
	end
	if value == nil or value == "" then
		return nil, "spool root is not registered"
	end
	if type(value) ~= "string" or value:find("\0", 1, true) then
		return nil, "spool root must be a non-empty string without NUL bytes"
	end
	local ok, normalized = pcall(vim.fs.normalize, value)
	return ok and normalized or nil, ok and nil or "spool root is invalid: " .. tostring(normalized)
end

local function auth_token(spool)
	if type(spool) == "string" then
		local pinned, prepare_err = prepare_spool_descriptors(spool)
		if not pinned then
			return nil, prepare_err
		end
		local token, token_err = auth_token(pinned)
		local _, close_err = close_spool(pinned)
		return token, token_err or close_err
	end
	local value, _, err = decode_secure_at(spool.root_fd, "auth.json", "spool authentication", AUTH_KEYS)
	if not value then
		return nil, err
	end
	if value.version ~= 2 or type(value.token) ~= "string" or #value.token < 32 or value.token:find("%z") then
		return nil, "spool authentication schema is invalid"
	end
	return value.token
end

local function acknowledge(spool, token, request, ok, err)
	local ack = {
		version = 2,
		request_id = request.request_id,
		ok = ok == true,
		action = request.action,
		error = err or vim.NIL,
	}
	local auth, auth_err = authenticate(token, "ack", ack)
	if not auth then
		return nil, auth_err
	end
	ack.auth = auth
	local committed, warning_or_err, snapshot =
		atomic_create_at(spool.acks_fd, request.request_id .. ".json", vim.json.encode(ack) .. "\n")
	if committed then
		report_commit_warning(nil, "Dev Container acknowledgement", warning_or_err)
	end
	return committed, warning_or_err, snapshot
end

local function consume_request(spool, name, token)
	local request, snapshot, decode_err = decode_secure_at(spool.inbox_fd, name, "spool request", REQUEST_KEYS)
	local retired, retire_err
	if snapshot then
		retired, retire_err = conditional_unlink_at(spool.inbox_fd, name, snapshot)
	end
	if request and not retired then
		return nil, retire_err
	end
	if retired then
		report_commit_warning(nil, "Dev Container inbound request retirement", retire_err)
	end
	if not request then
		if snapshot and not retired then
			decode_err = append_cleanup_failure(decode_err, retire_err)
		end
		return nil, decode_err
	end
	if
		request.version ~= 2
		or not valid_id(request.request_id)
		or name ~= request.request_id .. ".json"
		or request.action ~= "open_location"
		or type(request.path) ~= "string"
		or not positive_integer(request.line)
		or not positive_integer(request.column)
		or not recent_timestamp(request.created_at)
		or not valid_auth(token, "open_location", request)
	then
		return nil, "spool request authentication or schema is invalid"
	end
	local container_root = vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT
	local target, route_err = M.route(request.path, container_root, container_root, "file")
	if not target then
		acknowledge(spool, token, request, false, route_err)
		return nil, route_err
	end
	local open = configured.open
	if type(open) ~= "function" then
		acknowledge(spool, token, request, false, "open callback is not configured")
		return nil, "open callback is not configured"
	end
	local ok, open_err = pcall(open, target, { lnum = request.line, col = request.column })
	local acknowledged, ack_err = acknowledge(spool, token, request, ok, ok and nil or tostring(open_err))
	if not acknowledged then
		return nil, ack_err
	end
	if ok then
		return true
	end
	return nil, tostring(open_err)
end

function M.consume_spool_once()
	if not M.in_workspace() then
		local err = "not running inside a Dev Container editor"
		return nil, err, publish_transport("error", { error = err })
	end
	local root, root_err = spool_root()
	if not root then
		local err = root_err or "spool root is not registered"
		return nil, err, publish_transport("error", { error = err })
	end
	local spool, prepare_err = prepare_spool_descriptors(root)
	if not spool then
		return nil, prepare_err, publish_transport("error", { error = prepare_err })
	end
	local token, token_err = auth_token(spool)
	if not token then
		local _, close_err = close_spool(spool)
		local err = append_cleanup_failure(token_err, close_err)
		return nil, err, publish_transport("error", { error = err })
	end
	local names, scan_err = list_json_at(spool.inbox_fd)
	if not names then
		local _, close_err = close_spool(spool)
		local primary = scan_err or "could not enumerate anchored inbox"
		local err = append_cleanup_failure(primary, close_err)
		return nil, err, publish_transport("error", { error = err })
	end
	local consumed = 0
	local first_error
	local records = {}
	local limit = configured.max_messages_per_tick or DEFAULT_MAX_MESSAGES_PER_TICK
	for index = 1, math.min(#names, limit) do
		local name = names[index]
		local ok, request_err = consume_request(spool, name, token)
		first_error = first_error or request_err
		consumed = consumed + 1
		records[#records + 1] = { name = name, ok = ok == true, error = request_err }
	end
	local _, close_err = close_spool(spool)
	if first_error then
		first_error = append_cleanup_failure(first_error, close_err)
	else
		report_warning(nil, "Dev Container inbound spool result completed but close failed", close_err)
	end
	local failed = 0
	for _, record in ipairs(records) do
		failed = failed + (record.ok and 0 or 1)
	end
	local report = publish_transport(first_error and "partial" or (#names > consumed and "backlog" or "idle"), {
		processed = consumed,
		succeeded = consumed - failed,
		failed = failed,
		remaining = math.max(#names - consumed, 0),
		records = records,
		error = first_error,
		warning = first_error and nil or close_err,
	})
	if first_error then
		return nil, first_error, report
	end
	return consumed, nil, report
end

local function uuid()
	if type(configured.uuid) == "function" then
		local ok, value = pcall(configured.uuid)
		if ok and valid_id(value) then
			return value
		end
	end
	local random_ok, bytes = pcall(uv.random, 16)
	if not random_ok or type(bytes) ~= "string" or #bytes ~= 16 then
		return nil, "could not generate a lifecycle UUID"
	end
	local values = { bytes:byte(1, 16) }
	values[7] = values[7] % 16 + 64
	values[9] = values[9] % 64 + 128
	return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", unpack(values))
end

function M.new_claim_id()
	local value, uuid_err = uuid()
	if not valid_id(value) then
		return nil, uuid_err or "lifecycle claim id is not one canonical UUIDv4"
	end
	return value
end

local function request_ack(spool, token, request, dependencies, callback)
	local deps = dependencies or {}
	local name = request.request_id .. ".json"
	local attempts = 0
	local interval = deps.interval_ms or 50
	local timeout = deps.ack_timeout_ms or configured.ack_timeout_ms or DEFAULT_ACK_TIMEOUT_MS
	local maximum = deps.max_attempts or math.max(math.ceil(timeout / interval) + 1, 1)
	local defer = deps.defer or vim.defer_fn
	local function poll()
		attempts = attempts + 1
		local present, inspect_err, number = snapshot_at(spool.acks_fd, name)
		if present then
			local ack, snapshot, decode_err = decode_secure_at(spool.acks_fd, name, "spool acknowledgement", ACK_KEYS)
			local retired, retire_err
			if snapshot then
				retired, retire_err = conditional_unlink_at(spool.acks_fd, name, snapshot)
			end
			if retired then
				report_commit_warning(deps, "Dev Container acknowledgement retirement", retire_err)
			end
			local _, close_err = close_spool(spool)
			local validation_err = decode_err
			if
				ack
				and (
					ack.version ~= 2
					or ack.request_id ~= request.request_id
					or ack.action ~= request.action
					or type(ack.ok) ~= "boolean"
					or (ack.error ~= vim.NIL and type(ack.error) ~= "string")
					or not valid_auth(token, "ack", ack)
					or ack.ok ~= true
				)
			then
				validation_err = ack.error ~= vim.NIL and type(ack.error) == "string" and ack.error
					or "host request was rejected"
			end
			if snapshot and not retired then
				validation_err = append_cleanup_failure(validation_err, retire_err)
			end
			if validation_err then
				validation_err = append_cleanup_failure(validation_err, close_err)
				callback(nil, validation_err)
			else
				report_warning(deps, "Dev Container acknowledgement accepted but spool close failed", close_err)
				callback(copy(ack))
			end
			return
		end
		if number and number ~= descriptor_api.ENOENT then
			local _, close_err = close_spool(spool)
			local primary = inspect_err or "could not inspect host acknowledgement"
			callback(nil, append_cleanup_failure(primary, close_err))
			return
		end
		if attempts >= maximum then
			local _, close_err = close_spool(spool)
			callback(nil, append_cleanup_failure("host request timed out", close_err))
			return
		end
		defer(poll, interval)
	end
	poll()
end

function M.request_host(action, dependencies, on_success)
	if type(dependencies) == "function" and on_success == nil then
		on_success = dependencies
		dependencies = nil
	end
	if not M.in_workspace() then
		return nil, "not running inside a Dev Container editor"
	end
	if not HOST_ACTIONS[action] then
		return nil, "unsupported host action"
	end
	if on_success ~= nil and type(on_success) ~= "function" then
		return nil, "host success callback must be a function"
	end
	local root, root_err = spool_root()
	if not root then
		return nil, root_err or "authenticated host spool is not registered"
	end
	local spool, prepare_err = prepare_spool_descriptors(root)
	if not spool then
		return nil, prepare_err
	end
	local token, token_err = auth_token(spool)
	if not token then
		local _, close_err = close_spool(spool)
		return nil, append_cleanup_failure(token_err, close_err)
	end
	local request_id, uuid_err = uuid()
	if not valid_id(request_id) then
		local _, close_err = close_spool(spool)
		return nil, append_cleanup_failure(uuid_err or "host request id is not one canonical UUIDv4", close_err)
	end
	local request = {
		version = 2,
		request_id = request_id,
		action = action,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local auth, auth_err = authenticate(token, "host_request", request)
	if not auth then
		local _, close_err = close_spool(spool)
		return nil, append_cleanup_failure(auth_err, close_err)
	end
	request.auth = auth
	local written, write_warning_or_err =
		atomic_create_at(spool.outbox_fd, request_id .. ".json", vim.json.encode(request) .. "\n")
	if not written then
		local _, close_err = close_spool(spool)
		return nil, append_cleanup_failure(write_warning_or_err, close_err)
	end
	report_commit_warning(dependencies, "Dev Container host request", write_warning_or_err)
	request_ack(spool, token, request, dependencies, function(value, err)
		if value then
			if on_success then
				on_success(value)
			end
			return
		end
		local report = (dependencies or {}).notify or configured.notify
		if type(report) == "function" then
			report(err, vim.log.levels.ERROR)
		end
	end)
	return true, request_id
end

function M.lifecycle_argv(action, spec)
	if action ~= "up" and action ~= "status" and action ~= "log" and action ~= "host" and action ~= "doctor" then
		return nil, "unsupported lifecycle action"
	end
	local launcher = configured.launcher
	if type(launcher) ~= "string" or launcher == "" then
		return nil, "devcontainer launcher is not configured"
	end
	local argv = { launcher, action }
	if type(spec) == "table" and spec.root then
		vim.list_extend(argv, { "--repo", spec.root })
	end
	if action == "up" or action == "doctor" then
		vim.list_extend(argv, { "--cli", configured.cli or "devcontainer" })
		vim.list_extend(argv, { "--lockfile-policy", configured.lockfile_policy or "preserve" })
		vim.list_extend(argv, { "--ssh-agent", configured.ssh_agent or "auto" })
	end
	if action == "up" and type(spec) == "table" then
		if type(spec.tmux_pane) ~= "string" or not spec.tmux_pane:match("^%%%d+$") then
			return nil, "Dev Container lifecycle requires one explicit tmux pane"
		end
		if not valid_id(spec.claim_id) then
			return nil, "Dev Container lifecycle requires one canonical claim id"
		end
		vim.list_extend(argv, { "--tmux-pane", spec.tmux_pane })
		vim.list_extend(argv, { "--claim-id", spec.claim_id })
		if spec.config then
			vim.list_extend(argv, { "--config", spec.config })
		end
		if spec.recreate then
			argv[#argv + 1] = "--recreate"
		end
		if spec.allow_network then
			argv[#argv + 1] = "--allow-network"
		end
	elseif action == "up" then
		return nil, "Dev Container lifecycle requires one explicit tmux pane"
	end
	return argv
end

function M.stop()
	if not is_configured and not watcher then
		return M
	end
	watcher_generation = watcher_generation + 1
	if watcher then
		local current = watcher
		watcher = nil
		current:stop()
		current:close()
	end
	publish_transport("stopped")
	emit("stopped")
	return M
end

local function schedule_watch(delay, expected, generation)
	expected = expected or watcher
	generation = generation or watcher_generation
	if not expected or watcher ~= expected or watcher_generation ~= generation then
		return
	end
	expected:start(
		delay,
		0,
		vim.schedule_wrap(function()
			if watcher ~= expected or watcher_generation ~= generation then
				return
			end
			local ok, err, report = M.consume_spool_once()
			if ok == nil then
				watcher_failures = math.min(watcher_failures + 1, 5)
				if type(configured.notify) == "function" then
					configured.notify(err, vim.log.levels.ERROR)
				end
			else
				watcher_failures = 0
			end
			local next_delay = configured.poll_interval_ms
			if report and report.remaining > 0 then
				next_delay = 0
			elseif watcher_failures > 0 then
				next_delay = math.min(configured.poll_interval_ms * (2 ^ watcher_failures), 2000)
			end
			schedule_watch(next_delay, expected, generation)
		end)
	)
end

function M.effective_config()
	if not is_configured then
		return public_defaults()
	end
	return copy({
		ack_timeout_ms = configured.ack_timeout_ms,
		claim_timeout_ms = configured.claim_timeout_ms,
		cli = configured.cli,
		lockfile_policy = configured.lockfile_policy,
		max_messages_per_tick = configured.max_messages_per_tick,
		poll_interval_ms = configured.poll_interval_ms,
		ssh_agent = configured.ssh_agent,
		watch = configured.watch ~= false,
	})
end

function M.transport_status()
	return copy(transport_status)
end

function M.teardown()
	if not is_configured then
		return M
	end
	M.stop()
	emit("teardown")
	configured = {}
	is_configured = false
	watcher_failures = 0
	return M
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local candidate, candidate_err = validate_setup(opts)
	if not candidate then
		error(candidate_err)
	end
	if is_configured then
		M.teardown()
	end
	configured = candidate
	is_configured = true
	watcher_failures = 0
	publish_transport("idle")
	emit("setup", { config = M.effective_config() })
	if M.in_workspace() and configured.watch ~= false then
		watcher_generation = watcher_generation + 1
		watcher = uv.new_timer()
		schedule_watch(0, watcher, watcher_generation)
	end
	return M
end

M._atomic_write = atomic_write
M._atomic_create = atomic_create
M._secure_read = secure_read
M._prepare_spool = prepare_spool
M._authenticate = authenticate
M._auth_token = auth_token
M._set_test_hook = function(callback)
	assert(callback == nil or type(callback) == "function", "test hook must be a function or nil")
	test_hook = callback
end
M._record_keys = RECORD_KEYS
M._request_keys = REQUEST_KEYS
M._ack_keys = ACK_KEYS

return M
