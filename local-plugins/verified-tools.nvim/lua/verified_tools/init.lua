-- Verified, explicit lifecycle for release and package-manager tools.
local M = {}
local contracts = require("local_plugins.contracts")

local uv = vim.uv
local configured = {}
local queue = {}
local running = {}
local running_count = 0
local generation = 0
local temp_counter = 0

local STATUSES = {
	planned = true,
	blocked = true,
	claimed = true,
	queued = true,
	running = true,
	succeeded = true,
	failed = true,
	drift = true,
	cancelled = true,
	["repair-required"] = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function now()
	return type(configured.clock) == "function" and configured.clock() or os.time()
end

local function pid()
	return type(configured.pid) == "function" and configured.pid() or uv.os_getpid()
end

local function notify(message, level)
	if type(configured.notify) == "function" then
		configured.notify(message, level)
	end
end

local function emit(name, value)
	if type(configured.events) == "function" then
		configured.events(name, copy(value))
	end
end

local function root()
	local value = configured.state_root
	if type(value) == "function" then
		value = value()
	end
	assert(type(value) == "string" and value ~= "", "verified_tools.setup requires state_root")
	return vim.fs.normalize(vim.fn.fnamemodify(value, ":p"))
end

local function contained(path, parent)
	path = vim.fs.normalize(path)
	parent = vim.fs.normalize(parent):gsub("/+$", "")
	return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function secure_directory(path)
	local before = uv.fs_lstat(path)
	if before and before.type ~= "directory" then
		return nil, "state path is not a real directory"
	end
	local ok, made = pcall(vim.fn.mkdir, path, "p", tonumber("700", 8))
	if not ok or (made ~= 0 and made ~= 1) then
		return nil, "state directory is unavailable"
	end
	local stat = uv.fs_lstat(path)
	if not stat or stat.type ~= "directory" then
		return nil, "state path is not a real directory"
	end
	local secured, err = uv.fs_chmod(path, tonumber("700", 8))
	return secured and true or nil, secured and nil or "cannot secure state directory: " .. tostring(err)
end

local function prepare_state()
	for _, path in ipairs({
		root(),
		vim.fs.joinpath(root(), "records"),
		vim.fs.joinpath(root(), "locks"),
		vim.fs.joinpath(root(), "locks", "identity"),
		vim.fs.joinpath(root(), "locks", "destination"),
		vim.fs.joinpath(root(), "locks", "global"),
		vim.fs.joinpath(root(), "shims"),
		vim.fs.joinpath(root(), "shims", "bin"),
	}) do
		local ok, err = secure_directory(path)
		if not ok then
			return nil, err
		end
	end
	return true
end

local function unlink_regular(path)
	local stat = uv.fs_lstat(path)
	if stat and stat.type == "file" then
		pcall(uv.fs_unlink, path)
	end
end

local function write_all(fd, data)
	local offset = 0
	while offset < #data do
		local wrote, err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not wrote or wrote <= 0 then
			return nil, "write failed: " .. tostring(err)
		end
		offset = offset + wrote
	end
	return true
end

local function atomic_write(path, data)
	local current = uv.fs_lstat(path)
	if current and current.type ~= "file" then
		return nil, "refusing non-regular state target"
	end
	temp_counter = temp_counter + 1
	local temp = ("%s.tmp.%d.%s.%d"):format(path, pid(), tostring(uv.hrtime()), temp_counter)
	local fd, open_err = uv.fs_open(temp, "wx", tonumber("600", 8))
	if not fd then
		return nil, "cannot create state temporary: " .. tostring(open_err)
	end
	local wrote, write_err = write_all(fd, data)
	local synced = wrote and uv.fs_fsync(fd)
	local closed = uv.fs_close(fd)
	if not wrote or not synced or not closed then
		unlink_regular(temp)
		return nil, write_err or "cannot persist state temporary"
	end
	local renamed, rename_err = uv.fs_rename(temp, path)
	if not renamed then
		unlink_regular(temp)
		return nil, "cannot replace state: " .. tostring(rename_err)
	end
	local secured, secure_err = uv.fs_chmod(path, tonumber("600", 8))
	return secured and true or nil, secured and nil or "cannot secure state: " .. tostring(secure_err)
end

local function read_private(path)
	local before = uv.fs_lstat(path)
	if not before then
		return nil, "absent"
	end
	if before.type ~= "file" or before.mode % 512 ~= tonumber("600", 8) or before.size > 256 * 1024 then
		return nil, "unsafe"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "unreadable: " .. tostring(open_err)
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
		return nil, "changed"
	end
	local data = uv.fs_read(fd, opened.size, 0)
	uv.fs_close(fd)
	local after = uv.fs_lstat(path)
	if not data or not after or after.dev ~= opened.dev or after.ino ~= opened.ino or after.size ~= opened.size then
		return nil, "changed"
	end
	return data
end

local function normalize_identity(value)
	local identity, identity_err = contracts.normalize_tool_identity(value)
	if not identity then
		return nil, identity_err
	end
	identity.install_root = vim.fs.normalize(identity.install_root)
	return identity
end

local function identity_json(identity)
	return vim.json.encode({
		backend = identity.backend,
		name = identity.name,
		version = identity.version,
		target = identity.target,
		digest = identity.digest,
		install_root = identity.install_root,
	})
end

local function hash(value)
	if type(configured.hash) == "function" then
		return configured.hash(value)
	end
	return vim.fn.sha256(value)
end

local function identity_key(identity)
	return hash(identity_json(identity))
end

local function destination_key(identity)
	return hash(identity.install_root)
end

local function record_path(identity)
	return vim.fs.joinpath(root(), "records", identity_key(identity) .. ".json")
end

local function lock_path(kind, key)
	return vim.fs.joinpath(root(), "locks", kind, key .. ".lock")
end

local function record_value(identity, status, fields)
	generation = generation + 1
	local value = {
		schema = 1,
		identity = copy(identity),
		identity_key = identity_key(identity),
		status = status,
		generation = generation,
		updated_at = now(),
		pid = pid(),
	}
	for name, item in pairs(fields or {}) do
		if name == "detail" and item ~= nil then
			value[name] = tostring(item):gsub("[%c]", " "):sub(1, 160)
		else
			value[name] = item
		end
	end
	return value
end

local function persist(identity, status, fields)
	assert(STATUSES[status], "invalid verified tool status")
	local ok, err = prepare_state()
	if not ok then
		return nil, err
	end
	local value = record_value(identity, status, fields)
	ok, err = atomic_write(record_path(identity), vim.json.encode(value) .. "\n")
	if not ok then
		return nil, err
	end
	emit("status", value)
	return copy(value)
end

local function decode_record(identity)
	local data, read_err = read_private(record_path(identity))
	if not data then
		return nil, read_err
	end
	local ok, value = pcall(vim.json.decode, data)
	if
		not ok
		or type(value) ~= "table"
		or value.schema ~= 1
		or value.identity_key ~= identity_key(identity)
		or identity_json(value.identity or {}) ~= identity_json(identity)
		or not STATUSES[value.status]
	then
		return nil, "corrupt"
	end
	return copy(value)
end

local function process_alive(owner)
	if type(configured.process_alive) == "function" then
		return configured.process_alive(owner)
	end
	if type(owner) ~= "number" or owner < 1 then
		return nil
	end
	local ok, result, _, code = pcall(uv.kill, owner, 0)
	if not ok then
		return nil
	end
	if result ~= nil then
		return true
	end
	return code == "ESRCH" and false or nil
end

local function create_lock(kind, key, identity)
	local path = lock_path(kind, key)
	local fd, err = uv.fs_open(path, "wx", tonumber("600", 8))
	if not fd then
		local data = read_private(path)
		local decoded = data and pcall(vim.json.decode, data) and vim.json.decode(data) or nil
		local owner_matches = type(decoded) == "table"
			and (
				kind ~= "identity" and type(decoded.identity_key) == "string"
				or decoded.identity_key == identity_key(identity)
			)
		if
			type(decoded) == "table"
			and decoded.schema == 1
			and decoded.key == key
			and owner_matches
			and process_alive(decoded.pid) == false
		then
			unlink_regular(path)
			fd, err = uv.fs_open(path, "wx", tonumber("600", 8))
		end
	end
	if not fd then
		return nil, tostring(err):match("EEXIST") and "locked" or "lock-unavailable"
	end
	local value =
		vim.json.encode({ schema = 1, pid = pid(), key = key, identity_key = identity_key(identity), at = now() })
	local wrote = write_all(fd, value .. "\n")
	local synced = wrote and uv.fs_fsync(fd)
	local closed = uv.fs_close(fd)
	if not wrote or not synced or not closed then
		unlink_regular(path)
		return nil, "lock-write-failed"
	end
	return path
end

local function release_locks(job)
	for _, path in ipairs(job.locks or {}) do
		unlink_regular(path)
	end
	job.locks = {}
end

local function backend_for(identity)
	return configured.backends and configured.backends[identity.backend]
end

local function network_allowed(plan)
	if plan.requires_network == false then
		return true
	end
	if type(configured.network_authorized) == "function" then
		return configured.network_authorized(copy(plan.identity), copy(plan)) == true
	end
	return false
end

function M.setup(opts)
	assert(type(opts) == "table", "verified_tools.setup requires options")
	assert(type(opts.state_root) == "string" or type(opts.state_root) == "function", "state_root is required")
	configured = vim.tbl_extend("force", {}, opts)
	return M
end

function M.identity(value)
	local identity, err = normalize_identity(value)
	if not identity then
		return nil, err
	end
	return copy(identity)
end

function M.shim_bin()
	return vim.fs.joinpath(root(), "shims", "bin")
end

function M.plan(spec)
	local identity, err = normalize_identity(spec and (spec.identity or spec))
	if not identity then
		return nil, err
	end
	local external
	if type(configured.probe_external) == "function" then
		external = configured.probe_external(copy(identity), copy(spec))
	end
	local compatible = type(external) == "table" and external.compatible == true and type(external.path) == "string"
	local shim_path = vim.fs.joinpath(M.shim_bin(), identity.name)
	-- A previous managed shim has PATH precedence. Never report an external
	-- strategy while that shim would still win execution.
	compatible = compatible and uv.fs_lstat(shim_path) == nil
	local plan = {
		identity = identity,
		identity_key = identity_key(identity),
		destination_key = destination_key(identity),
		backend = identity.backend,
		requires_network = spec.requires_network ~= false,
		manifest = copy(spec.manifest or {}),
		external = copy(external),
		strategy = compatible and "external" or "managed",
	}
	if compatible then
		plan.executable = external.path
	else
		plan.shim_path = shim_path
	end
	return copy(plan)
end

function M.probe(spec)
	return M.plan(spec)
end

function M.status(identity)
	if identity then
		local normalized, err = normalize_identity(identity.identity or identity)
		if not normalized then
			return nil, err
		end
		return decode_record(normalized)
	end
	local values = {}
	local directory = vim.fs.joinpath(root(), "records")
	local stat = uv.fs_lstat(directory)
	if not stat then
		return values
	end
	if stat.type ~= "directory" then
		return nil, "unsafe"
	end
	for name in vim.fs.dir(directory) do
		local path = vim.fs.joinpath(directory, name)
		local data = read_private(path)
		if data then
			local ok, value = pcall(vim.json.decode, data)
			local identity = ok and type(value) == "table" and normalize_identity(value.identity) or nil
			if
				identity
				and value.schema == 1
				and STATUSES[value.status]
				and value.identity_key == identity_key(identity)
				and name == value.identity_key .. ".json"
			then
				values[#values + 1] = copy(value)
			end
		end
	end
	table.sort(values, function(left, right)
		return left.identity_key < right.identity_key
	end)
	return values
end

function M.claim(plan, options)
	options = options or {}
	local normalized, err = M.plan(plan)
	if not normalized then
		return nil, err
	end
	if normalized.strategy == "external" then
		return { plan = normalized, external = true, status = "succeeded" }
	end
	if not network_allowed(normalized) then
		return nil, "blocked/offline", copy(vim.tbl_extend("force", normalized, { status = "blocked" }))
	end
	local prepared, prepare_err = prepare_state()
	if not prepared then
		return nil, prepare_err
	end
	local claim_lock, lock_err = create_lock("identity", identity_key(normalized.identity), normalized.identity)
	if not claim_lock then
		return nil, lock_err
	end
	local function release_claim_lock()
		unlink_regular(claim_lock)
	end
	local current, current_reason = decode_record(normalized.identity)
	local mode = options.mode or "auto"
	if current then
		if mode == "auto" then
			release_claim_lock()
			return nil, "consumed"
		end
		local allowed = mode == "repair"
				and vim.tbl_contains({ "failed", "drift", "cancelled", "repair-required" }, current.status)
			or mode == "retry" and current.status == "failed"
		if not allowed then
			release_claim_lock()
			return nil, "repair-required"
		end
	elseif current_reason ~= "absent" then
		release_claim_lock()
		return nil, current_reason
	end
	local attempt = current and (current.attempt or 0) + 1 or 1
	local record, persist_err = persist(normalized.identity, "claimed", {
		attempt = attempt,
		attempt_consumed = true,
		mode = mode,
		plan = normalized,
	})
	if not record then
		release_claim_lock()
		return nil, persist_err
	end
	release_claim_lock()
	return { identity = copy(normalized.identity), plan = normalized, record = record, mode = mode }
end

local function create_shim(job, attestation)
	local path = job.plan.shim_path
	if not path then
		return true
	end
	local target = attestation and attestation.path
	if type(target) ~= "string" or not contained(target, job.identity.install_root) then
		return nil, "attested-path-outside-install-root"
	end
	local target_stat = uv.fs_lstat(target)
	if not target_stat or target_stat.type ~= "file" then
		return nil, "attested-path-invalid"
	end
	local current = uv.fs_lstat(path)
	if current then
		if current.type ~= "link" then
			return nil, "shim-target-unsafe"
		end
		local existing = uv.fs_readlink(path)
		if existing == target then
			return true
		end
	end
	local temp = path .. ".tmp." .. tostring(pid()) .. "." .. tostring(uv.hrtime())
	local linked, link_err = uv.fs_symlink(target, temp)
	if not linked then
		return nil, "shim-create-failed: " .. tostring(link_err)
	end
	local replaced, replace_err = uv.fs_rename(temp, path)
	if not replaced then
		pcall(uv.fs_unlink, temp)
		return nil, "shim-promote-failed: " .. tostring(replace_err)
	end
	return true
end

local function settle(job, ok, reason, attestation)
	if job.settled then
		return
	end
	job.settled = true
	release_locks(job)
	if running[job.key] == job then
		running[job.key] = nil
		running_count = math.max(0, running_count - 1)
	end
	local status = ok and "succeeded" or reason == "cancelled" and "cancelled" or "failed"
	local shim_ok, shim_err
	if ok then
		shim_ok, shim_err = create_shim(job, attestation)
	end
	if ok and not shim_ok then
		status, reason, ok = "failed", shim_err, false
	end
	persist(job.identity, status, {
		attempt = job.claim.record.attempt,
		attempt_consumed = true,
		detail = reason,
		attestation = copy(attestation),
		plan = job.plan,
	})
	if type(job.callback) == "function" then
		job.callback(ok, reason, copy(attestation))
	end
	emit("finished", { identity = job.identity, ok = ok, reason = reason })
	M._drain()
end

local function attest_job(job, callback)
	local backend = backend_for(job.identity)
	if not backend or type(backend.attest) ~= "function" then
		callback(false, "attester-unavailable")
		return
	end
	local called = false
	local function done(ok, value)
		if called then
			return
		end
		called = true
		if
			ok == true
			and (type(value) ~= "table" or value.digest ~= job.identity.digest or type(value.path) ~= "string")
		then
			callback(false, "attestation-identity-mismatch")
			return
		end
		callback(ok == true, value)
	end
	local ok, result, reason = pcall(backend.attest, copy(job.plan), done)
	if not ok then
		done(false, "attest-crashed")
	elseif type(result) == "boolean" then
		done(result, reason)
	end
end

local function start_job(job)
	local identity_lock, identity_err = create_lock("identity", job.key, job.identity)
	if not identity_lock then
		settle(job, false, identity_err)
		return
	end
	local destination_lock, destination_err = create_lock("destination", job.destination_key, job.identity)
	if not destination_lock then
		job.locks = { identity_lock }
		settle(job, false, destination_err)
		return
	end
	local global_lock
	for slot = 1, 2 do
		global_lock = create_lock("global", tostring(slot), job.identity)
		if global_lock then
			break
		end
	end
	if not global_lock then
		job.locks = { identity_lock, destination_lock }
		settle(job, false, "global-capacity")
		return
	end
	job.locks = { identity_lock, destination_lock, global_lock }
	running[job.key] = job
	running_count = running_count + 1
	persist(job.identity, "running", {
		attempt = job.claim.record.attempt,
		attempt_consumed = true,
		plan = job.plan,
	})
	local timeout = tonumber(job.plan.manifest.timeout_ms) or tonumber(configured.watchdog_ms) or 300000
	local defer = configured.defer or vim.defer_fn
	defer(function()
		if not job.settled then
			if type(job.cancel_primitive) == "function" then
				pcall(job.cancel_primitive)
			end
			settle(job, false, "watchdog-timeout")
		end
	end, timeout)
	local backend = backend_for(job.identity)
	if not backend or type(backend.run) ~= "function" then
		settle(job, false, "backend-unavailable")
		return
	end
	local called = false
	local function done(ok, reason)
		if called or job.settled then
			return
		end
		called = true
		if not ok then
			settle(job, false, reason or "backend-failed")
			return
		end
		attest_job(job, function(attested, value)
			settle(job, attested, attested and nil or value or "attestation-failed", attested and value or nil)
		end)
	end
	local ok, result = pcall(backend.run, copy(job.plan), done, {
		set_cancel = function(cancel)
			job.cancel_primitive = cancel
		end,
	})
	if not ok then
		done(false, "backend-crashed")
	elseif type(result) == "boolean" then
		done(result, result and nil or "backend-start-failed")
	end
end

function M._drain()
	local index = 1
	while running_count < 2 and index <= #queue do
		local job = queue[index]
		local destination_busy = false
		for _, active in pairs(running) do
			if active.destination_key == job.destination_key then
				destination_busy = true
				break
			end
		end
		if running[job.key] or destination_busy then
			index = index + 1
		else
			table.remove(queue, index)
			start_job(job)
		end
	end
end

function M.run(claim, callback)
	if type(claim) ~= "table" or type(claim.plan) ~= "table" or claim.external then
		return nil, "invalid claim"
	end
	local key = identity_key(claim.identity)
	for _, pending in ipairs(queue) do
		if pending.key == key then
			return nil, "already-queued"
		end
	end
	if running[key] then
		return nil, "already-running"
	end
	local job = {
		key = key,
		destination_key = destination_key(claim.identity),
		identity = copy(claim.identity),
		plan = copy(claim.plan),
		claim = copy(claim),
		callback = callback,
		locks = {},
	}
	queue[#queue + 1] = job
	persist(job.identity, "queued", {
		attempt = claim.record.attempt,
		attempt_consumed = true,
		plan = job.plan,
	})
	M._drain()
	return copy({ identity = job.identity, status = running[key] and "running" or "queued" })
end

function M.attest(identity, callback)
	if type(identity) ~= "table" then
		return nil, "attestation request must be a ToolIdentity or an envelope"
	end
	local source = identity
	local manifest = {}
	if identity.identity ~= nil then
		for key in pairs(identity) do
			if key ~= "identity" and key ~= "manifest" then
				return nil, "attestation request contains an unknown field: " .. tostring(key)
			end
		end
		source = identity.identity
		manifest = identity.manifest or {}
		if type(manifest) ~= "table" then
			return nil, "attestation manifest must be a table"
		end
	end
	local normalized, err = normalize_identity(source)
	if not normalized then
		return nil, err
	end
	local plan = assert(M.plan({ identity = normalized, manifest = manifest, requires_network = false }))
	local job = { identity = normalized, plan = plan }
	attest_job(job, function(ok, value)
		local current = decode_record(normalized)
		local status = ok and "succeeded" or current and current.status == "succeeded" and "drift" or "failed"
		persist(normalized, status, { attestation = ok and copy(value) or nil, detail = ok and nil or value })
		if callback then
			callback(ok, copy(value))
		end
	end)
	return true
end

function M.retry(spec, callback)
	local plan, err = M.plan(spec)
	if not plan then
		return nil, err
	end
	local claim, claim_err = M.claim(plan, { mode = "retry" })
	if not claim then
		return nil, claim_err
	end
	return M.run(claim, callback)
end

function M.repair(spec, callback)
	local plan, err = M.plan(spec)
	if not plan then
		return nil, err
	end
	local claim, claim_err = M.claim(plan, { mode = "repair" })
	if not claim then
		return nil, claim_err
	end
	return M.run(claim, callback)
end

function M.cancel(identity)
	local normalized, err = normalize_identity(identity.identity or identity)
	if not normalized then
		return nil, err
	end
	local key = identity_key(normalized)
	for index, job in ipairs(queue) do
		if job.key == key then
			table.remove(queue, index)
			persist(job.identity, "cancelled", {
				attempt = job.claim.record.attempt,
				attempt_consumed = true,
				detail = "cancelled",
			})
			if type(job.callback) == "function" then
				job.callback(false, "cancelled")
			end
			emit("finished", { identity = job.identity, ok = false, reason = "cancelled" })
			return true
		end
	end
	local job = running[key]
	if not job then
		return nil, "not-running"
	end
	if type(job.cancel_primitive) == "function" then
		pcall(job.cancel_primitive)
	end
	settle(job, false, "cancelled")
	return true
end

function M.import_legacy(spec, legacy, callback)
	local plan, err = M.plan(spec)
	if not plan then
		return nil, err
	end
	if type(legacy) ~= "table" or legacy.status ~= "succeeded" then
		return persist(plan.identity, "repair-required", {
			legacy = true,
			legacy_status = type(legacy) == "table" and legacy.status or "corrupt",
			detail = "legacy-repair-required",
		})
	end
	return M.attest({ identity = copy(plan.identity), manifest = plan.manifest }, function(ok, value)
		if not ok then
			persist(plan.identity, "repair-required", {
				legacy = true,
				legacy_status = legacy.status,
				detail = "legacy-attestation-failed",
			})
		end
		if callback then
			callback(ok, value)
		end
	end)
end

function M._reset_for_tests()
	queue = {}
	running = {}
	running_count = 0
	generation = 0
	temp_counter = 0
end

function M._queue_size()
	return #queue, running_count
end

return M
