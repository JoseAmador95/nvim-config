local contracts = require("local_plugins.contracts")

local M = {}

local STATE_VERSION = 1
local STATE_FILE = "trusted-workspace.json"
local MAX_STATE_BYTES = 1024 * 1024
local CAPABILITIES = {
	["lint-format"] = true,
	test = true,
	build = true,
	debug = true,
}
local LAYER_RANK = { host = 1, project = 2 }

local state = {
	configured = false,
	state_root = nil,
	mode = "full",
	sources = {},
	appliers = {},
	generation = 0,
	candidate = nil,
	applied = nil,
	pending = {},
	last_known_good = nil,
	persistent = { version = STATE_VERSION, approvals = {}, grants = {} },
	state_error = nil,
	apply_error = nil,
}

local function nonempty_string(value, label)
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, label .. " must be a non-empty string without NUL bytes"
	end
	return value
end

local function copy(value)
	return vim.deepcopy(value)
end

local function blank_snapshot()
	return {
		generation = 0,
		source = "trusted-workspace",
		validity = { valid = true, errors = {}, provenance = {}, pending = {} },
		value = {},
	}
end

local function snapshot_copy(snapshot)
	local normalized, err = contracts.normalize_snapshot(snapshot)
	if not normalized then
		error(err)
	end
	return normalized
end

local function is_list(value)
	if type(value) ~= "table" or next(value) == nil then
		return false
	end
	local count = 0
	local maximum = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count = count + 1
		maximum = math.max(maximum, key)
	end
	return count == maximum
end

local function join_path(prefix, key)
	if prefix == "" then
		return tostring(key)
	end
	return prefix .. "." .. tostring(key)
end

local function merge_into(target, incoming, provenance, source, prefix)
	for key, value in pairs(incoming) do
		local path = join_path(prefix, key)
		if type(value) == "table" and not is_list(value) and next(value) ~= nil then
			if type(target[key]) ~= "table" or is_list(target[key]) then
				target[key] = {}
			end
			merge_into(target[key], value, provenance, source, path)
		else
			target[key] = copy(value)
			provenance[path] = { id = source.id, layer = source.layer }
		end
	end
	return target
end

