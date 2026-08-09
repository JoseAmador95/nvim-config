-- Private editor registry and request bridge used by scripts/nvim-review-open.
local M = {}

local uv = vim.uv
local fs = require("config.fs")
local active
local deferred = false

local RECORD_KEYS = {
	version = true,
	instance_id = true,
	pid = true,
	socket = true,
	repo_roots = true,
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

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Editor RPC" })
end

local function uuid()
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
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.state_root()
	local root
	if vim.env.NVIM_REVIEW_STATE_HOME and vim.env.NVIM_REVIEW_STATE_HOME ~= "" then
		root = vim.env.NVIM_REVIEW_STATE_HOME
	elseif vim.env.XDG_STATE_HOME and vim.env.XDG_STATE_HOME ~= "" then
		root = vim.fs.joinpath(vim.env.XDG_STATE_HOME, "nvim-review")
	else
		root = vim.fs.joinpath(vim.env.HOME, ".local", "state", "nvim-review")
	end
	local expanded = vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))
	return uv.fs_realpath(expanded) or expanded
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

local function sorted_roots(instance)
	local roots = vim.tbl_keys(instance.roots)
	table.sort(roots)
	return roots
end

function M.write_registry(instance)
	local record = {
		version = 1,
		instance_id = instance.instance_id,
		pid = uv.os_getpid(),
		socket = instance.socket,
		repo_roots = sorted_roots(instance),
		TMUX_PANE = vim.env.TMUX_PANE or vim.NIL,
		updated_at = timestamp(),
	}
	local encoded = vim.json.encode(record) .. "\n"
	local ok, err = fs.write_binary_atomic(record_path(instance), encoded)
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

local function consume(request_id, instance, dependencies)
	if not is_uuid(request_id) then
		return nil, "request id must be a lowercase UUID"
	end
	local path = request_path(instance, request_id)
	local stat = uv.fs_lstat(path)
	if not stat or stat.type ~= "file" then
		return nil, "request is missing or is not a regular file"
	end
	if stat.size > 64 * 1024 then
		pcall(uv.fs_unlink, path)
		return nil, "request exceeds 64 KiB"
	end
	local encoded, read_err = fs.read_binary(path)
	pcall(uv.fs_unlink, path)
	if not encoded then
		return nil, read_err
	end
	local ok, value = pcall(vim.json.decode, encoded)
	if not ok or type(value) ~= "table" or vim.islist(value) then
		return nil, "request must be one JSON object"
	end
	local keys_ok, keys_err = exact_keys(value, REQUEST_KEYS, "request")
	if not keys_ok then
		return nil, keys_err
	end
	for key in pairs(REQUEST_KEYS) do
		if value[key] == nil then
			return nil, "request is missing " .. key
		end
	end
	if value.version ~= 1 or value.request_id ~= request_id or value.instance_id ~= instance.instance_id then
		return nil, "request identity does not match the selected editor"
	end
	if type(value.created_at) ~= "string" or value.created_at == "" then
		return nil, "request created_at is invalid"
	end
	if not positive_integer(value.line) or not positive_integer(value.column) then
		return nil, "request line and column must be positive integers"
	end
	if type(value.repo_root) ~= "string" or not instance.roots[value.repo_root] then
		return nil, "request repository is not registered by this editor"
	end
	local canonical, root_err = require("config.repo").root(value.repo_root)
	if not canonical or canonical ~= value.repo_root then
		return nil, root_err or "request repository is not canonical"
	end
	local target, target_err = require("config.repo").resolve_relative(canonical, value.path)
	if not target then
		return nil, target_err
	end
	local open_file = dependencies and dependencies.open_file or require("config.editor").open_file_in_tab
	open_file(target, { lnum = value.line, col = value.column })
	return 1
end

function M.consume_request(request_id, instance, dependencies)
	return consume(request_id, instance or active, dependencies)
end

local function discover(instance, path)
	local candidate = path
	if not candidate or candidate == "" then
		candidate = uv.cwd()
	end
	local absolute = vim.fn.fnamemodify(candidate, ":p")
	for root in pairs(instance.roots) do
		if absolute == root or absolute:sub(1, #root + 1) == root .. "/" then
			return M.write_registry(instance)
		end
	end
	local root = require("config.repo").root(absolute)
	if root then
		instance.roots[root] = true
	end
	return M.write_registry(instance)
end

local function cleanup(instance)
	if not instance then
		return
	end
	pcall(uv.fs_unlink, record_path(instance))
	if instance.owns_socket then
		pcall(vim.fn.serverstop, instance.socket)
		pcall(uv.fs_unlink, instance.socket)
	end
	if active == instance then
		active = nil
		_G.NvimReviewOpenRequest = nil
	end
end

local function start_server(root, instance_id)
	local socket = vim.fs.joinpath(root, "sockets", instance_id:gsub("%-", ""):sub(1, 12) .. ".sock")
	pcall(uv.fs_unlink, socket)
	local ok, result = pcall(vim.fn.serverstart, socket)
	if not ok or type(result) ~= "string" or result == "" then
		return nil, "could not start a Unix Neovim server: " .. tostring(result)
	end
	local secured, secure_err = uv.fs_chmod(result, tonumber("600", 8))
	if not secured then
		pcall(vim.fn.serverstop, result)
		pcall(uv.fs_unlink, result)
		return nil, "could not secure the Neovim socket: " .. tostring(secure_err)
	end
	return result
end

function M.setup()
	if active then
		return active
	end
	local root = M.state_root()
	local prepared, prepare_err = prepare_state(root)
	if not prepared then
		notify(prepare_err, vim.log.levels.ERROR)
		return nil
	end
	local instance_id = uuid()
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
		roots = {},
	}
	active = instance

	_G.NvimReviewOpenRequest = function(request_id)
		local handled, err = consume(request_id, instance)
		if not handled then
			error(err)
		end
		return handled
	end

	local group = vim.api.nvim_create_augroup("config_editor_rpc", { clear = true })
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
	local setup = deps.setup or M.setup

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
	local group = vim.api.nvim_create_augroup("config_editor_rpc_deferred", { clear = true })
	vim.api.nvim_create_autocmd("UIEnter", { group = group, once = true, callback = queue })
end

M._cleanup = cleanup
M._record_keys = RECORD_KEYS
M._prepare_state = prepare_state

return M
