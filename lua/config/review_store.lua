-- Strict, owner-only persistence for native review drafts. This module has no
-- UI or plugin dependency; callers explicitly decide when to save mutations.
local M = {}

local fs = require("config.fs")
local review_scope = require("config.review_scope")
local uv = vim.uv

local VERSION = 1
local MAX_BYTES = 1024 * 1024
local MAX_RECOVERY_BYTES = 2 * MAX_BYTES
local MAX_ITEMS = 2000
local MAX_BODY = 64 * 1024
local MAX_PATH = 4096
local MAX_ANCHOR_LAYER = 128
local MAX_ANCHOR_CONTEXT = 16 * 1024
local MAX_LOCK_BYTES = 1024
local LOCK_STALE_SECONDS = 30
local LOCK_OWNER_NAME = "owner.json"

local TYPES = {
	issue = true,
	suggestion = true,
	rationale = true,
	question = true,
	pedantic = true,
	praise = true,
}
local STATUSES = { draft = true, reply = true, resolved = true, exported = true }

local SESSION_KEYS = {
	version = true,
	revision = true,
	id = true,
	repo_root = true,
	repo_hash = true,
	scope = true,
	stale = true,
	bridge = true,
	created_at = true,
	updated_at = true,
	next_sequence = true,
	items = true,
}
local BRIDGE_KEYS = { backend = true, round = true, trusted_scope_id = true, linked_at = true }
local SCOPE_KEYS = {
	version = true,
	id = true,
	root = true,
	kind = true,
	backend_id = true,
	label = true,
	diffview_args = true,
	file_history_range = true,
	head_oid = true,
	commit_oid = true,
	from_oid = true,
	to_oid = true,
	base_oid = true,
	merge_base_oid = true,
	fingerprint = true,
	layers = true,
	base_ref = true,
	head_ref = true,
	default_remote = true,
}
local LAYER_KEYS = { head = true, staged = true, unstaged = true, untracked = true }
local ITEM_KEYS = {
	id = true,
	sequence = true,
	type = true,
	body = true,
	anchor = true,
	status = true,
	reply_to = true,
	created_at = true,
	updated_at = true,
	exported_at = true,
	export_id = true,
}
local ANCHOR_KEYS = {
	path = true,
	side = true,
	layer = true,
	context = true,
	context_hash = true,
	stale = true,
	start_line = true,
	start_column = true,
	end_line = true,
	end_column = true,
}
local ADD_KEYS = { type = true, body = true, anchor = true }
local EDIT_KEYS = ADD_KEYS

local function object(value)
	return type(value) == "table" and (next(value) == nil or not vim.islist(value))
end

local function null(value)
	return value == nil or value == vim.NIL
end

local function exact_keys(value, allowed, label)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains unknown key " .. vim.inspect(key)
		end
	end
	return true
end

local function valid_utf8(value)
	return pcall(vim.str_utfindex, value)
end

local function bounded_string(value, maximum, label)
	if type(value) ~= "string" or value == "" then
		return nil, label .. " must be a non-empty string"
	end
	if value:find("\0", 1, true) then
		return nil, label .. " contains a NUL byte"
	end
	if not valid_utf8(value) then
		return nil, label .. " is not valid UTF-8"
	end
	if #value > maximum then
		return nil, string.format("%s exceeds %d bytes", label, maximum)
	end
	return true
end

local function positive_integer(value, label)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		return nil, label .. " must be a positive integer"
	end
	return true
end

