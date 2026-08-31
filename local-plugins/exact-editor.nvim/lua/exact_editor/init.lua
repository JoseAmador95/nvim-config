-- Exact editor registry and request bridge.
local M = {}
local contracts = require("local_plugins.contracts")

local uv = vim.uv
local active
local deferred = false
local configured = {}
local temp_counter = 0

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
	report(message, level or vim.log.levels.INFO, { title = "Exact Editor" })
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

local function timestamp()
	local clock = configured.clock or function()
		return os.date("!%Y-%m-%dT%H:%M:%SZ")
	end
	return clock()
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

local function unlink_regular(path)
	local stat = uv.fs_lstat(path)
	if stat and stat.type == "file" then
		pcall(uv.fs_unlink, path)
	end
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
	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, fd)
			unlink_regular(temp)
			return nil, "cannot write temporary file: " .. tostring(write_err or "zero-byte write")
		end
		offset = offset + written
	end
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if not synced or not closed then
		unlink_regular(temp)
		return nil, "cannot persist temporary file: " .. tostring(sync_err or close_err)
	end
	local renamed, rename_err = uv.fs_rename(temp, path)
	if not renamed then
		unlink_regular(temp)
		return nil, "cannot replace target file: " .. tostring(rename_err)
	end
	local secured, secure_err = uv.fs_chmod(path, tonumber("600", 8))
	return secured and true or nil, secured and nil or "cannot secure target file: " .. tostring(secure_err)
end

local function secure_read(path, label, maximum)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" then
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
		or after.dev ~= opened.dev
		or after.ino ~= opened.ino
		or after.size ~= opened.size
		or after.mode ~= opened.mode
	then
		return nil, label .. " changed while validating"
	end
	return data
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
	local record = {
		version = 2,
		instance_id = instance.instance_id,
		pid = instance.pid or (configured.pid and configured.pid() or uv.os_getpid()),
		socket = instance.socket,
		workspaces = workspaces,
		TMUX_PANE = vim.env.TMUX_PANE or vim.NIL,
		updated_at = timestamp(),
	}
	local encoded = vim.json.encode(record) .. "\n"
	local ok, err = atomic_write(record_path(instance), encoded)
	if not ok then
		return nil, err
	end
	local chmod_ok, chmod_err = uv.fs_chmod(record_path(instance), tonumber("600", 8))
	if not chmod_ok then
		return nil, "cannot secure registry record: " .. tostring(chmod_err)
	end
	return record
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
	local state = {
		version = 1,
		request_id = request_id,
		instance_id = instance.instance_id,
		status = status,
		updated_at = timestamp(),
	}
	local path = wait_path(instance, request_id)
	local ok, err = atomic_write(path, vim.json.encode(state) .. "\n")
	if not ok then
		return nil, err
	end
	local chmod_ok, chmod_err = uv.fs_chmod(path, tonumber("600", 8))
	if not chmod_ok then
		return nil, "cannot secure editor wait state: " .. tostring(chmod_err)
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

