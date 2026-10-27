-- SQLite owns transactions and inter-process locking; input handlers only update Lua counters.
local bit = require("bit")
local M = {}
local Store = {}
Store.__index = Store

local SCHEMA = [[
.timeout 1000
.once /dev/null
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS meta (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL);
INSERT OR IGNORE INTO meta VALUES (1, 1);
CREATE TABLE IF NOT EXISTS usage (
  session TEXT NOT NULL, day TEXT NOT NULL, profile TEXT NOT NULL,
  origin TEXT NOT NULL, action TEXT NOT NULL, mode TEXT NOT NULL,
  count INTEGER NOT NULL, last_used INTEGER,
  PRIMARY KEY (session, day, origin, action, mode)
);
]]

local function quote(value)
	return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function session_id()
	return ("%d-%d-%s"):format(os.time(), vim.uv.os_getpid(), tostring(vim.uv.hrtime()))
end

local function private_path(path)
	local directory = vim.fs.dirname(path)
	vim.fn.mkdir(directory, "p", 448)
	local stat = vim.uv.fs_lstat(directory)
	if not stat or stat.type ~= "directory" or stat.uid ~= vim.uv.getuid() or bit.band(stat.mode, 511) ~= 448 then
		return nil, "usage directory must be an owner-only directory"
	end
	stat = vim.uv.fs_lstat(path)
	if not stat then
		local fd, err = vim.uv.fs_open(path, "wx", 384)
		if fd then
			vim.uv.fs_close(fd)
		elseif not vim.uv.fs_lstat(path) then
			return nil, err
		end
		stat = vim.uv.fs_lstat(path)
	end
	if not stat or stat.type ~= "file" or stat.uid ~= vim.uv.getuid() or bit.band(stat.mode, 511) ~= 384 then
		return nil, "usage database must be an owner-only regular file"
	end
	return true
end

function Store:run(sql, callback)
	local options = { stdin = ".timeout 1000\n" .. sql, text = true, timeout = 2000 }
	local ok, job = pcall(vim.system, { self.sqlite, "-batch", "-bail", "-json", self.path }, options, callback)
	if not ok then
		local result = { code = 1, stderr = tostring(job) }
		if callback then
			callback(result)
			return nil
		end
		return result
	end
	return callback and job or job:wait()
end

local function decode(result)
	if result.code ~= 0 then
		return nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "SQLite did not finish"
	end
	local ok, value = pcall(vim.json.decode, result.stdout == "" and "[]" or result.stdout)
	if not ok then
		return nil, "SQLite returned an invalid report"
	end
	return value
end

function M.open(path, profile, clock)
	local sqlite = vim.fn.exepath("sqlite3")
	if sqlite == "" then
		return nil, "install the host sqlite3 CLI to collect usage statistics"
	end
	local ok, err = private_path(path)
	if not ok then
		return nil, err
	end
	local self = setmetatable({
		path = path,
		profile = profile,
		sqlite = sqlite,
		clock = clock or os.time,
		session = session_id(),
		rows = {},
		revision = 0,
		saved = 0,
	}, Store)
	local result, init_err = decode(self:run(SCHEMA .. "SELECT generation FROM meta WHERE id=1;"))
	if not result then
		return nil, init_err
	end
	self.generation = result[1].generation
	return self
end

function Store:record(origin, action, mode, amount)
	local now = self.clock()
	local day = os.date("%Y-%m-%d", now)
	local key = table.concat({ day, origin, action, mode }, "\0")
	local row = self.rows[key]
	if not row then
		row = { day = day, origin = origin, action = action, mode = mode, count = 0 }
		self.rows[key] = row
	end
	row.count = row.count + (amount or 1)
	if row.count > 0 then
		row.last_used = now
	end
	self.revision = self.revision + 1
end

function Store:fresh(generation)
	self.generation = generation
	self.session = session_id()
	for _, row in pairs(self.rows) do
		row.count, row.last_used = 0, nil
	end
	self.revision = self.revision + 1
end

-- Absolute per-session counters make retries safe even if a process exited after COMMIT.
function Store:flush(synchronous)
	if self.job then
		if not synchronous then
			return true
		end
		self.job:wait(2500)
	end
	if self.revision == self.saved then
		return true
	end
	local revision = self.revision
	local sql = { "BEGIN IMMEDIATE;" }
	for _, row in pairs(self.rows) do
		sql[#sql + 1] = (
			"INSERT INTO usage SELECT %s,%s,%s,%s,%s,%s,%d,%s "
			.. "WHERE (SELECT generation FROM meta WHERE id=1)=%d "
			.. "ON CONFLICT(session,day,origin,action,mode) DO UPDATE SET "
			.. "count=max(usage.count,excluded.count),last_used=max(coalesce(usage.last_used,0),coalesce(excluded.last_used,0));"
		):format(
			quote(self.session),
			quote(row.day),
			quote(self.profile),
			quote(row.origin),
			quote(row.action),
			quote(row.mode),
			row.count,
			row.last_used or "NULL",
			self.generation
		)
	end
	vim.list_extend(sql, { "COMMIT;", "SELECT generation FROM meta WHERE id=1;" })
	local function complete(result)
		self.job = nil
		local values, err = decode(result)
		self.error = err
		if values then
			self.saved = revision
			if values[1].generation ~= self.generation then
				-- Another editor reset the shared database. Drop its old pending snapshot.
				self:fresh(values[1].generation)
			end
		end
	end
	if synchronous then
		complete(self:run(table.concat(sql, "\n")))
	else
		self.job = self:run(table.concat(sql, "\n"), complete)
	end
	return self.error == nil, self.error
end

function Store:report(origin, days)
	local ok, err = self:flush(true)
	if not ok then
		return nil, err
	end
	local condition = origin == "all" and "1" or "origin=" .. quote(origin)
	local period = "1"
	if days > 0 then
		period = ("day>=date('now','localtime','-%d days')"):format(days - 1)
	end
	return decode(self:run(([[
SELECT profile,origin,action,mode,sum(CASE WHEN %s THEN count ELSE 0 END) AS uses,
 count(DISTINCT CASE WHEN %s AND count>0 THEN day END) AS days,coalesce(max(last_used),0) AS last_used
FROM usage WHERE %s GROUP BY profile,origin,action,mode
ORDER BY uses DESC,action,mode,profile;
]]):format(period, period, condition)))
end

function Store:reset()
	local ok, err = self:flush(true)
	if not ok then
		return nil, err
	end
	local result, reset_err = decode(self:run([[BEGIN IMMEDIATE;
DELETE FROM usage;
UPDATE meta SET generation=generation+1 WHERE id=1;
COMMIT;
SELECT generation FROM meta WHERE id=1;]]))
	if not result then
		return nil, reset_err
	end
	self:fresh(result[1].generation)
	return true
end

return M
