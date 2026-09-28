local contracts = require("local_plugins.contracts")

local M = {}

local STATE_VERSION = 1
local STATE_FILE = "trusted-workspace.json"
local LOCK_FILE = "trusted-workspace.lock"
local MAX_STATE_BYTES = 1024 * 1024
local MAX_LOCK_BYTES = 4096
local LOCK_WAIT_MILLISECONDS = 2000
local LOCK_POLL_MILLISECONDS = 5
local FILE_MODE = 384 -- 0600
local DIRECTORY_MODE = 448 -- 0700
local CAPABILITIES = {
	["lint-format"] = true,
	test = true,
	build = true,
	debug = true,
}
local LAYER_RANK = { host = 1, project = 2 }
local HOST_SCOPE_KEY = "\0host"

local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	pcall(
		ffi.cdef,
		[[
			int fcntl(int fd, int cmd, ...);
			int openat(int fd, const char *path, int flags, ...);
			int mkdirat(int fd, const char *path, unsigned int mode);
			int linkat(int oldfd, const char *oldpath, int newfd, const char *newpath, int flags);
			int renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int renameatx_np(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			int unlinkat(int fd, const char *path, int flags);
			void *fdopendir(int fd);
			void *readdir(void *dirp);
			int closedir(void *dirp);
		]]
	)
end

local SYSTEM = uv.os_uname().sysname
local DARWIN_F_GETPATH = 50
local DARWIN_PATH_BYTES = 1024
local DIRENT_NAME_OFFSET = SYSTEM == "Darwin" and 21 or 19
local OPEN_FLAGS = SYSTEM == "Darwin"
		and {
			at_fdcwd = -2,
			close_on_exec = 16777216,
			create = 512,
			directory = 1048576,
			exclusive = 2048,
			nonblock = 4,
			no_follow = 256,
			write_only = 1,
			remove_directory = 128,
		}
	or {
		at_fdcwd = -100,
		close_on_exec = 524288,
		create = 64,
		directory = 65536,
		exclusive = 128,
		nonblock = 2048,
		no_follow = 131072,
		write_only = 1,
		remove_directory = 512,
	}

local state = {
	configured = false,
	state_root = nil,
	root_identity = nil,
	mode = "full",
	sources = {},
	scopes = {},
	current_scope = HOST_SCOPE_KEY,
	appliers = {},
	generation = 0,
	candidate = nil,
	applied = nil,
	pending = {},
	last_known_good = nil,
	applied_sources = {},
	persistent = { version = STATE_VERSION, approvals = {}, grants = {} },
	state_error = nil,
	apply_error = nil,
	on_state_change = nil,
}
local test_hook
local run_test_hook

local function append_warning(current, warning)
	if not warning or warning == "" then
		return current
	end
	if not current or current == "" then
		return tostring(warning)
	end
	return tostring(current) .. "; " .. tostring(warning)
end

local function nonempty_string(value, label)
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, label .. " must be a non-empty string without NUL bytes"
	end
	return value
end

local function copy(value)
	return vim.deepcopy(value)
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

local function workspace_identity(workspace)
	if not workspace then
		return HOST_SCOPE_KEY
	end
	return table.concat({ workspace.runtime, workspace.root, workspace.repo_identity }, "\0")
end

local function normalize_workspace(value, label)
	local normalized, err = contracts.normalize_workspace_key(value)
	if not normalized then
		return nil, (label or "workspace") .. ": " .. tostring(err)
	end
	normalized.root = vim.fs.normalize(normalized.root)
	return normalized
end

local function legacy_workspace(repo)
	return { runtime = "host", root = repo, repo_identity = repo }
end

local function new_scope(workspace)
	return {
		workspace = workspace and copy(workspace) or nil,
		sources = {},
		generation = 0,
		candidate = nil,
		applied = nil,
		pending = {},
		last_known_good = nil,
		applied_sources = {},
		apply_error = nil,
	}
end

local function scope_for(workspace, create)
	local key = workspace_identity(workspace)
	local scope = state.scopes[key]
	if not scope and create then
		scope = new_scope(workspace)
		state.scopes[key] = scope
	end
	return scope, key
end

local function host_scope()
	return scope_for(nil, true)
end

local function emit(kind, details)
	if type(state.on_state_change) ~= "function" then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	pcall(state.on_state_change, event)
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
			local reduces_host_limit = source.layer == "project"
				and (path == "plugins.log_workbench.max_lines" or path == "plugins.log_workbench.max_bytes")
				and type(target[key]) == "number"
				and type(value) == "number"
				and value > target[key]
			if not reduces_host_limit then
				target[key] = copy(value)
				provenance[path] = { id = source.id, layer = source.layer }
			end
		end
	end
	return target
end

local function sorted_sources(scope)
	local result = {}
	for _, source in pairs(state.sources) do
		result[#result + 1] = source
	end
	for _, source in pairs((scope and scope.sources) or {}) do
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

local function sorted_source_values(values)
	local result = vim.tbl_values(values)
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

local function merged_sources(scope, include_pending)
	local value = {}
	local provenance = {}
	local errors = {}
	local pending = {}
	for _, source in ipairs(sorted_sources(scope)) do
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

local function effective_sources(scope)
	local result = {}
	for _, source in ipairs(sorted_sources(scope)) do
		if source_enabled(source) then
			if approved(source) then
				result[source.id] = source
			elseif source.layer == "project" then
				local previous = scope.applied_sources[source.id]
				local approvals = previous and state.persistent.approvals[previous.repo] or nil
				if
					previous
					and previous.repo == source.repo
					and type(approvals) == "table"
					and approvals[previous.id] == previous.fingerprint
				then
					result[source.id] = previous
				end
			end
		end
	end
	return result
end

local function merged_effective_sources(sources)
	local value = {}
	local provenance = {}
	local errors = {}
	for _, source in ipairs(sorted_source_values(sources)) do
		vim.list_extend(errors, source.errors)
		merge_into(value, source.value, provenance, source, "")
	end
	table.sort(errors)
	return value, provenance, errors
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

local function plan_scope_recompute(scope)
	local generation = scope.generation + 1
	local candidate_value, candidate_provenance, errors, pending = merged_sources(scope, true)
	local next_sources = effective_sources(scope)
	local applied_value, applied_provenance, applied_errors = merged_effective_sources(next_sources)
	local validity = {
		valid = #errors == 0 and #pending == 0,
		errors = copy(errors),
		provenance = candidate_provenance,
		pending = copy(pending),
	}
	local candidate = assert(contracts.normalize_snapshot({
		generation = generation,
		source = "trusted-workspace",
		validity = validity,
		value = candidate_value,
	}))
	local next_applied = assert(contracts.normalize_snapshot({
		generation = generation,
		source = "trusted-workspace",
		validity = {
			valid = #applied_errors == 0,
			errors = copy(applied_errors),
			provenance = applied_provenance,
			pending = {},
		},
		value = applied_value,
	}))
	local previous = scope.applied or blank_snapshot()
	return {
		scope = scope,
		generation = generation,
		candidate = candidate,
		pending = pending,
		next_applied = next_applied,
		previous = previous,
		next_sources = next_sources,
	}
end

local function publish_scope_recompute(plan, ok, err)
	local scope = plan.scope
	scope.generation = plan.generation
	scope.candidate = plan.candidate
	scope.pending = plan.pending
	if ok then
		scope.apply_error = nil
		scope.applied = plan.next_applied
		scope.applied_sources = copy(plan.next_sources)
		if #plan.pending == 0 then
			scope.last_known_good = snapshot_copy(plan.next_applied)
		end
	else
		scope.apply_error = err
	end
	emit("scope", {
		workspace = scope.workspace,
		generation = plan.generation,
		pending = plan.pending,
		applied = ok == true,
		error = err,
	})
	return ok, err
end

local function recompute_scope(scope, force)
	local plan = plan_scope_recompute(scope)
	local ok, err = apply_transaction(plan.next_applied, plan.previous, force)
	publish_scope_recompute(plan, ok, err)
	return ok, err
end

local function apply_scope_plans(plans, force)
	local prepared = {}
	for _, plan in ipairs(plans) do
		if force or not vim.deep_equal(plan.next_applied.value, plan.previous.value) then
			for _, applier in ipairs(ordered_appliers()) do
				local ok, token, detail =
					pcall(applier.prepare, snapshot_copy(plan.next_applied), snapshot_copy(plan.previous))
				if not ok then
					return nil, ("applier %s prepare failed: %s"):format(applier.id, tostring(token))
				end
				local failure = callback_failure(token, detail, "prepare rejected the snapshot")
				if failure then
					return nil, ("applier %s prepare failed: %s"):format(applier.id, failure)
				end
				prepared[#prepared + 1] = { applier = applier, token = token, plan = plan }
			end
		end
	end

	local applied = {}
	for _, item in ipairs(prepared) do
		local ok, result, detail = pcall(
			item.applier.apply,
			item.token,
			snapshot_copy(item.plan.next_applied),
			snapshot_copy(item.plan.previous)
		)
		local failure = not ok and tostring(result) or callback_failure(result, detail, "apply rejected the snapshot")
		if failure then
			local rollback_errors = {}
			for index = #applied, 1, -1 do
				local completed = applied[index]
				local rollback_ok, rollback_result, rollback_detail = pcall(
					completed.applier.rollback,
					completed.token,
					snapshot_copy(completed.plan.next_applied),
					snapshot_copy(completed.plan.previous)
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

local function recompute_all(force)
	local keys = vim.tbl_keys(state.scopes)
	table.sort(keys)
	local plans = {}
	for _, key in ipairs(keys) do
		plans[#plans + 1] = plan_scope_recompute(state.scopes[key])
	end
	local ok, err = apply_scope_plans(plans, force)
	if not ok then
		for _, plan in ipairs(plans) do
			publish_scope_recompute(plan, false, err)
		end
		return nil, err
	end
	for _, plan in ipairs(plans) do
		publish_scope_recompute(plan, true)
	end
	return true
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
	local info, err = uv.fs_lstat(path)
	if not info and err and not tostring(err):find("ENOENT", 1, true) then
		return nil, err
	end
	return info
end

local function same_identity(left, right)
	return left and right and left.dev == right.dev and left.ino == right.ino
end

local function same_object(left, right, kind)
	return left and right and left.type == kind and right.type == kind and same_identity(left, right)
end

local function same_time(left, right)
	left = left or {}
	right = right or {}
	return left.sec == right.sec and left.nsec == right.nsec
end

local function same_entry_after_rename(left, right)
	return left
		and right
		and left.type == right.type
		and same_identity(left, right)
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and same_time(left.mtime, right.mtime)
end

local function same_read_snapshot(left, right)
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and same_identity(left, right)
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and same_time(left.mtime, right.mtime)
		and same_time(left.ctime, right.ctime)
end

local function same_directory_snapshot(left, right)
	return left
		and right
		and left.type == "directory"
		and right.type == "directory"
		and same_identity(left, right)
		and left.size == right.size
		and left.mode == right.mode
		and left.nlink == right.nlink
		and same_time(left.mtime, right.mtime)
		and same_time(left.ctime, right.ctime)
end

local function state_path()
	return vim.fs.joinpath(state.state_root, STATE_FILE)
end

local function lock_path()
	return vim.fs.joinpath(state.state_root, LOCK_FILE)
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
	return type(path) == "string" and vim.fs.normalize(path) == vim.fs.normalize(expected)
end

local function close_anchor(anchor)
	if not anchor or anchor.fd == nil then
		return true
	end
	local fd = anchor.fd
	anchor.fd = nil
	return uv.fs_close(fd)
end

local function directory_anchor_valid(anchor, logical_path)
	if not anchor or anchor.fd == nil then
		return false
	end
	local opened = uv.fs_fstat(anchor.fd)
	if not same_object(opened, anchor.identity, "directory") or not descriptor_is_bound(anchor.fd, anchor.path) then
		return false
	end
	if logical_path then
		local current = lstat(logical_path)
		if not same_object(opened, current, "directory") then
			return false
		end
	end
	return true
end

local function sync_directory(directory, operation)
	if not directory_anchor_valid(directory) then
		return nil, operation .. " directory changed before fsync"
	end
	local hook_ok, hook_err = run_test_hook("directory_fsync", {
		operation = operation,
		path = directory.path,
		committed = true,
	})
	if not hook_ok then
		return nil, operation .. " directory fsync hook failed: " .. tostring(hook_err)
	end
	local synced, sync_err = uv.fs_fsync(directory.fd)
	if not synced then
		return nil, operation .. " directory fsync failed: " .. tostring(sync_err)
	end
	if not directory_anchor_valid(directory) then
		return nil, operation .. " directory changed after fsync"
	end
	return true
end

local function sync_rename_directories(source_directory, destination_directory, operation)
	local warning
	local _, source_err = sync_directory(source_directory, operation .. " source")
	warning = append_warning(warning, source_err)
	if not same_identity(source_directory.identity, destination_directory.identity) then
		local _, destination_err = sync_directory(destination_directory, operation .. " destination")
		warning = append_warning(warning, destination_err)
	end
	return warning == nil, warning
end

local function openat_file(parent_fd, name, flags, mode)
	if not ffi_ready() then
		return nil, "descriptor-relative filesystem operations are unavailable"
	end
	-- Lua numbers are passed as doubles through C varargs. Box mode_t as an
	-- integer so openat never decodes the variadic argument with the wrong ABI.
	local raw_fd = ffi.C.openat(parent_fd, name, flags, ffi.new("unsigned int", mode or 0))
	if raw_fd < 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return tonumber(raw_fd)
end

local function open_directory(path, secure)
	local before, before_err = lstat(path)
	if before_err then
		return nil, "could not inspect state directory: " .. tostring(before_err)
	end
	if not before or before.type ~= "directory" then
		return nil, "state root must be a real directory (symlinks are rejected)"
	end
	if not ffi_ready() then
		return nil, "descriptor-relative filesystem operations are unavailable"
	end
	local expected, resolve_err = uv.fs_realpath(path)
	if not expected then
		return nil, "could not resolve state directory: " .. tostring(resolve_err)
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.close_on_exec
	local fd, open_err = openat_file(OPEN_FLAGS.at_fdcwd, path, flags, 0)
	if not fd then
		return nil, "could not open state directory: " .. tostring(open_err)
	end
	local opened, inspect_err = uv.fs_fstat(fd)
	if not same_object(before, opened, "directory") or not descriptor_is_bound(fd, expected) then
		uv.fs_close(fd)
		return nil, "state root changed while it was opened: " .. tostring(inspect_err or "identity mismatch")
	end
	local secured, secure_err = not secure or uv.fs_fchmod(fd, DIRECTORY_MODE)
	local after, after_err = lstat(path)
	if not secured then
		uv.fs_close(fd)
		return nil, "could not secure state root: " .. tostring(secure_err)
	end
	local completed = uv.fs_fstat(fd)
	if
		not same_object(opened, completed, "directory")
		or not same_object(completed, after, "directory")
		or not descriptor_is_bound(fd, expected)
	then
		uv.fs_close(fd)
		return nil, "state root changed while it was secured: " .. tostring(after_err or "identity mismatch")
	end
	return { fd = fd, path = expected, identity = completed }
end

local function open_directory_at(parent, name, secure)
	if not directory_anchor_valid(parent) then
		return nil, "state parent changed before the state root was opened"
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.close_on_exec
	local fd, open_err = openat_file(parent.fd, name, flags, 0)
	if not fd then
		return nil, "could not open state root relative to its parent: " .. tostring(open_err)
	end
	local expected = vim.fs.joinpath(parent.path, name)
	local opened, inspect_err = uv.fs_fstat(fd)
	if not opened or opened.type ~= "directory" or not descriptor_is_bound(fd, expected) then
		uv.fs_close(fd)
		return nil, "state root changed while it was opened: " .. tostring(inspect_err or "identity mismatch")
	end
	local secured, secure_err = not secure or uv.fs_fchmod(fd, DIRECTORY_MODE)
	local completed = uv.fs_fstat(fd)
	if
		not secured
		or not same_object(opened, completed, "directory")
		or not descriptor_is_bound(fd, expected)
		or not directory_anchor_valid(parent)
	then
		uv.fs_close(fd)
		return nil, "could not secure state root: " .. tostring(secure_err or "identity mismatch")
	end
	return { fd = fd, path = expected, identity = completed }
end

local function list_directory_entries(directory)
	if not ffi_ready() or not ffi.abi("64bit") then
		return nil, "descriptor-relative directory enumeration is unavailable"
	end
	local flags = OPEN_FLAGS.directory + OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.close_on_exec
	local fd, open_err = openat_file(directory.fd, ".", flags, 0)
	if not fd then
		return nil, "could not open pinned state directory for enumeration: " .. tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	if not same_object(opened, directory.identity, "directory") then
		uv.fs_close(fd)
		return nil, "pinned state directory changed before enumeration"
	end
	local stream = ffi.C.fdopendir(fd)
	if stream == ffi.NULL then
		local errno = ffi.errno()
		uv.fs_close(fd)
		return nil, "could not enumerate pinned state directory: errno " .. tostring(errno)
	end
	local names = {}
	local read_errno = 0
	while true do
		ffi.errno(0)
		local entry = ffi.C.readdir(stream)
		if entry == ffi.NULL then
			read_errno = ffi.errno()
			break
		end
		local name = ffi.string(ffi.cast("char *", entry) + DIRENT_NAME_OFFSET)
		if name ~= "." and name ~= ".." then
			names[#names + 1] = name
		end
	end
	local closed = ffi.C.closedir(stream)
	if read_errno ~= 0 then
		return nil, "could not read pinned state directory: errno " .. tostring(read_errno)
	end
	if closed ~= 0 then
		return nil, "could not close pinned state directory: errno " .. tostring(ffi.errno())
	end
	table.sort(names)
	return names
end

local function inspect_root(create)
	local info, err = lstat(state.state_root)
	if err then
		return nil, "could not inspect state root: " .. tostring(err)
	end
	if info then
		local anchor, open_err = open_directory(state.state_root, true)
		if not anchor then
			return nil, open_err
		end
		if state.root_identity and not same_identity(anchor.identity, state.root_identity) then
			close_anchor(anchor)
			return nil, "state root identity changed"
		end
		state.root_identity = state.root_identity or { dev = anchor.identity.dev, ino = anchor.identity.ino }
		return anchor
	end
	if state.root_identity then
		return nil, "state root was removed after setup"
	end
	if not create then
		return false
	end
	local parent = vim.fs.dirname(state.state_root)
	local parent_info, parent_err = lstat(parent)
	if parent_err then
		return nil, "could not inspect state parent: " .. tostring(parent_err)
	end
	if not parent_info or parent_info.type ~= "directory" then
		return nil, "state parent must be an existing real directory"
	end
	local parent_anchor, open_err = open_directory(parent, false)
	if not parent_anchor then
		return nil, "could not pin state parent: " .. tostring(open_err)
	end
	local basename = vim.fs.basename(state.state_root)
	local created = ffi.C.mkdirat(parent_anchor.fd, basename, DIRECTORY_MODE)
	local create_errno = ffi.errno()
	if created ~= 0 and create_errno ~= 17 then
		close_anchor(parent_anchor)
		return nil, "could not create state root: errno " .. tostring(create_errno)
	end
	local creation_warning
	if created == 0 then
		local _, sync_err = sync_directory(parent_anchor, "state root mkdir")
		creation_warning = append_warning(creation_warning, sync_err)
	end
	local anchor, root_err = open_directory_at(parent_anchor, basename, true)
	local parent_closed, close_err = close_anchor(parent_anchor)
	if not anchor then
		return nil, root_err
	end
	if not parent_closed then
		if created == 0 then
			creation_warning =
				append_warning(creation_warning, "could not close state parent after mkdir: " .. tostring(close_err))
		else
			close_anchor(anchor)
			return nil, "could not close state parent: " .. tostring(close_err)
		end
	end
	local current = lstat(state.state_root)
	if not same_object(anchor.identity, current, "directory") or not descriptor_is_bound(anchor.fd, anchor.path) then
		close_anchor(anchor)
		return nil, "state root changed while it was created"
	end
	state.root_identity = { dev = anchor.identity.dev, ino = anchor.identity.ino }
	anchor.warning = creation_warning
	return anchor
end

local function inspect_root_observational()
	local info, err = lstat(state.state_root)
	if err then
		return nil, "could not inspect state root: " .. tostring(err)
	end
	if not info then
		if state.root_identity then
			return nil, "state root was removed after setup"
		end
		return false
	end
	local anchor, open_err = open_directory(state.state_root, false)
	if not anchor then
		return nil, open_err
	end
	if anchor.identity.mode % 512 ~= DIRECTORY_MODE then
		close_anchor(anchor)
		return nil, "state root permissions must already be 0700"
	end
	if state.root_identity and not same_identity(anchor.identity, state.root_identity) then
		close_anchor(anchor)
		return nil, "state root identity changed"
	end
	return anchor
end

local function entry_name(name)
	if type(name) ~= "string" or name == "" or name == "." or name == ".." or name:find("/", 1, true) then
		return nil, "filesystem entry name is invalid"
	end
	return name
end

local function open_entry_optional(directory, name, label, maximum, link_count)
	local valid, valid_err = entry_name(name)
	if not valid then
		return nil, valid_err
	end
	if not directory_anchor_valid(directory) then
		return nil, "state root changed before " .. label .. " was opened"
	end
	local flags = OPEN_FLAGS.nonblock + OPEN_FLAGS.no_follow + OPEN_FLAGS.close_on_exec
	local fd, open_err, errno = openat_file(directory.fd, name, flags, 0)
	if not fd and errno == 2 then
		return false
	end
	if not fd then
		return nil,
			label
				.. " must be a single-link regular file (symlinks are rejected; hard links are rejected): "
				.. tostring(open_err)
	end
	local opened, inspect_err = uv.fs_fstat(fd)
	local expected = vim.fs.joinpath(directory.path, name)
	link_count = link_count or 1
	if
		not opened
		or opened.type ~= "file"
		or opened.nlink ~= link_count
		or (maximum and opened.size > maximum)
		or (link_count == 1 and not descriptor_is_bound(fd, expected))
	then
		uv.fs_close(fd)
		return nil,
			label
				.. " must be a bounded single-link regular file (symlinks are rejected; hard links are rejected): "
				.. tostring(inspect_err or "identity mismatch")
	end
	return fd, opened
end

local function write_all(fd, contents)
	local offset = 0
	while offset < #contents do
		local written, write_err = vim.uv.fs_write(fd, contents:sub(offset + 1), offset)
		if not written or written <= 0 then
			return nil, write_err or "short write"
		end
		offset = offset + written
	end
	return true
end

local function entry_snapshot(directory, name, label, maximum, link_count)
	local fd, opened_or_err = open_entry_optional(directory, name, label, maximum, link_count)
	if fd == false then
		return false
	end
	if not fd then
		return nil, opened_or_err
	end
	local closed, close_err = uv.fs_close(fd)
	if not closed then
		return nil, "could not close " .. label .. ": " .. tostring(close_err)
	end
	return opened_or_err
end

local function any_entry_snapshot(directory, name, label)
	local valid, valid_err = entry_name(name)
	if not valid then
		return nil, valid_err
	end
	if not directory_anchor_valid(directory) then
		return nil, "state root changed before " .. label .. " was inspected"
	end
	local current, current_err = lstat(vim.fs.joinpath(directory.path, name))
	if current_err then
		return nil, "could not inspect " .. label .. ": " .. tostring(current_err)
	end
	if not directory_anchor_valid(directory) then
		return nil, "state root changed while " .. label .. " was inspected"
	end
	return current or false
end

local function inspect_state_target(directory, name, label)
	return entry_snapshot(directory, name or STATE_FILE, label or "state file", MAX_STATE_BYTES)
end

local function read_verified_file(directory, name, label, maximum, link_count, options)
	options = options or {}
	local before, inspect_err = entry_snapshot(directory, name, label, maximum, link_count)
	if before == false then
		return nil, "missing"
	end
	if not before then
		return nil, inspect_err
	end
	local fd, opened_or_err = open_entry_optional(directory, name, label, maximum, link_count)
	if not fd then
		return nil, opened_or_err
	end
	local opened = opened_or_err
	if
		(options.repair_permissions == false and not same_read_snapshot(before, opened))
		or (options.repair_permissions ~= false and (not same_identity(before, opened) or before.size ~= opened.size))
	then
		uv.fs_close(fd)
		return nil, label .. " changed or became unsafe while it was opened: identity mismatch"
	end
	local secured, secure_err
	local read_snapshot = opened
	if options.repair_permissions == false then
		secured = opened.mode % 512 == FILE_MODE
		if not secured then
			secure_err = "permissions must already be 0600"
		end
	else
		secured, secure_err = uv.fs_fchmod(fd, FILE_MODE)
		read_snapshot = secured and uv.fs_fstat(fd) or nil
		secured = secured
			and read_snapshot ~= nil
			and same_identity(opened, read_snapshot)
			and opened.size == read_snapshot.size
			and read_snapshot.mode % 512 == FILE_MODE
	end
	local contents, read_err = secured and uv.fs_read(fd, read_snapshot.size, 0) or nil
	local after, after_err = entry_snapshot(directory, name, label, maximum, link_count)
	local closed, close_err = uv.fs_close(fd)
	if not secured then
		local action = options.repair_permissions == false and "use " or "secure "
		return nil, "could not " .. action .. label .. ": " .. tostring(secure_err)
	end
	if not contents or #contents ~= read_snapshot.size then
		return nil, "could not read complete " .. label .. ": " .. tostring(read_err or "short read")
	end
	if not after or not same_read_snapshot(read_snapshot, after) then
		return nil, label .. " changed while it was read: " .. tostring(after_err or "identity mismatch")
	end
	if not closed then
		return nil, "could not close " .. label .. ": " .. tostring(close_err)
	end
	return contents, nil, after
end

local function read_state(anchor, options)
	options = options or {}
	local owned = false
	if not anchor then
		local root, root_err
		if options.observational == true then
			root, root_err = inspect_root_observational()
		else
			root, root_err = inspect_root(false)
		end
		if root == false then
			return { version = STATE_VERSION, approvals = {}, grants = {} }, nil, { exists = false }
		end
		if not root then
			return nil, root_err
		end
		anchor = root
		owned = true
	end
	local contents, read_err, file_stat = read_verified_file(
		anchor,
		STATE_FILE,
		"state file",
		MAX_STATE_BYTES,
		nil,
		{ repair_permissions = options.observational ~= true }
	)
	local function finish(persistent, finish_err, snapshot)
		if options.observational == true and not finish_err then
			local current = anchor and anchor.fd and uv.fs_fstat(anchor.fd) or nil
			if
				not same_directory_snapshot(anchor.identity, current)
				or not directory_anchor_valid(anchor, state.state_root)
			then
				persistent = nil
				finish_err = "state root changed or became unsafe while state was read"
			end
		end
		if owned then
			local closed, close_err = close_anchor(anchor)
			if not closed and not finish_err then
				return nil, "could not close state root: " .. tostring(close_err)
			end
		end
		return persistent, finish_err, snapshot
	end
	if not contents and read_err == "missing" then
		return finish({ version = STATE_VERSION, approvals = {}, grants = {} }, nil, { exists = false })
	end
	if not contents then
		return finish(nil, read_err)
	end
	local decode_ok, decoded = pcall(vim.json.decode, contents)
	if not decode_ok then
		return finish(nil, "state JSON is corrupt: " .. tostring(decoded))
	end
	local persistent, validation_err = validate_persistent(decoded)
	if not persistent then
		return finish(nil, validation_err)
	end
	return finish(persistent, nil, { exists = true, data = contents, stat = file_stat })
end

local function unlinkat_entry(directory, name)
	if ffi.C.unlinkat(directory.fd, name, 0) ~= 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	local _, warning = sync_directory(directory, "unlink " .. name)
	return true, warning
end

local function remove_directory_entry(directory, name)
	if ffi.C.unlinkat(directory.fd, name, OPEN_FLAGS.remove_directory) ~= 0 then
		return nil, "errno " .. tostring(ffi.errno())
	end
	local _, warning = sync_directory(directory, "remove directory " .. name)
	return true, warning
end

local function linkat_entry(source_directory, source, destination_directory, destination)
	if ffi.C.linkat(source_directory.fd, source, destination_directory.fd, destination, 0) ~= 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	return true
end

local function renameat_noreplace(source_directory, source, destination_directory, destination)
	if not ffi_ready() then
		return nil, "descriptor-relative no-clobber rename is unavailable"
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(source_directory.fd, source, destination_directory.fd, destination, 4)
		end
		return ffi.C.renameat2(source_directory.fd, source, destination_directory.fd, destination, 1)
	end)
	if not ok then
		return nil, "no-clobber rename is unavailable: " .. tostring(result)
	end
	if result ~= 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	local _, warning = sync_rename_directories(
		source_directory,
		destination_directory,
		("rename %s to %s"):format(source, destination)
	)
	return true, warning
end

local function renameat_exchange(left_directory, left, right_directory, right)
	if not ffi_ready() then
		return nil, "descriptor-relative exchange rename is unavailable"
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(left_directory.fd, left, right_directory.fd, right, 2)
		end
		return ffi.C.renameat2(left_directory.fd, left, right_directory.fd, right, 2)
	end)
	if not ok then
		return nil, "exchange rename is unavailable: " .. tostring(result)
	end
	if result ~= 0 then
		local errno = ffi.errno()
		return nil, "errno " .. tostring(errno), errno
	end
	local _, warning =
		sync_rename_directories(left_directory, right_directory, ("exchange %s with %s"):format(left, right))
	return true, warning
end

local function create_private_directory(root, prefix)
	for attempt = 1, 8 do
		local name = ("%s.%d.%d.%d"):format(prefix, uv.os_getpid(), uv.hrtime(), attempt)
		if ffi.C.mkdirat(root.fd, name, DIRECTORY_MODE) == 0 then
			local _, mkdir_warning = sync_directory(root, "private quarantine mkdir " .. name)
			local anchor, open_err = open_directory_at(root, name, true)
			if anchor then
				return name, anchor, mkdir_warning
			end
			-- Without an anchored descriptor we cannot prove that the visible
			-- directory is still the one mkdirat created. Preserve it for manual
			-- inspection instead of deleting a possible replacement by name.
			return nil,
				tostring(open_err) .. "; unverified private directory was preserved at " .. vim.fs.joinpath(
					root.path,
					name
				) .. (mkdir_warning and "; " .. tostring(mkdir_warning) or "")
		end
		local errno = ffi.errno()
		if errno ~= 17 then
			return nil, "errno " .. tostring(errno)
		end
	end
	return nil, "private quarantine namespace is exhausted"
end

run_test_hook = function(phase, details)
	if not test_hook then
		return true
	end
	local ok, err = pcall(test_hook, phase, copy(details or {}))
	return ok and true or nil, ok and nil or tostring(err)
end

local function snapshot_matches(actual, expected)
	return type(actual) == "table"
		and type(expected) == "table"
		and type(actual.data) == "string"
		and type(expected.data) == "string"
		and actual.data == expected.data
		and same_identity(actual.stat, expected.stat)
end

local function read_file_snapshot(directory, name, label, maximum, link_count)
	local contents, read_err, file_stat = read_verified_file(directory, name, label, maximum, link_count)
	if not contents then
		return nil, read_err
	end
	return { data = contents, stat = file_stat }
end

local function read_any_snapshot(directory, name, label)
	local stat, stat_err = any_entry_snapshot(directory, name, label)
	if not stat then
		return nil, stat_err or "missing"
	end
	return { stat = stat }
end

local function capture_snapshot_like(directory, name, label, expected)
	if type(expected) == "table" and type(expected.data) == "string" then
		return read_file_snapshot(directory, name, label, MAX_STATE_BYTES)
	end
	return read_any_snapshot(directory, name, label)
end

local function snapshot_matches_after_rename(actual, expected)
	if type(actual) ~= "table" or type(expected) ~= "table" then
		return false
	end
	if type(actual.data) == "string" or type(expected.data) == "string" then
		return type(actual.data) == "string"
			and type(expected.data) == "string"
			and actual.data == expected.data
			and same_identity(actual.stat, expected.stat)
	end
	return same_entry_after_rename(actual.stat, expected.stat)
end

local function restore_reserved_entry(directory, name, reserved, label, detail)
	local restored, restore_warning_or_err = renameat_noreplace(directory, reserved, directory, name)
	if restored then
		return nil,
			detail
				.. "; replacement was restored without clobbering it"
				.. (restore_warning_or_err and "; " .. tostring(restore_warning_or_err) or "")
	end
	return nil,
		detail .. "; reserved replacement remains at " .. vim.fs.joinpath(directory.path, reserved) .. ": " .. tostring(
			restore_warning_or_err or label
		)
end

local function conditional_remove_entry(directory, name, expected, label, maximum, missing_ok)
	if type(expected) ~= "table" or type(expected.data) ~= "string" or type(expected.stat) ~= "table" then
		return nil, label .. " removal requires an exact snapshot"
	end
	local reserved
	local warning
	for attempt = 1, 8 do
		local candidate = ("%s.delete.%d.%d.%d"):format(name, uv.os_getpid(), uv.hrtime(), attempt)
		local moved, move_warning_or_err, move_errno = renameat_noreplace(directory, name, directory, candidate)
		if moved then
			reserved = candidate
			warning = append_warning(warning, move_warning_or_err)
			break
		end
		if move_errno == 2 then
			return missing_ok and true or nil,
				missing_ok and nil or (label .. " disappeared before conditional removal")
		end
		if move_errno ~= 17 then
			return nil, "could not reserve " .. label .. " for conditional removal: " .. tostring(move_warning_or_err)
		end
	end
	if not reserved then
		return nil, label .. " removal reservation namespace is exhausted"
	end
	local link_count = expected.stat.nlink or 1
	local moved_snapshot, moved_err = read_file_snapshot(directory, reserved, label, maximum, link_count)
	if not moved_snapshot or not snapshot_matches(moved_snapshot, expected) then
		return restore_reserved_entry(
			directory,
			name,
			reserved,
			label,
			append_warning(
				label .. " changed before conditional removal: " .. tostring(moved_err or "snapshot mismatch"),
				warning
			)
		)
	end
	local hook_ok, hook_err = run_test_hook("entry_reserved_before_remove", {
		path = vim.fs.joinpath(directory.path, name),
		reserved_path = vim.fs.joinpath(directory.path, reserved),
		label = label,
	})
	local final_snapshot, final_err = read_file_snapshot(directory, reserved, label, maximum, link_count)
	if not hook_ok or not final_snapshot or not snapshot_matches(final_snapshot, expected) then
		return restore_reserved_entry(
			directory,
			name,
			reserved,
			label,
			append_warning(
				not hook_ok and (label .. " removal hook failed: " .. tostring(hook_err))
					or (label .. " changed before reserved unlink: " .. tostring(final_err or "snapshot mismatch")),
				warning
			)
		)
	end
	local quarantine_hook_ok, quarantine_hook_err = run_test_hook("entry_validated_before_quarantine", {
		path = vim.fs.joinpath(directory.path, name),
		reserved_path = vim.fs.joinpath(directory.path, reserved),
		label = label,
	})
	if not quarantine_hook_ok then
		return restore_reserved_entry(
			directory,
			name,
			reserved,
			label,
			append_warning(label .. " quarantine hook failed: " .. tostring(quarantine_hook_err), warning)
		)
	end
	local quarantined
	for attempt = 1, 8 do
		local candidate = ("%s.quarantine.%d.%d.%d"):format(name, uv.os_getpid(), uv.hrtime(), attempt)
		local moved, move_warning_or_err, move_errno = renameat_noreplace(directory, reserved, directory, candidate)
		if moved then
			quarantined = candidate
			warning = append_warning(warning, move_warning_or_err)
			break
		end
		if move_errno ~= 17 then
			return nil,
				"could not quarantine validated " .. label .. "; entry remains at " .. vim.fs.joinpath(
					directory.path,
					reserved
				) .. ": " .. tostring(move_warning_or_err)
		end
	end
	if not quarantined then
		return nil, label .. " quarantine reservation namespace is exhausted"
	end
	local quarantined_snapshot, quarantined_err = read_file_snapshot(directory, quarantined, label, maximum, link_count)
	if not quarantined_snapshot or not snapshot_matches(quarantined_snapshot, expected) then
		return restore_reserved_entry(
			directory,
			name,
			quarantined,
			label,
			append_warning(
				label
					.. " changed after final validation and was preserved: "
					.. tostring(quarantined_err or "snapshot mismatch"),
				warning
			)
		)
	end
	local removed, remove_warning_or_err = unlinkat_entry(directory, quarantined)
	if not removed then
		return nil,
			"could not remove quarantined " .. label .. "; exact entry remains at " .. vim.fs.joinpath(
				directory.path,
				quarantined
			) .. ": " .. tostring(remove_warning_or_err)
	end
	warning = append_warning(warning, remove_warning_or_err)
	return true, warning
end

local function cleanup_owned_staging(directory, name, identity, label, maximum)
	if type(identity) ~= "table" then
		return nil, label .. " identity is unavailable; staging was preserved"
	end
	local snapshot, snapshot_err = read_file_snapshot(directory, name, label, maximum)
	if not snapshot then
		return nil, label .. " could not be revalidated; staging was preserved: " .. tostring(snapshot_err)
	end
	if not same_identity(snapshot.stat, identity) then
		return nil, label .. " was replaced; the replacement was preserved"
	end
	return conditional_remove_entry(directory, name, snapshot, label, maximum, true)
end

local function cleanup_empty_private_directory(root, name, directory, label)
	local entries, list_err = list_directory_entries(directory)
	if not entries then
		close_anchor(directory)
		return nil, "could not inspect " .. label .. " before cleanup: " .. tostring(list_err)
	end
	if #entries > 0 then
		local retained = vim.fs.joinpath(root.path, name)
		close_anchor(directory)
		return nil, label .. " contains an unknown entry and remains at " .. retained
	end
	local reserved
	local warning
	for attempt = 1, 8 do
		local candidate = ("%s.delete.%d.%d.%d"):format(name, uv.os_getpid(), uv.hrtime(), attempt)
		local moved, move_warning_or_err, move_errno = renameat_noreplace(root, name, root, candidate)
		if moved then
			reserved = candidate
			warning = append_warning(warning, move_warning_or_err)
			break
		end
		if move_errno ~= 17 then
			close_anchor(directory)
			return nil, "could not reserve " .. label .. " directory: " .. tostring(move_warning_or_err)
		end
	end
	if not reserved then
		close_anchor(directory)
		return nil, label .. " directory reservation namespace is exhausted"
	end
	local reserved_directory, open_err = open_directory_at(root, reserved, false)
	if not reserved_directory or not same_identity(reserved_directory.identity, directory.identity) then
		if reserved_directory then
			close_anchor(reserved_directory)
		end
		local _, restore_warning = renameat_noreplace(root, reserved, root, name)
		close_anchor(directory)
		return nil,
			label
				.. " directory changed while it was reserved: "
				.. tostring(open_err or "identity mismatch")
				.. (restore_warning and "; " .. tostring(restore_warning) or "")
	end
	local original_closed, original_close_err = close_anchor(directory)
	if not original_closed then
		warning = append_warning(warning, "could not close reserved " .. label .. ": " .. tostring(original_close_err))
	end
	local function restore(detail)
		local restored, restore_warning_or_err = renameat_noreplace(root, reserved, root, name)
		warning = append_warning(warning, restored and restore_warning_or_err or nil)
		local closed, close_err = close_anchor(reserved_directory)
		if not closed then
			warning = append_warning(warning, "could not close restored " .. label .. ": " .. tostring(close_err))
		end
		if restored then
			return nil,
				detail .. "; directory was restored without clobbering it" .. (warning and "; " .. warning or "")
		end
		return nil,
			detail .. "; reserved directory remains at " .. vim.fs.joinpath(root.path, reserved) .. ": " .. tostring(
				restore_warning_or_err
			)
	end
	entries, list_err = list_directory_entries(reserved_directory)
	if not entries or #entries > 0 then
		return restore(
			not entries and ("could not inspect reserved directory: " .. tostring(list_err))
				or "reserved directory gained an unknown entry"
		)
	end
	local hook_ok, hook_err = run_test_hook("directory_reserved_before_remove", {
		path = vim.fs.joinpath(root.path, name),
		reserved_path = vim.fs.joinpath(root.path, reserved),
		label = label,
	})
	entries, list_err = list_directory_entries(reserved_directory)
	if not hook_ok or not directory_anchor_valid(reserved_directory) or not entries or #entries > 0 then
		return restore(
			not hook_ok and (label .. " directory removal hook failed: " .. tostring(hook_err))
				or (label .. " directory changed before removal: " .. tostring(list_err or "identity mismatch"))
		)
	end
	local quarantine_hook_ok, quarantine_hook_err = run_test_hook("directory_validated_before_quarantine", {
		path = vim.fs.joinpath(root.path, name),
		reserved_path = vim.fs.joinpath(root.path, reserved),
		label = label,
	})
	if not quarantine_hook_ok then
		return restore(label .. " directory quarantine hook failed: " .. tostring(quarantine_hook_err))
	end
	local quarantined = reserved .. (".quarantine.%d"):format(uv.hrtime())
	local expected_identity = reserved_directory.identity
	local sealed, seal_warning_or_err = renameat_noreplace(root, reserved, root, quarantined)
	if not sealed then
		return restore(label .. " directory could not enter final quarantine: " .. tostring(seal_warning_or_err))
	end
	warning = append_warning(warning, seal_warning_or_err)
	local old_closed, old_close_err = close_anchor(reserved_directory)
	if not old_closed then
		warning = append_warning(warning, "could not close finalizing " .. label .. ": " .. tostring(old_close_err))
	end
	reserved = quarantined
	reserved_directory, list_err = open_directory_at(root, reserved, false)
	if not reserved_directory or not same_identity(reserved_directory.identity, expected_identity) then
		if reserved_directory then
			close_anchor(reserved_directory)
		end
		local restored, restore_warning_or_err = renameat_noreplace(root, reserved, root, name)
		warning = append_warning(warning, restored and restore_warning_or_err or nil)
		return nil,
			label
				.. " directory changed after final validation; replacement was preserved"
				.. (restored and " at " .. vim.fs.joinpath(root.path, name) or " at " .. vim.fs.joinpath(
					root.path,
					reserved
				))
				.. ": "
				.. tostring(list_err or restore_warning_or_err or "identity mismatch")
				.. (warning and "; " .. warning or "")
	end
	entries, list_err = list_directory_entries(reserved_directory)
	if not entries or #entries > 0 then
		return restore(
			not entries and (label .. " final quarantine could not be inspected: " .. tostring(list_err))
				or (label .. " final quarantine gained an unknown entry")
		)
	end
	local removed, remove_warning_or_err = remove_directory_entry(root, reserved)
	if not removed then
		close_anchor(reserved_directory)
		return nil,
			"could not remove reserved empty " .. label .. "; directory remains at " .. vim.fs.joinpath(
				root.path,
				reserved
			) .. ": " .. tostring(remove_warning_or_err)
	end
	warning = append_warning(warning, remove_warning_or_err)
	local closed, close_err = close_anchor(reserved_directory)
	if not closed then
		warning = append_warning(warning, "could not close removed " .. label .. ": " .. tostring(close_err))
	end
	return true, warning
end

local function state_conflict(detail)
	return nil, "state changed concurrently; refusing to overwrite it" .. (detail and ": " .. tostring(detail) or "")
end

local function cleanup_state_staging(root, temporary, snapshot, label)
	return conditional_remove_entry(root, temporary, snapshot, label, MAX_STATE_BYTES)
end

local function rollback_state_exchange(root, temporary, staged, published, incumbent, detail)
	if not published or not incumbent or not incumbent.stat or not same_identity(published.stat, staged.stat) then
		return state_conflict(
			tostring(detail or "exchange validation failed")
				.. "; state and recovery entry were retained without rollback"
		)
	end
	local published_now, published_err = read_file_snapshot(root, STATE_FILE, "published state", MAX_STATE_BYTES)
	local incumbent_now, incumbent_err = capture_snapshot_like(root, temporary, "state CAS incumbent", incumbent)
	if
		not snapshot_matches(published_now, published) or not snapshot_matches_after_rename(incumbent_now, incumbent)
	then
		return state_conflict(
			tostring(detail or "exchange validation failed")
				.. "; rollback inputs changed and remain at their current names: "
				.. tostring(published_err or incumbent_err or "snapshot mismatch")
		)
	end
	local restored, restore_warning_or_err = renameat_exchange(root, STATE_FILE, root, temporary)
	if not restored then
		return state_conflict(
			tostring(detail or "exchange validation failed")
				.. "; atomic rollback failed and both entries were retained: "
				.. tostring(restore_warning_or_err)
		)
	end
	local restored_state, restored_err = capture_snapshot_like(root, STATE_FILE, "restored state", incumbent)
	local displaced_staging, displaced_err =
		read_file_snapshot(root, temporary, "rolled-back state staging", MAX_STATE_BYTES)
	if
		not snapshot_matches_after_rename(restored_state, incumbent)
		or not snapshot_matches(displaced_staging, published)
	then
		return state_conflict(
			tostring(detail or "exchange validation failed")
				.. "; atomic rollback completed but exact verification failed: "
				.. tostring(restored_err or displaced_err or "snapshot mismatch")
		)
	end
	local cleaned, cleanup_err = cleanup_state_staging(root, temporary, displaced_staging, "rolled-back state staging")
	if not cleaned then
		detail = tostring(detail or "exchange validation failed") .. "; " .. tostring(cleanup_err)
	end
	detail = append_warning(detail, restore_warning_or_err)
	detail = append_warning(detail, cleaned and cleanup_err or nil)
	return state_conflict(detail)
end

local function publish_initial_state(root, temporary, staged)
	local current, current_err = inspect_state_target(root)
	if current == nil then
		return state_conflict(current_err)
	end
	if current then
		local cleaned, cleanup_err = cleanup_state_staging(root, temporary, staged, "initial state staging")
		return state_conflict(cleaned and nil or cleanup_err)
	end
	local hook_ok, hook_err = run_test_hook("state_target_checked", {
		path = state_path(),
		root = state.state_root,
		target_present = false,
	})
	if not hook_ok or not directory_anchor_valid(root, state.state_root) then
		cleanup_state_staging(root, temporary, staged, "initial state staging")
		return nil, hook_ok and "state root changed before publication" or "state publication hook failed: " .. hook_err
	end
	local staged_now, staged_err = read_file_snapshot(root, temporary, "initial state staging", MAX_STATE_BYTES)
	if not snapshot_matches(staged_now, staged) then
		return state_conflict(
			"initial state staging changed before publication and was preserved: "
				.. tostring(staged_err or "snapshot mismatch")
		)
	end
	local published_ok, publish_warning_or_err = renameat_noreplace(root, temporary, root, STATE_FILE)
	if not published_ok then
		local cleaned, cleanup_err = cleanup_state_staging(root, temporary, staged_now, "initial state staging")
		return state_conflict(tostring(publish_warning_or_err) .. (cleaned and "" or "; " .. tostring(cleanup_err)))
	end
	local final, final_err = read_file_snapshot(root, STATE_FILE, "published state", MAX_STATE_BYTES)
	if not snapshot_matches(final, staged) then
		return nil,
			"initial state changed after no-clobber publication and was preserved: " .. tostring(
				final_err or "snapshot mismatch"
			)
	end
	if not directory_anchor_valid(root, state.state_root) then
		return nil, "state root changed after initial publication; no rollback is claimed"
	end
	return true, publish_warning_or_err
end

local function publish_existing_state(root, temporary, staged, expected)
	if type(expected.data) ~= "string" or type(expected.stat) ~= "table" then
		return nil, "state CAS requires the prior bytes and identity"
	end
	local current, current_err = inspect_state_target(root)
	if current == nil or not current then
		cleanup_state_staging(root, temporary, staged, "state staging")
		return state_conflict(current_err)
	end
	local hook_ok, hook_err = run_test_hook("state_target_checked", {
		path = state_path(),
		root = state.state_root,
		target_present = true,
	})
	if not hook_ok or not directory_anchor_valid(root, state.state_root) then
		cleanup_state_staging(root, temporary, staged, "state staging")
		return nil, hook_ok and "state root changed before publication" or "state publication hook failed: " .. hook_err
	end
	local staged_now, staged_err = read_file_snapshot(root, temporary, "state staging", MAX_STATE_BYTES)
	if not snapshot_matches(staged_now, staged) then
		return state_conflict(
			"state staging changed before exchange and was preserved: " .. tostring(staged_err or "snapshot mismatch")
		)
	end
	local exchanged, exchange_warning_or_err = renameat_exchange(root, temporary, root, STATE_FILE)
	if not exchanged then
		local cleaned, cleanup_err = cleanup_state_staging(root, temporary, staged_now, "state staging")
		return state_conflict(tostring(exchange_warning_or_err) .. (cleaned and "" or "; " .. tostring(cleanup_err)))
	end
	local exchange_hook_ok, exchange_hook_err = run_test_hook("state_exchanged", {
		path = state_path(),
		recovery_path = vim.fs.joinpath(root.path, temporary),
	})
	local published, published_err = read_file_snapshot(root, STATE_FILE, "published state", MAX_STATE_BYTES)
	local incumbent, incumbent_err = read_file_snapshot(root, temporary, "state CAS incumbent", MAX_STATE_BYTES)
	local incumbent_any, incumbent_any_err = read_any_snapshot(root, temporary, "state CAS incumbent")
	if
		not exchange_hook_ok
		or not snapshot_matches(published, staged)
		or not snapshot_matches(incumbent, expected)
		or not directory_anchor_valid(root, state.state_root)
	then
		return rollback_state_exchange(
			root,
			temporary,
			staged,
			published,
			incumbent or incumbent_any,
			not exchange_hook_ok and ("state exchange hook failed: " .. tostring(exchange_hook_err))
				or tostring(published_err or incumbent_err or incumbent_any_err or "exact state CAS mismatch")
		)
	end
	if exchange_warning_or_err then
		return true,
			append_warning(
				exchange_warning_or_err,
				"state CAS incumbent retained at "
					.. vim.fs.joinpath(root.path, temporary)
					.. " because exchange durability is uncertain"
			)
	end
	local cleaned, cleanup_warning_or_err = cleanup_state_staging(root, temporary, incumbent, "state CAS incumbent")
	if not cleaned then
		return true, cleanup_warning_or_err
	end
	local final, final_err = read_file_snapshot(root, STATE_FILE, "published state", MAX_STATE_BYTES)
	if not snapshot_matches(final, staged) then
		return nil, "published state changed after exact CAS: " .. tostring(final_err or "snapshot mismatch")
	end
	return true, cleanup_warning_or_err
end

local function publish_state_cas(root, temporary, staged, expected)
	if type(expected) ~= "table" or type(expected.exists) ~= "boolean" then
		cleanup_state_staging(root, temporary, staged, "state staging")
		return nil, "state CAS requires an exact prior snapshot"
	end
	if expected.exists == false then
		return publish_initial_state(root, temporary, staged)
	end
	return publish_existing_state(root, temporary, staged, expected)
end

local function atomic_write(root, persistent, expected)
	if not directory_anchor_valid(root, state.state_root) then
		return nil, "state root changed before writing"
	end
	local _, target_err = inspect_state_target(root)
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

	local temporary = STATE_FILE .. (".tmp.%d.%d"):format(uv.os_getpid(), uv.hrtime())
	local flags = OPEN_FLAGS.write_only
		+ OPEN_FLAGS.create
		+ OPEN_FLAGS.exclusive
		+ OPEN_FLAGS.no_follow
		+ OPEN_FLAGS.close_on_exec
	local fd, open_err = openat_file(root.fd, temporary, flags, FILE_MODE)
	if not fd then
		return nil, "could not create temporary state: " .. tostring(open_err)
	end
	local secured, secure_err = uv.fs_fchmod(fd, FILE_MODE)
	local wrote, write_err = secured and write_all(fd, contents) or nil
	if not wrote then
		local created = uv.fs_fstat(fd)
		local closed, close_err = uv.fs_close(fd)
		local cleaned, cleanup_err = closed
			and cleanup_owned_staging(root, temporary, created, "temporary state", MAX_STATE_BYTES)
		return nil,
			"could not write temporary state: "
				.. tostring(secure_err or write_err or close_err)
				.. (cleaned and "" or "; " .. tostring(cleanup_err or "staging was preserved"))
	end
	local sync_ok, sync_err = uv.fs_fsync(fd)
	local temporary_info, temporary_err = uv.fs_fstat(fd)
	local close_ok, close_err = uv.fs_close(fd)
	if
		not sync_ok
		or not temporary_info
		or temporary_info.type ~= "file"
		or temporary_info.nlink ~= 1
		or temporary_info.size ~= #contents
		or not close_ok
	then
		local cleaned, cleanup_err = close_ok
			and cleanup_owned_staging(root, temporary, temporary_info, "temporary state", MAX_STATE_BYTES)
		return nil,
			"could not flush temporary state: "
				.. tostring(sync_err or temporary_err or close_err)
				.. (cleaned and "" or "; " .. tostring(cleanup_err or "staging was preserved"))
	end
	local staged, staged_err = read_file_snapshot(root, temporary, "temporary state", MAX_STATE_BYTES)
	local expected_staging = { data = contents, stat = temporary_info }
	if not snapshot_matches(staged, expected_staging) then
		cleanup_state_staging(root, temporary, expected_staging, "temporary state")
		return nil,
			"temporary state changed before replacement and was preserved: " .. tostring(
				staged_err or "snapshot mismatch"
			)
	end
	local _, recheck_err = inspect_state_target(root)
	if recheck_err then
		cleanup_state_staging(root, temporary, staged, "temporary state")
		return nil, recheck_err
	end
	return publish_state_cas(root, temporary, staged, expected)
end

local function process_alive(pid)
	if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then
		return nil
	end
	local called, result, _, code = pcall(vim.uv.kill, pid, 0)
	if not called then
		return nil
	end
	if result ~= nil then
		return true
	end
	if code == "ESRCH" then
		return false
	end
	return nil
end

local function exact_fields(value, fields)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if not fields[key] then
			return false
		end
	end
	return true
end

local function lock_claim_path(base, kind, token, number)
	if kind == "choosing" then
		return base .. ".choosing." .. token
	end
	return ("%s.ticket.%020d.%s"):format(base, number, token)
end

local function write_lock_claim(root, name, claim)
	local contents = vim.json.encode(claim) .. "\n"
	-- This deterministic O_EXCL staging path reserves the claim's unique token.
	-- Descriptor-relative no-clobber publication also preserves a hostile rival.
	local temporary = name .. ".publish"
	local flags = OPEN_FLAGS.write_only
		+ OPEN_FLAGS.create
		+ OPEN_FLAGS.exclusive
		+ OPEN_FLAGS.no_follow
		+ OPEN_FLAGS.close_on_exec
	local fd, open_err = openat_file(root.fd, temporary, flags, FILE_MODE)
	if not fd then
		return nil, "could not create lock claim staging file: " .. tostring(open_err)
	end
	local secured, secure_err = uv.fs_fchmod(fd, FILE_MODE)
	local wrote, write_err = secured and write_all(fd, contents) or nil
	local synced, sync_err = wrote and uv.fs_fsync(fd) or nil
	local opened, inspect_err = synced and uv.fs_fstat(fd) or nil
	local closed, close_err = uv.fs_close(fd)
	if
		not wrote
		or not synced
		or not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or opened.size ~= #contents
		or not closed
	then
		local cleaned, cleanup_err = closed
			and cleanup_owned_staging(root, temporary, opened, "staged lock claim", MAX_LOCK_BYTES)
		return nil,
			"could not stage lock claim: " .. tostring(
				secure_err or write_err or sync_err or inspect_err or close_err or "unsafe claim"
			) .. (cleaned and "" or "; " .. tostring(cleanup_err or "staging was preserved"))
	end
	local staged, staged_err = read_file_snapshot(root, temporary, "staged lock claim", MAX_LOCK_BYTES)
	local intended = { data = contents, stat = opened }
	if not snapshot_matches(staged, intended) then
		conditional_remove_entry(root, temporary, intended, "staged lock claim", MAX_LOCK_BYTES)
		return nil, "staged lock claim changed and was preserved: " .. tostring(staged_err or "snapshot mismatch")
	end
	local collision, collision_err = entry_snapshot(root, name, "final lock claim", MAX_LOCK_BYTES)
	if collision == nil then
		conditional_remove_entry(root, temporary, staged, "staged lock claim", MAX_LOCK_BYTES)
		return nil, "could not inspect final lock claim path: " .. tostring(collision_err)
	end
	if collision then
		conditional_remove_entry(root, temporary, staged, "staged lock claim", MAX_LOCK_BYTES)
		return nil, "lock claim path collision"
	end
	local hook_ok, hook_err = run_test_hook("lock_claim_staged", {
		path = vim.fs.joinpath(state.state_root, name),
		staging_path = vim.fs.joinpath(state.state_root, temporary),
	})
	if not hook_ok or not directory_anchor_valid(root, state.state_root) then
		conditional_remove_entry(root, temporary, staged, "staged lock claim", MAX_LOCK_BYTES)
		return nil,
			hook_ok and "state root changed before lock publication" or "lock publication hook failed: " .. hook_err
	end
	local publishable, publishable_err = read_file_snapshot(root, temporary, "staged lock claim", MAX_LOCK_BYTES)
	if not snapshot_matches(publishable, intended) then
		return nil,
			"staged lock claim content changed before publication and was preserved: " .. tostring(
				publishable_err or "snapshot mismatch"
			)
	end
	local published, publish_warning_or_err = renameat_noreplace(root, temporary, root, name)
	if not published then
		conditional_remove_entry(root, temporary, publishable, "staged lock claim", MAX_LOCK_BYTES)
		return nil, "could not publish lock claim: " .. tostring(publish_warning_or_err)
	end
	local final, final_err = read_file_snapshot(root, name, "published lock claim", MAX_LOCK_BYTES)
	if not snapshot_matches(final, intended) then
		return nil, "published lock claim changed and was preserved: " .. tostring(final_err or "snapshot mismatch")
	end
	return true, final, publish_warning_or_err
end

local function read_lock_claim(root, name, expected_kind, expected_token, expected_number)
	local contents, read_err, file_stat = read_verified_file(root, name, "lock claim", MAX_LOCK_BYTES)
	if not contents then
		local current = entry_snapshot(root, name, "lock claim", MAX_LOCK_BYTES)
		if current == false then
			return nil, "missing"
		end
		return nil, read_err
	end
	local decoded_ok, claim = pcall(vim.json.decode, contents)
	local fields = expected_kind == "ticket"
			and { version = true, kind = true, pid = true, token = true, number = true }
		or { version = true, kind = true, pid = true, token = true }
	if
		not decoded_ok
		or not exact_fields(claim, fields)
		or claim.version ~= 1
		or claim.kind ~= expected_kind
		or type(claim.pid) ~= "number"
		or claim.pid < 1
		or claim.pid % 1 ~= 0
		or claim.token ~= expected_token
		or #claim.token ~= 64
		or not claim.token:match("^[0-9a-f]+$")
		or (expected_kind == "ticket" and claim.number ~= expected_number)
	then
		return nil, "lock claim metadata is invalid"
	end
	return claim, nil, { data = contents, stat = file_stat }
end

local function cleanup_lock_claim_quarantine(root, quarantine_name, quarantine)
	return cleanup_empty_private_directory(root, quarantine_name, quarantine, "lock claim quarantine")
end

local function restore_replaced_claim(root, name, quarantine_name, quarantine, detail)
	local restored, restore_warning_or_err = renameat_noreplace(quarantine, "record", root, name)
	if restored then
		local cleaned, cleanup_warning_or_err = cleanup_lock_claim_quarantine(root, quarantine_name, quarantine)
		if not cleaned then
			return nil,
				detail .. "; replacement was restored but quarantine cleanup failed: " .. tostring(
					cleanup_warning_or_err
				)
		end
		local warning = append_warning(restore_warning_or_err, cleanup_warning_or_err)
		return nil, detail .. "; replacement was restored without clobbering it" .. (warning and "; " .. warning or "")
	end
	local rival = entry_snapshot(root, name, "competing lock claim", MAX_LOCK_BYTES)
	local retained = vim.fs.joinpath(state.state_root, quarantine_name, "record")
	close_anchor(quarantine)
	if rival then
		return nil,
			detail
				.. "; a newer claim was preserved and the displaced replacement remains at "
				.. retained
				.. ": "
				.. tostring(restore_warning_or_err)
	end
	return nil, detail .. "; displaced replacement remains at " .. retained .. ": " .. tostring(restore_warning_or_err)
end

local function remove_unique_claim(root, name, expected, missing_ok)
	if not directory_anchor_valid(root, state.state_root) then
		return nil, "state root changed before lock claim removal"
	end
	if type(expected) ~= "table" or type(expected.data) ~= "string" or type(expected.stat) ~= "table" then
		return nil, "lock claim removal requires an exact snapshot"
	end
	local hook_ok, hook_err = run_test_hook("lock_claim_before_remove", {
		path = vim.fs.joinpath(state.state_root, name),
		name = name,
	})
	if not hook_ok or not directory_anchor_valid(root, state.state_root) then
		return nil,
			hook_ok and "state root changed before lock claim removal" or "lock removal hook failed: " .. hook_err
	end
	local quarantine_name, quarantine, warning = create_private_directory(root, name .. ".remove")
	if not quarantine_name then
		return nil, "could not create lock claim quarantine: " .. tostring(quarantine)
	end
	local ready_ok, ready_err = run_test_hook("lock_claim_quarantine_ready", {
		path = vim.fs.joinpath(state.state_root, name),
		quarantine_path = quarantine.path,
	})
	if not ready_ok then
		local cleaned, cleanup_err = cleanup_lock_claim_quarantine(root, quarantine_name, quarantine)
		return nil,
			"lock claim quarantine hook failed: " .. tostring(ready_err) .. (cleaned and "" or "; " .. tostring(
				cleanup_err
			))
	end
	local moved, move_warning_or_err, move_errno = renameat_noreplace(root, name, quarantine, "record")
	if not moved then
		local cleaned, cleanup_warning_or_err = cleanup_lock_claim_quarantine(root, quarantine_name, quarantine)
		if not cleaned then
			return nil, cleanup_warning_or_err
		end
		warning = append_warning(warning, cleanup_warning_or_err)
		if move_errno == 2 then
			return missing_ok and true or nil,
				missing_ok and warning or "lock claim disappeared before conditional removal"
		end
		return nil, "could not quarantine lock claim for conditional removal: " .. tostring(move_warning_or_err)
	end
	warning = append_warning(warning, move_warning_or_err)
	local moved_snapshot, moved_err = read_file_snapshot(quarantine, "record", "quarantined lock claim", MAX_LOCK_BYTES)
	if not moved_snapshot then
		return restore_replaced_claim(
			root,
			name,
			quarantine_name,
			quarantine,
			"lock claim became unsafe before conditional removal: " .. tostring(moved_err)
		)
	end
	if not snapshot_matches(moved_snapshot, expected) then
		return restore_replaced_claim(
			root,
			name,
			quarantine_name,
			quarantine,
			"lock claim changed before conditional removal"
		)
	end
	local record_hook_ok, record_hook_err = run_test_hook("lock_claim_record_checked", {
		path = vim.fs.joinpath(state.state_root, name),
		record_path = vim.fs.joinpath(quarantine.path, "record"),
	})
	if not record_hook_ok then
		return restore_replaced_claim(
			root,
			name,
			quarantine_name,
			quarantine,
			"lock claim removal hook failed: " .. tostring(record_hook_err)
		)
	end
	local removed, remove_warning_or_err =
		conditional_remove_entry(quarantine, "record", moved_snapshot, "quarantined lock claim", MAX_LOCK_BYTES, false)
	if not removed then
		return restore_replaced_claim(
			root,
			name,
			quarantine_name,
			quarantine,
			"could not remove verified lock claim: " .. tostring(remove_warning_or_err)
		)
	end
	warning = append_warning(warning, remove_warning_or_err)
	local cleaned, cleanup_warning_or_err = cleanup_lock_claim_quarantine(root, quarantine_name, quarantine)
	if not cleaned then
		return nil, cleanup_warning_or_err
	end
	return true, append_warning(warning, cleanup_warning_or_err)
end

local function collect_lock_claims(root, base)
	local legacy, legacy_err = entry_snapshot(root, base, "legacy state lock", MAX_LOCK_BYTES)
	if legacy == nil then
		return nil, "could not inspect legacy state lock: " .. tostring(legacy_err)
	end
	if legacy then
		return nil, "legacy state lock is unsafe and must be removed manually"
	end
	local basename = base:gsub("([^%w])", "%%%1")
	local claims = {}
	local before_ok, before_err = run_test_hook("lock_claim_list_before", { path = state.state_root })
	if not before_ok then
		return nil, "lock claim listing hook failed: " .. tostring(before_err)
	end
	local names, list_err = list_directory_entries(root)
	local after_ok, after_err = run_test_hook("lock_claim_list_after", { path = state.state_root })
	if not after_ok then
		return nil, "lock claim listing hook failed: " .. tostring(after_err)
	end
	if not names then
		return nil, list_err
	end
	if not directory_anchor_valid(root, state.state_root) then
		return nil, "state root changed while lock claims were listed"
	end
	local parsed, parse_err = pcall(function()
		for _, name in ipairs(names) do
			local token = name:match("^" .. basename .. "%.choosing%.([0-9a-f]+)$")
			local number
			local kind
			if token then
				kind = "choosing"
			else
				local encoded
				encoded, token = name:match("^" .. basename .. "%.ticket%.(%d+)%.([0-9a-f]+)$")
				if encoded then
					number = tonumber(encoded)
					kind = "ticket"
				end
			end
			if kind then
				if #token ~= 64 or (kind == "ticket" and (not number or number < 1 or number % 1 ~= 0)) then
					error("lock claim filename is invalid: " .. name)
				end
				local claim, claim_err, snapshot = read_lock_claim(root, name, kind, token, number)
				if not claim and claim_err ~= "missing" then
					error("unsafe lock claim " .. name .. ": " .. tostring(claim_err))
				end
				if claim then
					claim.name = name
					claim.snapshot = snapshot
					claims[#claims + 1] = claim
				end
			end
		end
	end)
	if not parsed then
		return nil, tostring(parse_err)
	end
	return claims
end

local function live_lock_claims(root, base, protected)
	local claims, claims_err = collect_lock_claims(root, base)
	if not claims then
		return nil, claims_err
	end
	local live = {}
	local warning
	for _, claim in ipairs(claims) do
		if protected and claim.name == protected.name then
			if not snapshot_matches(claim.snapshot, protected.snapshot) then
				return nil, "owned lock claim changed before acquisition"
			end
			live[#live + 1] = claim
		else
			local alive = process_alive(claim.pid)
			if alive == false then
				local removed, remove_warning_or_err = remove_unique_claim(root, claim.name, claim.snapshot, true)
				if not removed then
					return nil, "could not reclaim dead lock claim: " .. tostring(remove_warning_or_err)
				end
				warning = append_warning(warning, remove_warning_or_err)
			elseif alive == nil then
				return nil, "could not determine lock owner liveness for process " .. tostring(claim.pid)
			else
				live[#live + 1] = claim
			end
		end
	end
	return live, warning
end

local function release_state_lock(lock)
	local removed, remove_warning_or_err = remove_unique_claim(lock.root, lock.name, lock.snapshot, false)
	local closed, close_err = close_anchor(lock.root)
	if not removed then
		return nil, append_warning(lock.warning, "could not release state lock: " .. tostring(remove_warning_or_err))
	end
	local warning = append_warning(lock.warning, remove_warning_or_err)
	if not closed then
		warning = append_warning(warning, "could not close state root after lock release: " .. tostring(close_err))
	end
	return true, warning
end

local function acquire_state_lock()
	local root, root_err = inspect_root(true)
	if not root then
		return nil, root_err
	end
	local warning = root.warning
	local function abandon(name, snapshot)
		if name then
			remove_unique_claim(root, name, snapshot)
		end
		close_anchor(root)
	end
	local base = LOCK_FILE
	local pid = uv.os_getpid()
	local token = vim.fn.sha256(table.concat({ lock_path(), tostring(pid), tostring(uv.hrtime()), tostring({}) }, "\0"))
	local choosing_path = lock_claim_path(base, "choosing", token)
	local choosing = { version = 1, kind = "choosing", pid = pid, token = token }
	local created, choosing_snapshot, choosing_warning = write_lock_claim(root, choosing_path, choosing)
	if not created then
		close_anchor(root)
		return nil, choosing_snapshot
	end
	warning = append_warning(warning, choosing_warning)

	local claims, claims_err = live_lock_claims(root, base, { name = choosing_path, snapshot = choosing_snapshot })
	if not claims then
		abandon(choosing_path, choosing_snapshot)
		return nil, claims_err
	end
	warning = append_warning(warning, claims_err)
	local maximum = 0
	for _, claim in ipairs(claims) do
		if claim.kind == "ticket" then
			maximum = math.max(maximum, claim.number)
		end
	end
	if maximum >= 9007199254740991 then
		abandon(choosing_path, choosing_snapshot)
		return nil, "state lock ticket space is exhausted"
	end
	local number = maximum + 1
	local ticket_path = lock_claim_path(base, "ticket", token, number)
	local ticket = { version = 1, kind = "ticket", pid = pid, token = token, number = number }
	local ticket_snapshot
	local ticket_warning
	created, ticket_snapshot, ticket_warning = write_lock_claim(root, ticket_path, ticket)
	if not created then
		abandon(choosing_path, choosing_snapshot)
		return nil, ticket_snapshot
	end
	warning = append_warning(warning, ticket_warning)
	local removed, remove_warning_or_err = remove_unique_claim(root, choosing_path, choosing_snapshot)
	if not removed then
		remove_unique_claim(root, ticket_path, ticket_snapshot)
		close_anchor(root)
		return nil, "could not finish lock choice: " .. tostring(remove_warning_or_err)
	end
	warning = append_warning(warning, remove_warning_or_err)

	local deadline = uv.hrtime() + LOCK_WAIT_MILLISECONDS * 1000000
	while true do
		claims, claims_err = live_lock_claims(root, base, { name = ticket_path, snapshot = ticket_snapshot })
		if not claims then
			abandon(ticket_path, ticket_snapshot)
			return nil, claims_err
		end
		warning = append_warning(warning, claims_err)
		local blocking
		for _, claim in ipairs(claims) do
			if claim.token ~= token then
				if claim.kind == "choosing" then
					blocking = claim
					break
				end
				if claim.number < number or (claim.number == number and claim.token < token) then
					blocking = claim
					break
				end
			end
		end
		if not blocking then
			if not directory_anchor_valid(root, state.state_root) then
				abandon(ticket_path, ticket_snapshot)
				return nil, "state root changed while its lock was acquired"
			end
			return {
				root = root,
				name = ticket_path,
				token = token,
				number = number,
				snapshot = ticket_snapshot,
				warning = warning,
			}
		end
		if blocking.pid == pid or uv.hrtime() >= deadline then
			abandon(ticket_path, ticket_snapshot)
			return nil, "trusted workspace state is locked by process " .. tostring(blocking.pid)
		end
		vim.wait(LOCK_POLL_MILLISECONDS, function()
			return false
		end, LOCK_POLL_MILLISECONDS)
	end
end

local function update_persistent(mutator)
	local lock, lock_err = acquire_state_lock()
	if not lock then
		return nil, lock_err
	end
	-- Keep the cooperative state lock through atomic_write's displaced-entry
	-- cleanup. Releasing after publication but before cleanup would let another
	-- cooperating writer reuse the same private namespace mid-transaction.
	local operation_warning
	local called, persistent, update_err = pcall(function()
		local latest, read_err, snapshot = read_state(lock.root)
		if not latest then
			return nil, read_err
		end
		local changed, mutation_err = mutator(latest)
		if changed == nil then
			return nil, mutation_err
		end
		if changed then
			local wrote, write_warning_or_err = atomic_write(lock.root, latest, snapshot)
			if not wrote then
				return nil, write_warning_or_err
			end
			operation_warning = append_warning(operation_warning, write_warning_or_err)
		end
		return latest
	end)
	local released, release_warning_or_err = release_state_lock(lock)
	if not called then
		local failure = append_warning(tostring(persistent), release_warning_or_err)
		if release_warning_or_err then
			state.state_error = append_warning(state.state_error, release_warning_or_err)
		end
		return nil, failure
	end
	if not persistent then
		local failure = append_warning(update_err, release_warning_or_err)
		if release_warning_or_err then
			state.state_error = append_warning(state.state_error, release_warning_or_err)
		end
		return nil, failure
	end
	state.persistent = persistent
	operation_warning = append_warning(operation_warning, release_warning_or_err)
	if not released then
		-- The state publication has already committed. Surface lock cleanup as a
		-- status warning without telling callers that their mutation failed.
		state.state_error = append_warning(state.state_error, operation_warning)
		return persistent, operation_warning
	end
	if operation_warning then
		state.state_error = append_warning(state.state_error, operation_warning)
	end
	return persistent, operation_warning
end

local function project_value(value)
	local top_ok, top_err = exact_options(value, { plugins = true }, "project source value")
	if not top_ok then
		return nil, top_err
	end
	local plugins = value.plugins or {}
	local plugins_ok, plugins_err = exact_options(
		plugins,
		{ native_review = true, log_workbench = true, clangd_compile_db = true },
		"project source value.plugins"
	)
	if not plugins_ok then
		return nil, plugins_err
	end
	local result = {}
	local normalized_plugins = {}
	if plugins.native_review ~= nil then
		local review_ok, review_err =
			exact_options(plugins.native_review, { hunk_context = true }, "project source value.plugins.native_review")
		if not review_ok then
			return nil, review_err
		end
		local context = plugins.native_review.hunk_context
		if context ~= nil and (type(context) ~= "number" or context < 0 or context % 1 ~= 0) then
			return nil, "project source value.plugins.native_review.hunk_context must be a non-negative integer"
		end
		normalized_plugins.native_review = copy(plugins.native_review)
	end
	if plugins.log_workbench ~= nil then
		local logs_ok, logs_err = exact_options(
			plugins.log_workbench,
			{ max_lines = true, max_bytes = true },
			"project source value.plugins.log_workbench"
		)
		if not logs_ok then
			return nil, logs_err
		end
		for name, maximum in pairs({ max_lines = 100000, max_bytes = 64 * 1024 * 1024 }) do
			local configured = plugins.log_workbench[name]
			if
				configured ~= nil
				and (type(configured) ~= "number" or configured < 1 or configured % 1 ~= 0 or configured > maximum)
			then
				return nil,
					("project source value.plugins.log_workbench.%s must be a positive integer no greater than %d"):format(
						name,
						maximum
					)
			end
		end
		normalized_plugins.log_workbench = copy(plugins.log_workbench)
	end
	if plugins.clangd_compile_db ~= nil then
		local clangd_ok, clangd_err = exact_options(
			plugins.clangd_compile_db,
			{ path = true, profile = true },
			"project source value.plugins.clangd_compile_db"
		)
		if not clangd_ok then
			return nil, clangd_err
		end
		local clangd = plugins.clangd_compile_db
		if
			clangd.path ~= nil
			and (type(clangd.path) ~= "string" or clangd.path == "" or clangd.path:find("\0", 1, true))
		then
			return nil, "project source value.plugins.clangd_compile_db.path must be a non-empty string"
		end
		if clangd.profile ~= nil and clangd.profile ~= "full" and clangd.profile ~= "light" then
			return nil, "project source value.plugins.clangd_compile_db.profile must be full or light"
		end
		normalized_plugins.clangd_compile_db = copy(clangd)
	end
	if next(normalized_plugins) ~= nil then
		result.plugins = normalized_plugins
	end
	return result, {}
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
	local workspace
	local fingerprint
	if spec.layer == "project" then
		if spec.workspace ~= nil then
			workspace, value_err = normalize_workspace(spec.workspace, "source.workspace")
			if not workspace then
				return nil, value_err
			end
			repo = workspace.repo_identity
		else
			repo, value_err = nonempty_string(spec.repo, "source.repo")
			if not repo then
				return nil, value_err
			end
			workspace, value_err = normalize_workspace(legacy_workspace(repo), "source.workspace")
			if not workspace then
				return nil, value_err
			end
		end
		fingerprint, value_err = nonempty_string(spec.fingerprint, "source.fingerprint")
		if not fingerprint then
			return nil, value_err
		end
		normalized_value, errors = project_value(normalized_value)
		if not normalized_value then
			return nil, errors
		end
	end
	return {
		id = id,
		layer = spec.layer,
		priority = priority,
		enabled = enabled,
		value = normalized_value,
		repo = repo,
		workspace = workspace,
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
		return repo_or_spec.workspace,
			repo_or_spec.repo,
			repo_or_spec.source or repo_or_spec.id,
			repo_or_spec.fingerprint
	end
	return nil, repo_or_spec, source_id, fingerprint
end

local function grant_args(repo_or_spec, capability)
	if type(repo_or_spec) == "table" then
		return repo_or_spec.repo, repo_or_spec.capability
	end
	return repo_or_spec, capability
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local options_ok, options_err =
		exact_options(opts, { state_root = true, mode = true, reset = true, on_state_change = true }, "setup")
	if not options_ok then
		return nil, options_err
	end
	if opts.reset ~= nil and type(opts.reset) ~= "boolean" then
		return nil, "setup.reset must be boolean"
	end
	if opts.on_state_change ~= nil and type(opts.on_state_change) ~= "function" then
		return nil, "setup.on_state_change must be a function"
	end
	local root, root_err = nonempty_string(opts.state_root, "setup.state_root")
	if not root then
		return nil, root_err
	end
	root = vim.fs.normalize(root)
	if root:sub(1, 1) ~= "/" then
		return nil, "setup.state_root must be absolute"
	end
	local mode = opts.mode
	if mode == nil then
		mode = "full"
	end
	if mode ~= "full" and mode ~= "host-only" then
		return nil, "setup.mode must be full or host-only"
	end
	if state.configured and state.state_root == root and state.mode == mode and opts.reset ~= true then
		state.on_state_change = opts.on_state_change
		return true
	end
	local root_changed = state.state_root ~= root
	local reset = opts.reset == true or root_changed
	local previous = state
	local candidate = copy(state)
	state = candidate
	if reset then
		state.sources = {}
		state.scopes = {}
		state.current_scope = HOST_SCOPE_KEY
		state.appliers = {}
		state.generation = 0
		state.candidate = nil
		state.applied = nil
		state.pending = {}
		state.last_known_good = nil
		state.applied_sources = {}
		state.apply_error = nil
		if root_changed then
			state.root_identity = nil
		end
	end
	state.state_root = root
	state.mode = mode
	state.on_state_change = nil
	state.configured = true
	local persistent, err = read_state()
	if err then
		state = previous
		return nil, err
	end
	state.state_error = nil
	state.persistent = persistent
	host_scope()
	local recomputed, recompute_err = recompute_all()
	if not recomputed then
		state = previous
		return nil, recompute_err
	end
	state.on_state_change = opts.on_state_change
	return true
end

function M.effective_config()
	if not state.configured then
		return { mode = "full" }
	end
	return copy({ state_root = state.state_root, mode = state.mode })
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
	local ok, apply_err
	if source.layer == "host" then
		state.sources[source.id] = source
		ok, apply_err = recompute_all()
	else
		local scope, key = scope_for(source.workspace, true)
		scope.sources[source.id] = source
		state.current_scope = key
		ok, apply_err = recompute_scope(scope)
	end
	if not ok then
		return nil, apply_err
	end
	return M.snapshot()
end

local function scope_from_selector(selector, create)
	if selector == nil then
		return state.scopes[state.current_scope] or host_scope(), state.current_scope
	end
	local workspace
	if type(selector) == "string" then
		local matches = {}
		for key, scope in pairs(state.scopes) do
			if scope.workspace and (scope.workspace.repo_identity == selector or scope.workspace.root == selector) then
				matches[#matches + 1] = { key = key, scope = scope }
			end
		end
		table.sort(matches, function(left, right)
			return left.key < right.key
		end)
		if #matches == 1 then
			return matches[1].scope, matches[1].key
		end
		if #matches > 1 then
			return nil, "workspace selector is ambiguous; pass an exact WorkspaceKey"
		end
		workspace = legacy_workspace(selector)
	else
		local normalized, err = normalize_workspace(selector, "workspace")
		if not normalized then
			return nil, err
		end
		workspace = normalized
	end
	local scope, key = scope_for(workspace, create)
	if not scope then
		return nil, "workspace scope is not registered"
	end
	return scope, key
end

function M.snapshot(workspace)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local scope, scope_err = scope_from_selector(workspace, false)
	if not scope then
		return nil, scope_err
	end
	return snapshot_copy(scope.applied or blank_snapshot())
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
	local ok, apply_err = recompute_all(true)
	if not ok then
		return nil, apply_err
	end
	return true
end

function M.approve(repo_or_spec, source_id, fingerprint)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local workspace, repo, source, expected = approval_args(repo_or_spec, source_id, fingerprint)
	local scope, scope_err
	if workspace ~= nil then
		workspace, scope_err = normalize_workspace(workspace, "approval.workspace")
		if not workspace then
			return nil, scope_err
		end
		repo = workspace.repo_identity
		scope, scope_err = scope_from_selector(workspace, false)
	else
		scope, scope_err = scope_from_selector(repo, false)
	end
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
	if not scope then
		return nil, "approval must match the currently registered enabled project source"
	end
	local registered = scope.sources[source]
	if
		not registered
		or registered.layer ~= "project"
		or not source_enabled(registered)
		or registered.repo ~= repo
		or registered.fingerprint ~= expected
	then
		return nil, "approval must match the currently registered enabled project source"
	end
	local persistent, write_err = update_persistent(function(latest)
		local current = scope.sources[source]
		if
			not current
			or current.layer ~= "project"
			or not source_enabled(current)
			or current.repo ~= repo
			or current.fingerprint ~= expected
		then
			return nil, "approval source changed before persistence"
		end
		latest.approvals[repo] = latest.approvals[repo] or {}
		if latest.approvals[repo][source] == expected then
			return false
		end
		latest.approvals[repo][source] = expected
		return true
	end)
	if not persistent then
		return nil, write_err
	end
	local applied, apply_err = recompute_scope(scope)
	if not applied then
		return nil, apply_err
	end
	return true
end

function M.approvals(selector)
	if not state.configured then
		return nil, "setup must be called first"
	end
	if selector == nil then
		return copy(state.persistent.approvals)
	end
	local repo = selector
	if type(selector) == "table" then
		local workspace, err = normalize_workspace(selector.workspace or selector, "approvals.workspace")
		if not workspace then
			return nil, err
		end
		repo = workspace.repo_identity
	end
	local valid, err = nonempty_string(repo, "approvals.repo")
	if not valid then
		return nil, err
	end
	return copy(state.persistent.approvals[repo] or {})
end

function M.has_approval(repo_or_spec, source_id, fingerprint)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local workspace, repo, source, expected = approval_args(repo_or_spec, source_id, fingerprint)
	if workspace ~= nil then
		local workspace_err
		workspace, workspace_err = normalize_workspace(workspace, "approval.workspace")
		if not workspace then
			return nil, workspace_err
		end
		repo = workspace.repo_identity
	end
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
	local persistent, read_err = read_state(nil, { observational = true })
	if not persistent then
		return nil, read_err
	end
	local by_repo = persistent.approvals[repo]
	return type(by_repo) == "table" and by_repo[source] == expected
end

function M.revoke_approval(workspace_or_repo, source_id)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local workspace
	local repo = workspace_or_repo
	if type(workspace_or_repo) == "table" then
		workspace = workspace_or_repo.workspace or workspace_or_repo
		source_id = workspace_or_repo.source or workspace_or_repo.id or source_id
		local workspace_err
		workspace, workspace_err = normalize_workspace(workspace, "approval.workspace")
		if not workspace then
			return nil, workspace_err
		end
		repo = workspace.repo_identity
	end
	local repo_ok, err = nonempty_string(repo, "approval.repo")
	if not repo_ok then
		return nil, err
	end
	local source_ok
	source_ok, err = nonempty_string(source_id, "approval.source")
	if not source_ok then
		return nil, err
	end
	local persistent, write_err = update_persistent(function(latest)
		if not latest.approvals[repo] or latest.approvals[repo][source_id] == nil then
			return false
		end
		latest.approvals[repo][source_id] = nil
		if next(latest.approvals[repo]) == nil then
			latest.approvals[repo] = nil
		end
		return true
	end)
	if not persistent then
		return nil, write_err
	end
	local scopes = {}
	for _, scope in pairs(state.scopes) do
		if scope.workspace and scope.workspace.repo_identity == repo and scope.sources[source_id] then
			scopes[#scopes + 1] = scope
		end
	end
	table.sort(scopes, function(left, right)
		return workspace_identity(left.workspace) < workspace_identity(right.workspace)
	end)
	for _, scope in ipairs(scopes) do
		local ok, apply_err = recompute_scope(scope)
		if not ok then
			return nil, apply_err
		end
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
	local persistent, write_err = update_persistent(function(latest)
		latest.grants[repo] = latest.grants[repo] or {}
		if latest.grants[repo][requested] == true then
			return false
		end
		latest.grants[repo][requested] = true
		return true
	end)
	if not persistent then
		return nil, write_err
	end
	return true
end

function M.has_grant(repo_or_spec, capability)
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
	local persistent, read_err = read_state(nil, { observational = true })
	if not persistent then
		return nil, read_err
	end
	return persistent.grants[repo] ~= nil and persistent.grants[repo][requested] == true
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
	local persistent, write_err = update_persistent(function(latest)
		if not latest.grants[repo] or not latest.grants[repo][requested] then
			return false
		end
		latest.grants[repo][requested] = nil
		if next(latest.grants[repo]) == nil then
			latest.grants[repo] = nil
		end
		return true
	end)
	if not persistent then
		return nil, write_err
	end
	return true
end

function M.status(selector)
	if not state.configured then
		return {
			configured = false,
			mode = "unconfigured",
			profile = nil,
			workspace = nil,
			generation = 0,
			candidate = nil,
			applied = nil,
			pending = {},
			last_known_good = nil,
			sources = {},
			grants = {},
			state_error = nil,
			apply_error = nil,
			scopes = {},
		}
	end
	local scope, scope_err = scope_from_selector(selector, false)
	if not scope and type(selector) == "string" and scope_err == "workspace scope is not registered" then
		scope = host_scope()
	end
	if not scope then
		return nil, scope_err
	end
	local source_status = {}
	for _, source in ipairs(sorted_sources(scope)) do
		source_status[#source_status + 1] = {
			id = source.id,
			layer = source.layer,
			priority = source.priority,
			enabled = source_enabled(source),
			repo = source.repo,
			workspace = copy(source.workspace),
			fingerprint = source.fingerprint,
			approved = approved(source),
			pending = source_enabled(source) and source.layer == "project" and not approved(source),
			errors = copy(source.errors),
		}
	end
	local mode = "candidate"
	if #scope.pending > 0 then
		mode = "pending"
	elseif scope.applied then
		mode = "applied"
	end
	local result = {
		configured = true,
		mode = mode,
		profile = state.mode,
		workspace = copy(scope.workspace),
		generation = scope.generation,
		candidate = scope.candidate and snapshot_copy(scope.candidate) or nil,
		applied = scope.applied and snapshot_copy(scope.applied) or nil,
		pending = copy(scope.pending),
		last_known_good = scope.last_known_good and snapshot_copy(scope.last_known_good) or nil,
		sources = source_status,
		grants = copy(state.persistent.grants),
		state_error = state.state_error,
		apply_error = scope.apply_error,
	}
	local repo = type(selector) == "string" and selector or scope.workspace and scope.workspace.repo_identity or nil
	if repo ~= nil then
		local repo_ok, err = nonempty_string(repo, "status.repo")
		if not repo_ok then
			return nil, err
		end
		result.repo_grants = copy(state.persistent.grants[repo] or {})
	end
	if selector == nil then
		result.scopes = {}
		local keys = vim.tbl_keys(state.scopes)
		table.sort(keys)
		for _, key in ipairs(keys) do
			local item = state.scopes[key]
			local item_mode = "candidate"
			if #item.pending > 0 then
				item_mode = "pending"
			elseif item.applied then
				item_mode = "applied"
			end
			result.scopes[#result.scopes + 1] = {
				workspace = copy(item.workspace),
				generation = item.generation,
				mode = item_mode,
				candidate = item.candidate and snapshot_copy(item.candidate) or nil,
				applied = item.applied and snapshot_copy(item.applied) or nil,
				pending = copy(item.pending),
				last_known_good = item.last_known_good and snapshot_copy(item.last_known_good) or nil,
				apply_error = item.apply_error,
			}
		end
	end
	return result
end

function M.teardown()
	state.configured = false
	state.state_root = nil
	state.root_identity = nil
	state.mode = "full"
	state.sources = {}
	state.scopes = {}
	state.current_scope = HOST_SCOPE_KEY
	state.appliers = {}
	state.generation = 0
	state.candidate = nil
	state.applied = nil
	state.pending = {}
	state.last_known_good = nil
	state.applied_sources = {}
	state.persistent = { version = STATE_VERSION, approvals = {}, grants = {} }
	state.state_error = nil
	state.apply_error = nil
	state.on_state_change = nil
	test_hook = nil
	return true
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

function M.diff(workspace)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local scope, scope_err = scope_from_selector(workspace, false)
	if not scope then
		return nil, scope_err
	end
	local result = {}
	local before = scope.applied and scope.applied.value or {}
	local after = scope.candidate and scope.candidate.value or {}
	local provenance = scope.candidate and scope.candidate.validity.provenance or {}
	append_diff(result, before, after, provenance, "")
	return copy(result)
end

function M._set_test_hook(callback)
	if callback ~= nil and type(callback) ~= "function" then
		error("trusted_workspace test hook must be a function or nil")
	end
	test_hook = callback
end

return M
