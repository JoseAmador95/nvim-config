-- Immutable, read-only Git snapshots used by the standalone native review presenter.
local M = {}

local repo = require("native_review.dependencies").get("repo")
local review_scope = require("native_review.scope")

local ZERO_OID = "^0+$"
local LAYER_ORDER = { staged = 1, unstaged = 2, untracked = 3 }
local BLOB_BATCH_SIZE = 512
local READ_CHUNK_BYTES = 64 * 1024
local DEFAULT_LIMITS = {
	max_files = 2000,
	max_file_bytes = 4 * 1024 * 1024,
	max_model_bytes = 64 * 1024 * 1024,
}

local function failure(code, message, details)
	return { code = code, message = message, details = details or {} }
end

local function limit_failure(limit, maximum, actual, entry, side)
	return failure("review_limit_exceeded", ("review %s exceeded for %s"):format(limit, entry.path or "scope"), {
		limit = limit,
		maximum = maximum,
		actual = actual,
		path = side == "OLD" and (entry.old_path or entry.path) or (entry.new_path or entry.path),
		layer = entry.layer or "history",
		side = side,
	})
end

local function option_limit(options, name)
	local source = type(options.limits) == "table" and options.limits or options
	local value = source[name]
	if type(value) == "number" and value % 1 == 0 and value > 0 then
		return value
	end
	return DEFAULT_LIMITS[name]
end

local function checkpoint(deps, phase, progress)
	local callback = deps.control and deps.control.checkpoint
	if type(callback) ~= "function" then
		return true
	end
	local allowed, reason = callback(phase, vim.deepcopy(progress or {}))
	if allowed == false then
		return nil,
			failure("review_cancelled", tostring(reason or "review model construction was cancelled"), {
				phase = phase,
				progress = vim.deepcopy(progress or {}),
			})
	end
	return true
end

local function binary_runner(command, input)
	return vim.system(repo.clean_git_command(command), { text = false, stdin = input }):wait()
end

local function dependencies(options)
	options = options or {}
	local repository = options.repo or repo
	return {
		repo = repository,
		runner = options.runner or (repository == repo and binary_runner or nil),
		read_file = options.read_file,
		lstat = options.lstat or vim.uv.fs_lstat,
		readlink = options.readlink or vim.uv.fs_readlink,
		control = options.control,
		max_files = option_limit(options, "max_files"),
		max_file_bytes = option_limit(options, "max_file_bytes"),
		max_model_bytes = option_limit(options, "max_model_bytes"),
	}
end

local function git(root, arguments, deps, context)
	local output, err = deps.repo.git(root, arguments, deps.runner)
	if not output then
		return nil, failure("git_failed", context .. ": " .. tostring(err), { argv = arguments })
	end
	local continued, checkpoint_err = checkpoint(deps, "changes.git", { argv = arguments, context = context })
	if not continued then
		return nil, checkpoint_err
	end
	return output
end