local function arm_editor_wait(instance, request_id, target, win, buf, dependencies)
	local group = vim.api.nvim_create_augroup("exact_editor_wait_" .. request_id:gsub("%-", "_"), { clear = true })
	local finished = false
	local recovery_created = false
	local remove_finish_mapping

	local function cleanup()
		pcall(vim.api.nvim_del_augroup_by_id, group)
		if type(remove_finish_mapping) == "function" then
			pcall(remove_finish_mapping)
		end
	end

	local function finish(status)
		if finished then
			return true
		end
		if status ~= "aborted" and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
			status = "aborted"
		end
		local state, err = write_wait_state(instance, request_id, status)
		if not state then
			notify("Could not update editor wait state: " .. tostring(err), vim.log.levels.ERROR)
			return nil
		end
		finished = true
		cleanup()
		return true
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(win),
		callback = function()
			local modified = vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified
			local completed = not modified
			if modified and not recovery_created then
				recovery_created = true
				preserve_modified_buffer(buf, target)
			end
			finish("completed")
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
		group = group,
		buffer = buf,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified and not recovery_created then
				recovery_created = true
				preserve_modified_buffer(buf, target)
			end
			finish("completed")
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			finish("completed")
		end,
	})
	local function save_and_finish()
		local wrote, write_err = pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd.write()
		end)
		if not wrote or (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified) then
			finish("aborted")
			notify("Could not save external-editor text: " .. tostring(write_err), vim.log.levels.ERROR)
			return
		end
		if vim.api.nvim_win_is_valid(win) then
			local closed, close_window_err = pcall(vim.api.nvim_win_close, win, false)
			if not closed then
				finish("aborted")
				notify("Could not close external-editor window: " .. tostring(close_window_err), vim.log.levels.ERROR)
			end
		else
			finish("completed")
		end
	end
	local install_finish_mapping = (dependencies and dependencies.install_finish_mapping)
		or configured.install_finish_mapping
	if type(install_finish_mapping) == "function" then
		local installed, remover_or_err = pcall(install_finish_mapping, buf, save_and_finish)
		if not installed or (remover_or_err ~= nil and type(remover_or_err) ~= "function") then
			cleanup()
			return nil, "could not install external-editor finish action: " .. tostring(remover_or_err)
		end
		remove_finish_mapping = remover_or_err
	end

	local state, state_err = write_wait_state(instance, request_id, "waiting")
	if not state then
		cleanup()
		return nil, state_err
	end
	return true
end

local function consume(request_id, instance, dependencies, expected_version)
	if not is_uuid(request_id) then
		return nil, "request id must be a lowercase UUID"
	end
	local path = request_path(instance, request_id)
	local encoded, read_err = secure_read(path, "request", 64 * 1024)
	unlink_regular(path)
	if not encoded then
		return nil, read_err
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
			return M.write_registry(instance)
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
		instance.workspaces[workspace_identity(normalized)] = normalized
	elseif resolve_err then
		return nil, resolve_err
	end
	return M.write_registry(instance)
end

local function cleanup(instance)
	if not instance then
		return
	end
	unlink_regular(record_path(instance))
	if instance.owns_socket then
		pcall(configured.server_stop or vim.fn.serverstop, instance.socket)
		local socket_stat = uv.fs_lstat(instance.socket)
		if socket_stat and socket_stat.type == "socket" then
			pcall(uv.fs_unlink, instance.socket)
		end
	end
	if active == instance then
		active = nil
		_G.ExactEditorRequest = nil
	end
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
		pcall(configured.server_stop or vim.fn.serverstop, result)
		return nil, "Neovim server path is not a Unix socket"
	end
	local secured, secure_err = uv.fs_chmod(result, tonumber("600", 8))
	if not secured then
		pcall(configured.server_stop or vim.fn.serverstop, result)
		pcall(uv.fs_unlink, result)
		return nil, "could not secure the Neovim socket: " .. tostring(secure_err)
	end
	return result
end

function M.setup(opts)
	opts = opts or {}
	if active then
		return active
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
	configured = vim.tbl_extend("force", {}, opts)
	local root = M.state_root()
	local prepared, prepare_err = prepare_state(root)
	if not prepared then
		notify(prepare_err, vim.log.levels.ERROR)
		return nil
	end
	local instance_id = uuid()
	if not is_uuid(instance_id) then
		notify("UUID provider returned an invalid identifier", vim.log.levels.ERROR)
		return nil
	end
	local socket, server_err = start_server(root, instance_id)
	if not socket then
		notify(server_err, vim.log.levels.ERROR)
		return nil
	end
	local instance = {
		root = root,
		instance_id = instance_id,
		socket = socket,
		owns_socket = true,
		workspaces = {},
	}
	active = instance

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

	local ok, err = discover(instance, vim.api.nvim_buf_get_name(0))
	if not ok then
		cleanup(instance)
		notify("Could not create editor registry: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	return instance
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
		schedule(function()
			deferred = false
			if ui_count() > 0 then
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

return M
