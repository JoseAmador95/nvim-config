local M = {}

local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	pcall(ffi.cdef, "int fcntl(int fd, int cmd, ...);")
end

local MEBIBYTE = 1024 * 1024
local MAX_REPORT_BYTES = 256 * MEBIBYTE
local MAX_SOURCE_BYTES = 16 * MEBIBYTE
local MAX_MODEL_BYTES = 64 * MEBIBYTE
local MAX_SIGN_LINE = 2147483647
local MODEL_FILE_BASE_BYTES = 512
local MODEL_LINE_BYTES = 64
local DEFAULT_CONFIG = {
	max_report_bytes = 50 * MEBIBYTE,
	max_source_bytes = MAX_SOURCE_BYTES,
	max_model_bytes = MAX_MODEL_BYTES,
	signs = "all",
	stale = "hide",
}
local config = vim.deepcopy(DEFAULT_CONFIG)
local registry = {}
local roots_by_path = {}
local buffer_paths = {}
local render_states = {}
local sign_groups = {}
local generation = 0
local event_callback
local configured = false
local SIGN_GROUP_PREFIX = "coverage-workbench:"
local SIGN_COVERED = "CoverageWorkbenchCovered"
local SIGN_MISSING = "CoverageWorkbenchMissing"
local DARWIN_F_GETPATH = 50
local DARWIN_PATH_BYTES = 1024

local function default_descriptor_path(handle)
	local system = uv.os_uname().sysname
	if system == "Linux" then
		return uv.fs_readlink("/proc/self/fd/" .. tostring(handle))
	end
	if system ~= "Darwin" or not ffi_ok then
		return nil, "descriptor path inspection is unavailable"
	end
	local ok, path = pcall(function()
		local buffer = ffi.new("char[?]", DARWIN_PATH_BYTES)
		if ffi.C.fcntl(handle, DARWIN_F_GETPATH, buffer) ~= 0 then
			return nil
		end
		return ffi.string(buffer)
	end)
	if not ok or type(path) ~= "string" or path == "" then
		return nil, "descriptor path inspection failed"
	end
	return path
end