local function sorted_sources()
	local result = {}
	for _, source in pairs(state.sources) do
		result[#result + 1] = source
	end
	table.sort(result, function(left, right)
		local left_layer = LAYER_RANK[left.layer]
		local right_layer = LAYER_RANK[right.layer]
		if left_layer ~= right_layer then
			return left_layer < right_layer
		end
		if left.priority ~= right.priority then
			return left.priority < right.priority
		end
		return left.id < right.id
	end)
	return result
end

local function approved(source)
	if source.layer == "host" then
		return true
	end
	local by_repo = state.persistent.approvals[source.repo]
	return type(by_repo) == "table" and by_repo[source.id] == source.fingerprint
end

local function source_enabled(source)
	return source.enabled and (source.layer ~= "project" or state.mode == "full")
end

local function merged_sources(include_pending)
	local value = {}
	local provenance = {}
	local errors = {}
	local pending = {}
	for _, source in ipairs(sorted_sources()) do
		if source_enabled(source) then
			vim.list_extend(errors, source.errors)
			local is_approved = approved(source)
			if source.layer == "project" and not is_approved then
				pending[#pending + 1] = {
					id = source.id,
					repo = source.repo,
					fingerprint = source.fingerprint,
				}
			end
			if include_pending or is_approved then
				merge_into(value, source.value, provenance, source, "")
			end
		end
	end
	table.sort(errors)
	table.sort(pending, function(left, right)
		if left.repo ~= right.repo then
			return left.repo < right.repo
		end
		return left.id < right.id
	end)
	return value, provenance, errors, pending
end

local function callback_failure(result, detail, fallback)
	if result == false then
		return detail and tostring(detail) or fallback
	end
	return nil
end

local function ordered_appliers()
	local result = {}
	for _, applier in pairs(state.appliers) do
		result[#result + 1] = applier
	end
	table.sort(result, function(left, right)
		if left.order ~= right.order then
			return left.order < right.order
		end
		return left.id < right.id
	end)
	return result
end

local function apply_transaction(next_snapshot, previous_snapshot, force)
	if not force and vim.deep_equal(next_snapshot.value, previous_snapshot.value) then
		return true
	end

	local prepared = {}
	for _, applier in ipairs(ordered_appliers()) do
		local ok, token, detail = pcall(applier.prepare, snapshot_copy(next_snapshot), snapshot_copy(previous_snapshot))
		if not ok then
			return nil, ("applier %s prepare failed: %s"):format(applier.id, tostring(token))
		end
		local failure = callback_failure(token, detail, "prepare rejected the snapshot")
		if failure then
			return nil, ("applier %s prepare failed: %s"):format(applier.id, failure)
		end
		prepared[#prepared + 1] = { applier = applier, token = token }
	end

	local applied = {}
	for _, item in ipairs(prepared) do
		local ok, result, detail =
			pcall(item.applier.apply, item.token, snapshot_copy(next_snapshot), snapshot_copy(previous_snapshot))
		local failure = not ok and tostring(result) or callback_failure(result, detail, "apply rejected the snapshot")
		if failure then
			local rollback_errors = {}
			for index = #applied, 1, -1 do
				local completed = applied[index]
				local rollback_ok, rollback_result, rollback_detail = pcall(
					completed.applier.rollback,
					completed.token,
					snapshot_copy(next_snapshot),
					snapshot_copy(previous_snapshot)
				)
				local rollback_failure = not rollback_ok and tostring(rollback_result)
					or callback_failure(rollback_result, rollback_detail, "rollback rejected the snapshot")
				if rollback_failure then
					rollback_errors[#rollback_errors + 1] = ("applier %s rollback failed: %s"):format(
						completed.applier.id,
						rollback_failure
					)
				end
			end
			local message = ("applier %s apply failed: %s"):format(item.applier.id, failure)
			if #rollback_errors > 0 then
				message = message .. "; " .. table.concat(rollback_errors, "; ")
			end
			return nil, message
		end
		applied[#applied + 1] = item
	end
	return true
end

local function recompute(force)
	state.generation = state.generation + 1
	local candidate_value, candidate_provenance, errors, pending = merged_sources(true)
	local applied_value, applied_provenance = merged_sources(false)
	local validity = {
		valid = #errors == 0 and #pending == 0,
		errors = copy(errors),
		provenance = candidate_provenance,
		pending = copy(pending),
	}
	local candidate = assert(contracts.normalize_snapshot({
		generation = state.generation,
		source = "trusted-workspace",
		validity = validity,
		value = candidate_value,
	}))
	local next_applied = assert(contracts.normalize_snapshot({
		generation = state.generation,
		source = "trusted-workspace",
		validity = {
			valid = #errors == 0 and #pending == 0,
			errors = copy(errors),
			provenance = applied_provenance,
			pending = copy(pending),
		},
		value = applied_value,
	}))
	local previous = state.applied or blank_snapshot()
	state.candidate = candidate
	state.pending = pending
	if #pending > 0 then
		state.apply_error = nil
		return true
	end
	local ok, err = apply_transaction(next_applied, previous, force)
	if ok then
		state.apply_error = nil
		state.applied = next_applied
		state.last_known_good = snapshot_copy(next_applied)
	else
		state.apply_error = err
	end
	return ok, err
end

local function validate_string_map(value, label, value_validator)
	if type(value) ~= "table" then
		return nil, label .. " must be an object"
	end
	local result = {}
	for key, child in pairs(value) do
		local valid_key, key_err = nonempty_string(key, label .. " key")
		if not valid_key then
			return nil, key_err
		end
		local normalized, err = value_validator(child, label .. "." .. key)
		if not normalized then
			return nil, err
		end
		result[key] = normalized
	end
	return result
end

local function validate_persistent(decoded)
	if type(decoded) ~= "table" then
		return nil, "state must be a JSON object"
	end
	for key in pairs(decoded) do
		if key ~= "version" and key ~= "approvals" and key ~= "grants" then
			return nil, "state contains an unknown field: " .. tostring(key)
		end
	end
	if decoded.version ~= STATE_VERSION then
		return nil, "unsupported state version: " .. tostring(decoded.version)
	end

	local approvals, approvals_err = validate_string_map(
		decoded.approvals or {},
		"approvals",
		function(by_source, label)
			return validate_string_map(by_source, label, function(fingerprint, fingerprint_label)
				return nonempty_string(fingerprint, fingerprint_label)
			end)
		end
	)
	if not approvals then
		return nil, approvals_err
	end
	local grants, grants_err = validate_string_map(decoded.grants or {}, "grants", function(by_capability, label)
		return validate_string_map(by_capability, label, function(enabled, capability_label)
			local capability = capability_label:match("%.([^.]*)$")
			if not CAPABILITIES[capability] or enabled ~= true then
				return nil, capability_label .. " must be an enabled supported capability"
			end
			return true
		end)
	end)
	if not grants then
		return nil, grants_err
	end
	return { version = STATE_VERSION, approvals = approvals, grants = grants }
end

local function lstat(path)
	local info, err = vim.uv.fs_lstat(path)
	if not info and err and not tostring(err):find("ENOENT", 1, true) then
		return nil, err
	end
	return info
end

local function state_path()
	return vim.fs.joinpath(state.state_root, STATE_FILE)
end

local function inspect_root(create)
	local info, err = lstat(state.state_root)
	if err then
		return nil, "could not inspect state root: " .. tostring(err)
	end
	if info then
		if info.type ~= "directory" then
			return nil, "state root must be a real directory (symlinks are rejected)"
		end
		local ok, chmod_err = vim.uv.fs_chmod(state.state_root, 448)
		if not ok then
			return nil, "could not secure state root: " .. tostring(chmod_err)
		end
		return true
	end
	if not create then
		return true
	end
	local parent = vim.fs.dirname(state.state_root)
	local parent_info, parent_err = lstat(parent)
	if parent_err then
		return nil, "could not inspect state parent: " .. tostring(parent_err)
	end
	if not parent_info or parent_info.type ~= "directory" then
		return nil, "state parent must be an existing real directory"
	end
	local ok, mkdir_err = vim.uv.fs_mkdir(state.state_root, 448)
	if not ok then
		return nil, "could not create state root: " .. tostring(mkdir_err)
	end
	return true
end

local function inspect_state_target(path)
	local info, err = lstat(path)
	if err then
		return nil, "could not inspect state file: " .. tostring(err)
	end
	if info and info.type ~= "file" then
		return nil, "state file must be regular (symlinks are rejected)"
	end
	return info or false
end

local function read_state()
	local root_ok, root_err = inspect_root(false)
	if not root_ok then
		return nil, root_err
	end
	local path = state_path()
	local info, target_err = inspect_state_target(path)
	if target_err then
		return nil, target_err
	end
	if not info then
		return { version = STATE_VERSION, approvals = {}, grants = {} }
	end
	if info.size > MAX_STATE_BYTES then
		return nil, "state file exceeds the 1 MiB limit"
	end
	local fd, open_err = vim.uv.fs_open(path, "r", 384)
	if not fd then
		return nil, "could not open state file: " .. tostring(open_err)
	end
	local contents, read_err = vim.uv.fs_read(fd, info.size, 0)
	local close_ok, close_err = vim.uv.fs_close(fd)
	if not contents then
		return nil, "could not read state file: " .. tostring(read_err)
	end
	if not close_ok then
		return nil, "could not close state file: " .. tostring(close_err)
	end
	local chmod_ok, chmod_err = vim.uv.fs_chmod(path, 384)
	if not chmod_ok then
		return nil, "could not secure state file: " .. tostring(chmod_err)
	end
	local decode_ok, decoded = pcall(vim.json.decode, contents)
	if not decode_ok then
		return nil, "state JSON is corrupt: " .. tostring(decoded)
	end
	return validate_persistent(decoded)
end

local function atomic_write(persistent)
	if state.state_error then
		return nil, "state is unavailable: " .. state.state_error
	end
	local root_ok, root_err = inspect_root(true)
	if not root_ok then
		return nil, root_err
	end
	local path = state_path()
	local _, target_err = inspect_state_target(path)
	if target_err then
		return nil, target_err
	end
	local encode_ok, contents = pcall(vim.json.encode, persistent)
	if not encode_ok then
		return nil, "could not encode state: " .. tostring(contents)
	end
	if #contents > MAX_STATE_BYTES then
		return nil, "encoded state exceeds the 1 MiB limit"
	end

	local temporary = path .. (".tmp.%d.%d"):format(vim.uv.os_getpid(), vim.uv.hrtime())
	local fd, open_err = vim.uv.fs_open(temporary, "wx", 384)
	if not fd then
		return nil, "could not create temporary state: " .. tostring(open_err)
	end
	local offset = 0
	while offset < #contents do
		local written, write_err = vim.uv.fs_write(fd, contents:sub(offset + 1), offset)
		if not written then
			vim.uv.fs_close(fd)
			vim.uv.fs_unlink(temporary)
			return nil, "could not write temporary state: " .. tostring(write_err)
		end
		offset = offset + written
	end
	local sync_ok, sync_err = vim.uv.fs_fsync(fd)
	local close_ok, close_err = vim.uv.fs_close(fd)
	if not sync_ok or not close_ok then
		vim.uv.fs_unlink(temporary)
		return nil, "could not flush temporary state: " .. tostring(sync_err or close_err)
	end
	local chmod_ok, chmod_err = vim.uv.fs_chmod(temporary, 384)
	if not chmod_ok then
		vim.uv.fs_unlink(temporary)
		return nil, "could not secure temporary state: " .. tostring(chmod_err)
	end
	local _, recheck_err = inspect_state_target(path)
	if recheck_err then
		vim.uv.fs_unlink(temporary)
		return nil, recheck_err
	end
	local renamed, rename_err = vim.uv.fs_rename(temporary, path)
	if not renamed then
		vim.uv.fs_unlink(temporary)
		return nil, "could not replace state atomically: " .. tostring(rename_err)
	end
	local final_ok, final_err = vim.uv.fs_chmod(path, 384)
	if not final_ok then
		return nil, "could not secure final state: " .. tostring(final_err)
	end
	return true
end

local function project_value(value)
	local result = {}
	local errors = {}
	for key, child in pairs(value) do
		if key == "clangd" then
			if type(child) ~= "table" then
				errors[#errors + 1] = "clangd: project field must be a table (ignored)"
			else
				local clangd = {}
				for clangd_key, clangd_value in pairs(child) do
					if clangd_key == "path" or clangd_key == "profile" then
						if type(clangd_value) == "string" and clangd_value ~= "" then
							clangd[clangd_key] = clangd_value
						else
							errors[#errors + 1] = ("clangd.%s: project field must be a non-empty string (ignored)"):format(
								clangd_key
							)
						end
					else
						errors[#errors + 1] = ("clangd.%s: project field is not allowed (ignored)"):format(
							tostring(clangd_key)
						)
					end
				end
				if next(clangd) then
					result.clangd = clangd
				end
			end
		elseif key == "review" or key == "logs" or key == "log_watch" then
			if type(child) ~= "table" then
				errors[#errors + 1] = ("%s: project field must be a table (ignored)"):format(key)
			else
				local destination = key == "logs" and "log_watch" or key
				if result[destination] then
					errors[#errors + 1] = "logs: duplicate project log settings (ignored)"
				else
					result[destination] = copy(child)
				end
			end
		else
			errors[#errors + 1] = ("%s: project field is not allowed (ignored)"):format(tostring(key))
		end
	end
	table.sort(errors)
	return result, errors
end

local function normalize_source(spec)
	if type(spec) ~= "table" then
		return nil, "source must be a table"
	end
	local id, id_err = nonempty_string(spec.id, "source.id")
	if not id then
		return nil, id_err
	end
	if not LAYER_RANK[spec.layer] then
		return nil, "source.layer must be host or project"
	end
	local priority = spec.priority or 0
	if type(priority) ~= "number" or priority % 1 ~= 0 then
		return nil, "source.priority must be an integer"
	end
	local enabled = spec.enabled ~= false
	if type(spec.value) ~= "table" then
		return nil, "source.value must be a table"
	end
	local value, value_err = contracts.normalize_snapshot({
		generation = 0,
		source = id,
		validity = true,
		value = spec.value,
	})
	if not value then
		return nil, value_err
	end
	local errors = {}
	local normalized_value = value.value
	local repo
	local fingerprint
	if spec.layer == "project" then
		repo, value_err = nonempty_string(spec.repo, "source.repo")
		if not repo then
			return nil, value_err
		end
		fingerprint, value_err = nonempty_string(spec.fingerprint, "source.fingerprint")
		if not fingerprint then
			return nil, value_err
		end
		normalized_value, errors = project_value(normalized_value)
	end
	return {
		id = id,
		layer = spec.layer,
		priority = priority,
		enabled = enabled,
		value = normalized_value,
		repo = repo,
		fingerprint = fingerprint,
		errors = errors,
	}
end

local function normalize_applier(id_or_spec, maybe_spec)
	local spec
	if type(id_or_spec) == "string" then
		spec = copy(maybe_spec or {})
		spec.id = id_or_spec
	else
		spec = id_or_spec
	end
	if type(spec) ~= "table" then
		return nil, "applier must be a table"
	end
	local id, id_err = nonempty_string(spec.id, "applier.id")
	if not id then
		return nil, id_err
	end
	local order = spec.order or 0
	if type(order) ~= "number" or order % 1 ~= 0 then
		return nil, "applier.order must be an integer"
	end
	for _, callback in ipairs({ "prepare", "apply", "rollback" }) do
		if type(spec[callback]) ~= "function" then
			return nil, ("applier.%s must be a function"):format(callback)
		end
	end
	return {
		id = id,
		order = order,
		prepare = spec.prepare,
		apply = spec.apply,
		rollback = spec.rollback,
	}
end

local function approval_args(repo_or_spec, source_id, fingerprint)
	if type(repo_or_spec) == "table" then
		return repo_or_spec.repo, repo_or_spec.source or repo_or_spec.id, repo_or_spec.fingerprint
	end
	return repo_or_spec, source_id, fingerprint
end

local function grant_args(repo_or_spec, capability)
	if type(repo_or_spec) == "table" then
		return repo_or_spec.repo, repo_or_spec.capability
	end
	return repo_or_spec, capability
end

function M.setup(opts)
	opts = opts or {}
	local root, root_err = nonempty_string(opts.state_root, "setup.state_root")
	if not root then
		return nil, root_err
	end
	root = vim.fs.normalize(root)
	if root:sub(1, 1) ~= "/" then
		return nil, "setup.state_root must be absolute"
	end
	local mode = opts.mode or "full"
	if mode ~= "full" and mode ~= "host-only" then
		return nil, "setup.mode must be full or host-only"
	end
	local reset = opts.reset == true or state.state_root ~= root
	if reset then
		state.sources = {}
		state.appliers = {}
		state.generation = 0
		state.candidate = nil
		state.applied = nil
		state.pending = {}
		state.last_known_good = nil
		state.apply_error = nil
	end
	state.state_root = root
	state.mode = mode
	state.configured = true
	local persistent, err = read_state()
	state.state_error = err
	state.persistent = persistent or { version = STATE_VERSION, approvals = {}, grants = {} }
	recompute()
	if err then
		return nil, err
	end
	return true
end

function M.register_source(id_or_spec, maybe_spec)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local spec
	if type(id_or_spec) == "string" then
		spec = copy(maybe_spec or {})
		spec.id = id_or_spec
	else
		spec = id_or_spec
	end
	local source, err = normalize_source(spec)
	if not source then
		return nil, err
	end
	state.sources[source.id] = source
	local ok, apply_err = recompute()
	if not ok then
		return nil, apply_err
	end
	return M.snapshot()
end

function M.snapshot()
	if not state.configured then
		return nil, "setup must be called first"
	end
	return snapshot_copy(state.applied or blank_snapshot())
end

function M.register_applier(id_or_spec, maybe_spec)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local applier, err = normalize_applier(id_or_spec, maybe_spec)
	if not applier then
		return nil, err
	end
	state.appliers[applier.id] = applier
	local ok, apply_err = recompute(true)
	if not ok then
		return nil, apply_err
	end
	return true
end

function M.approve(repo_or_spec, source_id, fingerprint)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local repo, source, expected = approval_args(repo_or_spec, source_id, fingerprint)
	local repo_ok, err = nonempty_string(repo, "approval.repo")
	if not repo_ok then
		return nil, err
	end
	local source_ok
	source_ok, err = nonempty_string(source, "approval.source")
	if not source_ok then
		return nil, err
	end
	local fingerprint_ok
	fingerprint_ok, err = nonempty_string(expected, "approval.fingerprint")
	if not fingerprint_ok then
		return nil, err
	end
	if state.persistent.approvals[repo] and state.persistent.approvals[repo][source] == expected then
		recompute()
		return true
	end
	local persistent = copy(state.persistent)
	persistent.approvals[repo] = persistent.approvals[repo] or {}
	persistent.approvals[repo][source] = expected
	local ok, write_err = atomic_write(persistent)
	if not ok then
		return nil, write_err
	end
	state.persistent = persistent
	local applied, apply_err = recompute()
	if not applied then
		return nil, apply_err
	end
	return true
end

function M.authorize(repo_or_spec, capability)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local repo, requested = grant_args(repo_or_spec, capability)
	local repo_ok, err = nonempty_string(repo, "grant.repo")
	if not repo_ok then
		return nil, err
	end
	if not CAPABILITIES[requested] then
		return nil, "grant.capability must be one of lint-format, test, build, debug"
	end
	if state.persistent.grants[repo] and state.persistent.grants[repo][requested] == true then
		return true
	end
	local persistent = copy(state.persistent)
	persistent.grants[repo] = persistent.grants[repo] or {}
	persistent.grants[repo][requested] = true
	local ok, write_err = atomic_write(persistent)
	if not ok then
		return nil, write_err
	end
	state.persistent = persistent
	return true
end

function M.revoke(repo_or_spec, capability)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local repo, requested = grant_args(repo_or_spec, capability)
	local repo_ok, err = nonempty_string(repo, "grant.repo")
	if not repo_ok then
		return nil, err
	end
	if not CAPABILITIES[requested] then
		return nil, "grant.capability must be one of lint-format, test, build, debug"
	end
	if not state.persistent.grants[repo] or not state.persistent.grants[repo][requested] then
		return true
	end
	local persistent = copy(state.persistent)
	persistent.grants[repo][requested] = nil
	if next(persistent.grants[repo]) == nil then
		persistent.grants[repo] = nil
	end
	local ok, write_err = atomic_write(persistent)
	if not ok then
		return nil, write_err
	end
	state.persistent = persistent
	return true
end

function M.status(repo)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local source_status = {}
	for _, source in ipairs(sorted_sources()) do
		source_status[#source_status + 1] = {
			id = source.id,
			layer = source.layer,
			priority = source.priority,
			enabled = source_enabled(source),
			repo = source.repo,
			fingerprint = source.fingerprint,
			approved = approved(source),
			pending = source_enabled(source) and source.layer == "project" and not approved(source),
			errors = copy(source.errors),
		}
	end
	local mode = "candidate"
	if #state.pending > 0 then
		mode = "pending"
	elseif state.applied then
		mode = "applied"
	end
	local result = {
		mode = mode,
		profile = state.mode,
		generation = state.generation,
		candidate = state.candidate and snapshot_copy(state.candidate) or nil,
		applied = state.applied and snapshot_copy(state.applied) or nil,
		pending = copy(state.pending),
		last_known_good = state.last_known_good and snapshot_copy(state.last_known_good) or nil,
		sources = source_status,
		grants = copy(state.persistent.grants),
		state_error = state.state_error,
		apply_error = state.apply_error,
	}
	if repo ~= nil then
		local repo_ok, err = nonempty_string(repo, "status.repo")
		if not repo_ok then
			return nil, err
		end
		result.repo_grants = copy(state.persistent.grants[repo] or {})
	end
	return result
end

local function append_diff(result, before, after, provenance, prefix)
	if vim.deep_equal(before, after) then
		return
	end
	if type(before) == "table" and type(after) == "table" and not is_list(before) and not is_list(after) then
		local keys = {}
		for key in pairs(before) do
			keys[key] = true
		end
		for key in pairs(after) do
			keys[key] = true
		end
		local ordered = vim.tbl_keys(keys)
		table.sort(ordered, function(left, right)
			return tostring(left) < tostring(right)
		end)
		for _, key in ipairs(ordered) do
			append_diff(result, before[key], after[key], provenance, join_path(prefix, key))
		end
		return
	end
	result[#result + 1] = {
		path = prefix,
		before = copy(before),
		after = copy(after),
		provenance = copy(provenance[prefix]),
	}
end

function M.diff()
	if not state.configured then
		return nil, "setup must be called first"
	end
	local result = {}
	local before = state.applied and state.applied.value or {}
	local after = state.candidate and state.candidate.value or {}
	local provenance = state.candidate and state.candidate.validity.provenance or {}
	append_diff(result, before, after, provenance, "")
	return copy(result)
end

return M
