-- Dev Container lifecycle and authenticated editor transport core.
local M = {}
local contracts = require("local_plugins.contracts")

local uv = vim.uv
local configured = {}
local watcher
local temp_counter = 0

local MAX_MESSAGE = 64 * 1024
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
	workspace_key = true,
	pid = true,
	status = true,
	network_authorized = true,
	ssh_agent_forwarding = true,
	token = true,
	tmux_pane = true,
	log_path = true,
	updated_at = true,
	exit_code = true,
	error = true,
}
local REQUEST_KEYS = {
	version = true,
	token = true,
	request_id = true,
	action = true,
	path = true,
	line = true,
	column = true,
	created_at = true,
}
local ACK_KEYS = {
	version = true,
	token = true,
	request_id = true,
	ok = true,
	action = true,
	error = true,
}

local function copy(value)
	return vim.deepcopy(value)
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
	return true
end

local function state_root()
	local root = configured.state_root
	if type(root) == "function" then
		root = root()
	end
	if type(root) ~= "string" or root == "" then
		root = vim.env.NVIM_DEVCONTAINER_STATE_HOME
	end
	if type(root) ~= "string" or root == "" then
		local state = vim.env.XDG_STATE_HOME or (vim.env.HOME and vim.fs.joinpath(vim.env.HOME, ".local", "state"))
		root = state and vim.fs.joinpath(state, "nvim-devcontainer") or nil
	end
	return root and vim.fs.normalize(vim.fn.fnamemodify(root, ":p")) or nil
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
	if not stat or stat.type ~= "directory" then
		return nil, "state path is not a real directory: " .. path
	end
	local ok, err = uv.fs_chmod(path, tonumber("700", 8))
	return ok and true or nil, ok and nil or "could not secure state directory: " .. tostring(err)
end

local function unlink_regular(path)
	local stat = uv.fs_lstat(path)
	if stat and stat.type == "file" then
		pcall(uv.fs_unlink, path)
	end
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
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if offset ~= #payload or not synced or not closed then
		unlink_regular(temporary)
		return nil, "could not persist private file: " .. tostring(write_err or sync_err or close_err)
	end
	local renamed, rename_err = uv.fs_rename(temporary, path)
	if not renamed then
		unlink_regular(temporary)
		return nil, "could not replace private file: " .. tostring(rename_err)
	end
	local secured, secure_err = uv.fs_chmod(path, tonumber("600", 8))
	return secured and true or nil, secured and nil or "could not secure private file: " .. tostring(secure_err)
end

local function secure_read(path, label)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" then
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
	return type(value) == "string" and value:match("^[0-9a-f]+%-[0-9a-f%-]+$") ~= nil and #value == 36
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
	local root = state_root()
	if not root then
		return nil
	end
	return vim.fs.joinpath(root, "workspaces", vim.fn.sha256(host_root) .. ".json")
end

function M.status(host_root)
	local path = workspace_record_path(host_root)
	if not path then
		return nil, "state root is unavailable"
	end
	local value, err = decode_secure(path, "workspace record", RECORD_KEYS)
	if not value then
		return nil, err
	end
	if value.version ~= 1 or value.host_root ~= host_root then
		return nil, "workspace record identity does not match"
	end
	local workspace, workspace_err = M.workspace_key(value.workspace_key)
	if not workspace then
		return nil, workspace_err
	end
	value.workspace_key = workspace
	value.token = nil
	return copy(value)
end

local function token()
	local value = vim.env.NVIM_DEVCONTAINER_TOKEN
	return type(value) == "string" and #value >= 32 and value or nil
end

local function spool_root()
	local value = configured.spool_root
	if type(value) == "function" then
		value = value()
	end
	if type(value) ~= "string" or value == "" then
		value = vim.env.NVIM_DEVCONTAINER_SPOOL_ROOT
	end
	return type(value) == "string" and value ~= "" and vim.fs.normalize(value) or nil
end

local function acknowledge(root, request, ok, err)
	local ack = {
		version = 1,
		token = request.token,
		request_id = request.request_id,
		ok = ok == true,
		action = request.action,
		error = err or vim.NIL,
	}
	return atomic_write(vim.fs.joinpath(root, "acks", request.request_id .. ".json"), vim.json.encode(ack) .. "\n")
end