local function valid_oid(value)
	return type(value) == "string" and (#value == 40 or #value == 64) and value:match("^[0-9a-f]+$") ~= nil
end

local function valid_digest(value)
	return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function valid_timestamp(value)
	return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil
end

local function valid_uuid(value)
	return type(value) == "string"
		and value == value:lower()
		and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function validate_bridge(bridge, session_id)
	if null(bridge) then
		return bridge
	end
	if not object(bridge) then
		return nil, "session.bridge must be an object or null"
	end
	local keys_ok, keys_err = exact_keys(bridge, BRIDGE_KEYS, "session.bridge")
	if not keys_ok then
		return nil, keys_err
	end
	if bridge.backend ~= "tuicr" then
		return nil, "session.bridge.backend must be tuicr"
	end
	if not valid_uuid(bridge.round) then
		return nil, "session.bridge.round must be a canonical lowercase UUID"
	end
	if bridge.trusted_scope_id ~= session_id then
		return nil, "session.bridge.trusted_scope_id must match session.id"
	end
	if not valid_timestamp(bridge.linked_at) then
		return nil, "session.bridge.linked_at is invalid"
	end
	return vim.deepcopy(bridge)
end

local function make_dependencies(options)
	options = options or {}
	local repo = options.repo or require("config.repo")
	local selected_uv = options.uv or uv
	return {
		repo = repo,
		root = options.root or repo.root,
		runner = options.runner,
		fs = options.fs or fs,
		uv = selected_uv,
		state_home = options.state_home or vim.fn.stdpath("state"),
		hash = options.hash or vim.fn.sha256,
		now = options.now or function()
			return os.date("!%Y-%m-%dT%H:%M:%SZ")
		end,
		time = options.time or os.time,
		nonce = options.nonce or function()
			return table.concat({
				tostring(selected_uv.os_getpid()),
				tostring(selected_uv.hrtime()),
				tostring({}),
			}, "\0")
		end,
		process_alive = options.process_alive or function(pid)
			return selected_uv.kill(pid, 0) == 0
		end,
	}
end

local function canonical_root(root, deps)
	local resolved, err = deps.root(root, deps.runner)
	if not resolved then
		return nil, "repository unavailable: " .. tostring(err)
	end
	return resolved
end

local function digest(value, deps)
	local result = deps.hash(value)
	if not valid_digest(result) then
		return nil, "hash dependency returned an invalid SHA-256 digest"
	end
	return result
end

local function normalize_path(path)
	local ok, err = bounded_string(path, MAX_PATH, "anchor.path")
	if not ok then
		return nil, err
	end
	if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") or path:find("\\", 1, true) then
		return nil, "anchor.path must be repository-relative"
	end
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return nil, "anchor.path traversal is not allowed"
		end
	end
	local normalized = path:gsub("/+", "/"):gsub("/$", "")
	if normalized == "" then
		return nil, "anchor.path must identify a file"
	end
	return normalized
end

local function optional_integer(value, label)
	if null(value) then
		return true
	end
	return positive_integer(value, label)
end

local function normalize_anchor(value, deps)
	if value == nil then
		return {}
	end
	if not object(value) then
		return nil, "anchor must be an object"
	end
	local keys_ok, keys_err = exact_keys(value, ANCHOR_KEYS, "anchor")
	if not keys_ok then
		return nil, keys_err
	end
	local anchor = {}
	if not null(value.path) then
		local path, path_err = normalize_path(value.path)
		if not path then
			return nil, path_err
		end
		anchor.path = path
	end
	if not null(value.side) then
		if value.side ~= "left" and value.side ~= "right" then
			return nil, "anchor.side must be left or right"
		end
		anchor.side = value.side
	end
	if not null(value.layer) then
		local layer_ok, layer_err = bounded_string(value.layer, MAX_ANCHOR_LAYER, "anchor.layer")
		if not layer_ok then
			return nil, layer_err
		end
		anchor.layer = value.layer
	end
	local has_context = not null(value.context)
	local has_context_hash = not null(value.context_hash)
	if has_context ~= has_context_hash then
		return nil, "anchor.context and anchor.context_hash must be provided together"
	end
	if has_context then
		local context_ok, context_err = bounded_string(value.context, MAX_ANCHOR_CONTEXT, "anchor.context")
		if not context_ok then
			return nil, context_err
		end
		anchor.context = value.context
		if not valid_digest(value.context_hash) then
			return nil, "anchor.context_hash must be a lowercase SHA-256 digest"
		end
		local expected_hash, hash_err = digest(value.context, deps)
		if not expected_hash or value.context_hash ~= expected_hash then
			return nil, "anchor.context_hash does not match anchor.context: " .. tostring(hash_err or "mismatch")
		end
		anchor.context_hash = value.context_hash
	end
	if not null(value.stale) then
		if type(value.stale) ~= "boolean" then
			return nil, "anchor.stale must be boolean"
		end
		anchor.stale = value.stale
	end
	for _, key in ipairs({ "start_line", "start_column", "end_line", "end_column" }) do
		local integer_ok, integer_err = optional_integer(value[key], "anchor." .. key)
		if not integer_ok then
			return nil, integer_err
		end
		if not null(value[key]) then
			anchor[key] = value[key]
		end
	end
	if anchor.side and not anchor.path then
		return nil, "anchor.side requires anchor.path"
	end
	if anchor.start_line and not anchor.path then
		return nil, "anchor.start_line requires anchor.path"
	end
	if anchor.start_column and not anchor.start_line then
		return nil, "anchor.start_column requires anchor.start_line"
	end
	if anchor.end_line and not anchor.start_line then
		return nil, "anchor.end_line requires anchor.start_line"
	end
	if anchor.end_column and not anchor.end_line then
		return nil, "anchor.end_column requires anchor.end_line"
	end
	if anchor.end_line then
		if anchor.end_line < anchor.start_line then
			return nil, "anchor end is before start"
		end
		if
			anchor.end_line == anchor.start_line
			and anchor.start_column
			and anchor.end_column
			and anchor.end_column < anchor.start_column
		then
			return nil, "anchor end is before start"
		end
	end
	return anchor
end

local function validate_scope(scope, root, deps)
	if not object(scope) then
		return nil, "scope must be an object"
	end
	local keys_ok, keys_err = exact_keys(scope, SCOPE_KEYS, "scope")
	if not keys_ok then
		return nil, keys_err
	end
	for _, key in ipairs({ "version", "id", "root", "kind", "backend_id", "label", "diffview_args" }) do
		if scope[key] == nil then
			return nil, "scope is missing " .. key
		end
	end
	if scope.version ~= VERSION or scope.root ~= root or not valid_digest(scope.id) then
		return nil, "scope version, root, or id is invalid"
	end
	if type(scope.backend_id) ~= "string" or not scope.backend_id:match("^[%w_.:-]+$") or #scope.backend_id > 128 then
		return nil, "scope.backend_id is invalid"
	end
	local label_ok, label_err = bounded_string(scope.label, 4096, "scope.label")
	if not label_ok then
		return nil, label_err
	end
	if type(scope.diffview_args) ~= "table" or not vim.islist(scope.diffview_args) or #scope.diffview_args > 1 then
		return nil, "scope.diffview_args must contain zero or one argument"
	end
	local argument = scope.diffview_args[1]
	if argument ~= nil and type(argument) ~= "string" then
		return nil, "scope.diffview_args contains a non-string argument"
	end

	local expected_range
	if scope.kind == "working" then
		if #scope.diffview_args ~= 0 then
			return nil, "working scope must use the aggregate index-to-local Diffview"
		end
		if not valid_oid(scope.head_oid) or not valid_digest(scope.fingerprint) then
			return nil, "working scope object IDs or fingerprint are invalid"
		end
		if not object(scope.layers) then
			return nil, "working scope layers are missing"
		end
		local layer_keys_ok, layer_keys_err = exact_keys(scope.layers, LAYER_KEYS, "scope.layers")
		if not layer_keys_ok then
			return nil, layer_keys_err
		end
		if
			scope.layers.head ~= scope.head_oid
			or not valid_digest(scope.layers.staged)
			or not valid_digest(scope.layers.unstaged)
			or not valid_digest(scope.layers.untracked)
		then
			return nil, "working scope layers are invalid"
		end
		expected_range = scope.head_oid
		if not null(scope.file_history_range) then
			return nil, "working scope must not define file_history_range"
		end
	elseif scope.kind == "commit" then
		if not valid_oid(scope.commit_oid) then
			return nil, "commit scope object ID is invalid"
		end
		expected_range = scope.commit_oid .. "^!"
	elseif scope.kind == "range" then
		if not valid_oid(scope.from_oid) or not valid_oid(scope.to_oid) then
			return nil, "range scope object IDs are invalid"
		end
		expected_range = scope.from_oid .. ".." .. scope.to_oid
	elseif scope.kind == "branch" then
		if not valid_oid(scope.base_oid) or not valid_oid(scope.merge_base_oid) or not valid_oid(scope.head_oid) then
			return nil, "branch scope object IDs are invalid"
		end
		if type(scope.base_ref) ~= "string" or type(scope.head_ref) ~= "string" then
			return nil, "branch scope refs are missing"
		end
		if scope.label ~= scope.base_ref .. "…" .. scope.head_ref then
			return nil, "branch scope label no longer describes the three-dot comparison"
		end
		expected_range = scope.merge_base_oid .. ".." .. scope.head_oid
	else
		return nil, "scope.kind is invalid"
	end
	if scope.kind ~= "working" and (#scope.diffview_args ~= 1 or argument ~= expected_range) then
		return nil, "scope.diffview_args does not match its frozen object IDs"
	end
	if scope.kind ~= "working" and scope.file_history_range ~= expected_range then
		return nil, "scope.file_history_range does not match its frozen object IDs"
	end
	local expected_id, id_err = review_scope.scope_id(root, scope, deps.hash)
	if not expected_id or expected_id ~= scope.id then
		return nil, "scope.id is not deterministic for this repository: " .. tostring(id_err or "mismatch")
	end
	return vim.deepcopy(scope)
end

local function item_id(session_id, sequence, deps)
	return digest(table.concat({ session_id, "item", tostring(sequence), deps.nonce() }, "\0"), deps)
end

local function validate_item(item, seen, deps, index)
	local label = "items[" .. index .. "]"
	if not object(item) then
		return nil, label .. " must be an object"
	end
	local keys_ok, keys_err = exact_keys(item, ITEM_KEYS, label)
	if not keys_ok then
		return nil, keys_err
	end
	for _, key in ipairs({
		"id",
		"sequence",
		"type",
		"body",
		"anchor",
		"status",
		"reply_to",
		"created_at",
		"updated_at",
		"exported_at",
		"export_id",
	}) do
		if item[key] == nil then
			return nil, label .. " is missing " .. key
		end
	end
	local sequence_ok, sequence_err = positive_integer(item.sequence, label .. ".sequence")
	if not sequence_ok then
		return nil, sequence_err
	end
	if not valid_digest(item.id) or seen[item.id] then
		return nil, label .. ".id must be a unique lowercase SHA-256 digest"
	end
	if not TYPES[item.type] then
		return nil, label .. ".type must be one of the six supported review types"
	end
	local body_ok, body_err = bounded_string(item.body, MAX_BODY, label .. ".body")
	if not body_ok then
		return nil, body_err
	end
	local anchor, anchor_err = normalize_anchor(item.anchor, deps)
	if not anchor then
		return nil, label .. "." .. anchor_err
	end
	if not STATUSES[item.status] then
		return nil, label .. ".status is invalid"
	end
	if not valid_timestamp(item.created_at) or not valid_timestamp(item.updated_at) then
		return nil, label .. " timestamps are invalid"
	end
	local has_reply = not null(item.reply_to)
	if has_reply and (type(item.reply_to) ~= "string" or not seen[item.reply_to]) then
		return nil, label .. ".reply_to must reference an earlier item"
	end
	if item.status == "reply" and not has_reply then
		return nil, label .. ".reply status requires reply_to"
	end
	if item.status == "draft" and has_reply then
		return nil, label .. ".draft status cannot be a reply"
	end
	if item.status == "exported" then
		if not valid_timestamp(item.exported_at) then
			return nil, label .. ".exported_at is invalid"
		end
		local export_ok, export_err = bounded_string(item.export_id, 512, label .. ".export_id")
		if not export_ok then
			return nil, export_err
		end
	elseif not null(item.exported_at) or not null(item.export_id) then
		return nil, label .. " has export metadata before export"
	end
	seen[item.id] = true
	local copy = vim.deepcopy(item)
	copy.anchor = anchor
	return copy
end

local function validate_session(session, root, deps)
	if not object(session) then
		return nil, "session must be an object"
	end
	local keys_ok, keys_err = exact_keys(session, SESSION_KEYS, "session")
	if not keys_ok then
		return nil, keys_err
	end
	for _, key in ipairs({
		"version",
		"revision",
		"id",
		"repo_root",
		"repo_hash",
		"scope",
		"stale",
		"created_at",
		"updated_at",
		"next_sequence",
		"items",
	}) do
		if session[key] == nil then
			return nil, "session is missing " .. key
		end
	end
	if session.version ~= VERSION or session.repo_root ~= root or not valid_digest(session.id) then
		return nil, "session version, root, or id is invalid"
	end
	if type(session.revision) ~= "number" or session.revision < 0 or session.revision % 1 ~= 0 then
		return nil, "session.revision must be a non-negative integer"
	end
	local expected_repo_hash, hash_err = digest(root, deps)
	if not expected_repo_hash or session.repo_hash ~= expected_repo_hash then
		return nil, "session.repo_hash is invalid: " .. tostring(hash_err or "mismatch")
	end
	local scope, scope_err = validate_scope(session.scope, root, deps)
	if not scope or scope.id ~= session.id then
		return nil, "session scope is invalid: " .. tostring(scope_err or "id mismatch")
	end
	if type(session.stale) ~= "boolean" then
		return nil, "session.stale must be boolean"
	end
	local bridge, bridge_err = validate_bridge(session.bridge, session.id)
	if not bridge and bridge_err then
		return nil, bridge_err
	end
	if not valid_timestamp(session.created_at) or not valid_timestamp(session.updated_at) then
		return nil, "session timestamps are invalid"
	end
	if type(session.next_sequence) ~= "number" or session.next_sequence < 0 or session.next_sequence % 1 ~= 0 then
		return nil, "session.next_sequence must be a non-negative integer"
	end
	if type(session.items) ~= "table" or not vim.islist(session.items) then
		return nil, "session.items must be an array"
	end
	if #session.items > MAX_ITEMS then
		return nil, string.format("session.items contains %d entries; maximum is %d", #session.items, MAX_ITEMS)
	end
	local copy = vim.deepcopy(session)
	copy.scope = scope
	copy.bridge = bridge
	copy.items = {}
	local seen = {}
	local maximum_sequence = 0
	for index, item in ipairs(session.items) do
		local validated, item_err = validate_item(item, seen, deps, index)
		if not validated then
			return nil, item_err
		end
		maximum_sequence = math.max(maximum_sequence, item.sequence)
		copy.items[#copy.items + 1] = validated
	end
	if session.next_sequence < maximum_sequence then
		return nil, "session.next_sequence precedes an existing item"
	end
	return copy
end

local function directory_paths(deps, repo_hash)
	local config_root = vim.fs.joinpath(deps.state_home, "nvim-config")
	local reviews = vim.fs.joinpath(config_root, "reviews")
	local version = vim.fs.joinpath(reviews, "v1")
	local paths = { deps.state_home, config_root, reviews, version }
	if repo_hash then
		paths[#paths + 1] = vim.fs.joinpath(version, repo_hash)
	end
	return paths
end

local function ensure_directory(path, create, deps)
	local stat = deps.uv.fs_lstat(path)
	if not stat and not create then
		return nil, "missing"
	end
	if not stat then
		local ok, result = pcall(vim.fn.mkdir, path, "p", 448) -- 0700
		if not ok or (result ~= 0 and result ~= 1) then
			return nil, "cannot create review state directory"
		end
		stat = deps.uv.fs_lstat(path)
	end
	if not stat or stat.type ~= "directory" then
		return nil, "review state path is a symlink or non-directory: " .. path
	end
	local changed, chmod_err = deps.uv.fs_chmod(path, 448) -- 0700
	if not changed then
		return nil, "cannot secure review state directory: " .. tostring(chmod_err)
	end
	return true
end

local function repository_directory(root, create, deps)
	local repo_hash, hash_err = digest(root, deps)
	if not repo_hash then
		return nil, hash_err
	end
	local paths = directory_paths(deps, repo_hash)
	for _, path in ipairs(paths) do
		local ok, err = ensure_directory(path, create, deps)
		if not ok then
			return nil, err
		end
	end
	return paths[#paths], repo_hash
end

local function secure_file(path, deps)
	local stat = deps.uv.fs_lstat(path)
	if not stat or stat.type ~= "file" then
		return nil, "review state file is missing, a symlink, or non-regular"
	end
	if stat.size > MAX_BYTES then
		return nil, string.format("review state file is %d bytes; maximum is %d", stat.size, MAX_BYTES)
	end
	local changed, chmod_err = deps.uv.fs_chmod(path, 384) -- 0600
	if not changed then
		return nil, "cannot secure review state file: " .. tostring(chmod_err)
	end
	return stat
end

local function session_path(root, scope_id, create, deps)
	if not valid_digest(scope_id) then
		return nil, "scope id must be a lowercase SHA-256 digest"
	end
	local directory, directory_err = repository_directory(root, create, deps)
	if not directory then
		return nil, directory_err
	end
	return vim.fs.joinpath(directory, scope_id .. ".json")
end

local function read_lock_owner(lock_path, deps)
	local owner_path = vim.fs.joinpath(lock_path, LOCK_OWNER_NAME)
	local stat = deps.uv.fs_lstat(owner_path)
	if not stat then
		return nil, "missing", owner_path
	end
	if stat.type ~= "file" or stat.size > MAX_LOCK_BYTES then
		return nil, "lock owner metadata is unsafe", owner_path
	end
	local encoded, read_err = deps.fs.read_binary(owner_path)
	if not encoded then
		return nil, read_err, owner_path
	end
	local ok, owner = pcall(vim.json.decode, encoded)
	if not ok or not object(owner) then
		return nil, "lock owner metadata is invalid", owner_path
	end
	local keys_ok = exact_keys(owner, { created_at = true, pid = true, token = true }, "lock owner")
	if
		not keys_ok
		or owner.created_at == nil
		or owner.pid == nil
		or owner.token == nil
		or type(owner.pid) ~= "number"
		or owner.pid < 1
		or owner.pid % 1 ~= 0
		or type(owner.created_at) ~= "number"
		or owner.created_at < 0
		or not valid_digest(owner.token)
	then
		return nil, "lock owner metadata is invalid", owner_path
	end
	return owner, nil, owner_path
end

local function remove_lock(lock_path, owner_path, deps)
	if owner_path and deps.uv.fs_lstat(owner_path) then
		local removed, remove_err = deps.uv.fs_unlink(owner_path)
		if not removed then
			return nil, "cannot remove review lock owner: " .. tostring(remove_err)
		end
	end
	local removed, remove_err = deps.uv.fs_rmdir(lock_path)
	if not removed then
		return nil, "cannot remove review session lock: " .. tostring(remove_err)
	end
	return true
end

local function recover_stale_lock(lock_path, deps)
	local stat = deps.uv.fs_lstat(lock_path)
	if not stat or stat.type ~= "directory" then
		return nil, "review lock is a symlink or non-directory"
	end
	local owner, owner_err, owner_path = read_lock_owner(lock_path, deps)
	if owner then
		if deps.process_alive(owner.pid) then
			return nil, "review session is being saved by process " .. owner.pid
		end
		return remove_lock(lock_path, owner_path, deps)
	end
	local modified = stat.mtime and stat.mtime.sec or deps.time()
	if deps.time() - modified < LOCK_STALE_SECONDS then
		return nil, "review session lock is incomplete; retry shortly"
	end
	if owner_err ~= "missing" then
		local owner_stat = deps.uv.fs_lstat(owner_path)
		if not owner_stat or owner_stat.type ~= "file" then
			return nil, owner_err
		end
	end
	return remove_lock(lock_path, owner_path, deps)
end

local function acquire_lock(path, deps)
	local lock_path = path .. ".lock"
	local locked, lock_err = deps.uv.fs_mkdir(lock_path, 448) -- 0700
	if not locked then
		local recovered, recover_err = recover_stale_lock(lock_path, deps)
		if not recovered then
			return nil, recover_err .. ": " .. tostring(lock_err)
		end
		locked, lock_err = deps.uv.fs_mkdir(lock_path, 448)
		if not locked then
			return nil, "review session lock was claimed concurrently: " .. tostring(lock_err)
		end
	end
	local pid = deps.uv.os_getpid()
	local token = deps.hash(table.concat({ tostring(pid), tostring(deps.uv.hrtime()), path }, "\0"))
	local owner = { created_at = deps.time(), pid = pid, token = token }
	local owner_path = vim.fs.joinpath(lock_path, LOCK_OWNER_NAME)
	local wrote, write_err = deps.fs.write_binary_atomic(owner_path, vim.json.encode(owner) .. "\n")
	if not wrote then
		deps.uv.fs_rmdir(lock_path)
		return nil, "cannot record review session lock owner: " .. tostring(write_err)
	end
	return { path = lock_path, owner_path = owner_path, token = token }
end

local function release_lock(lock, deps)
	local owner, owner_err = read_lock_owner(lock.path, deps)
	if not owner or owner.token ~= lock.token then
		return nil, owner_err or "review session lock ownership changed"
	end
	return remove_lock(lock.path, lock.owner_path, deps)
end

local function with_session_lock(path, deps, callback)
	local lock, lock_err = acquire_lock(path, deps)
	if not lock then
		return nil, lock_err
	end
	local called, first, second = pcall(callback)
	local released, release_err = release_lock(lock, deps)
	if not called then
		return nil, tostring(first)
	end
	if not released then
		return nil, "could not release review session lock: " .. tostring(release_err)
	end
	return first, second
end

local function read_session(root, scope_id, deps)
	local path, path_err = session_path(root, scope_id, false, deps)
	if not path then
		return nil, path_err
	end
	local stat, stat_err = secure_file(path, deps)
	if not stat then
		return nil, stat_err
	end
	local encoded, read_err = deps.fs.read_binary(path)
	if not encoded then
		return nil, read_err
	end
	if #encoded > MAX_BYTES or not valid_utf8(encoded) then
		return nil, "review state JSON exceeds its limit or is not valid UTF-8"
	end
	local ok, value = pcall(vim.json.decode, encoded)
	if not ok then
		return nil, "review state file is not strict JSON"
	end
	local session, session_err = validate_session(value, root, deps)
	if not session then
		return nil, session_err
	end
	return session, path
end

local function find_item(session, id)
	for index, item in ipairs(session.items) do
		if item.id == id then
			return item, index
		end
	end
	return nil
end

local function touch(session, deps)
	session.updated_at = deps.now()
	return session
end

local function mutate(session, options, callback)
	local deps = make_dependencies(options)
	local root, root_err = canonical_root(session and session.repo_root, deps)
	if not root then
		return nil, root_err
	end
	local copy, validation_err = validate_session(session, root, deps)
	if not copy then
		return nil, validation_err
	end
	local ok, err = callback(copy, deps)
	if not ok then
		return nil, err
	end
	touch(copy, deps)
	return validate_session(copy, root, deps)
end

function M.new(root, scope, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	local validated_scope, scope_err = validate_scope(scope, resolved_root, deps)
	if not validated_scope then
		return nil, scope_err
	end
	local repo_hash, hash_err = digest(resolved_root, deps)
	if not repo_hash then
		return nil, hash_err
	end
	local now = deps.now()
	local session = {
		version = VERSION,
		revision = 0,
		id = validated_scope.id,
		repo_root = resolved_root,
		repo_hash = repo_hash,
		scope = validated_scope,
		stale = false,
		created_at = now,
		updated_at = now,
		next_sequence = 0,
		items = {},
	}
	return validate_session(session, resolved_root, deps)
end

function M.load(root, scope_id, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	return read_session(resolved_root, scope_id, deps)
end

function M.save(root, session, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	local validated, validation_err = validate_session(session, resolved_root, deps)
	if not validated then
		return nil, validation_err
	end
	local path, path_err = session_path(resolved_root, validated.id, true, deps)
	if not path then
		return nil, path_err
	end
	return with_session_lock(path, deps, function()
		local existing = deps.uv.fs_lstat(path)
		if existing and existing.type ~= "file" then
			return nil, "review state target is a symlink or non-regular file"
		end
		if existing then
			local current, read_err = read_session(resolved_root, validated.id, deps)
			if not current then
				return nil, read_err
			end
			if current.revision ~= validated.revision then
				return nil, "review changed in another Neovim; reopen the saved session and retry"
			end
		elseif validated.revision ~= 0 then
			return nil, "saved review disappeared; reopen the review scope before writing"
		end
		local persisted = vim.deepcopy(validated)
		persisted.revision = persisted.revision + 1
		local encoded = vim.json.encode(persisted) .. "\n"
		if #encoded > MAX_BYTES then
			return nil, string.format("review state is %d bytes; maximum is %d", #encoded, MAX_BYTES)
		end
		local wrote, write_err = deps.fs.write_binary_atomic(path, encoded)
		if not wrote then
			return nil, write_err
		end
		local secured, secure_err = secure_file(path, deps)
		if not secured then
			return nil, secure_err
		end
		return persisted, path
	end)
end

function M.list(root, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	local directory, directory_err = repository_directory(resolved_root, false, deps)
	if not directory then
		if directory_err == "missing" then
			return {}
		end
		return nil, directory_err
	end
	local handle, scan_err = deps.uv.fs_scandir(directory)
	if not handle then
		return nil, "cannot list review sessions: " .. tostring(scan_err)
	end
	local sessions = {}
	while true do
		local name, entry_type = deps.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if name:sub(-5) == ".json" then
			local id = name:sub(1, -6)
			if not valid_digest(id) or entry_type ~= "file" then
				return nil, "review state directory contains an unsafe session entry: " .. name
			end
			local session, load_err = read_session(resolved_root, id, deps)
			if not session then
				return nil, load_err
			end
			sessions[#sessions + 1] = session
		end
	end
	table.sort(sessions, function(left, right)
		if left.updated_at == right.updated_at then
			return left.id < right.id
		end
		return left.updated_at > right.updated_at
	end)
	return sessions
end

function M.add(session, values, options)
	return mutate(session, options, function(copy, deps)
		if #copy.items >= MAX_ITEMS then
			return nil, string.format("session.items maximum is %d", MAX_ITEMS)
		end
		if not object(values) then
			return nil, "new review item must be an object"
		end
		local keys_ok, keys_err = exact_keys(values, ADD_KEYS, "new review item")
		if not keys_ok then
			return nil, keys_err
		end
		if not TYPES[values.type] then
			return nil, "review item type must be one of the six supported types"
		end
		local body_ok, body_err = bounded_string(values.body, MAX_BODY, "review item body")
		if not body_ok then
			return nil, body_err
		end
		local anchor, anchor_err = normalize_anchor(values.anchor, deps)
		if not anchor then
			return nil, anchor_err
		end
		copy.next_sequence = copy.next_sequence + 1
		local now = deps.now()
		local id, id_err = item_id(copy.id, copy.next_sequence, deps)
		if not id then
			return nil, id_err
		end
		copy.items[#copy.items + 1] = {
			id = id,
			sequence = copy.next_sequence,
			type = values.type,
			body = values.body,
			anchor = anchor,
			status = "draft",
			reply_to = vim.NIL,
			created_at = now,
			updated_at = now,
			exported_at = vim.NIL,
			export_id = vim.NIL,
		}
		return true
	end)
end

function M.link_tuicr(session, round, options)
	return mutate(session, options, function(copy, deps)
		if not valid_uuid(round) then
			return nil, "TUICR round must be a canonical lowercase UUID"
		end
		if copy.bridge then
			if copy.bridge.round == round then
				return true
			end
			return nil, "review is already linked to a different TUICR round"
		end
		for _, item in ipairs(copy.items) do
			if item.status == "exported" then
				return nil, "link TUICR before exporting review comments to another backend"
			end
		end
		copy.bridge = {
			backend = "tuicr",
			round = round,
			trusted_scope_id = copy.id,
			linked_at = deps.now(),
		}
		return true
	end)
end

function M.edit(session, id, changes, options)
	return mutate(session, options, function(copy, deps)
		local item = find_item(copy, id)
		if not item then
			return nil, "review item does not exist"
		end
		if item.status == "exported" then
			return nil, "exported review items are immutable"
		end
		if not object(changes) then
			return nil, "review item changes must be an object"
		end
		local keys_ok, keys_err = exact_keys(changes, EDIT_KEYS, "review item changes")
		if not keys_ok then
			return nil, keys_err
		end
		if changes.type ~= nil then
			if not TYPES[changes.type] then
				return nil, "review item type must be one of the six supported types"
			end
			item.type = changes.type
		end
		if changes.body ~= nil then
			local body_ok, body_err = bounded_string(changes.body, MAX_BODY, "review item body")
			if not body_ok then
				return nil, body_err
			end
			item.body = changes.body
		end
		if changes.anchor ~= nil then
			local anchor, anchor_err = normalize_anchor(changes.anchor, deps)
			if not anchor then
				return nil, anchor_err
			end
			item.anchor = anchor
		end
		item.status = null(item.reply_to) and "draft" or "reply"
		item.updated_at = deps.now()
		return true
	end)
end

function M.set_type(session, id, item_type, options)
	return mutate(session, options, function(copy, deps)
		local item = find_item(copy, id)
		if not item then
			return nil, "review item does not exist"
		end
		if item.status == "exported" then
			return nil, "exported review items are immutable"
		end
		if not TYPES[item_type] then
			return nil, "review item type must be one of the six supported types"
		end
		item.type = item_type
		item.updated_at = deps.now()
		return true
	end)
end

function M.delete(session, id, options)
	return mutate(session, options, function(copy)
		local item, index = find_item(copy, id)
		if not item then
			return nil, "review item does not exist"
		end
		if item.status == "exported" then
			return nil, "exported review items are immutable"
		end
		for _, candidate in ipairs(copy.items) do
			if candidate.reply_to == id then
				return nil, "review item has replies and cannot be deleted"
			end
		end
		table.remove(copy.items, index)
		return true
	end)
end

function M.reply(session, parent_id, values, options)
	return mutate(session, options, function(copy, deps)
		if #copy.items >= MAX_ITEMS then
			return nil, string.format("session.items maximum is %d", MAX_ITEMS)
		end
		local parent = find_item(copy, parent_id)
		if not parent then
			return nil, "reply target does not exist"
		end
		if not object(values) then
			return nil, "reply must be an object"
		end
		local keys_ok, keys_err = exact_keys(values, ADD_KEYS, "reply")
		if not keys_ok then
			return nil, keys_err
		end
		local item_type = values.type or parent.type
		if not TYPES[item_type] then
			return nil, "reply type must be one of the six supported types"
		end
		local body_ok, body_err = bounded_string(values.body, MAX_BODY, "reply body")
		if not body_ok then
			return nil, body_err
		end
		local anchor, anchor_err = normalize_anchor(values.anchor or parent.anchor, deps)
		if not anchor then
			return nil, anchor_err
		end
		copy.next_sequence = copy.next_sequence + 1
		local now = deps.now()
		local id, id_err = item_id(copy.id, copy.next_sequence, deps)
		if not id then
			return nil, id_err
		end
		copy.items[#copy.items + 1] = {
			id = id,
			sequence = copy.next_sequence,
			type = item_type,
			body = values.body,
			anchor = anchor,
			status = "reply",
			reply_to = parent_id,
			created_at = now,
			updated_at = now,
			exported_at = vim.NIL,
			export_id = vim.NIL,
		}
		return true
	end)
end

function M.set_status(session, id, status, options)
	return mutate(session, options, function(copy, deps)
		local item = find_item(copy, id)
		if not item then
			return nil, "review item does not exist"
		end
		if item.status == "exported" then
			return nil, "exported review items are immutable"
		end
		local is_reply = not null(item.reply_to)
		if status ~= "resolved" and status ~= (is_reply and "reply" or "draft") then
			return nil, "status transition is invalid for this review item"
		end
		item.status = status
		item.updated_at = deps.now()
		return true
	end)
end

function M.mark_exported(session, id, export_id, options)
	return mutate(session, options, function(copy, deps)
		local item = find_item(copy, id)
		if not item then
			return nil, "review item does not exist"
		end
		if item.status == "exported" then
			return nil, "review item is already exported"
		end
		local export_ok, export_err = bounded_string(export_id, 512, "export id")
		if not export_ok then
			return nil, export_err
		end
		local now = deps.now()
		item.status = "exported"
		item.export_id = export_id
		item.exported_at = now
		item.updated_at = now
		return true
	end)
end

---Persist one complete Markdown snapshot before an unsaved review is discarded.
---@param root string
---@param session table
---@param markdown string
---@param options? table
---@return table? receipt
---@return string? error_message
function M.save_recovery(root, session, markdown, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	local validated, validation_err = validate_session(session, resolved_root, deps)
	if not validated then
		return nil, validation_err
	end
	if type(markdown) ~= "string" or markdown == "" or #markdown > MAX_RECOVERY_BYTES or not valid_utf8(markdown) then
		return nil, string.format("recovery Markdown must be valid UTF-8 within %d bytes", MAX_RECOVERY_BYTES)
	end
	local directory, directory_err = repository_directory(resolved_root, true, deps)
	if not directory then
		return nil, directory_err
	end
	local recovery_digest, digest_err = digest(markdown, deps)
	if not recovery_digest then
		return nil, digest_err
	end
	local path = vim.fs.joinpath(directory, "recovery-" .. validated.id .. "-" .. recovery_digest .. ".md")
	local existing = deps.uv.fs_lstat(path)
	if existing and existing.type ~= "file" then
		return nil, "review recovery target is a symlink or non-regular file"
	end
	local wrote, write_err = deps.fs.write_binary_atomic(path, markdown)
	if not wrote then
		return nil, write_err
	end
	local stat = deps.uv.fs_lstat(path)
	if not stat or stat.type ~= "file" or stat.size > MAX_RECOVERY_BYTES then
		return nil, "review recovery file is missing, unsafe, or too large"
	end
	local secured, secure_err = deps.uv.fs_chmod(path, 384) -- 0600
	if not secured then
		return nil, "cannot secure review recovery file: " .. tostring(secure_err)
	end
	return { path = path, digest = recovery_digest }
end

---Verify that a recovery receipt still identifies its unchanged owner-only file.
---@param root string
---@param receipt table
---@param options? table
---@return boolean
---@return string? error_message
function M.verify_recovery(root, receipt, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return false, root_err
	end
	if not object(receipt) or type(receipt.path) ~= "string" or not valid_digest(receipt.digest) then
		return false, "review recovery receipt is invalid"
	end
	local keys_ok, keys_err = exact_keys(receipt, { path = true, digest = true }, "review recovery receipt")
	if not keys_ok then
		return false, keys_err
	end
	local directory, directory_err = repository_directory(resolved_root, false, deps)
	if not directory then
		return false, directory_err
	end
	if receipt.path:sub(1, #directory + 1) ~= directory .. "/" then
		return false, "review recovery file is outside its repository state directory"
	end
	local stat = deps.uv.fs_lstat(receipt.path)
	if
		not stat
		or stat.type ~= "file"
		or stat.size > MAX_RECOVERY_BYTES
		or type(stat.mode) ~= "number"
		or stat.mode % 512 ~= 384
	then
		return false, "review recovery file is missing, unsafe, or too large"
	end
	local markdown, read_err = deps.fs.read_binary(receipt.path)
	if not markdown then
		return false, read_err
	end
	local current_digest, digest_err = digest(markdown, deps)
	if not current_digest or current_digest ~= receipt.digest then
		return false, "review recovery file changed: " .. tostring(digest_err or "digest mismatch")
	end
	return true
end

M.max_bytes = MAX_BYTES
M.max_items = MAX_ITEMS
M.max_anchor_context = MAX_ANCHOR_CONTEXT
M.types = vim.deepcopy(TYPES)

return M
