-- Pure Git scope resolution for the native review workspace. Historical
-- revisions are frozen to object IDs; working reviews record an exact drift
-- fingerprint around Diffview's live aggregate. No command here updates refs,
-- the index, the worktree, or the object database.
local M = {}

local DEFAULT_BACKEND = "diffview"
local HASH_VERSION = "nvim-review-scope-v1"
local EXECUTABLE_BITS = tonumber("111", 8)

local COMMON_KEYS = { kind = true, backend_id = true }
local REQUEST_KEYS = {
	working = COMMON_KEYS,
	commit = { kind = true, backend_id = true, rev = true },
	range = { kind = true, backend_id = true, from = true, to = true },
	branch = { kind = true, backend_id = true, base = true, head = true },
}

local function failure(code, message, details)
	return { code = code, message = message, details = details or {} }
end

local function valid_oid(value)
	return type(value) == "string" and (#value == 40 or #value == 64) and value:match("^[0-9a-fA-F]+$") ~= nil
end

local function valid_ref(value)
	return type(value) == "string" and value ~= "" and #value <= 4096 and not value:find("%c")
end

local function valid_backend(value)
	return type(value) == "string" and #value >= 1 and #value <= 128 and value:match("^[%w_.:-]+$") ~= nil
end

local function exact_keys(value, allowed)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, "scope request contains unknown key " .. vim.inspect(key)
		end
	end
	return true
end

local function make_dependencies(options)
	options = options or {}
	local repo = options.repo or require("config.repo")
	return {
		repo = repo,
		root = options.root or repo.root,
		git = options.git,
		runner = options.runner,
		hash = options.hash or vim.fn.sha256,
		lstat = options.lstat or vim.uv.fs_lstat,
		readlink = options.readlink or vim.uv.fs_readlink,
	}
end

local function git(root, arguments, deps)
	if deps.git then
		return deps.git(root, vim.deepcopy(arguments))
	end
	return deps.repo.git(root, arguments, deps.runner)
end

local function canonical_root(root, deps)
	local resolved, err = deps.root(root, deps.runner)
	if not resolved then
		return nil, failure("repository_unavailable", tostring(err), { root = root })
	end
	return resolved
end

local function git_required(root, arguments, deps, code, context)
	local output, err = git(root, arguments, deps)
	if not output then
		return nil, failure(code, context .. ": " .. tostring(err), { argv = arguments })
	end
	return output
end

local function resolve_oid(root, revision, deps)
	if not valid_ref(revision) then
		return nil, failure("invalid_revision", "revision must be a non-empty string without control bytes")
	end
	local output, err = git_required(
		root,
		{ "rev-parse", "--verify", "--end-of-options", revision .. "^{commit}" },
		deps,
		"revision_unavailable",
		"cannot resolve " .. revision
	)
	if not output then
		return nil, err
	end
	local oid = vim.trim(output):lower()
	if not valid_oid(oid) or oid:find("\n", 1, true) then
		return nil, failure("invalid_git_output", "Git returned an invalid full object ID", { revision = revision })
	end
	return oid
end

local function digest(value, deps)
	local result = deps.hash(value)
	assert(type(result) == "string" and result:match("^[0-9a-fA-F]+$"), "hash dependency returned an invalid digest")
	return result:lower()
end

local function parse_nul_list(output)
	if output == "" then
		return {}
	end
	if output:sub(-1) ~= "\0" then
		return nil, "Git returned a malformed NUL-delimited path list"
	end
	local paths = {}
	local offset = 1
	while offset <= #output do
		local boundary = assert(output:find("\0", offset, true))
		if boundary > offset then
			paths[#paths + 1] = output:sub(offset, boundary - 1)
		end
		offset = boundary + 1
	end
	return paths
end

local function untracked_mode(root, path, deps)
	local full_path = vim.fs.joinpath(root, path)
	local stat, stat_err = deps.lstat(full_path)
	if not stat then
		return nil,
			nil,
			failure("working_tree_unavailable", "cannot inspect untracked file " .. path .. ": " .. tostring(stat_err))
	end
	if stat.type == "link" then
		local target, target_err = deps.readlink(full_path)
		if not target then
			return nil,
				nil,
				failure(
					"working_tree_unavailable",
					"cannot read untracked symlink " .. path .. ": " .. tostring(target_err)
				)
		end
		return "120000", digest("symlink\0" .. target, deps)
	end
	if stat.type ~= "file" or type(stat.mode) ~= "number" then
		return nil, nil, failure("working_tree_unavailable", "unsupported untracked file type for " .. path)
	end
	local mode = bit.band(stat.mode, EXECUTABLE_BITS) == 0 and "100644" or "100755"
	return mode
end

local function fingerprint_worktree(root, deps)
	local head, head_err = resolve_oid(root, "HEAD", deps)
	if not head then
		return nil, head_err
	end

	local staged, staged_err = git_required(root, {
		"diff",
		"--cached",
		"--binary",
		"--full-index",
		"--no-ext-diff",
		"--no-textconv",
		"--no-renames",
		"--",
	}, deps, "working_tree_unavailable", "cannot fingerprint staged changes")
	if not staged then
		return nil, staged_err
	end

	local unstaged, unstaged_err = git_required(root, {
		"diff",
		"--binary",
		"--full-index",
		"--no-ext-diff",
		"--no-textconv",
		"--no-renames",
		"--",
	}, deps, "working_tree_unavailable", "cannot fingerprint unstaged changes")
	if not unstaged then
		return nil, unstaged_err
	end

	local untracked_output, untracked_err = git_required(
		root,
		{ "ls-files", "--others", "--exclude-standard", "-z" },
		deps,
		"working_tree_unavailable",
		"cannot enumerate untracked files"
	)
	if not untracked_output then
		return nil, untracked_err
	end
	local paths, paths_err = parse_nul_list(untracked_output)
	if not paths then
		return nil, failure("invalid_git_output", paths_err)
	end
	table.sort(paths)
	local untracked_material = {}
	for _, path in ipairs(paths) do
		local mode, link_digest, mode_err = untracked_mode(root, path, deps)
		if not mode then
			return nil, mode_err
		end
		local content_id = link_digest
		if not content_id then
			local output, hash_err = git_required(
				root,
				{ "hash-object", "--no-filters", "--", path },
				deps,
				"working_tree_unavailable",
				"cannot fingerprint untracked file " .. path
			)
			if not output then
				return nil, hash_err
			end
			content_id = vim.trim(output):lower()
			if not valid_oid(content_id) then
				return nil,
					failure("invalid_git_output", "Git returned an invalid untracked content ID", { path = path })
			end
		end
		untracked_material[#untracked_material + 1] = table.concat({ path, mode, content_id }, "\0")
	end

	local layers = {
		head = head,
		staged = digest(staged, deps),
		unstaged = digest(unstaged, deps),
		untracked = digest(table.concat(untracked_material, "\0"), deps),
	}
	local fingerprint = digest(
		table.concat({ "working-v2", layers.head, layers.staged, layers.unstaged, layers.untracked }, "\0"),
		deps
	)
	return { head_oid = head, fingerprint = fingerprint, layers = layers }
end

local function split_lines(output)
	local values = {}
	for line in output:gmatch("[^\r\n]+") do
		if line ~= "" then
			values[#values + 1] = line
		end
	end
	return values
end

local function contains(values, expected)
	for _, value in ipairs(values) do
		if value == expected then
			return true
		end
	end
	return false
end

local function add_unique(values, value)
	if value and not contains(values, value) then
		values[#values + 1] = value
	end
end

local function upstream_remote(root, remotes, deps)
	local output = git(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, deps)
	if not output then
		return nil
	end
	local upstream = vim.trim(output)
	local best
	for _, remote in ipairs(remotes) do
		if upstream:sub(1, #remote + 1) == remote .. "/" and (not best or #remote > #best) then
			best = remote
		end
	end
	return best
end

local function default_branch(root, deps)
	local output, remotes_err =
		git_required(root, { "remote" }, deps, "remote_head_unavailable", "cannot enumerate Git remotes")
	if not output then
		return nil, remotes_err
	end
	local remotes = split_lines(output)
	local candidates = {}
	add_unique(candidates, upstream_remote(root, remotes, deps))
	if contains(remotes, "origin") then
		add_unique(candidates, "origin")
	end
	if #remotes == 1 then
		add_unique(candidates, remotes[1])
	end

	local attempted = {}
	for _, remote in ipairs(candidates) do
		attempted[#attempted + 1] = remote
		local symbolic = git(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/" .. remote .. "/HEAD" }, deps)
		if symbolic then
			local ref = vim.trim(symbolic)
			if valid_ref(ref) and ref:sub(1, #remote + 1) == remote .. "/" then
				local oid = resolve_oid(root, ref, deps)
				if oid then
					return { remote = remote, ref = ref, oid = oid }
				end
			end
		end
	end

	return nil,
		failure(
			"remote_head_unavailable",
			"no local remote symbolic HEAD is available; select a base branch explicitly",
			{ remotes = remotes, attempted = attempted }
		)
end

local function identity_fields(scope)
	if scope.kind == "working" then
		return { scope.head_oid, scope.fingerprint }
	elseif scope.kind == "commit" then
		return { scope.commit_oid }
	elseif scope.kind == "range" then
		return { scope.from_oid, scope.to_oid }
	elseif scope.kind == "branch" then
		return { scope.base_oid, scope.merge_base_oid, scope.head_oid }
	end
	return nil
end

function M.scope_id(root, scope, hasher)
	if type(root) ~= "string" or root == "" or type(scope) ~= "table" then
		return nil, "root and scope are required"
	end
	if not REQUEST_KEYS[scope.kind] or not valid_backend(scope.backend_id) then
		return nil, "scope kind or backend is invalid"
	end
	local fields = identity_fields(scope)
	if not fields then
		return nil, "scope identity fields are missing"
	end
	for _, value in ipairs(fields) do
		if type(value) ~= "string" or value == "" then
			return nil, "scope identity fields are missing"
		end
	end
	local hash = hasher or vim.fn.sha256
	return hash(table.concat(vim.list_extend({ HASH_VERSION, root, scope.backend_id, scope.kind }, fields), "\0")):lower()
end

local function finish(root, scope, deps)
	local id, id_err = M.scope_id(root, scope, deps.hash)
	if not id then
		return nil, failure("invalid_scope", id_err)
	end
	scope.id = id
	scope.version = 1
	scope.root = root
	return scope
end

local function resolve_working(root, request, deps)
	local snapshot, err = fingerprint_worktree(root, deps)
	if not snapshot then
		return nil, err
	end
	return finish(root, {
		kind = "working",
		backend_id = request.backend_id,
		label = "Live working tree @ " .. snapshot.head_oid:sub(1, 12),
		head_oid = snapshot.head_oid,
		fingerprint = snapshot.fingerprint,
		layers = snapshot.layers,
		diffview_args = {},
	}, deps)
end

local function resolve_commit(root, request, deps)
	local oid, err = resolve_oid(root, request.rev, deps)
	if not oid then
		return nil, err
	end
	local range = oid .. "^!"
	return finish(root, {
		kind = "commit",
		backend_id = request.backend_id,
		label = request.rev .. " (" .. oid:sub(1, 12) .. ")",
		commit_oid = oid,
		diffview_args = { range },
		file_history_range = range,
	}, deps)
end

local function resolve_range(root, request, deps)
	local from_oid, from_err = resolve_oid(root, request.from, deps)
	if not from_oid then
		return nil, from_err
	end
	local to_oid, to_err = resolve_oid(root, request.to, deps)
	if not to_oid then
		return nil, to_err
	end
	local range = from_oid .. ".." .. to_oid
	return finish(root, {
		kind = "range",
		backend_id = request.backend_id,
		label = request.from .. ".." .. request.to,
		from_oid = from_oid,
		to_oid = to_oid,
		diffview_args = { range },
		file_history_range = range,
	}, deps)
end

local function resolve_branch(root, request, deps)
	local base_ref = request.base
	local base_oid
	local remote
	if base_ref == nil then
		local default, default_err = default_branch(root, deps)
		if not default then
			return nil, default_err
		end
		base_ref = default.ref
		base_oid = default.oid
		remote = default.remote
	else
		local base_err
		base_oid, base_err = resolve_oid(root, base_ref, deps)
		if not base_oid then
			return nil, base_err
		end
	end

	local head_ref = request.head or "HEAD"
	local head_oid, head_err = resolve_oid(root, head_ref, deps)
	if not head_oid then
		return nil, head_err
	end
	local merge_output, merge_err = git_required(
		root,
		{ "merge-base", base_oid, head_oid },
		deps,
		"merge_base_unavailable",
		"cannot resolve branch merge base"
	)
	if not merge_output then
		return nil, merge_err
	end
	local merge_base = vim.trim(merge_output):lower()
	if not valid_oid(merge_base) then
		return nil, failure("invalid_git_output", "Git returned an invalid merge-base object ID")
	end
	local range = merge_base .. ".." .. head_oid
	return finish(root, {
		kind = "branch",
		backend_id = request.backend_id,
		label = base_ref .. "…" .. head_ref,
		base_ref = base_ref,
		head_ref = head_ref,
		default_remote = remote,
		base_oid = base_oid,
		merge_base_oid = merge_base,
		head_oid = head_oid,
		diffview_args = { range },
		file_history_range = range,
	}, deps)
end

function M.resolve(root, request, options)
	if type(request) ~= "table" or vim.islist(request) then
		return nil, failure("invalid_scope", "scope request must be an object")
	end
	local allowed = REQUEST_KEYS[request.kind]
	if not allowed then
		return nil, failure("invalid_scope", "kind must be working, commit, range, or branch")
	end
	local keys_ok, keys_err = exact_keys(request, allowed)
	if not keys_ok then
		return nil, failure("invalid_scope", keys_err)
	end
	request = vim.deepcopy(request)
	request.backend_id = request.backend_id or DEFAULT_BACKEND
	if not valid_backend(request.backend_id) then
		return nil, failure("invalid_scope", "backend_id is invalid")
	end

	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	if request.kind == "working" then
		return resolve_working(resolved_root, request, deps)
	elseif request.kind == "commit" then
		return resolve_commit(resolved_root, request, deps)
	elseif request.kind == "range" then
		return resolve_range(resolved_root, request, deps)
	end
	return resolve_branch(resolved_root, request, deps)
end

function M.default_branch(root, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	return default_branch(resolved_root, deps)
end

function M.working_fingerprint(root, options)
	local deps = make_dependencies(options)
	local resolved_root, root_err = canonical_root(root, deps)
	if not resolved_root then
		return nil, root_err
	end
	return fingerprint_worktree(resolved_root, deps)
end

function M.detect_drift(scope, options)
	if type(scope) ~= "table" or vim.islist(scope) then
		return nil, failure("invalid_scope", "scope must be an object")
	end
	if scope.kind ~= "working" then
		return { stale = false }
	end
	if type(scope.root) ~= "string" or scope.root == "" or type(scope.fingerprint) ~= "string" then
		return nil, failure("invalid_scope", "working scope root or fingerprint is missing")
	end
	local current, err = M.working_fingerprint(scope.root, options)
	if not current then
		return nil, err
	end
	return {
		stale = current.fingerprint ~= scope.fingerprint,
		current = current,
	}
end

M.backend_id = DEFAULT_BACKEND

return M