local function consume_request(root, path)
	local request, read_err = decode_secure(path, "spool request", REQUEST_KEYS)
	unlink_regular(path)
	if not request then
		return nil, read_err
	end
	if
		request.version ~= 1
		or request.token ~= token()
		or not valid_id(request.request_id)
		or request.action ~= "open_location"
		or not positive_integer(request.line)
		or not positive_integer(request.column)
		or not recent_timestamp(request.created_at)
	then
		return nil, "spool request authentication or schema is invalid"
	end
	local container_root = vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT
	local target, route_err = M.route(request.path, container_root, container_root, "file")
	if not target then
		acknowledge(root, request, false, route_err)
		return nil, route_err
	end
	local open = configured.open
	if type(open) ~= "function" then
		acknowledge(root, request, false, "open callback is not configured")
		return nil, "open callback is not configured"
	end
	local ok, open_err = pcall(open, target, { lnum = request.line, col = request.column })
	acknowledge(root, request, ok, ok and nil or tostring(open_err))
	return ok and true or nil, ok and nil or tostring(open_err)
end

function M.consume_spool_once()
	if not M.in_workspace() then
		return nil, "not running inside a Dev Container editor"
	end
	local root = spool_root()
	if not root then
		return nil, "spool root is not registered"
	end
	local prepared, prepare_err = prepare_spool(root)
	if not prepared then
		return nil, prepare_err
	end
	local request_dir = vim.fs.joinpath(root, "inbox")
	local handle = uv.fs_scandir(request_dir)
	if not handle then
		return 0
	end
	local consumed = 0
	while true do
		local name, kind = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind == "file" and name:match("^[0-9a-f%-]+%.json$") then
			consume_request(root, vim.fs.joinpath(request_dir, name))
			consumed = consumed + 1
		end
	end
	return consumed
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

local function request_ack(root, request_id, dependencies, callback)
	local deps = dependencies or {}
	local path = vim.fs.joinpath(root, "acks", request_id .. ".json")
	local attempts = 0
	local maximum = deps.max_attempts or 100
	local defer = deps.defer or vim.defer_fn
	local function poll()
		attempts = attempts + 1
		local stat = uv.fs_lstat(path)
		if stat then
			local ack, ack_err = decode_secure(path, "spool acknowledgement", ACK_KEYS)
			unlink_regular(path)
			if
				not ack
				or ack.version ~= 1
				or ack.token ~= token()
				or ack.request_id ~= request_id
				or ack.ok ~= true
			then
				callback(nil, ack_err or (ack and ack.error) or "host request was rejected")
			else
				callback(copy(ack))
			end
			return
		end
		if attempts >= maximum then
			callback(nil, "host request timed out")
			return
		end
		defer(poll, deps.interval_ms or 50)
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
	local root = spool_root()
	local auth = token()
	if not root or not auth then
		return nil, "authenticated host spool is not registered"
	end
	local prepared, prepare_err = prepare_spool(root)
	if not prepared then
		return nil, prepare_err
	end
	local request_id = uuid()
	local request = {
		version = 1,
		token = auth,
		request_id = request_id,
		action = action,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local path = vim.fs.joinpath(root, "outbox", request_id .. ".json")
	local written, write_err = atomic_write(path, vim.json.encode(request) .. "\n")
	if not written then
		return nil, write_err
	end
	request_ack(root, request_id, dependencies, function(value, err)
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
	if action ~= "up" and action ~= "status" and action ~= "log" and action ~= "host" then
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
	if action == "up" and type(spec) == "table" then
		if spec.config then
			vim.list_extend(argv, { "--config", spec.config })
		end
		if spec.recreate then
			argv[#argv + 1] = "--recreate"
		end
		if spec.allow_network then
			argv[#argv + 1] = "--allow-network"
		end
	end
	return argv
end

function M.stop()
	if watcher then
		watcher:stop()
		watcher:close()
		watcher = nil
	end
end

function M.setup(opts)
	M.stop()
	configured = copy(opts or {})
	if M.in_workspace() and configured.watch ~= false then
		watcher = uv.new_timer()
		watcher:start(
			0,
			configured.poll_interval_ms or 100,
			vim.schedule_wrap(function()
				local ok, err = M.consume_spool_once()
				if ok == nil and type(configured.notify) == "function" then
					configured.notify(err, vim.log.levels.ERROR)
				end
			end)
		)
	end
	return M
end

M._atomic_write = atomic_write
M._secure_read = secure_read
M._prepare_spool = prepare_spool
M._record_keys = RECORD_KEYS
M._request_keys = REQUEST_KEYS
M._ack_keys = ACK_KEYS

return M