local function valid_oid(value)
	return type(value) == "string" and (#value == 40 or #value == 64) and value:match("^[0-9a-f]+$") ~= nil
end

local function present_oid(value)
	if value:match(ZERO_OID) then
		return nil
	end
	return value
end

local function split_nul(output)
	if output == "" then
		return {}
	end
	if output:sub(-1) ~= "\0" then
		return nil, "Git returned a malformed NUL-delimited response"
	end
	local fields = {}
	local offset = 1
	while offset <= #output do
		local boundary = assert(output:find("\0", offset, true))
		fields[#fields + 1] = output:sub(offset, boundary - 1)
		offset = boundary + 1
	end
	return fields
end

local function parse_raw(output, layer)
	local fields, fields_err = split_nul(output)
	if not fields then
		return nil, failure("invalid_git_output", fields_err)
	end
	local entries = {}
	local index = 1
	while index <= #fields do
		local header = fields[index]
		index = index + 1
		local old_mode, new_mode, old_oid, new_oid, status, score =
			header:match("^:(%d+) (%d+) ([0-9a-f]+) ([0-9a-f]+) ([A-Z])(%d*)$")
		if not status then
			return nil, failure("invalid_git_output", "Git returned a malformed raw diff header", { header = header })
		end
		local first_path = fields[index]
		index = index + 1
		if first_path == nil or first_path == "" then
			return nil, failure("invalid_git_output", "Git returned a raw diff entry without a path")
		end
		local old_path = first_path
		local new_path = first_path
		if status == "A" then
			old_path = nil
		elseif status == "D" then
			new_path = nil
		end
		if status == "R" or status == "C" then
			new_path = fields[index]
			index = index + 1
			if not new_path or new_path == "" then
				return nil, failure("invalid_git_output", "Git returned a rename without its destination")
			end
			old_path = first_path
		end
		entries[#entries + 1] = {
			layer = layer,
			status = status,
			score = score ~= "" and tonumber(score) or nil,
			old_mode = old_mode,
			new_mode = new_mode,
			old_oid = present_oid(old_oid),
			new_oid = present_oid(new_oid),
			old_path = old_path,
			new_path = new_path,
		}
	end
	return entries
end

local function safe_worktree_path(root, relative)
	if type(relative) ~= "string" or relative == "" or relative:find("\0", 1, true) then
		return nil, "path is empty or invalid"
	end
	if relative:sub(1, 1) == "/" or relative:sub(1, 1) == "\\" or relative:match("^%a:[/\\]") then
		return nil, "path is not repository-relative"
	end
	for segment in relative:gmatch("[^/]+") do
		if segment == ".." then
			return nil, "path traversal is not allowed"
		end
	end
	local canonical_root = vim.uv.fs_realpath(root)
	if not canonical_root then
		return nil, "repository root does not exist"
	end
	canonical_root = vim.fs.normalize(canonical_root)
	local path = vim.fs.normalize(vim.fs.joinpath(canonical_root, relative))
	if path:sub(1, #canonical_root + 1) ~= canonical_root .. "/" then
		return nil, "path escapes the repository"
	end
	return path
end

local WORKTREE_IDENTITY_FIELDS = { "type", "size", "mode", "dev", "ino", "uid", "gid", "nlink", "mtime", "ctime" }

local function worktree_identity(stat)
	local identity = {}
	for _, field in ipairs(WORKTREE_IDENTITY_FIELDS) do
		if stat[field] ~= nil then
			identity[field] = vim.deepcopy(stat[field])
		end
	end
	return identity
end

local function read_regular(path, entry, side, expected, deps)
	local handle, open_err = vim.uv.fs_open(path, "r", 0)
	if not handle then
		return nil, open_err
	end
	local stat, stat_err = vim.uv.fs_fstat(handle)
	if not stat then
		vim.uv.fs_close(handle)
		return nil, stat_err
	end
	if stat.type ~= "file" or type(stat.size) ~= "number" or stat.size < 0 then
		vim.uv.fs_close(handle)
		return nil, "path is no longer a regular file"
	end
	if stat.size > deps.max_file_bytes then
		vim.uv.fs_close(handle)
		return nil, limit_failure("max_file_bytes", deps.max_file_bytes, stat.size, entry, side)
	end
	if stat.size ~= expected then
		vim.uv.fs_close(handle)
		return nil,
			failure("working_tree_changed", "working-tree file size changed during review model construction", {
				path = side == "OLD" and entry.old_path or entry.new_path,
				layer = entry.layer or "history",
				side = side,
				expected = expected,
				actual = stat.size,
			})
	end
	local chunks = {}
	local offset = 0
	local read_err
	while offset < stat.size do
		local value
		value, read_err = vim.uv.fs_read(handle, math.min(READ_CHUNK_BYTES, stat.size - offset), offset)
		if value == nil then
			break
		end
		if value == "" then
			read_err = "unexpected end of file"
			break
		end
		chunks[#chunks + 1] = value
		offset = offset + #value
	end
	local final_stat, final_stat_err = vim.uv.fs_fstat(handle)
	vim.uv.fs_close(handle)
	if read_err then
		return nil, read_err
	end
	if not final_stat then
		return nil, final_stat_err
	end
	if final_stat.size > deps.max_file_bytes then
		return nil, limit_failure("max_file_bytes", deps.max_file_bytes, final_stat.size, entry, side)
	end
	if final_stat.size ~= expected then
		return nil,
			failure("working_tree_changed", "working-tree file size changed while it was read", {
				path = side == "OLD" and entry.old_path or entry.new_path,
				layer = entry.layer or "history",
				side = side,
				expected = expected,
				actual = final_stat.size,
			})
	end
	return table.concat(chunks)
end

local function inspect_worktree(root, entry, side, deps)
	local path = side == "OLD" and entry.old_path or entry.new_path
	local full_path, path_err = safe_worktree_path(root, path)
	if not full_path then
		return nil, failure("unsafe_path", path_err, { path = path })
	end
	local stat, stat_err = deps.lstat(full_path)
	if not stat then
		return nil, failure("worktree_unavailable", tostring(stat_err), { path = path })
	end
	if (stat.type ~= "file" and stat.type ~= "link") or type(stat.size) ~= "number" or stat.size < 0 then
		return nil, failure("worktree_unavailable", "path is not a regular file or symlink", { path = path })
	end
	if stat.size > deps.max_file_bytes then
		return nil, limit_failure("max_file_bytes", deps.max_file_bytes, stat.size, entry, side)
	end
	return {
		entry = entry,
		side = side,
		source = "worktree",
		path = path,
		full_path = full_path,
		kind = stat.type,
		size = stat.size,
		identity = worktree_identity(stat),
	}
end

local function read_worktree(plan, deps)
	local stat, stat_err = deps.lstat(plan.full_path)
	if not stat then
		return nil, failure("worktree_unavailable", tostring(stat_err), { path = plan.path })
	end
	if stat.type ~= plan.kind or type(stat.size) ~= "number" or stat.size < 0 then
		return nil,
			failure("working_tree_changed", "working-tree file type changed during review model construction", {
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
			})
	end
	local identity = worktree_identity(stat)
	if not vim.deep_equal(identity, plan.identity) then
		return nil,
			failure("working_tree_changed", "working-tree metadata changed before content was read", {
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
				expected = plan.identity,
				actual = identity,
			})
	end
	if stat.size > deps.max_file_bytes then
		return nil, limit_failure("max_file_bytes", deps.max_file_bytes, stat.size, plan.entry, plan.side)
	end
	if stat.size ~= plan.size then
		return nil,
			failure("working_tree_changed", "working-tree file size changed during review model construction", {
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
				expected = plan.size,
				actual = stat.size,
			})
	end
	local value
	local read_err
	if plan.kind == "link" then
		value, read_err = deps.readlink(plan.full_path)
	elseif deps.read_file then
		value, read_err = deps.read_file(plan.full_path, plan.path)
	else
		value, read_err = read_regular(plan.full_path, plan.entry, plan.side, plan.size, deps)
	end
	if value == nil then
		if type(read_err) == "table" then
			return nil, read_err
		end
		return nil, failure("worktree_unavailable", tostring(read_err), { path = plan.path })
	end
	if type(value) ~= "string" then
		return nil, failure("worktree_unavailable", "file reader returned non-string content", { path = plan.path })
	end
	if #value > deps.max_file_bytes then
		return nil, limit_failure("max_file_bytes", deps.max_file_bytes, #value, plan.entry, plan.side)
	end
	if #value ~= plan.size then
		return nil,
			failure("working_tree_changed", "working-tree bytes changed during review model construction", {
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
				expected = plan.size,
				actual = #value,
			})
	end
	local final_stat, final_err = deps.lstat(plan.full_path)
	if not final_stat then
		return nil, failure("worktree_unavailable", tostring(final_err), { path = plan.path })
	end
	local final_identity = worktree_identity(final_stat)
	if not vim.deep_equal(final_identity, plan.identity) then
		return nil,
			failure("working_tree_changed", "working-tree metadata changed while content was read", {
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
				expected = plan.identity,
				actual = final_identity,
			})
	end
	return value
end

local function finish_entry_metadata(entry)
	entry.renamed = entry.status == "R"
	entry.copied = entry.status == "C"
	entry.added = entry.status == "A" or entry.old_path == nil
	entry.deleted = entry.status == "D" or entry.new_path == nil
	entry.submodule = entry.old_mode == "160000" or entry.new_mode == "160000"
	entry.conflicted = entry.status == "U"
	entry.path = entry.new_path or entry.old_path
	entry.identity = table.concat({ entry.layer or "history", entry.old_path or "", entry.new_path or "" }, "\0")
	entry.binary = false
	entry.metadata_only = entry.submodule or entry.conflicted
	return entry
end

local function blob_plan(entry, side)
	local oid = side == "OLD" and entry.old_oid or entry.new_oid
	local path = side == "OLD" and entry.old_path or entry.new_path
	if not path then
		return nil
	end
	if not valid_oid(oid or "") then
		return nil, failure("invalid_git_output", "Git returned an invalid blob object ID", { oid = oid, path = path })
	end
	return { entry = entry, side = side, source = "blob", path = path, oid = oid }
end

local function add_plan(plans, descriptors, entry, side, plan)
	plans[entry] = plans[entry] or {}
	plans[entry][side == "OLD" and "old" or "new"] = plan
	descriptors[#descriptors + 1] = plan
end

local function result_output(result)
	if not result or result.code ~= 0 then
		local reason = result and vim.trim(result.stderr or "") or "could not start Git"
		return nil, reason ~= "" and reason or "Git exited with a nonzero status"
	end
	return result.stdout or ""
end

local function parse_blob_batch(output, batch)
	local lines = vim.split(output, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines ~= #batch then
		return nil, "Git returned incomplete blob metadata"
	end
	local sizes = {}
	for index, line in ipairs(lines) do
		local oid, kind, size_text = line:match("^([0-9a-f]+) ([^ ]+) (%d+)$")
		if oid ~= batch[index] or kind ~= "blob" then
			return nil, "Git returned invalid blob metadata"
		end
		local size = tonumber(size_text)
		if not size or size < 0 or size % 1 ~= 0 then
			return nil, "Git returned an invalid blob size"
		end
		sizes[oid] = size
	end
	return sizes
end

local function batch_blob_sizes(root, oids, deps)
	local sizes = {}
	if #oids == 0 then
		return sizes
	end
	if not deps.runner then
		for index, oid in ipairs(oids) do
			local output, err = git(root, { "cat-file", "-s", oid }, deps, "cannot inspect exact blob " .. oid)
			if not output then
				return nil, err
			end
			local size = tonumber(vim.trim(output))
			if not size or size < 0 or size % 1 ~= 0 then
				return nil, failure("invalid_git_output", "Git returned an invalid blob size", { oid = oid })
			end
			sizes[oid] = size
			local continued, checkpoint_err =
				checkpoint(deps, "changes.blob_metadata", { index = index, total = #oids, oid = oid })
			if not continued then
				return nil, checkpoint_err
			end
		end
		return sizes
	end
	local batch_number = 0
	for first = 1, #oids, BLOB_BATCH_SIZE do
		local batch = vim.list_slice(oids, first, math.min(#oids, first + BLOB_BATCH_SIZE - 1))
		batch_number = batch_number + 1
		local continued, checkpoint_err = checkpoint(deps, "changes.blob_metadata_batch", {
			batch = batch_number,
			processed = first - 1,
			total = #oids,
		})
		if not continued then
			return nil, checkpoint_err
		end
		local command = { "git", "-C", root, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)" }
		local output, run_err = result_output(deps.runner(command, table.concat(batch, "\n") .. "\n"))
		if not output then
			return nil,
				failure("git_failed", "cannot inspect exact blob batch: " .. tostring(run_err), {
					argv = vim.list_slice(command, 4),
				})
		end
		local parsed, parse_err = parse_blob_batch(output, batch)
		if not parsed then
			return nil, failure("invalid_git_output", parse_err, { oids = vim.deepcopy(batch) })
		end
		for oid, size in pairs(parsed) do
			sizes[oid] = size
		end
	end
	return sizes
end

local function preflight(root, entries, deps)
	if #entries > deps.max_files then
		local entry = finish_entry_metadata(entries[deps.max_files + 1])
		local side = entry.new_path and "NEW" or "OLD"
		return nil, limit_failure("max_files", deps.max_files, #entries, entry, side)
	end
	local plans = {}
	local descriptors = {}
	local unique_oids = {}
	local seen_oids = {}
	for index, entry in ipairs(entries) do
		finish_entry_metadata(entry)
		local continued, checkpoint_err = checkpoint(deps, "changes.file_metadata", {
			index = index,
			total = #entries,
			path = entry.path,
			layer = entry.layer or "history",
		})
		if not continued then
			return nil, checkpoint_err
		end
		if not entry.metadata_only then
			if entry.old_path then
				local plan, plan_err = blob_plan(entry, "OLD")
				if not plan then
					return nil, plan_err
				end
				add_plan(plans, descriptors, entry, "OLD", plan)
			end
			if entry.new_path then
				local plan
				local plan_err
				if entry.layer == "unstaged" or entry.layer == "untracked" then
					plan, plan_err = inspect_worktree(root, entry, "NEW", deps)
				else
					plan, plan_err = blob_plan(entry, "NEW")
				end
				if not plan then
					return nil, plan_err
				end
				add_plan(plans, descriptors, entry, "NEW", plan)
			end
		end
	end
	for _, descriptor in ipairs(descriptors) do
		if descriptor.source == "blob" and not seen_oids[descriptor.oid] then
			seen_oids[descriptor.oid] = true
			unique_oids[#unique_oids + 1] = descriptor.oid
		end
	end
	local blob_sizes, blob_err = batch_blob_sizes(root, unique_oids, deps)
	if not blob_sizes then
		return nil, blob_err
	end
	local represented_bytes = 0
	for _, descriptor in ipairs(descriptors) do
		if descriptor.source == "blob" then
			descriptor.size = blob_sizes[descriptor.oid]
		end
		if descriptor.size > deps.max_file_bytes then
			return nil,
				limit_failure("max_file_bytes", deps.max_file_bytes, descriptor.size, descriptor.entry, descriptor.side)
		end
		represented_bytes = represented_bytes + descriptor.size
		if represented_bytes > deps.max_model_bytes then
			return nil,
				limit_failure(
					"max_model_bytes",
					deps.max_model_bytes,
					represented_bytes,
					descriptor.entry,
					descriptor.side
				)
		end
	end
	return plans
end

local function read_blob(root, plan, deps)
	local value, err = git(root, { "cat-file", "blob", plan.oid }, deps, "cannot read exact blob " .. plan.oid)
	if value == nil then
		return nil, err
	end
	if type(value) ~= "string" then
		return nil,
			failure("invalid_git_output", "Git returned non-string blob content", {
				oid = plan.oid,
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
			})
	end
	if #value > deps.max_file_bytes then
		return nil, limit_failure("max_file_bytes", deps.max_file_bytes, #value, plan.entry, plan.side)
	end
	if #value ~= plan.size then
		return nil,
			failure("invalid_git_output", "Git blob size changed after metadata preflight", {
				oid = plan.oid,
				path = plan.path,
				layer = plan.entry.layer or "history",
				side = plan.side,
				expected = plan.size,
				actual = #value,
			})
	end
	return value
end

local function read_side(root, plan, deps)
	if not plan then
		return ""
	end
	if plan.source == "worktree" then
		return read_worktree(plan, deps)
	end
	return read_blob(root, plan, deps)
end

local function materialize(root, entries, plans, deps)
	local represented_bytes = 0
	for index, entry in ipairs(entries) do
		local continued, checkpoint_err = checkpoint(deps, "changes.file_read", {
			index = index,
			total = #entries,
			path = entry.path,
			layer = entry.layer or "history",
		})
		if not continued then
			return nil, checkpoint_err
		end
		if not entry.metadata_only then
			local entry_plans = plans[entry] or {}
			local old_text, old_err = read_side(root, entry_plans.old, deps)
			if old_text == nil then
				return nil, old_err
			end
			local new_text, new_err = read_side(root, entry_plans.new, deps)
			if new_text == nil then
				return nil, new_err
			end
			for _, side_value in ipairs({ { "OLD", old_text, entry_plans.old }, { "NEW", new_text, entry_plans.new } }) do
				if side_value[3] then
					represented_bytes = represented_bytes + #side_value[2]
					if represented_bytes > deps.max_model_bytes then
						return nil,
							limit_failure(
								"max_model_bytes",
								deps.max_model_bytes,
								represented_bytes,
								entry,
								side_value[1]
							)
					end
				end
			end
			entry.old_text = old_text
			entry.new_text = new_text
			entry.binary = old_text:find("\0", 1, true) ~= nil or new_text:find("\0", 1, true) ~= nil
		end
		entry.binary = entry.binary == true
		entry.metadata_only = entry.metadata_only or entry.binary
		continued, checkpoint_err = checkpoint(deps, "changes.diff", {
			index = index,
			total = #entries,
			path = entry.path,
			layer = entry.layer or "history",
		})
		if not continued then
			return nil, checkpoint_err
		end
		entry.hunks = entry.metadata_only and {}
			or vim.diff(entry.old_text, entry.new_text, { result_type = "indices" })
	end
	return true
end

local function raw_command(arguments)
	local command = vim.deepcopy(arguments)
	vim.list_extend(command, {
		"--raw",
		"-z",
		"--no-abbrev",
		"--find-renames",
		"--ignore-submodules=none",
		"--no-ext-diff",
		"--no-textconv",
		"--",
	})
	return command
end

local function load_raw(root, arguments, layer, deps)
	local output, err = git(root, raw_command(arguments), deps, "cannot enumerate changed files")
	if not output then
		return nil, err
	end
	local entries, parse_err = parse_raw(output, layer)
	if not entries then
		return nil, parse_err
	end
	return entries
end

local function load_untracked(root, deps)
	local output, err = git(
		root,
		{ "ls-files", "--others", "--exclude-standard", "-z", "--" },
		deps,
		"cannot enumerate untracked files"
	)
	if not output then
		return nil, err
	end
	local paths, parse_err = split_nul(output)
	if not paths then
		return nil, failure("invalid_git_output", parse_err)
	end
	table.sort(paths)
	local entries = {}
	for _, path in ipairs(paths) do
		local full_path, path_err = safe_worktree_path(root, path)
		if not full_path then
			return nil, failure("unsafe_path", path_err, { path = path })
		end
		local stat, stat_err = deps.lstat(full_path)
		if not stat then
			return nil, failure("worktree_unavailable", tostring(stat_err), { path = path })
		end
		local new_mode
		if stat.type == "link" then
			new_mode = "120000"
		elseif stat.type == "file" and type(stat.mode) == "number" then
			new_mode = bit.band(stat.mode, tonumber("111", 8)) == 0 and "100644" or "100755"
		else
			return nil, failure("worktree_unavailable", "unsupported untracked file type", { path = path })
		end
		local entry = {
			layer = "untracked",
			status = "A",
			old_mode = "000000",
			new_mode = new_mode,
			old_path = nil,
			new_path = path,
		}
		entries[#entries + 1] = entry
	end
	return entries
end

local function parse_commits(output)
	local fields, fields_err = split_nul(output)
	if not fields then
		return nil, failure("invalid_git_output", fields_err)
	end
	if #fields % 5 ~= 0 then
		return nil, failure("invalid_git_output", "Git returned incomplete commit metadata")
	end
	local commits = {}
	for index = 1, #fields, 5 do
		local oid, parent_text, date, author, subject = unpack(fields, index, index + 4)
		if not valid_oid(oid) then
			return nil, failure("invalid_git_output", "Git returned an invalid commit list")
		end
		local parents = vim.split(parent_text, " ", { plain = true, trimempty = true })
		for _, parent in ipairs(parents) do
			if not valid_oid(parent) then
				return nil, failure("invalid_git_output", "Git returned an invalid commit parent")
			end
		end
		if not date:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$") then
			return nil, failure("invalid_git_output", "Git returned an invalid commit date")
		end
		if author == "" or author:find("[%c]") or subject:find("[%c]") then
			return nil, failure("invalid_git_output", "Git returned invalid commit display metadata")
		end
		commits[#commits + 1] = {
			oid = oid,
			parents = parents,
			parent_oid = parents[1],
			index = #commits + 1,
			date = date,
			author = author,
			subject = subject,
		}
	end
	return commits
end

local function historical_endpoints(scope)
	if scope.kind == "commit" then
		return nil, scope.commit_oid
	elseif scope.kind == "range" then
		return scope.from_oid, scope.to_oid
	elseif scope.kind == "branch" then
		return scope.merge_base_oid, scope.head_oid
	end
	return nil, nil
end

local function historical_commits(root, scope, old_oid, new_oid, deps)
	local revision = scope.kind == "commit" and new_oid or old_oid .. ".." .. new_oid
	local arguments = {
		"log",
		"-z",
		"--no-decorate",
		"--format=%H%x00%P%x00%aI%x00%an%x00%s",
	}
	if scope.kind == "commit" then
		vim.list_extend(arguments, { "-n", "1", revision })
	else
		vim.list_extend(arguments, { "--reverse", "--topo-order", revision })
	end
	local output, err = git(root, arguments, deps, "cannot enumerate review commits")
	if not output then
		return nil, err
	end
	return parse_commits(output)
end

local function build_historical(root, scope, deps)
	local old_oid, new_oid = historical_endpoints(scope)
	if not valid_oid(new_oid or "") or old_oid and not valid_oid(old_oid) then
		return nil, failure("invalid_scope", "historical scope endpoints are missing or invalid")
	end
	local commits, commits_err = historical_commits(root, scope, old_oid, new_oid, deps)
	if not commits then
		return nil, commits_err
	end
	if scope.kind == "commit" then
		old_oid = commits[1] and commits[1].parent_oid or nil
	end
	local arguments
	if old_oid then
		arguments = { "diff", old_oid, new_oid }
	else
		arguments = { "diff-tree", "--root", "--no-commit-id", "-r", new_oid }
	end
	local entries, entries_err = load_raw(root, arguments, nil, deps)
	if not entries then
		return nil, entries_err
	end
	return { old_oid = old_oid, new_oid = new_oid, commits = commits, entries = entries }
end

local function append(target, values)
	for _, value in ipairs(values) do
		target[#target + 1] = value
	end
end

local function build_working(root, scope, deps)
	if not valid_oid(scope.head_oid or "") then
		return nil, failure("invalid_scope", "working scope HEAD is missing or invalid")
	end
	local staged, staged_err = load_raw(root, { "diff", "--cached", scope.head_oid }, "staged", deps)
	if not staged then
		return nil, staged_err
	end
	local unstaged, unstaged_err = load_raw(root, { "diff" }, "unstaged", deps)
	if not unstaged then
		return nil, unstaged_err
	end
	local untracked, untracked_err = load_untracked(root, deps)
	if not untracked then
		return nil, untracked_err
	end
	local entries = {}
	append(entries, staged)
	append(entries, unstaged)
	append(entries, untracked)
	return { old_oid = scope.head_oid, new_oid = nil, commits = {}, entries = entries }
end

local function sort_entries(entries)
	table.sort(entries, function(left, right)
		local left_layer = LAYER_ORDER[left.layer] or 0
		local right_layer = LAYER_ORDER[right.layer] or 0
		if left_layer ~= right_layer then
			return left_layer < right_layer
		end
		if left.path ~= right.path then
			return left.path < right.path
		end
		return left.identity < right.identity
	end)
end

local readonly_value

local function readonly_list(value)
	local copy = {}
	for index, child in ipairs(value) do
		copy[index] = readonly_value(child)
	end
	return copy
end

local function readonly_object(value)
	return setmetatable({}, {
		__index = function(_, key)
			return readonly_value(value[key])
		end,
		__newindex = function()
			error("review model is immutable", 2)
		end,
		__metatable = false,
	})
end

readonly_value = function(value)
	if type(value) ~= "table" then
		return value
	end
	return vim.islist(value) and readonly_list(value) or readonly_object(value)
end

---Build an exact review model from a resolved native_review.scope value.
---@param root string
---@param scope table
---@param options? { repo?: table, runner?: fun(command: string[]): table, read_file?: fun(path: string, relative: string): string?, lstat?: fun(path: string): table?, readlink?: fun(path: string): string? }
---@return table? model
---@return table? err
function M.build(root, scope, options)
	if type(root) ~= "string" or root == "" or type(scope) ~= "table" then
		return nil, failure("invalid_scope", "root and resolved scope are required")
	end
	local deps = dependencies(options)
	local canonical = vim.uv.fs_realpath(root)
	if not canonical or vim.fs.normalize(canonical) ~= vim.fs.normalize(vim.uv.fs_realpath(scope.root or "") or "") then
		return nil, failure("invalid_scope", "scope root does not match the requested repository")
	end
	canonical = vim.fs.normalize(canonical)
	local scope_options = {
		repo = deps.repo,
		runner = deps.runner,
		control = deps.control,
		max_files = deps.max_files,
		max_file_bytes = deps.max_file_bytes,
		max_model_bytes = deps.max_model_bytes,
	}
	if scope.kind == "working" and type(scope.fingerprint) == "string" then
		local drift, drift_err = review_scope.detect_drift(scope, scope_options)
		if not drift then
			return nil, drift_err
		end
		if drift.stale then
			return nil, failure("working_tree_changed", "working tree changed before review model construction")
		end
	end
	local built, build_err
	if scope.kind == "working" then
		built, build_err = build_working(canonical, scope, deps)
	elseif scope.kind == "commit" or scope.kind == "range" or scope.kind == "branch" then
		built, build_err = build_historical(canonical, scope, deps)
	else
		return nil, failure("invalid_scope", "scope kind is not supported")
	end
	if not built then
		return nil, build_err
	end
	local plans, preflight_err = preflight(canonical, built.entries, deps)
	if not plans then
		return nil, preflight_err
	end
	local materialized, materialize_err = materialize(canonical, built.entries, plans, deps)
	if not materialized then
		return nil, materialize_err
	end
	if scope.kind == "working" and type(scope.fingerprint) == "string" then
		local drift, drift_err = review_scope.detect_drift(scope, scope_options)
		if not drift then
			return nil, drift_err
		end
		if drift.stale then
			return nil, failure("working_tree_changed", "working tree changed during review model construction")
		end
	end
	sort_entries(built.entries)
	built.root = canonical
	built.scope = vim.deepcopy(scope)
	built.kind = scope.kind
	built.version = 1
	return readonly_object(built)
end

---Find one entry by either old or new path; a working-tree layer disambiguates duplicates.
---@param model table
---@param path string
---@param layer? "staged"|"unstaged"|"untracked"
---@return table?
function M.find(model, path, layer)
	local found
	for _, entry in ipairs(model and model.entries or {}) do
		if (layer == nil or entry.layer == layer) and (entry.old_path == path or entry.new_path == path) then
			if found then
				return nil
			end
			found = entry
		end
	end
	return found
end

---Create a resolved-scope request for one commit or an inclusive contiguous commit span.
---@param model table
---@param first_oid string
---@param second_oid? string
---@return table? request
---@return table? err
function M.selection_request(model, first_oid, second_oid)
	if type(model) ~= "table" or type(model.commits) ~= "table" then
		return nil, failure("invalid_selection", "review model is required")
	end
	local first_index
	local second_index
	second_oid = second_oid or first_oid
	for index, commit in ipairs(model.commits) do
		if commit.oid == first_oid then
			first_index = index
		end
		if commit.oid == second_oid then
			second_index = index
		end
	end
	if not first_index or not second_index then
		return nil, failure("invalid_selection", "selected commit is not part of this review")
	end
	local oldest = model.commits[math.min(first_index, second_index)]
	local newest = model.commits[math.max(first_index, second_index)]
	local backend_id = model.scope.backend_id
	if oldest.oid == newest.oid then
		return { kind = "commit", rev = oldest.oid, backend_id = backend_id }
	end
	local previous
	for index = math.min(first_index, second_index), math.max(first_index, second_index) do
		local commit = model.commits[index]
		if type(commit.parents) ~= "table" or #commit.parents ~= 1 then
			return nil,
				failure(
					"invalid_selection",
					"selected commits must form a linear single-parent span; review merge commits individually"
				)
		end
		if previous and commit.parent_oid ~= previous.oid then
			return nil,
				failure("invalid_selection", "selected commits are adjacent in the list but not in one linear history")
		end
		previous = commit
	end
	return { kind = "range", from = oldest.parent_oid, to = newest.oid, backend_id = backend_id }
end

M._parse_raw = parse_raw

return M
