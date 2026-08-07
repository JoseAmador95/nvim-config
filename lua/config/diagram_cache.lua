-- Shared content-addressed cache for diagram renderers.
local M = {}

local uv = vim.uv

local DAY_SECONDS = 24 * 60 * 60
local DEFAULT_MAX_AGE_SECONDS = 30 * DAY_SECONDS
local DEFAULT_MAX_BYTES = 256 * 1024 * 1024

local live = {}
local prune_scheduled = false
local prune_running = false

local function number_or(value, fallback, minimum)
	value = tonumber(value)
	if not value or value < minimum then
		return fallback
	end
	return math.floor(value)
end

local function limits()
	local configured = require("config.local_config").get("diagram_cache", {})
	if type(configured) ~= "table" then
		configured = {}
	end
	return {
		max_age_seconds = number_or(configured.max_age_seconds, DEFAULT_MAX_AGE_SECONDS, 1),
		max_bytes = number_or(configured.max_bytes, DEFAULT_MAX_BYTES, 1),
	}
end

local function mtime_seconds(stat)
	local mtime = stat and stat.mtime
	if type(mtime) == "table" then
		return tonumber(mtime.sec) or 0
	end
	return tonumber(mtime) or 0
end

local function encode(value)
	value = tostring(value or "")
	return tostring(#value) .. ":" .. value
end

local function argv_string(argv)
	local out = {}
	for _, arg in ipairs(argv or {}) do
		out[#out + 1] = encode(arg)
	end
	return table.concat(out)
end

-- A cheap version signal that changes when the resolved renderer binary does.
-- It avoids blocking the UI on `--version` while still invalidating cache files
-- after package upgrades or command-path changes.
function M.renderer_signal(argv)
	local executable = argv and argv[1] or ""
	local resolved = executable ~= "" and vim.fn.exepath(executable) or ""
	if resolved == "" then
		resolved = executable
	end
	local stat = resolved ~= "" and uv.fs_stat(resolved) or nil
	return table.concat({
		encode(resolved),
		encode(stat and stat.size or "missing"),
		encode(mtime_seconds(stat)),
	}, "|")
end

-- Cache identity includes source, semantic mode, exact renderer argv, and a
-- renderer version signal. `extra` can chain an upstream renderer key.
function M.key(spec)
	local argv = spec.argv or {}
	local material = table.concat({
		"diagram-cache-v2",
		encode(spec.source),
		encode(spec.mode),
		argv_string(argv),
		encode(spec.version_signal or M.renderer_signal(argv)),
		encode(spec.extra),
	}, "\0")
	return vim.fn.sha256(material)
end

local function schedule_prune()
	if prune_scheduled then
		return
	end
	prune_scheduled = true
	vim.schedule(function()
		M.prune()
	end)
end

function M.dir()
	local dir = vim.fn.stdpath("cache") .. "/diagram"
	vim.fn.mkdir(dir, "p")
	schedule_prune()
	return dir
end

function M.path(key, extension)
	return M.dir() .. "/" .. key .. "." .. extension
end

function M.retain(path)
	if path then
		live[path] = (live[path] or 0) + 1
	end
end

function M.release(path)
	if not path or not live[path] then
		return
	end
	live[path] = live[path] - 1
	if live[path] <= 0 then
		live[path] = nil
	end
end

function M.touch(path)
	local now = os.time()
	pcall(uv.fs_utime, path, now, now)
end

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

function M.is_png_data(data)
	return type(data) == "string"
		and #data >= 33
		and data:sub(1, 8) == PNG_SIGNATURE
		and data:sub(13, 16) == "IHDR"
		and data:sub(-8, -5) == "IEND"
end

function M.is_valid_png(path)
	local fd = uv.fs_open(path, "r", 0)
	if not fd then
		return false
	end
	local stat = uv.fs_fstat(fd)
	if not stat or stat.size < 33 then
		uv.fs_close(fd)
		return false
	end
	local head = uv.fs_read(fd, 24, 0) or ""
	local tail = uv.fs_read(fd, 12, stat.size - 12) or ""
	uv.fs_close(fd)
	local valid = head:sub(1, 8) == PNG_SIGNATURE and head:sub(13, 16) == "IHDR" and tail:sub(-8, -5) == "IEND"
	if valid then
		M.touch(path)
	end
	return valid
end

function M.read(path)
	local fd = uv.fs_open(path, "r", 0)
	if not fd then
		return nil
	end
	local stat = uv.fs_fstat(fd)
	local data = stat and uv.fs_read(fd, stat.size, 0) or nil
	uv.fs_close(fd)
	if data then
		M.touch(path)
	end
	return data
end

local function removable(path)
	return not live[path] and not path:find(".tmp.", 1, true)
end

-- Remove expired files first, then the oldest remaining cache entries until
-- the cache fits under its size ceiling. Retained images and renderer temp
-- files are never candidates.
function M.prune(options)
	if prune_running then
		return
	end
	prune_running = true
	prune_scheduled = true

	local opts = options or limits()
	local max_age = number_or(opts.max_age_seconds, DEFAULT_MAX_AGE_SECONDS, 1)
	local max_bytes = number_or(opts.max_bytes, DEFAULT_MAX_BYTES, 1)
	local dir = vim.fn.stdpath("cache") .. "/diagram"
	local scan = uv.fs_scandir(dir)
	if not scan then
		prune_running = false
		return
	end

	local now = os.time()
	local entries = {}
	while true do
		local name, kind = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if kind == "file" or kind == nil then
			local path = dir .. "/" .. name
			local stat = uv.fs_stat(path)
			if stat and removable(path) then
				local age = now - mtime_seconds(stat)
				if age > max_age then
					pcall(uv.fs_unlink, path)
				else
					entries[#entries + 1] = { path = path, size = stat.size or 0, mtime = mtime_seconds(stat) }
				end
			end
		end
	end

	local total = 0
	for _, entry in ipairs(entries) do
		total = total + entry.size
	end
	if total > max_bytes then
		table.sort(entries, function(a, b)
			if a.mtime == b.mtime then
				return a.path < b.path
			end
			return a.mtime < b.mtime
		end)
		for _, entry in ipairs(entries) do
			if total <= max_bytes then
				break
			end
			if removable(entry.path) then
				local called, removed = pcall(uv.fs_unlink, entry.path)
				if called and removed then
					total = total - entry.size
				end
			end
		end
	end

	prune_running = false
end

return M