local function canonical(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local absolute = vim.fs.abspath(path)
	return uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

local function contains(root, path)
	root = canonical(root)
	path = canonical(path)
	return root ~= nil and path ~= nil and (path == root or vim.fs.relpath(root, path) ~= nil)
end

local function same_time(left, right)
	left = left or {}
	right = right or {}
	return left.sec == right.sec and left.nsec == right.nsec
end

local function same_file_snapshot(left, right)
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and same_time(left.mtime, right.mtime)
		and same_time(left.ctime, right.ctime)
end

local path_snapshot_matches
local descriptor_path_is_bound

local function source_identity(root, path, bound_source_bytes)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" then
		return nil, "source changed while binding coverage: " .. path
	end
	local handle, open_err = uv.fs_open(path, "r", 0)
	if not handle then
		return nil, tostring(open_err)
	end
	local opened = uv.fs_fstat(handle)
	if
		not opened
		or not same_file_snapshot(before, opened)
		or not descriptor_path_is_bound(root, path, handle)
		or not path_snapshot_matches(root, path, opened)
	then
		uv.fs_close(handle)
		return nil, "source changed while binding coverage: " .. path
	end
	if opened.size > config.max_source_bytes then
		uv.fs_close(handle)
		return nil, ("source exceeds %d bytes: %s"):format(config.max_source_bytes, path)
	end
	if bound_source_bytes ~= nil and opened.size > config.max_model_bytes - bound_source_bytes then
		uv.fs_close(handle)
		return nil, ("coverage sources exceed %d bytes"):format(config.max_model_bytes)
	end
	local data, read_err = uv.fs_read(handle, opened.size, 0)
	local after = uv.fs_fstat(handle)
	local bound = after and descriptor_path_is_bound(root, path, handle) and path_snapshot_matches(root, path, after)
	uv.fs_close(handle)
	if not data or #data ~= opened.size or not after or not bound or not same_file_snapshot(opened, after) then
		return nil, tostring(read_err or "source changed while binding coverage: " .. path)
	end
	return {
		dev = opened.dev,
		ino = opened.ino,
		size = opened.size,
		mtime = vim.deepcopy(opened.mtime),
		ctime = vim.deepcopy(opened.ctime),
		digest = vim.fn.sha256(data),
	}
end

local function consume_model_budget(budget, amount)
	if amount > config.max_model_bytes - budget.model_bytes then
		return nil, ("coverage model exceeds %d bytes"):format(config.max_model_bytes)
	end
	budget.model_bytes = budget.model_bytes + amount
	return true
end

local function emit(kind, payload)
	if type(event_callback) ~= "function" then
		return
	end
	local event = vim.deepcopy(payload or {})
	event.kind = kind
	pcall(event_callback, event)
end

local function report_path_is_bound(root, resolved)
	local current = uv.fs_realpath(resolved)
	return current ~= nil and current == resolved and (current == root or vim.fs.relpath(root, current) ~= nil)
end

path_snapshot_matches = function(root, resolved, expected)
	if not report_path_is_bound(root, resolved) then
		return false
	end
	local current = uv.fs_lstat(resolved)
	if not same_file_snapshot(expected, current) then
		return false
	end
	return report_path_is_bound(root, resolved)
end

local function is_absolute(path)
	return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

descriptor_path_is_bound = function(root, resolved, handle)
	local ok, current = pcall(default_descriptor_path, handle)
	if not ok or type(current) ~= "string" or current == "" or current:find("\0", 1, true) then
		return false
	end
	current = vim.fs.normalize(current)
	return is_absolute(current) and current == resolved and (current == root or vim.fs.relpath(root, current) ~= nil)
end

local function source_path(root, name)
	if type(name) ~= "string" or name == "" or name:find("%z", 1, true) then
		return nil, "invalid source path"
	end
	local candidate = is_absolute(name) and name or vim.fs.joinpath(root, name)
	local resolved = uv.fs_realpath(candidate)
	local stat = resolved and uv.fs_stat(resolved) or nil
	if not resolved or not stat or stat.type ~= "file" or not contains(root, resolved) then
		return nil, "source is missing or outside the project: " .. name
	end
	return resolved
end

local function source_entry(root, name, files, budget, duplicate_error)
	local path, path_err = source_path(root, name)
	if not path then
		return nil, path_err
	end
	if files[path] then
		return nil, duplicate_error .. name
	end
	local identity, identity_err = source_identity(root, path, budget.source_bytes)
	if not identity then
		return nil, identity_err
	end
	local budgeted, budget_err = consume_model_budget(budget, MODEL_FILE_BASE_BYTES + #path + #name)
	if not budgeted then
		return nil, budget_err
	end
	budget.source_bytes = budget.source_bytes + identity.size
	return path, identity
end

local function integer_list(value, field, name, budget)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or not vim.islist(value) then
		return nil, ("%s must be a list for %s"):format(field, name)
	end
	local result = {}
	local seen = {}
	for _, line in ipairs(value) do
		if type(line) ~= "number" or line < 1 or line > MAX_SIGN_LINE or line % 1 ~= 0 then
			return nil, ("%s contains an invalid line for %s"):format(field, name)
		end
		if not seen[line] then
			local budgeted, budget_err = consume_model_budget(budget, MODEL_LINE_BYTES)
			if not budgeted then
				return nil, budget_err
			end
			seen[line] = true
			result[#result + 1] = line
		end
	end
	table.sort(result)
	return result
end

local function disjoint_lines(name, lists)
	local seen = {}
	for _, item in ipairs(lists) do
		for _, line in ipairs(item.lines) do
			local previous = seen[line]
			if previous then
				return nil,
					("coverage line %d appears in both %s and %s for %s"):format(line, previous, item.field, name)
			end
			seen[line] = item.field
		end
	end
	return true
end

local function totals(files)
	local covered, missing, excluded = 0, 0, 0
	for _, entry in pairs(files) do
		covered = covered + #entry.executed_lines
		missing = missing + #entry.missing_lines
		excluded = excluded + #entry.excluded_lines
	end
	local statements = covered + missing
	return {
		covered_lines = covered,
		missing_lines = missing,
		excluded_lines = excluded,
		num_statements = statements,
		percent_covered = statements == 0 and 100 or covered * 100 / statements,
	}
end

function M.parse_coverage_json(root, raw)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil, "invalid coverage.py JSON"
	end
	if type(decoded.files) ~= "table" or type(decoded.totals) ~= "table" then
		return nil, "coverage.py JSON requires files and totals objects"
	end
	if decoded.meta ~= nil and (type(decoded.meta) ~= "table" or vim.islist(decoded.meta)) then
		return nil, "coverage.py JSON meta must be an object"
	end
	local format = decoded.meta and decoded.meta.format or nil
	if format ~= nil and (type(format) ~= "number" or format % 1 ~= 0 or format < 1 or format > 3) then
		return nil, "unsupported coverage.py JSON format: " .. tostring(format)
	end
	local files = {}
	local budget = { model_bytes = 0, source_bytes = 0 }
	for name, entry in pairs(decoded.files) do
		if type(entry) ~= "table" then
			return nil, "invalid coverage.py file entry: " .. tostring(name)
		end
		local path, identity_or_err = source_entry(root, name, files, budget, "duplicate canonical source: ")
		if not path then
			return nil, identity_or_err
		end
		local executed, executed_err = integer_list(entry.executed_lines, "executed_lines", name, budget)
		if not executed then
			return nil, executed_err
		end
		local missing, missing_err = integer_list(entry.missing_lines, "missing_lines", name, budget)
		if not missing then
			return nil, missing_err
		end
		local excluded, excluded_err = integer_list(entry.excluded_lines, "excluded_lines", name, budget)
		if not excluded then
			return nil, excluded_err
		end
		local disjoint, disjoint_err = disjoint_lines(name, {
			{ field = "executed_lines", lines = executed },
			{ field = "missing_lines", lines = missing },
			{ field = "excluded_lines", lines = excluded },
		})
		if not disjoint then
			return nil, disjoint_err
		end
		files[path] = {
			executed_lines = executed,
			missing_lines = missing,
			excluded_lines = excluded,
			source = identity_or_err,
		}
	end
	return {
		kind = "coverage.py-json",
		schema_version = format or "legacy",
		root = root,
		files = files,
		totals = totals(files),
	}
end

local function finish_lcov_record(root, record, files, budget)
	if not record then
		return true
	end
	local path, identity_or_err = source_entry(root, record.source, files, budget, "duplicate LCOV source record: ")
	if not path then
		return nil, identity_or_err
	end
	local executed, missing = {}, {}
	for line, count in pairs(record.lines) do
		local target = count > 0 and executed or missing
		target[#target + 1] = line
	end
	table.sort(executed)
	table.sort(missing)
	files[path] = { executed_lines = executed, missing_lines = missing, excluded_lines = {}, source = identity_or_err }
	return true
end

function M.parse_lcov(root, raw)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	if type(raw) ~= "string" or raw:find("\0", 1, true) then
		return nil, "invalid LCOV data"
	end
	local files = {}
	local budget = { model_bytes = 0, source_bytes = 0 }
	local record
	for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		if line:sub(1, 3) == "SF:" then
			if record then
				return nil, "LCOV source record was not terminated"
			end
			record = { source = line:sub(4), lines = {} }
		elseif line:sub(1, 3) == "DA:" then
			if not record then
				return nil, "LCOV line data appears before a source"
			end
			local number, count = line:match("^DA:(%d+),([%-]?%d+)")
			number, count = tonumber(number), tonumber(count)
			if not number or number < 1 or number > MAX_SIGN_LINE or not count or count < 0 then
				return nil, "invalid LCOV line record: " .. line
			end
			if record.lines[number] == nil then
				local budgeted, budget_err = consume_model_budget(budget, MODEL_LINE_BYTES)
				if not budgeted then
					return nil, budget_err
				end
			end
			record.lines[number] = (record.lines[number] or 0) + count
		elseif line == "end_of_record" then
			local ok, err = finish_lcov_record(root, record, files, budget)
			if not ok then
				return nil, err
			end
			record = nil
		end
	end
	if record then
		return nil, "LCOV source record was not terminated"
	end
	if not next(files) then
		return nil, "LCOV report has no source records"
	end
	return { kind = "lcov", schema_version = 1, root = root, files = files, totals = totals(files) }
end

local function read_report(root, path)
	local resolved = uv.fs_realpath(path)
	if not resolved then
		return nil, "report is not a regular file"
	end
	if not report_path_is_bound(root, resolved) then
		return nil, "report is outside the project"
	end
	local before, before_err = uv.fs_lstat(resolved)
	if not before or before.type ~= "file" then
		return nil, before_err and tostring(before_err) or "report is not a regular file"
	end
	if before.size > config.max_report_bytes then
		return nil, ("report exceeds %d bytes"):format(config.max_report_bytes)
	end
	local handle, open_err = uv.fs_open(resolved, "r", 0)
	if not handle then
		return nil, tostring(open_err)
	end
	local opened, stat_err = uv.fs_fstat(handle)
	if not opened or opened.type ~= "file" then
		uv.fs_close(handle)
		return nil, tostring(stat_err or "report changed while opening")
	end
	if opened.size > config.max_report_bytes then
		uv.fs_close(handle)
		return nil, ("report exceeds %d bytes"):format(config.max_report_bytes)
	end
	if not same_file_snapshot(before, opened) then
		uv.fs_close(handle)
		return nil, "report changed while opening"
	end
	if not descriptor_path_is_bound(root, resolved, handle) or not path_snapshot_matches(root, resolved, opened) then
		uv.fs_close(handle)
		return nil, "report changed while opening"
	end

	local data, read_err = uv.fs_read(handle, opened.size, 0)
	local after_handle, after_handle_err = uv.fs_fstat(handle)
	local descriptor_unchanged = after_handle and descriptor_path_is_bound(root, resolved, handle)
	local path_unchanged = after_handle and path_snapshot_matches(root, resolved, after_handle)
	local close_ok, close_err = uv.fs_close(handle)
	if not data then
		return nil, tostring(read_err)
	end
	if #data ~= opened.size then
		return nil, "report changed while reading"
	end
	if
		not after_handle
		or not descriptor_unchanged
		or not path_unchanged
		or not same_file_snapshot(opened, after_handle)
	then
		return nil, tostring(after_handle_err or "report changed while reading")
	end
	if not close_ok then
		return nil, tostring(close_err)
	end
	return data, resolved
end

local function sign_group(root)
	local group = sign_groups[root]
	if not group then
		group = SIGN_GROUP_PREFIX .. vim.fn.sha256(root):sub(1, 16)
		sign_groups[root] = group
	end
	return group
end

local function buffer_path(buf, refresh)
	local name = vim.api.nvim_buf_get_name(buf)
	local cached = buffer_paths[buf]
	if not refresh and cached and cached.name == name then
		return cached.path, false
	end
	local path = canonical(name)
	local changed = cached ~= nil and (cached.name ~= name or cached.path ~= path)
	buffer_paths[buf] = { name = name, path = path }
	return path, changed
end

local function state_table(buf)
	local states = render_states[buf]
	if not states then
		states = {}
		render_states[buf] = states
	end
	return states
end

local function forget_root_state(root)
	for buf, states in pairs(render_states) do
		states[root] = nil
		if not next(states) then
			render_states[buf] = nil
		end
	end
end

local function unindex_model(root, model)
	if not model then
		return
	end
	for path in pairs(model.files) do
		local roots = roots_by_path[path]
		if roots then
			roots[root] = nil
			if not next(roots) then
				roots_by_path[path] = nil
			end
		end
	end
end

local function index_model(root, model)
	for path in pairs(model.files) do
		local roots = roots_by_path[path]
		if not roots then
			roots = {}
			roots_by_path[path] = roots
		end
		roots[root] = true
	end
end

local function source_metadata_matches(root, path, expected)
	local before = uv.fs_lstat(path)
	local function matches(stat)
		return stat
			and stat.type == "file"
			and stat.dev == expected.dev
			and stat.ino == expected.ino
			and stat.size == expected.size
			and same_time(stat.mtime, expected.mtime)
			and same_time(stat.ctime, expected.ctime)
	end
	if not matches(before) then
		return false
	end
	local resolved = uv.fs_realpath(path)
	if not resolved or resolved ~= path or (resolved ~= root and vim.fs.relpath(root, resolved) == nil) then
		return false
	end
	return same_file_snapshot(before, uv.fs_lstat(path))
end

local function place_signs(buf, group, entry)
	if config.signs == "none" then
		return false
	end
	local id = 1
	if config.signs == "all" or config.signs == "covered" then
		for _, line in ipairs(entry.executed_lines) do
			vim.fn.sign_place(id, group, SIGN_COVERED, buf, { lnum = line, priority = 8 })
			id = id + 1
		end
	end
	if config.signs == "all" or config.signs == "missing" then
		for _, line in ipairs(entry.missing_lines) do
			vim.fn.sign_place(id, group, SIGN_MISSING, buf, { lnum = line, priority = 9 })
			id = id + 1
		end
	end
	return id > 1
end

local function has_configured_signs(entry)
	return (config.signs == "all" and (#entry.executed_lines > 0 or #entry.missing_lines > 0))
		or (config.signs == "covered" and #entry.executed_lines > 0)
		or (config.signs == "missing" and #entry.missing_lines > 0)
end

local function render_buffer(buf, current, options)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	options = options or {}
	local model = current.model
	local root = model.root
	local group = sign_group(root)
	local states = state_table(buf)
	local previous = states[root]
	local path = buffer_path(buf, options.refresh_path == true)
	local entry = path and model.files[path] or nil
	if not entry then
		if options.force or (previous and previous.placed) then
			vim.fn.sign_unplace(group, { buffer = buf })
		end
		states[root] = nil
		if not next(states) then
			render_states[buf] = nil
		end
		return
	end
	local modified = vim.bo[buf].modified
	local changedtick = vim.api.nvim_buf_get_changedtick(buf)
	local same_generation = previous
		and previous.generation == current.generation
		and previous.path == path
		and previous.signs == config.signs
		and previous.stale_policy == config.stale
	if not options.force and modified and same_generation and previous.modified then
		-- TextChanged/TextChangedI remain O(1) after the first dirty transition:
		-- no canonicalization, source I/O, hashing, sign churn, or repeated event.
		previous.changedtick = changedtick
		return
	end
	if
		not options.force
		and not modified
		and same_generation
		and not previous.modified
		and options.revalidate == false
	then
		previous.changedtick = changedtick
		return
	end

	local stale = modified or not source_metadata_matches(root, path, entry.source)
	entry.stale = stale
	local should_hide = stale and config.stale == "hide"
	local should_place = not should_hide and has_configured_signs(entry)
	local stable_display = same_generation
		and previous.stale == stale
		and previous.placed == should_place
		and not options.force
	if stable_display then
		previous.modified = modified
		previous.changedtick = changedtick
		return
	end

	if options.force or (previous and previous.placed) then
		vim.fn.sign_unplace(group, { buffer = buf })
	end
	local placed = false
	if stale and config.stale == "hide" then
		if not previous or not previous.stale then
			emit("stale", { root = root, path = path, bufnr = buf })
		end
	else
		placed = place_signs(buf, group, entry)
	end
	states[root] = {
		changedtick = changedtick,
		generation = current.generation,
		modified = modified,
		path = path,
		placed = placed,
		signs = config.signs,
		stale = stale,
		stale_policy = config.stale,
	}
end

local function render(current, force)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		render_buffer(buf, current, { force = force == true, revalidate = true })
	end
end

local function release_buffer(buf, unplace)
	local states = render_states[buf]
	if unplace and states then
		for root, state in pairs(states) do
			if state.placed then
				vim.fn.sign_unplace(sign_group(root), { buffer = buf })
			end
		end
	end
	render_states[buf] = nil
	buffer_paths[buf] = nil
end

local function render_event(args)
	if not vim.api.nvim_buf_is_valid(args.buf) then
		return
	end
	local hot = args.event == "TextChanged" or args.event == "TextChangedI"
	local refresh_path = not hot
	local path, path_changed = buffer_path(args.buf, refresh_path)
	if args.event == "BufFilePost" or path_changed then
		local resolved = buffer_paths[args.buf]
		release_buffer(args.buf, true)
		-- Keep the newly resolved identity after releasing the old buffer state.
		-- BufReadPost after a symlink retarget can now index only the new target.
		buffer_paths[args.buf] = resolved
	end
	local roots = path and roots_by_path[path] or nil
	if not roots then
		return
	end
	local revalidate = not hot
	for root in pairs(roots) do
		local current = registry[root]
		if current then
			render_buffer(args.buf, current, { revalidate = revalidate })
		end
	end
end

function M.load(options)
	options = options or {}
	if type(options) ~= "table" or (next(options) ~= nil and vim.islist(options)) then
		return nil, "load options must be an object"
	end
	for key in pairs(options) do
		if key ~= "root" and key ~= "path" and key ~= "format" then
			return nil, "load options contain an unknown option: " .. tostring(key)
		end
	end
	local root = canonical(options.root)
	if not root then
		return nil, "root is required"
	end
	local path = options.path
	if type(path) ~= "string" or path == "" then
		return nil, "report path is required"
	end
	if not is_absolute(path) then
		path = vim.fs.joinpath(root, path)
	end
	local raw, resolved_or_err = read_report(root, path)
	if not raw then
		return nil, resolved_or_err
	end
	local resolved = resolved_or_err
	local format = options.format or (resolved:lower():match("%.json$") and "coverage.py-json" or "lcov")
	local model, parse_err
	if format == "coverage.py-json" then
		model, parse_err = M.parse_coverage_json(root, raw)
	elseif format == "lcov" then
		model, parse_err = M.parse_lcov(root, raw)
	else
		return nil, "unsupported coverage format: " .. tostring(format)
	end
	if not model then
		return nil, parse_err
	end
	local previous = registry[root]
	local next_generation = generation + 1
	local candidate = { generation = next_generation, path = resolved, model = model }
	local rendered, render_err = xpcall(function()
		render(candidate, true)
	end, debug.traceback)
	if not rendered then
		if previous then
			pcall(render, previous, true)
		else
			pcall(vim.fn.sign_unplace, sign_group(root))
			forget_root_state(root)
		end
		return nil, "coverage render failed: " .. tostring(render_err)
	end
	generation = next_generation
	unindex_model(root, previous and previous.model or nil)
	registry[root] = candidate
	index_model(root, model)
	emit("loaded", { root = root, path = resolved, generation = generation })
	return M.snapshot(root)
end

function M.refresh(root)
	root = canonical(root)
	local current = root and registry[root] or nil
	if not current then
		return nil, "no report is registered for the project"
	end
	local loaded, load_err = M.load({ root = root, path = current.path, format = current.model.kind })
	if not loaded then
		render(current, true)
		emit("refresh_failed", { root = root, path = current.path, error = tostring(load_err) })
	end
	return loaded, load_err
end

function M.snapshot(root)
	root = canonical(root)
	local current = root and registry[root] or nil
	return current and vim.deepcopy(current) or nil
end

function M.summary(root)
	local snapshot = M.snapshot(root)
	return snapshot and vim.deepcopy(snapshot.model.totals) or nil
end

function M.clear(root)
	root = canonical(root)
	if not root then
		return false
	end
	vim.fn.sign_unplace(sign_group(root))
	local current = registry[root]
	unindex_model(root, current and current.model or nil)
	registry[root] = nil
	forget_root_state(root)
	sign_groups[root] = nil
	emit("cleared", { root = root })
	return true
end

function M.setup(options)
	if options == nil then
		options = {}
	end
	if type(options) ~= "table" or (next(options) ~= nil and vim.islist(options)) then
		return nil, "setup options must be an object"
	end
	for key in pairs(options) do
		if
			key ~= "max_report_bytes"
			and key ~= "max_source_bytes"
			and key ~= "max_model_bytes"
			and key ~= "signs"
			and key ~= "stale"
			and key ~= "event"
		then
			return nil, "setup contains an unknown option: " .. tostring(key)
		end
	end
	local max_report_bytes = options.max_report_bytes
	if max_report_bytes == nil then
		max_report_bytes = DEFAULT_CONFIG.max_report_bytes
	end
	if
		type(max_report_bytes) ~= "number"
		or max_report_bytes % 1 ~= 0
		or max_report_bytes < 1
		or max_report_bytes > MAX_REPORT_BYTES
	then
		return nil, ("setup.max_report_bytes must be an integer between 1 and %d"):format(MAX_REPORT_BYTES)
	end
	local max_source_bytes = options.max_source_bytes
	if max_source_bytes == nil then
		max_source_bytes = DEFAULT_CONFIG.max_source_bytes
	end
	if
		type(max_source_bytes) ~= "number"
		or max_source_bytes % 1 ~= 0
		or max_source_bytes < 1
		or max_source_bytes > MAX_SOURCE_BYTES
	then
		return nil, ("setup.max_source_bytes must be an integer between 1 and %d"):format(MAX_SOURCE_BYTES)
	end
	local max_model_bytes = options.max_model_bytes
	if max_model_bytes == nil then
		max_model_bytes = DEFAULT_CONFIG.max_model_bytes
	end
	if
		type(max_model_bytes) ~= "number"
		or max_model_bytes % 1 ~= 0
		or max_model_bytes < 1
		or max_model_bytes > MAX_MODEL_BYTES
	then
		return nil, ("setup.max_model_bytes must be an integer between 1 and %d"):format(MAX_MODEL_BYTES)
	end
	local signs = options.signs
	if signs == nil then
		signs = DEFAULT_CONFIG.signs
	end
	if signs ~= "all" and signs ~= "covered" and signs ~= "missing" and signs ~= "none" then
		return nil, "setup.signs must be all, covered, missing, or none"
	end
	local stale = options.stale
	if stale == nil then
		stale = DEFAULT_CONFIG.stale
	end
	if stale ~= "hide" and stale ~= "show" then
		return nil, "setup.stale must be hide or show"
	end
	if options.event ~= nil and type(options.event) ~= "function" then
		return nil, "setup.event must be a function"
	end
	config = {
		max_report_bytes = max_report_bytes,
		max_source_bytes = max_source_bytes,
		max_model_bytes = max_model_bytes,
		signs = signs,
		stale = stale,
	}
	event_callback = options.event
	configured = true
	vim.fn.sign_define(SIGN_COVERED, { text = "▎", texthl = "DiagnosticOk" })
	vim.fn.sign_define(SIGN_MISSING, { text = "▎", texthl = "DiagnosticError" })
	local group = vim.api.nvim_create_augroup("coverage_workbench", { clear = true })
	vim.api.nvim_create_autocmd(
		{ "BufReadPost", "BufEnter", "BufModifiedSet", "TextChanged", "TextChangedI", "BufWritePost", "BufFilePost" },
		{
			group = group,
			callback = render_event,
		}
	)
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			release_buffer(args.buf, false)
		end,
	})
	return true
end

function M.effective_config()
	return vim.deepcopy(config)
end

function M.status()
	local projects = {}
	for root, current in pairs(registry) do
		projects[#projects + 1] = { root = root, generation = current.generation, path = current.path }
	end
	table.sort(projects, function(left, right)
		return left.root < right.root
	end)
	return vim.deepcopy({ configured = configured, config = config, projects = projects })
end

function M.teardown()
	for root in pairs(vim.deepcopy(registry)) do
		M.clear(root)
	end
	pcall(vim.api.nvim_del_augroup_by_name, "coverage_workbench")
	config = vim.deepcopy(DEFAULT_CONFIG)
	roots_by_path = {}
	buffer_paths = {}
	render_states = {}
	sign_groups = {}
	event_callback = nil
	configured = false
	return true
end

return M
