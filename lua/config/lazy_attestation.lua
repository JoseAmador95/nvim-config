-- Positive checkout authority is deliberately metadata-bound, not time-bound.
-- A fast hit is valid only while the private cache, resolved HEAD/ref material,
-- Git index/shared-index set, checkout root, and every non-.git worktree entry
-- retain the exact owner-controlled identity stored after an authoritative Git
-- inspection. A hit reads that receipt first, then validates its bounded path
-- set twice around HEAD/index inspection without readdir; directory identities
-- detect additions, removals, and renames. Cache creation uses one exhaustive
-- snapshot before Git and one after it, followed by a final path revalidation.
-- Enumerating every entry preserves
-- detection of new ignored/untracked paths. `doc/tags` is the sole normalized
-- exception and must remain a safe regular file. Any ambiguity, unsafe metadata,
-- cache corruption, or before/after race falls back to Git or fails closed; a
-- cache miss is never authority by itself.
local M = {}

local fs = require("config.fs")
local uv = vim.uv

local SCHEMA_VERSION = 2
local CHECKOUT_SCHEMA_VERSION = 1
local MAX_CACHE_BYTES = 64 * 1024
local MAX_CHECKOUT_CACHE_BYTES = 512 * 1024
local MAX_INDEX_BYTES = 16 * 1024 * 1024
local MAX_SHARED_INDEXES = 64
local MAX_HEAD_BYTES = 1024 * 1024
local MAX_HEAD_FILES = 16
local MAX_WORKTREE_ENTRIES = 4096
local MAX_WORKTREE_PATH_BYTES = 1024 * 1024
local MAX_LSTAT_IN_FLIGHT = 32
local LSTAT_TIMEOUT_MS = 30000

local function same_identity(left, right)
	local left_mtime = left and left.mtime or {}
	local right_mtime = right and right.mtime or {}
	local left_ctime = left and left.ctime or {}
	local right_ctime = right and right.ctime or {}
	return left
		and right
		and left.type == right.type
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.uid == right.uid
		and left.gid == right.gid
		and left.nlink == right.nlink
		and left_mtime.sec == right_mtime.sec
		and left_mtime.nsec == right_mtime.nsec
		and left_ctime.sec == right_ctime.sec
		and left_ctime.nsec == right_ctime.nsec
end

local function exact_keys(value, allowed)
	if type(value) ~= "table" or vim.islist(value) then
		return false
	end
	for key in pairs(value) do
		if not allowed[key] then
			return false
		end
	end
	for key in pairs(allowed) do
		if value[key] == nil then
			return false
		end
	end
	return true
end

local SNAPSHOT_KEYS = {
	git_dir = true,
	git_dir_identity = true,
	files = true,
}
local IDENTITY_KEYS = {
	dev = true,
	ino = true,
	mode = true,
	uid = true,
	gid = true,
	nlink = true,
	size = true,
	mtime_sec = true,
	mtime_nsec = true,
	ctime_sec = true,
	ctime_nsec = true,
}
local FILE_KEYS = vim.tbl_extend("force", { name = true }, IDENTITY_KEYS)
local CHECKOUT_FILE_KEYS = vim.tbl_extend("force", { name = true, digest = true }, IDENTITY_KEYS)
local WORKTREE_ENTRY_KEYS = vim.tbl_extend("force", { path = true, type = true }, IDENTITY_KEYS)
local CHECKOUT_SNAPSHOT_KEYS = {
	head = true,
	index = true,
	worktree = true,
}
local HEAD_SNAPSHOT_KEYS = {
	files = true,
	resolved = true,
}
local WORKTREE_SNAPSHOT_KEYS = {
	entries = true,
	root_identity = true,
}
local CHECKOUT_RECORD_KEYS = {
	head = true,
	root = true,
	safe_checkout = true,
	schema_version = true,
	snapshot = true,
}

