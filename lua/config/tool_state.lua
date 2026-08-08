-- Persistent one-shot installation state. An automatic claim is deliberately
-- consumptive: once the exact name@version record exists, even an interrupted
-- or corrupt attempt is never retried implicitly.
local M = {}

local fs = require("config.fs")
local uv = vim.uv

local VALID_STATUS = {
	claimed = true,
	installing = true,
	succeeded = true,
	failed = true,
}

local function root()
	return vim.fs.joinpath(require("config.tool_paths").primary_state_root(), "tool-bootstrap")
end

local function identity(name, version)
	assert(type(name) == "string" and name:match("^[%w_.-]+$"), "invalid tool name")
	assert(type(version) == "string" and version:match("^[%w][%w._+-]*$"), "invalid tool version")
	return name .. "@" .. version
end

local function paths(name, version)
	local exact = identity(name, version)
	local base = vim.fs.joinpath(root(), exact .. ".json")
	return exact, base, base .. ".lock"
end

local function mkdir_secure()
	local directory = root()
	local ok, result = pcall(vim.fn.mkdir, directory, "p", 448) -- 0700
	if not ok or (result ~= 0 and result ~= 1) then
		return nil, "state directory is not writable"
	end
	local changed, chmod_err = uv.fs_chmod(directory, 448)
	if not changed then
		return nil, "cannot secure state directory: " .. tostring(chmod_err)
	end
	return true
end

local function decode_record(path, expected, name, version)
	local data, read_err = fs.read_binary(path)
	if not data then
		return nil, "unreadable: " .. tostring(read_err)
	end
	local ok, value = pcall(vim.json.decode, data)
	if
		not ok
		or type(value) ~= "table"
		or value.schema ~= 1
		or value.name ~= name
		or value.version ~= version
		or value.identity ~= expected
		or not VALID_STATUS[value.status]
	then
		return nil, "corrupt"
	end
	return value
end

local function record(exact, name, version, status, detail)
	local value = {
		schema = 1,
		name = name,
		version = version,
		identity = exact,
		status = status,
		updated_at = os.time(),
		pid = uv.os_getpid(),
	}
	if type(detail) == "string" and detail ~= "" then
		-- Persist only a bounded, single-line reason category. Process output is
		-- intentionally excluded because it can contain credentials or host data.
		value.detail = detail:gsub("[%c]", " "):sub(1, 160)
	end
	return vim.json.encode(value) .. "\n"
end

local function write_fd(fd, data)
	local offset = 0
	while offset < #data do
		local written, err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			return nil, "cannot write claim: " .. tostring(err)
		end
		offset = offset + written
	end
	return true
end

local function write_atomic(path, exact, name, version, status, detail)
	local ok, err = fs.write_binary_atomic(path, record(exact, name, version, status, detail))
	if not ok then
		return nil, err
	end
	local changed, chmod_err = uv.fs_chmod(path, 384) -- 0600
	if not changed then
		return nil, "cannot secure state record: " .. tostring(chmod_err)
	end
	return true
end

local function create_exclusive(path, exact, name, version, status)
	local fd, open_err = uv.fs_open(path, "wx", 384)
	if not fd then
		return nil, tostring(open_err):match("EEXIST") and "consumed" or "state unavailable"
	end
	local wrote, write_err = write_fd(fd, record(exact, name, version, status))
	local closed = uv.fs_close(fd)
	if not wrote then
		return nil, write_err
	end
	if not closed then
		return nil, "cannot close claim"
	end
	return true
end

local function process_alive(pid)
	if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then
		return nil
	end
	local called, result, _, code = pcall(uv.kill, pid, 0)
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

function M.root()
	return root()
end

function M.identity(name, version)
	return identity(name, version)
end

-- Read-only inspection: this never creates the state directory.
function M.inspect(name, version)
	local exact, path, lock_path = paths(name, version)
	local stat, stat_err = uv.fs_stat(path)
	if not stat then
		if stat_err and not tostring(stat_err):match("ENOENT") then
			return nil, "unreadable"
		end
		return nil, uv.fs_stat(lock_path) and "locked" or "absent"
	end
	if stat.type ~= "file" then
		return nil, "corrupt"
	end
	return decode_record(path, exact, name, version)
end

-- Claim an automatic attempt with O_EXCL. An existing record of any contents
-- consumes the attempt. A failed initial write is intentionally left behind.
function M.claim_auto(name, version)
	local exact, path, lock_path = paths(name, version)
	if uv.fs_stat(lock_path) then
		return nil, "locked"
	end
	local ok, err = mkdir_secure()
	if not ok then
		return nil, err
	end
	local created, create_err = create_exclusive(path, exact, name, version, "claimed")
	if not created then
		return nil, create_err
	end
	return { identity = exact, name = name, version = version, path = path, mode = "auto" }
end

-- A manual attempt owns a separate exclusive lock for its whole lifetime.
-- Completed records and interrupted attempts whose owner no longer exists may
-- be retried manually. A live or unverifiable owner remains fail-closed.
function M.claim_manual(name, version)
	local exact, path, lock_path = paths(name, version)
	local ok, err = mkdir_secure()
	if not ok then
		return nil, err
	end
	local lock_fd, lock_err = uv.fs_open(lock_path, "wx", 384)
	if not lock_fd then
		return nil, tostring(lock_err):match("EEXIST") and "locked" or "state unavailable"
	end
	local lock_ok = write_fd(lock_fd, tostring(uv.os_getpid()) .. "\n")
	uv.fs_close(lock_fd)
	if not lock_ok then
		uv.fs_unlink(lock_path)
		return nil, "cannot write manual lock"
	end

	local stat = uv.fs_stat(path)
	if stat then
		local current, decode_err = decode_record(path, exact, name, version)
		if not current then
			uv.fs_unlink(lock_path)
			return nil, decode_err
		end
		if current.status == "claimed" or current.status == "installing" then
			local alive = process_alive(current.pid)
			if alive ~= false then
				uv.fs_unlink(lock_path)
				return nil, alive and current.status or "owner-unverifiable"
			end
		elseif current.status ~= "succeeded" and current.status ~= "failed" then
			uv.fs_unlink(lock_path)
			return nil, current.status
		end
		local wrote, write_err = write_atomic(path, exact, name, version, "claimed")
		if not wrote then
			uv.fs_unlink(lock_path)
			return nil, write_err
		end
	else
		-- Do not rename over an automatic claim that raced after our stat.
		-- O_EXCL makes absent-record manual claims and automatic claims mutually
		-- exclusive even when their separate lock checks interleave.
		local created, create_err = create_exclusive(path, exact, name, version, "claimed")
		if not created then
			uv.fs_unlink(lock_path)
			return nil, create_err
		end
	end

	return { identity = exact, name = name, version = version, path = path, lock_path = lock_path, mode = "manual" }
end

function M.transition(claim, status, detail)
	assert(type(claim) == "table" and claim.identity and claim.path, "invalid tool claim")
	assert(VALID_STATUS[status], "invalid tool state")
	return write_atomic(claim.path, claim.identity, claim.name, claim.version, status, detail)
end

function M.finish(claim, succeeded, detail)
	local ok, err = M.transition(claim, succeeded and "succeeded" or "failed", detail)
	if claim.mode == "manual" and claim.lock_path then
		local removed, unlink_err = uv.fs_unlink(claim.lock_path)
		if not removed and not tostring(unlink_err):match("ENOENT") and ok then
			return nil, "cannot release manual lock"
		end
	end
	return ok, err
end

return M
