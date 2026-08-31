local M = {}

local uv = vim.uv
local config = { max_bytes = 50 * 1024 * 1024 }
local registry = {}
local generation = 0
local SIGN_GROUP_PREFIX = "coverage-workbench:"
local SIGN_COVERED = "CoverageWorkbenchCovered"
local SIGN_MISSING = "CoverageWorkbenchMissing"

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

local function is_absolute(path)
	return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
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

local function integer_list(value, field, name)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or not vim.islist(value) then
		return nil, ("%s must be a list for %s"):format(field, name)
	end
	local result = {}
	local seen = {}
	for _, line in ipairs(value) do
		if type(line) ~= "number" or line < 1 or line % 1 ~= 0 then
			return nil, ("%s contains an invalid line for %s"):format(field, name)
		end
		if not seen[line] then
			seen[line] = true
			result[#result + 1] = line
		end
	end
	table.sort(result)
	return result
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
	local format = decoded.meta and decoded.meta.format or nil
	if format ~= nil and (type(format) ~= "number" or format % 1 ~= 0 or format < 1 or format > 3) then
		return nil, "unsupported coverage.py JSON format: " .. tostring(format)
	end
	local files = {}
	for name, entry in pairs(decoded.files) do
		if type(entry) ~= "table" then
			return nil, "invalid coverage.py file entry: " .. tostring(name)
		end
		local path, path_err = source_path(root, name)
		if not path then
			return nil, path_err
		end
		if files[path] then
			return nil, "duplicate canonical source: " .. name
		end
		local executed, executed_err = integer_list(entry.executed_lines, "executed_lines", name)
		if not executed then
			return nil, executed_err
		end
		local missing, missing_err = integer_list(entry.missing_lines, "missing_lines", name)
		if not missing then
			return nil, missing_err
		end
		local excluded, excluded_err = integer_list(entry.excluded_lines, "excluded_lines", name)
		if not excluded then
			return nil, excluded_err
		end
		files[path] = { executed_lines = executed, missing_lines = missing, excluded_lines = excluded }
	end
	return {
		kind = "coverage.py-json",
		schema_version = format or "legacy",
		root = root,
		files = files,
		totals = totals(files),
	}
end

local function finish_lcov_record(root, record, files)
	if not record then
		return true
	end
	local path, path_err = source_path(root, record.source)
	if not path then
		return nil, path_err
	end
	if files[path] then
		return nil, "duplicate LCOV source record: " .. record.source
	end
	local executed, missing = {}, {}
	for line, count in pairs(record.lines) do
		local target = count > 0 and executed or missing
		target[#target + 1] = line
	end
	table.sort(executed)
	table.sort(missing)
	files[path] = { executed_lines = executed, missing_lines = missing, excluded_lines = {} }
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
			if not number or number < 1 or not count or count < 0 then
				return nil, "invalid LCOV line record: " .. line
			end
			record.lines[number] = (record.lines[number] or 0) + count
		elseif line == "end_of_record" then
			local ok, err = finish_lcov_record(root, record, files)
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

local function read_report(path)
	local resolved = uv.fs_realpath(path)
	local stat = resolved and uv.fs_stat(resolved) or nil
	if not resolved or not stat or stat.type ~= "file" then
		return nil, "report is not a regular file"
	end
	if stat.size > config.max_bytes then
		return nil, ("report exceeds %d bytes"):format(config.max_bytes)
	end
	local handle, open_err = uv.fs_open(resolved, "r", 0)
	if not handle then
		return nil, tostring(open_err)
	end
	local data, read_err = uv.fs_read(handle, stat.size, 0)
	local close_ok, close_err = uv.fs_close(handle)
	if not data then
		return nil, tostring(read_err)
	end
	if not close_ok then
		return nil, tostring(close_err)
	end
	return data, resolved
end

local function sign_group(root)
	return SIGN_GROUP_PREFIX .. vim.fn.sha256(root):sub(1, 16)
end

local function render_buffer(buf, model)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local name = canonical(vim.api.nvim_buf_get_name(buf))
	local entry = name and model.files[name] or nil
	if not entry then
		return
	end
	local group = sign_group(model.root)
	vim.fn.sign_unplace(group, { buffer = buf })
	local id = 1
	for _, line in ipairs(entry.executed_lines) do
		vim.fn.sign_place(id, group, SIGN_COVERED, buf, { lnum = line, priority = 8 })
		id = id + 1
	end
	for _, line in ipairs(entry.missing_lines) do
		vim.fn.sign_place(id, group, SIGN_MISSING, buf, { lnum = line, priority = 9 })
		id = id + 1
	end
end

local function render(model)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		render_buffer(buf, model)
	end
end

function M.load(options)
	options = options or {}
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
	local raw, resolved_or_err = read_report(path)
	if not raw then
		return nil, resolved_or_err
	end
	local resolved = resolved_or_err
	if not contains(root, resolved) then
		return nil, "report is outside the project"
	end
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
	generation = generation + 1
	registry[root] = { generation = generation, path = resolved, model = model }
	render(model)
	return M.snapshot(root)
end

function M.refresh(root)
	root = canonical(root)
	local current = root and registry[root] or nil
	if not current then
		return nil, "no report is registered for the project"
	end
	return M.load({ root = root, path = current.path, format = current.model.kind })
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
	registry[root] = nil
	return true
end

function M.setup(options)
	options = options or {}
	config.max_bytes = options.max_bytes or config.max_bytes
	vim.fn.sign_define(SIGN_COVERED, { text = "▎", texthl = "DiagnosticOk" })
	vim.fn.sign_define(SIGN_MISSING, { text = "▎", texthl = "DiagnosticError" })
	local group = vim.api.nvim_create_augroup("coverage_workbench", { clear = true })
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = group,
		callback = function(args)
			for _, current in pairs(registry) do
				render_buffer(args.buf, current.model)
			end
		end,
	})
end

return M