local function identity_record(stat)
	local mtime = stat.mtime or {}
	local ctime = stat.ctime or {}
	return {
		dev = stat.dev,
		ino = stat.ino,
		mode = stat.mode,
		uid = stat.uid,
		gid = stat.gid,
		nlink = stat.nlink,
		size = stat.size,
		mtime_sec = mtime.sec or 0,
		mtime_nsec = mtime.nsec or 0,
		ctime_sec = ctime.sec or 0,
		ctime_nsec = ctime.nsec or 0,
	}
end

local function valid_identity_record(value, keys)
	if not exact_keys(value, keys or IDENTITY_KEYS) then
		return false
	end
	for key in pairs(IDENTITY_KEYS) do
		if type(value[key]) ~= "number" then
			return false
		end
	end
	return true
end

local function read_regular(path, maximum, expected)
	local before = uv.fs_lstat(path)
	if
		not before
		or before.type ~= "file"
		or before.nlink ~= 1
		or before.size > maximum
		or (expected ~= nil and not same_identity(expected, before))
	then
		return nil
	end
	local fd = uv.fs_open(path, "r", 0)
	if not fd then
		return nil
	end
	local opened = uv.fs_fstat(fd)
	if not same_identity(before, opened) then
		pcall(uv.fs_close, fd)
		return nil
	end
	local data = uv.fs_read(fd, opened.size, 0)
	local after_fd = uv.fs_fstat(fd)
	local closed = uv.fs_close(fd)
	local after = uv.fs_lstat(path)
	if
		type(data) ~= "string"
		or #data ~= opened.size
		or not closed
		or not same_identity(opened, after_fd)
		or not same_identity(opened, after)
	then
		return nil
	end
	return data
end

local function owned_without_shared_writes(stat)
	return stat and (not uv.getuid or stat.uid == uv.getuid()) and bit.band(stat.mode, tonumber("22", 8)) == 0
end

local function private_cache_data(path, maximum)
	local parent = vim.fs.dirname(path)
	local parent_stat = uv.fs_lstat(parent)
	local parent_real = parent_stat and parent_stat.type == "directory" and uv.fs_realpath(parent) or nil
	if
		not parent_real
		or vim.fs.normalize(parent_real) ~= vim.fs.normalize(parent)
		or not owned_without_shared_writes(parent_stat)
		or bit.band(parent_stat.mode, tonumber("77", 8)) ~= 0
	then
		return nil
	end
	local stat = uv.fs_lstat(path)
	if
		not stat
		or stat.type ~= "file"
		or stat.nlink ~= 1
		or not owned_without_shared_writes(stat)
		or bit.band(stat.mode, tonumber("77", 8)) ~= 0
	then
		return nil
	end
	return read_regular(path, maximum, stat)
end

