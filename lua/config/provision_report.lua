-- Deterministic, owner-only report contract for explicit runtime provisioning.
local M = {}

local fs = require("config.fs")
local toolchain = require("config.toolchain")
local uv = vim.uv

local SCHEMA = 1
local MAX_REPORT_BYTES = 1024 * 1024
local FILE_MODE = tonumber("600", 8)
local allowed_errors = {
	["nvim-version"] = true,
	["lock-changed"] = true,
	["plugin-editor"] = true,
	["plugin-nvimpager"] = true,
	["mason"] = true,
	["managed-tools"] = true,
	["parser-editor"] = true,
	["parser-nvimpager"] = true,
	["unsupported-platform"] = true,
	["strict-managed"] = true,
	["verification"] = true,
}

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function json_encode(value, seen)
	if value == vim.NIL or value == nil then
		return "null"
	end
	local kind = type(value)
	if kind == "string" or kind == "boolean" then
		return vim.json.encode(value)
	end
	if kind == "number" then
		assert(value == value and value ~= math.huge and value ~= -math.huge, "report numbers must be finite")
		return vim.json.encode(value)
	end
	assert(kind == "table", "unsupported report value: " .. kind)
	seen = seen or {}
	assert(not seen[value], "cyclic report value")
	seen[value] = true
	local encoded
	if vim.islist(value) then
		local items = {}
		for index, item in ipairs(value) do
			items[index] = json_encode(item, seen)
		end
		encoded = "[" .. table.concat(items, ",") .. "]"
	else
		local keys = vim.tbl_keys(value)
		table.sort(keys)
		local items = {}
		for _, key in ipairs(keys) do
			assert(type(key) == "string", "report object keys must be strings")
			items[#items + 1] = vim.json.encode(key) .. ":" .. json_encode(value[key], seen)
		end
		encoded = "{" .. table.concat(items, ",") .. "}"
	end
	seen[value] = nil
	return encoded
end

local function home_root()
	local home = vim.env.HOME
	assert(type(home) == "string" and home:sub(1, 1) == "/", "HOME must be absolute")
	home = vim.fs.normalize(home)
	local real = uv.fs_realpath(home)
	assert(real and vim.fs.normalize(real) == home and home ~= "/", "HOME must be a canonical real directory")
	assert(not contained(home, "/localdata"), "HOME must not use /localdata")
	return home
end

local function report_path()
	local path = vim.env.NVIM_CONFIG_PROVISION_REPORT
	assert(
		type(path) == "string" and path:sub(1, 1) == "/" and not path:find("%z"),
		"provision report path must be absolute"
	)
	path = vim.fs.normalize(path)
	assert(contained(path, home_root()), "provision report must stay under HOME")
	return path
end

local function safe_parent(path)
	local parent = vim.fs.dirname(path)
	local stat = uv.fs_lstat(parent)
	local real = stat and stat.type == "directory" and uv.fs_realpath(parent) or nil
	assert(
		real and vim.fs.normalize(real) == parent and contained(real, home_root()),
		"provision report parent is unsafe"
	)
	if uv.getuid then
		assert(stat.uid == uv.getuid(), "provision report parent is not owner-controlled")
	end
	return parent, stat
end

local function same_directory(left, right)
	return left
		and right
		and left.type == "directory"
		and right.type == "directory"
		and left.dev == right.dev
		and left.ino == right.ino
end

local function write_all(fd, data)
	local offset = 0
	while offset < #data do
		local wrote, err = uv.fs_write(fd, data:sub(offset + 1), offset)
		assert(wrote and wrote > 0, "cannot write provision report: " .. tostring(err))
		offset = offset + wrote
	end
end

local write_counter = 0
local function write_report(value)
	local data = json_encode(value) .. "\n"
	assert(#data <= MAX_REPORT_BYTES, "provision report is too large")
	local path = report_path()
	local parent, parent_before = safe_parent(path)
	local current = uv.fs_lstat(path)
	assert(not current or current.type == "file" and current.nlink == 1, "provision report target is unsafe")
	if current and uv.getuid then
		assert(current.uid == uv.getuid(), "provision report target is not owner-controlled")
	end
	write_counter = write_counter + 1
	local temporary = ("%s/.%s.tmp.%d.%s.%d"):format(
		parent,
		vim.fs.basename(path),
		uv.os_getpid(),
		tostring(uv.hrtime()),
		write_counter
	)
	local fd, open_err = uv.fs_open(temporary, "wx", FILE_MODE)
	assert(fd, "cannot create provision report staging file: " .. tostring(open_err))
	local ok, err = xpcall(function()
		assert(uv.fs_fchmod(fd, FILE_MODE), "cannot secure provision report staging file")
		write_all(fd, data)
		assert(uv.fs_fsync(fd), "cannot sync provision report staging file")
	end, debug.traceback)
	local closed, close_err = uv.fs_close(fd)
	if not ok or not closed then
		pcall(uv.fs_unlink, temporary)
		error(ok and ("cannot close provision report staging file: " .. tostring(close_err)) or err)
	end
	if not same_directory(parent_before, uv.fs_lstat(parent)) then
		pcall(uv.fs_unlink, temporary)
		error("provision report parent changed during write")
	end
	local renamed, rename_err = uv.fs_rename(temporary, path)
	if not renamed then
		pcall(uv.fs_unlink, temporary)
		error("cannot publish provision report: " .. tostring(rename_err))
	end
	local final = uv.fs_lstat(path)
	assert(final and final.type == "file" and final.nlink == 1, "published provision report is unsafe")
	assert(uv.fs_chmod(path, FILE_MODE), "cannot secure published provision report")
end

local function load_report()
	local path = report_path()
	local before = uv.fs_lstat(path)
	assert(
		before and before.type == "file" and before.nlink == 1 and before.size <= MAX_REPORT_BYTES,
		"provision report is unsafe"
	)
	if uv.getuid then
		assert(before.uid == uv.getuid(), "provision report is not owner-controlled")
	end
	local raw, read_err = fs.read_binary(path)
	assert(raw, "cannot read provision report: " .. tostring(read_err))
	local after = uv.fs_lstat(path)
	assert(
		after and before.dev == after.dev and before.ino == after.ino and before.size == after.size,
		"provision report changed while read"
	)
	local ok, report = pcall(vim.json.decode, raw)
	assert(ok and type(report) == "table" and report.schema_version == SCHEMA, "invalid provision report")
	return report
end

local function config_root()
	local root = vim.env.NVIM_CONFIG_ROOT
	assert(type(root) == "string" and root:sub(1, 1) == "/", "NVIM_CONFIG_ROOT must be absolute")
	return vim.fs.normalize(root)
end

local function lock_digest()
	local raw, err = fs.read_binary(vim.fs.joinpath(config_root(), "lazy-lock.json"))
	assert(raw, "cannot read lazy-lock.json: " .. tostring(err))
	return vim.fn.sha256(raw)
end

function M.empty_inventory()
	return { required = {}, exact = false, problems = { "not-run" }, extras = {} }
end

local function managed_placeholder(name)
	local entry = assert(toolchain.managed_tools[name])
	return { version = entry.version, direct = vim.NIL, effective = vim.NIL, shadowed = false, exact = false }
end

function M.initialize()
	local managed = {}
	for _, name in ipairs(toolchain.managed_order) do
		managed[name] = managed_placeholder(name)
	end
	local version = vim.version()
	local report = {
		schema_version = SCHEMA,
		status = "running",
		changed = false,
		error_codes = {},
		nvim = {
			actual = ("%d.%d.%d"):format(version.major, version.minor, version.patch),
			minimum = "0.12.0",
			supported = vim.fn.has("nvim-0.12") == 1,
		},
		lock = { sha256 = lock_digest(), unchanged = true },
		profiles = {
			editor = { plugins = M.empty_inventory(), parsers = M.empty_inventory() },
			nvimpager = { plugins = M.empty_inventory(), parsers = M.empty_inventory() },
		},
		mason = M.empty_inventory(),
		managed_tools = managed,
	}
	write_report(report)
	if not report.nvim.supported then
		return M.fail("nvim-version")
	end
	return true
end

function M.update_lock(report)
	report.lock.unchanged = report.lock.sha256 == lock_digest()
	return report.lock.unchanged
end

function M.fail(code)
	assert(allowed_errors[code], "unknown provision error code")
	local report = load_report()
	if not vim.tbl_contains(report.error_codes, code) then
		report.error_codes[#report.error_codes + 1] = code
		table.sort(report.error_codes)
	end
	report.status = "failed"
	M.update_lock(report)
	write_report(report)
	return false
end

function M.fail_if_running(code)
	local report = load_report()
	return report.status == "running" and M.fail(code) or false
end

M.contract_version = SCHEMA
M.json_encode = json_encode
M.load = load_report
M.write = write_report
M.path = report_path
M.config_root = config_root

return M
