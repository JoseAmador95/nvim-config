local M = {}

local uv = vim.uv
local options = {
	max_age_seconds = 30 * 24 * 60 * 60,
	lease_seconds = 5 * 60,
	now = os.time,
}
local sequence = 0

local function copy(value)
	return vim.deepcopy(value)
end

local function private_file(path, label)
	local stat = uv.fs_lstat(path)
	if not stat then
		return true
	end
	if stat.type == "link" then
		return nil, "refusing symlinked " .. label .. ": " .. path
	end
	if stat.type ~= "file" then
		return nil, label .. " is not a regular file: " .. path
	end
	local ok, err = uv.fs_chmod(path, tonumber("600", 8))
	return ok and true or nil, ok and nil or tostring(err)
end

local function ensure_root()
	if type(options.state_root) ~= "string" or options.state_root == "" then
		return nil, "state_root is required"
	end
	local requested = vim.fs.abspath(options.state_root)
	local ancestor = requested
	local missing = {}
	local stat = uv.fs_lstat(ancestor)
	while not stat do
		table.insert(missing, 1, vim.fs.basename(ancestor))
		local parent = vim.fs.dirname(ancestor)
		if parent == ancestor then
			return nil, "could not resolve state directory parent"
		end
		ancestor = parent
		stat = uv.fs_lstat(ancestor)
	end
	if stat.type == "link" then
		return nil, "refusing symlinked state directory: " .. ancestor
	end
	if stat.type ~= "directory" then
		return nil, "state path is not a directory: " .. ancestor
	end
	local current = uv.fs_realpath(ancestor) or ancestor
	for _, part in ipairs(missing) do
		current = vim.fs.joinpath(current, part)
		local made, make_err = uv.fs_mkdir(current, tonumber("700", 8))
		if not made and not uv.fs_stat(current) then
			return nil, "could not create state directory: " .. tostring(make_err)
		end
	end
	local ok, err = uv.fs_chmod(current, tonumber("700", 8))
	return ok and current or nil, ok and nil or tostring(err)
end

local function read(path)
	local valid, valid_err = private_file(path, "scratch state")
	if not valid then
		return nil, valid_err
	end
	local stat = uv.fs_stat(path)
	if not stat then
		return nil, "missing"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, tostring(open_err)
	end
	local inspected, inspect_err = uv.fs_fstat(fd)
	if not inspected or inspected.type ~= "file" then
		pcall(uv.fs_close, fd)
		return nil, tostring(inspect_err or "not a regular file")
	end
	local data, data_err = uv.fs_read(fd, inspected.size, 0)
	local closed, close_err = uv.fs_close(fd)
	if not data then
		return nil, tostring(data_err)
	end
	return closed and data or nil, closed and nil or tostring(close_err)
end

local function write_atomic(path, data)
	local valid, valid_err = private_file(path, "scratch target")
	if not valid then
		return nil, valid_err
	end
	sequence = sequence + 1
	local temporary = ("%s.tmp.%d.%d"):format(path, uv.os_getpid(), sequence)
	local fd, open_err = uv.fs_open(temporary, "wx", tonumber("600", 8))
	if not fd then
		return nil, tostring(open_err)
	end
	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, fd)
			pcall(uv.fs_unlink, temporary)
			return nil, tostring(write_err or "short write")
		end
		offset = offset + written
	end
	local synced, sync_err = uv.fs_fsync(fd)
	local closed, close_err = uv.fs_close(fd)
	if not synced or not closed then
		pcall(uv.fs_unlink, temporary)
		return nil, tostring(sync_err or close_err)
	end
	local renamed, rename_err = uv.fs_rename(temporary, path)
	if not renamed then
		pcall(uv.fs_unlink, temporary)
		return nil, tostring(rename_err)
	end
	uv.fs_chmod(path, tonumber("600", 8))
	return true
end

local function decode(path)
	local raw, err = read(path)
	if not raw then
		return nil, err
	end
	local ok, value = pcall(vim.json.decode, raw)
	return ok and type(value) == "table" and value or nil, ok and nil or "invalid JSON state"
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

local function lease_active(path, token)
	local lease = decode(path)
	if not lease then
		return false
	end
	return lease.expires_at >= options.now() and (token == nil or lease.token == token), lease
end

