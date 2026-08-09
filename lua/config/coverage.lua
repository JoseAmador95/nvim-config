-- Read-only coverage import.  This deliberately bypasses nvim-coverage's
-- Python conversion command: reports must already exist as coverage.py JSON
-- or LCOV and loading them never runs tests or regenerates data.
local M = {}

local MAX_BYTES = 50 * 1024 * 1024

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Coverage" })
end

local function current_root()
	local root, err = require("config.repo").current_root(0)
	if not root then
		return nil, err
	end
	return root
end

local function resolve_report(root, path)
	if not path or path == "" then
		path = vim.bo.filetype == "python" and "coverage.json" or "coverage/lcov.info"
	end
	local absolute = path:sub(1, 1) == "/" and path or vim.fs.joinpath(root, path)
	local resolved = vim.uv.fs_realpath(absolute)
	if not resolved or not require("config.repo").contains(root, resolved) then
		return nil, "report is missing or outside the repository"
	end
	local stat = vim.uv.fs_stat(resolved)
	if not stat or stat.type ~= "file" then
		return nil, "report is not a regular file"
	end
	if stat.size > MAX_BYTES then
		return nil, "report exceeds 50 MiB"
	end
	return resolved
end

local function number_list(value)
	if type(value) ~= "table" or not vim.islist(value) then
		return false
	end
	for _, item in ipairs(value) do
		if type(item) ~= "number" or item < 0 or item % 1 ~= 0 then
			return false
		end
	end
	return true
end

local function sanitize_python(root, decoded)
	if type(decoded) ~= "table" or type(decoded.files) ~= "table" or type(decoded.totals) ~= "table" then
		return nil, "coverage.json must contain files and totals objects"
	end
	local files = {}
	for name, entry in pairs(decoded.files) do
		if type(name) ~= "string" or name == "" or name:find("%z") or type(entry) ~= "table" then
			return nil, "coverage.json contains an invalid file entry"
		end
		local absolute = name:sub(1, 1) == "/" and name or vim.fs.joinpath(root, name)
		local resolved = vim.uv.fs_realpath(absolute)
		if not resolved or not require("config.repo").contains(root, resolved) then
			return nil, "coverage.json references a file outside the repository: " .. name
		end
		for _, field in ipairs({ "executed_lines", "missing_lines", "excluded_lines" }) do
			if entry[field] ~= nil and not number_list(entry[field]) then
				return nil, ("coverage.json field %s is invalid for %s"):format(field, name)
			end
		end
		files[resolved] = vim.deepcopy(entry)
	end
	local sanitized = vim.deepcopy(decoded)
	sanitized.files = files
	return sanitized
end

local function load_python(root, path)
	local raw, read_err = require("config.fs").read_binary(path)
	if not raw then
		return nil, read_err
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok then
		return nil, "invalid JSON: " .. tostring(decoded)
	end
	local data, validation_err = sanitize_python(root, decoded)
	if not data then
		return nil, validation_err
	end
	local language = require("coverage.languages.python")
	local signs = require("coverage.signs")
	signs.clear()
	require("coverage.report").cache(data, "python")
	signs.place(language.sign_list(data))
	return true
end

local function validate_lcov(root, path)
	local raw, read_err = require("config.fs").read_binary(path)
	if not raw then
		return nil, read_err
	end
	if raw:find("\0", 1, true) then
		return nil, "LCOV report contains a NUL byte"
	end
	local sources = 0
	for source in raw:gmatch("[\r\n]SF:([^\r\n]+)") do
		sources = sources + 1
		local absolute = source:sub(1, 1) == "/" and source or vim.fs.joinpath(root, source)
		local resolved = vim.uv.fs_realpath(absolute)
		if not resolved or not require("config.repo").contains(root, resolved) then
			return nil, "LCOV references a file outside the repository: " .. source
		end
	end
	-- Also match an SF record at byte zero.
	local first = raw:match("^SF:([^\r\n]+)")
	if first then
		sources = sources + 1
		local absolute = first:sub(1, 1) == "/" and first or vim.fs.joinpath(root, first)
		local resolved = vim.uv.fs_realpath(absolute)
		if not resolved or not require("config.repo").contains(root, resolved) then
			return nil, "LCOV references a file outside the repository: " .. first
		end
	end
	return sources > 0 and true or nil, sources > 0 and nil or "LCOV report has no source records"
end

local function load_lcov(root, path)
	local ok, data = pcall(require("coverage.util").lcov_to_table, require("plenary.path"):new(path))
	if not ok or type(data) ~= "table" or type(data.files) ~= "table" or type(data.totals) ~= "table" then
		return nil, "could not parse LCOV: " .. tostring(data)
	end
	local files = {}
	for name, entry in pairs(data.files) do
		if type(name) ~= "string" or type(entry) ~= "table" then
			return nil, "LCOV parser returned an invalid file entry"
		end
		local absolute = name:sub(1, 1) == "/" and name or vim.fs.joinpath(root, name)
		local resolved = vim.uv.fs_realpath(absolute)
		if not resolved or not require("config.repo").contains(root, resolved) then
			return nil, "LCOV references a file outside the repository: " .. name
		end
		files[resolved] = entry
	end
	data.files = files
	local signs = require("coverage.signs")
	signs.clear()
	require("coverage.report").cache(data, "common")
	signs.place(require("coverage.languages.common").sign_list(data))
	return true
end

function M.load(path)
	local root, root_err = current_root()
	if not root then
		notify(root_err, vim.log.levels.ERROR)
		return false
	end
	local report, report_err = resolve_report(root, path)
	if not report then
		notify(report_err, vim.log.levels.ERROR)
		return false
	end
	local is_json = report:lower():match("%.json$") ~= nil
	local ok, err
	if is_json then
		ok, err = load_python(root, report)
	else
		ok, err = validate_lcov(root, report)
		if ok then
			ok, err = load_lcov(root, report)
		end
	end
	if not ok then
		notify("Could not load report: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	notify("Loaded existing coverage report: " .. report)
	return true
end

function M.clear()
	require("coverage").clear()
	require("coverage.report").clear()
end

function M.setup()
	vim.api.nvim_create_user_command("CoverageLoad", function(opts)
		M.load(opts.args)
	end, { nargs = "?", complete = "file", desc = "Load an existing coverage.json or LCOV report" })
	vim.api.nvim_create_user_command("CoverageSummary", function()
		require("coverage").summary()
	end, { nargs = 0, desc = "Show the loaded coverage summary" })
	vim.api.nvim_create_user_command("CoverageClear", M.clear, { nargs = 0, desc = "Clear loaded coverage data" })
end

M._sanitize_python = sanitize_python
M._validate_lcov = validate_lcov

return M