local function shared_indexes(git_dir)
	local result = {}
	local ok, err = pcall(function()
		for name, kind in vim.fs.dir(git_dir) do
			local oid = name:match("^sharedindex%.([0-9a-f]+)$")
			if kind == "file" and oid and (#oid == 40 or #oid == 64) then
				result[#result + 1] = name
			end
		end
	end)
	if not ok then
		return nil, tostring(err)
	end
	table.sort(result)
	if #result > MAX_SHARED_INDEXES then
		return nil, "too many shared index files"
	end
	return result
end

local function index_snapshot(root)
	local dotgit = vim.fs.joinpath(root, ".git")
	local dotgit_stat = uv.fs_lstat(dotgit)
	local git_dir = dotgit_stat and dotgit_stat.type == "directory" and uv.fs_realpath(dotgit) or nil
	if
		not git_dir
		or vim.fs.normalize(git_dir) ~= vim.fs.normalize(dotgit)
		or not owned_without_shared_writes(dotgit_stat)
	then
		return nil, "Git metadata is not a fixed real directory"
	end

	local before_names, names_err = shared_indexes(git_dir)
	if not before_names then
		return nil, names_err
	end
	local names = { "index" }
	vim.list_extend(names, before_names)
	local total = 0
	local files = {}
	for _, name in ipairs(names) do
		local path = vim.fs.joinpath(git_dir, name)
		local stat = uv.fs_lstat(path)
		if
			not stat
			or stat.type ~= "file"
			or stat.nlink ~= 1
			or (uv.getuid and stat.uid ~= uv.getuid())
			or bit.band(stat.mode, tonumber("22", 8)) ~= 0
		then
			return nil, "index material is not a single-link regular file"
		end
		local remaining = MAX_INDEX_BYTES - total
		if remaining < 0 or stat.size > remaining then
			return nil, "index material exceeds the cache bound"
		end
		total = total + stat.size
		if total > MAX_INDEX_BYTES then
			return nil, "index material exceeds the cache bound"
		end
		files[#files + 1] = vim.tbl_extend("force", { name = name }, identity_record(stat))
	end
	local after_names = shared_indexes(git_dir)
	if not after_names or not vim.deep_equal(before_names, after_names) then
		return nil, "shared index set changed while reading"
	end
	return {
		git_dir = vim.fs.normalize(git_dir),
		git_dir_identity = identity_record(dotgit_stat),
		files = files,
	}
end

local function safe_material(path, name, maximum)
	local stat = uv.fs_lstat(path)
	if
		not stat
		or stat.type ~= "file"
		or stat.nlink ~= 1
		or not owned_without_shared_writes(stat)
		or stat.size > maximum
	then
		return nil, "repository metadata is not a safe regular file: " .. name
	end
	local data = read_regular(path, maximum, stat)
	if not data then
		return nil, "repository metadata changed while reading: " .. name
	end
	return vim.tbl_extend("force", {
		name = name,
		digest = vim.fn.sha256(data),
	}, identity_record(stat)), data
end

local function valid_ref_name(name)
	if
		type(name) ~= "string"
		or not name:match("^refs/[%w%._/-]+$")
		or name:find("//", 1, true)
		or name:sub(-1) == "/"
	then
		return false
	end
	for component in name:gmatch("[^/]+") do
		if component == "." or component == ".." or component:sub(1, 1) == "." or component:sub(-5) == ".lock" then
			return false
		end
	end
	return true
end

local function head_snapshot(root, expected)
	local git_dir = vim.fs.joinpath(root, ".git")
	local files = {}
	local seen = {}
	local name = "HEAD"
	for _ = 1, MAX_HEAD_FILES do
		if seen[name] then
			return nil, "symbolic HEAD contains a cycle"
		end
		seen[name] = true
		local path = vim.fs.joinpath(git_dir, name)
		local material, data = safe_material(path, name, MAX_HEAD_BYTES)
		if not material then
			if name == "HEAD" or uv.fs_lstat(path) then
				return nil, data
			end
			local packed, packed_data =
				safe_material(vim.fs.joinpath(git_dir, "packed-refs"), "packed-refs", MAX_HEAD_BYTES)
			if not packed then
				return nil, packed_data
			end
			local resolved
			for line in packed_data:gmatch("[^\r\n]+") do
				local oid, ref = line:match("^([0-9a-f]+) ([^ ]+)$")
				if ref == name then
					if resolved then
						return nil, "packed refs contain a duplicate active ref"
					end
					resolved = oid
				end
			end
			if resolved ~= expected then
				return nil, "HEAD does not resolve to the locked commit"
			end
			files[#files + 1] = packed
			return { files = files, resolved = resolved }
		end
		files[#files + 1] = material
		local direct = data:match("^([0-9a-f]+)%s*$")
		if direct then
			if direct ~= expected then
				return nil, "HEAD does not resolve to the locked commit"
			end
			return { files = files, resolved = direct }
		end
		local target = data:match("^ref: ([^\r\n]+)%s*$")
		if not valid_ref_name(target) then
			return nil, "HEAD contains an unsafe symbolic ref"
		end
		name = target
	end
	return nil, "symbolic HEAD exceeds the traversal bound"
end

local function worktree_snapshot(root)
	local root_stat = uv.fs_lstat(root)
	local root_real = root_stat and root_stat.type == "directory" and uv.fs_realpath(root) or nil
	if not root_real or vim.fs.normalize(root_real) ~= root or not owned_without_shared_writes(root_stat) then
		return nil, "checkout root is not a fixed owner-controlled directory"
	end

	local entries = {}
	local path_bytes = 0
	local stack = { { path = root, relative = "", stat = root_stat } }
	while #stack > 0 do
		local directory = table.remove(stack)
		local before = directory.stat
		local ok, scan_err = pcall(function()
			for name in vim.fs.dir(directory.path) do
				if name == "." or name == ".." or name:find("/", 1, true) or name:find("\0", 1, true) then
					error("checkout contains an unsafe entry name")
				end
				local relative = directory.relative == "" and name or (directory.relative .. "/" .. name)
				local path = vim.fs.joinpath(directory.path, name)
				local stat = uv.fs_lstat(path)
				if not stat then
					error("checkout entry disappeared while scanning: " .. relative)
				end
				if relative == ".git" then
					local real = stat.type == "directory" and uv.fs_realpath(path) or nil
					if not real or vim.fs.normalize(real) ~= vim.fs.normalize(path) then
						error("Git metadata is not a fixed real directory")
					end
				elseif relative == "doc/tags" then
					-- Neovim owns this ignored, non-executable helptags index. Match the
					-- authoritative Git exception exactly: only a safe regular file is
					-- normalized out of the worktree snapshot.
					if stat.type ~= "file" or stat.nlink ~= 1 or not owned_without_shared_writes(stat) then
						error("doc/tags is not a safe generated file")
					end
				else
					if
						(stat.type ~= "file" and stat.type ~= "directory")
						or not owned_without_shared_writes(stat)
						or (stat.type == "file" and stat.nlink ~= 1)
					then
						error("checkout contains unsafe metadata: " .. relative)
					end
					path_bytes = path_bytes + #relative
					if #entries >= MAX_WORKTREE_ENTRIES or path_bytes > MAX_WORKTREE_PATH_BYTES then
						error("checkout exceeds the attestation cache bound")
					end
					entries[#entries + 1] = vim.tbl_extend("force", {
						path = relative,
						type = stat.type,
					}, identity_record(stat))
					if stat.type == "directory" then
						stack[#stack + 1] = { path = path, relative = relative, stat = stat }
					end
				end
			end
		end)
		if not ok then
			return nil, tostring(scan_err)
		end
		local after = uv.fs_lstat(directory.path)
		if not same_identity(before, after) then
			return nil,
				"checkout directory changed while scanning: "
					.. (directory.relative ~= "" and directory.relative or ".")
		end
	end
	table.sort(entries, function(left, right)
		return left.path < right.path
	end)
	return { root_identity = identity_record(root_stat), entries = entries }
end

local function checkout_snapshot(root, head)
	root = vim.fs.normalize(root)
	local index_before, index_err = index_snapshot(root)
	if not index_before then
		return nil, index_err
	end
	local head_before, head_err = head_snapshot(root, head)
	if not head_before then
		return nil, head_err
	end
	local worktree, worktree_err = worktree_snapshot(root)
	if not worktree then
		return nil, worktree_err
	end
	local head_after = head_snapshot(root, head)
	local index_after = index_snapshot(root)
	if
		not head_after
		or not index_after
		or not vim.deep_equal(head_before, head_after)
		or not vim.deep_equal(index_before, index_after)
	then
		return nil, "repository metadata changed while taking the checkout snapshot"
	end
	return { head = head_after, index = index_after, worktree = worktree }
end

local function cache_record(path)
	local raw = private_cache_data(path, MAX_CACHE_BYTES)
	if not raw then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" or vim.islist(decoded) then
		return nil
	end
	if
		decoded.schema_version ~= SCHEMA_VERSION
		or decoded.safe_hidden_flags ~= true
		or type(decoded.root) ~= "string"
		or type(decoded.head) ~= "string"
		or not exact_keys(decoded, {
			schema_version = true,
			safe_hidden_flags = true,
			root = true,
			head = true,
			index = true,
		})
		or not exact_keys(decoded.index, SNAPSHOT_KEYS)
		or type(decoded.index.git_dir) ~= "string"
		or not valid_identity_record(decoded.index.git_dir_identity)
		or type(decoded.index.files) ~= "table"
		or not vim.islist(decoded.index.files)
	then
		return nil
	end
	for _, file in ipairs(decoded.index.files) do
		if
			not valid_identity_record(file, FILE_KEYS)
			or type(file.name) ~= "string"
			or not (file.name == "index" or file.name:match("^sharedindex%.[0-9a-f]+$"))
		then
			return nil
		end
	end
	return decoded
end

local function cache_matches(record, root, head, snapshot)
	return record and record.root == root and record.head == head and vim.deep_equal(record.index, snapshot)
end

local function valid_index_snapshot(value)
	if
		not exact_keys(value, SNAPSHOT_KEYS)
		or type(value.git_dir) ~= "string"
		or not valid_identity_record(value.git_dir_identity)
		or type(value.files) ~= "table"
		or not vim.islist(value.files)
		or #value.files < 1
		or #value.files > MAX_SHARED_INDEXES + 1
	then
		return false
	end
	local seen = {}
	for index, file in ipairs(value.files) do
		if
			not valid_identity_record(file, FILE_KEYS)
			or type(file.name) ~= "string"
			or (index == 1 and file.name ~= "index")
			or (index > 1 and not file.name:match("^sharedindex%.[0-9a-f]+$"))
			or seen[file.name]
		then
			return false
		end
		seen[file.name] = true
	end
	return true
end

local function valid_worktree_path(path)
	if
		type(path) ~= "string"
		or path == ""
		or path:find("\0", 1, true)
		or path:sub(1, 1) == "/"
		or path:sub(-1) == "/"
		or path:find("\\", 1, true)
		or path:match("^%a:")
	then
		return false
	end
	local first = true
	for component in path:gmatch("[^/]+") do
		if component == "." or component == ".." or (first and component == ".git") then
			return false
		end
		first = false
	end
	return not path:find("//", 1, true)
end

local function valid_checkout_snapshot(value)
	if not exact_keys(value, CHECKOUT_SNAPSHOT_KEYS) then
		return false
	end
	if
		not exact_keys(value.head, HEAD_SNAPSHOT_KEYS)
		or type(value.head.resolved) ~= "string"
		or type(value.head.files) ~= "table"
		or not vim.islist(value.head.files)
		or #value.head.files < 1
		or #value.head.files > MAX_HEAD_FILES
	then
		return false
	end
	local seen_head = {}
	for index, file in ipairs(value.head.files) do
		if
			not valid_identity_record(file, CHECKOUT_FILE_KEYS)
			or type(file.name) ~= "string"
			or type(file.digest) ~= "string"
			or #file.digest ~= 64
			or not file.digest:match("^[0-9a-f]+$")
			or (index == 1 and file.name ~= "HEAD")
			or (file.name ~= "HEAD" and file.name ~= "packed-refs" and not valid_ref_name(file.name))
			or seen_head[file.name]
		then
			return false
		end
		seen_head[file.name] = true
	end
	if not valid_index_snapshot(value.index) then
		return false
	end
	if
		not exact_keys(value.worktree, WORKTREE_SNAPSHOT_KEYS)
		or not valid_identity_record(value.worktree.root_identity)
		or type(value.worktree.entries) ~= "table"
		or not vim.islist(value.worktree.entries)
		or #value.worktree.entries > MAX_WORKTREE_ENTRIES
	then
		return false
	end
	local previous = ""
	local path_bytes = 0
	for _, entry in ipairs(value.worktree.entries) do
		if
			not valid_identity_record(entry, WORKTREE_ENTRY_KEYS)
			or not valid_worktree_path(entry.path)
			or entry.path <= previous
			or entry.path == "doc/tags"
			or (entry.type ~= "file" and entry.type ~= "directory")
		then
			return false
		end
		previous = entry.path
		path_bytes = path_bytes + #entry.path
		if path_bytes > MAX_WORKTREE_PATH_BYTES then
			return false
		end
	end
	return true
end

local function checkout_cache_record(path)
	local raw = private_cache_data(path, MAX_CHECKOUT_CACHE_BYTES)
	if not raw then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if
		not ok
		or not exact_keys(decoded, CHECKOUT_RECORD_KEYS)
		or decoded.schema_version ~= CHECKOUT_SCHEMA_VERSION
		or decoded.safe_checkout ~= true
		or type(decoded.root) ~= "string"
		or type(decoded.head) ~= "string"
		or not valid_checkout_snapshot(decoded.snapshot)
	then
		return nil
	end
	return decoded
end

local function stat_matches_record(stat, record, kind)
	return stat
		and stat.type == kind
		and stat.dev == record.dev
		and stat.ino == record.ino
		and stat.mode == record.mode
		and stat.uid == record.uid
		and stat.gid == record.gid
		and stat.nlink == record.nlink
		and stat.size == record.size
		and (stat.mtime or {}).sec == record.mtime_sec
		and (stat.mtime or {}).nsec == record.mtime_nsec
		and (stat.ctime or {}).sec == record.ctime_sec
		and (stat.ctime or {}).nsec == record.ctime_nsec
end

local function checkout_identity_paths(root, snapshot)
	local git_dir = vim.fs.normalize(vim.fs.joinpath(root, ".git"))
	if snapshot.index.git_dir ~= git_dir then
		return nil, "cached Git directory does not belong to the checkout"
	end
	local result = {}
	local seen = {}
	local function add(path, expected, kind, generated_tags)
		path = vim.fs.normalize(path)
		if seen[path] then
			return nil
		end
		seen[path] = true
		result[#result + 1] = { path = path, expected = expected, kind = kind, generated_tags = generated_tags }
		return true
	end
	if not add(root, snapshot.worktree.root_identity, "directory") then
		return nil, "cached checkout paths are not unique"
	end
	for _, entry in ipairs(snapshot.worktree.entries) do
		if not add(vim.fs.joinpath(root, entry.path), entry, entry.type) then
			return nil, "cached checkout paths are not unique"
		end
	end
	if not add(git_dir, snapshot.index.git_dir_identity, "directory") then
		return nil, "cached checkout paths are not unique"
	end
	for _, file in ipairs(snapshot.index.files) do
		if not add(vim.fs.joinpath(git_dir, file.name), file, "file") then
			return nil, "cached checkout paths are not unique"
		end
	end
	for _, file in ipairs(snapshot.head.files) do
		if not add(vim.fs.joinpath(git_dir, file.name), file, "file") then
			return nil, "cached checkout paths are not unique"
		end
	end
	add(vim.fs.joinpath(root, "doc", "tags"), nil, nil, true)
	return result
end

local function lstat_batch(items)
	local results = {}
	local requests = {}
	local next_index = 1
	local active = 0
	local finished = 0
	local aborted = false
	local pump
	pump = function()
		while not aborted and active < MAX_LSTAT_IN_FLIGHT and next_index <= #items do
			local index = next_index
			next_index = next_index + 1
			active = active + 1
			local request, submit_err = uv.fs_lstat(items[index].path, function(err, stat)
				requests[index] = nil
				active = active - 1
				finished = finished + 1
				results[index] = { error = err, stat = stat }
				pump()
			end)
			if request then
				requests[index] = request
			else
				active = active - 1
				finished = finished + 1
				results[index] = { error = submit_err }
			end
		end
	end
	pump()
	if not vim.wait(LSTAT_TIMEOUT_MS, function()
		return finished == #items
	end, 2) then
		aborted = true
		for _, request in pairs(requests) do
			pcall(uv.cancel, request)
		end
		return nil, "cached checkout identity validation timed out"
	end
	return results
end

local function validate_checkout_paths(root, snapshot)
	local items, items_err = checkout_identity_paths(root, snapshot)
	if not items then
		return nil, items_err
	end
	local results, results_err = lstat_batch(items)
	if not results then
		return nil, results_err
	end
	for index, item in ipairs(items) do
		local result = results[index]
		local stat = result and result.stat or nil
		if item.generated_tags then
			if stat and (stat.type ~= "file" or stat.nlink ~= 1 or not owned_without_shared_writes(stat)) then
				return nil, "doc/tags is not a safe generated file"
			end
			if not stat and (not result or not tostring(result.error):match("^ENOENT")) then
				return nil, "cannot inspect generated doc/tags"
			end
		elseif
			not stat_matches_record(stat, item.expected, item.kind)
			or not owned_without_shared_writes(stat)
			or (item.kind == "file" and stat.nlink ~= 1)
		then
			return nil, "cached checkout identity changed: " .. item.path
		end
	end
	return true
end

local function checkout_cache_matches(record, root, head)
	if not record or record.root ~= root or record.head ~= head or record.snapshot.head.resolved ~= head then
		return false
	end
	local before = validate_checkout_paths(root, record.snapshot)
	if not before then
		return false
	end
	local current_head = head_snapshot(root, head)
	if not current_head or not vim.deep_equal(current_head, record.snapshot.head) then
		return false
	end
	return validate_checkout_paths(root, record.snapshot) == true
end

local function ensure_real_directory(path)
	path = vim.fs.normalize(path)
	local stat = uv.fs_lstat(path)
	if stat then
		local real = stat.type == "directory" and uv.fs_realpath(path) or nil
		return real and vim.fs.normalize(real) == path or nil
	end
	local parent = vim.fs.dirname(path)
	if parent == path or not ensure_real_directory(parent) then
		return nil
	end
	local created, create_err = uv.fs_mkdir(path, tonumber("700", 8))
	if not created and not tostring(create_err):find("EEXIST", 1, true) then
		return nil
	end
	stat = uv.fs_lstat(path)
	local real = stat and stat.type == "directory" and uv.fs_realpath(path) or nil
	return real and vim.fs.normalize(real) == path or nil
end

local function private_cache_parent(path)
	local parent = vim.fs.dirname(path)
	if not ensure_real_directory(parent) then
		return nil
	end
	local stat = uv.fs_lstat(parent)
	return stat
			and stat.type == "directory"
			and owned_without_shared_writes(stat)
			and bit.band(stat.mode, tonumber("77", 8)) == 0
		or nil
end

local function write_private_cache(path, record)
	if not private_cache_parent(path) then
		return nil
	end
	local existing = uv.fs_lstat(path)
	if
		existing
		and (
			existing.type ~= "file"
			or existing.nlink ~= 1
			or not owned_without_shared_writes(existing)
			or bit.band(existing.mode, tonumber("77", 8)) ~= 0
		)
	then
		return nil
	end
	return fs.write_binary_atomic(path, vim.json.encode(record) .. "\n")
end

local function write_cache(path, root, head, snapshot)
	local record = {
		schema_version = SCHEMA_VERSION,
		safe_hidden_flags = true,
		root = root,
		head = head,
		index = snapshot,
	}
	write_private_cache(path, record)
end

local function hidden_entry(flags)
	for entry in flags:gmatch("[^%z]+") do
		local tag = entry:sub(1, 1)
		if tag == "S" or tag:match("%l") then
			return entry
		end
	end
	return nil
end

function M.default_cache_path()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "nvim-config", "lazy-index-flags-v2.json")
end

function M.default_checkout_cache_path()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "nvim-config", "lazy-checkout-v1.json")
end

function M.checkout_begin(opts)
	assert(type(opts) == "table", "lazy checkout attestation options must be a table")
	assert(type(opts.root) == "string" and opts.root ~= "", "lazy checkout attestation root is required")
	assert(type(opts.head) == "string" and opts.head ~= "", "lazy checkout attestation head is required")
	local root = vim.fs.normalize(opts.root)
	local cache_path = opts.cache_path or M.default_checkout_cache_path()
	if opts.allow_cache ~= false then
		local record = checkout_cache_record(cache_path)
		if checkout_cache_matches(record, root, opts.head) then
			return true, { cache_hit = true, snapshot = record.snapshot }
		end
	end
	local snapshot, snapshot_err = checkout_snapshot(root, opts.head)
	if not snapshot then
		return false, { cache_hit = false, reason = snapshot_err }
	end
	return false, {
		cache_hit = false,
		snapshot = snapshot,
	}
end

function M.checkout_commit(opts)
	assert(type(opts) == "table", "lazy checkout attestation options must be a table")
	assert(type(opts.root) == "string" and opts.root ~= "", "lazy checkout attestation root is required")
	assert(type(opts.head) == "string" and opts.head ~= "", "lazy checkout attestation head is required")
	if opts.before == nil then
		return true, { cached = false, reason = "checkout is not eligible for metadata caching" }
	end
	if not valid_checkout_snapshot(opts.before) or opts.before.head.resolved ~= opts.head then
		return nil, { kind = "invalid-before", detail = "invalid pre-inspection checkout snapshot" }
	end
	local root = vim.fs.normalize(opts.root)
	local after, after_err = checkout_snapshot(root, opts.head)
	if not after or not vim.deep_equal(opts.before, after) then
		return nil, { kind = "checkout-changed", detail = after_err or "checkout changed during inspection" }
	end
	local stable, stable_err = validate_checkout_paths(root, after)
	if not stable then
		return nil, { kind = "checkout-changed", detail = stable_err }
	end
	if opts.allow_cache == false then
		return true, { cached = false, reason = "checkout cache disabled" }
	end
	local cache_path = opts.cache_path or M.default_checkout_cache_path()
	local written = write_private_cache(cache_path, {
		schema_version = CHECKOUT_SCHEMA_VERSION,
		safe_checkout = true,
		root = root,
		head = opts.head,
		snapshot = after,
	})
	return true, {
		cached = written == true,
		reason = written and nil or "private checkout cache is unavailable",
	}
end

function M.verify(opts)
	assert(type(opts) == "table", "lazy attestation options must be a table")
	assert(type(opts.root) == "string" and opts.root ~= "", "lazy attestation root is required")
	assert(type(opts.head) == "string" and opts.head ~= "", "lazy attestation head is required")
	assert(type(opts.run_git) == "function", "lazy attestation run_git callback is required")

	local root = vim.fs.normalize(opts.root)
	local cache_path = opts.cache_path or M.default_cache_path()
	local snapshot
	if opts.allow_cache ~= false then
		snapshot = index_snapshot(root)
	end
	if snapshot and cache_matches(cache_record(cache_path), root, opts.head, snapshot) then
		return true, { cache_hit = true }
	end

	local code, flags, detail = opts.run_git({ "git", "-C", root, "ls-files", "-v", "-z" })
	if code ~= 0 then
		return nil, { kind = "inspect-failed", code = code, detail = detail }
	end
	local entry = hidden_entry(flags)
	if entry then
		return nil, { kind = "hidden-index-flags", entry = entry }
	end

	if snapshot then
		local after = index_snapshot(root)
		if not after or not vim.deep_equal(after, snapshot) then
			return nil, { kind = "index-changed" }
		end
		write_cache(cache_path, root, opts.head, after)
	end
	return true, { cache_hit = false }
end

M.SCHEMA_VERSION = SCHEMA_VERSION
M.CHECKOUT_SCHEMA_VERSION = CHECKOUT_SCHEMA_VERSION
M._index_snapshot = index_snapshot
M._checkout_snapshot = checkout_snapshot
M._read_regular = read_regular

return M