local function claim_lease(path)
	local active, lease = lease_active(path)
	if active then
		return nil, { kind = "leased", lease = copy(lease) }
	end
	local token = vim.fn.sha256(table.concat({ path, uv.os_getpid(), uv.hrtime() }, "\0"))
	local value = { token = token, pid = uv.os_getpid(), expires_at = options.now() + options.lease_seconds }
	local ok, err = write_atomic(path, vim.json.encode(value) .. "\n")
	return ok and value or nil, ok and nil or err
end

local function legacy_path(root, ids)
	for _, id in ipairs(ids or {}) do
		if type(id) == "string" and id:match("^[0-9a-f]+$") then
			local path = vim.fs.joinpath(root, id .. ".md")
			if uv.fs_lstat(path) then
				return path
			end
		end
	end
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
	if not uv.fs_lstat(path) then
		local legacy = legacy_path(root, request.legacy_ids)
		if legacy then
			path = legacy
			meta = path .. ".meta"
			lease_path = path .. ".lease"
			adopted = true
		else
			local created, create_err = write_atomic(path, "")
			if not created then
				return nil, create_err
			end
		end
	end
	local content, content_err = read(path)
	if not content then
		return nil, content_err
	end
	local lease, lease_err = claim_lease(lease_path)
	if not lease then
		return nil, lease_err
	end
	local metadata = {
		version = 2,
		managed = true,
		id = id,
		key = copy(request.key),
		path = path,
		adopted = adopted,
		updated_at = options.now(),
	}
	local wrote_meta, meta_err = write_atomic(meta, vim.json.encode(metadata) .. "\n")
	if not wrote_meta then
		pcall(uv.fs_unlink, lease_path)
		return nil, meta_err
	end
	return {
		key = copy(request.key),
		path = path,
		meta_path = meta,
		lease_path = lease_path,
		lease_token = lease.token,
		content = content,
		revision = vim.fn.sha256(content),
		adopted = adopted,
	}
end

function M.renew(handle)
	local active = lease_active(handle.lease_path, handle.lease_token)
	if not active then
		return nil, "scratch lease was lost"
	end
	local value =
		{ token = handle.lease_token, pid = uv.os_getpid(), expires_at = options.now() + options.lease_seconds }
	return write_atomic(handle.lease_path, vim.json.encode(value) .. "\n")
end

function M.save(handle, content)
	if type(content) ~= "string" then
		return nil, "scratch content must be a string"
	end
	local active = lease_active(handle.lease_path, handle.lease_token)
	if not active then
		return nil, { kind = "lease-lost" }
	end
	local current, current_err = read(handle.path)
	if not current then
		return nil, current_err
	end
	local revision = vim.fn.sha256(current)
	if revision ~= handle.revision then
		return nil, { kind = "conflict", current = current, proposed = content, revision = revision }
	end
	local ok, err = write_atomic(handle.path, content)
	if not ok then
		return nil, err
	end
	handle.content = content
	handle.revision = vim.fn.sha256(content)
	M.renew(handle)
	return copy(handle)
end

function M.release(handle)
	local active = lease_active(handle.lease_path, handle.lease_token)
	if active then
		return uv.fs_unlink(handle.lease_path)
	end
	return false
end

local function managed_meta(path)
	local value = decode(path)
	return value and value.version == 2 and value.managed == true and value.path
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
	for name, kind in vim.fs.dir(root) do
		if kind == "file" and name:sub(-5) == ".meta" then
			local meta_path = vim.fs.joinpath(root, name)
			local scratch = managed_meta(meta_path)
			local stat = scratch and uv.fs_stat(scratch) or nil
			local lease_path = scratch and (scratch .. ".lease") or nil
			local active = lease_path and lease_active(lease_path) or false
			if
				stat
				and stat.type == "file"
				and stat.mtime.sec < options.now() - options.max_age_seconds
				and not kept[vim.fs.normalize(scratch)]
				and not active
			then
				uv.fs_unlink(scratch)
				uv.fs_unlink(meta_path)
				pcall(uv.fs_unlink, lease_path)
				removed[#removed + 1] = scratch
			end
		elseif kind == "link" then
			return nil, "refusing symlinked scratch state: " .. vim.fs.joinpath(root, name)
		end
	end
	return removed
end

function M.setup(config)
	config = config or {}
	options.state_root = assert(config.state_root, "repo_scratch.setup requires state_root")
	options.max_age_seconds = config.max_age_seconds or options.max_age_seconds
	options.lease_seconds = config.lease_seconds or options.lease_seconds
	options.now = config.now or options.now
	return ensure_root()
end

M._private_file = private_file

return M
