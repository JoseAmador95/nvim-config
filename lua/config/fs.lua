-- Small filesystem helpers shared by configuration modules.
local M = {}

local uv = vim.uv

local temp_counter = 0

local function cleanup(path)
	if path then
		pcall(uv.fs_unlink, path)
	end
end

-- Read a complete file as bytes. Keeping this helper binary-safe avoids
-- newline rewriting when a lockfile or renderer output is copied verbatim.
function M.read_binary(path)
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "cannot open file: " .. tostring(open_err)
	end
	local stat, stat_err = uv.fs_fstat(fd)
	if not stat then
		pcall(uv.fs_close, fd)
		return nil, "cannot inspect file: " .. tostring(stat_err)
	end
	local data, read_err = uv.fs_read(fd, stat.size, 0)
	local closed, close_err = uv.fs_close(fd)
	if data == nil then
		return nil, "cannot read file: " .. tostring(read_err)
	end
	if not closed then
		return nil, "cannot close file: " .. tostring(close_err)
	end
	return data
end

-- Return a process-unique sibling path suitable for an external renderer's
-- output. Keeping the temporary file beside the target makes the final rename
-- atomic on normal filesystems.
function M.temp_path(path)
	temp_counter = temp_counter + 1
	return ("%s.tmp.%d.%s.%d"):format(path, uv.os_getpid(), tostring(uv.hrtime()), temp_counter)
end

-- Promote an already-written temporary file without exposing partial target
-- contents. The caller owns `temp`; it is removed when promotion fails.
function M.replace_atomic(temp, path)
	if type(temp) ~= "string" or temp == "" then
		return nil, "temporary path is empty"
	end
	if type(path) ~= "string" or path == "" then
		cleanup(temp)
		return nil, "target path is empty"
	end

	local renamed, rename_err = uv.fs_rename(temp, path)
	if not renamed then
		cleanup(temp)
		return nil, "cannot replace target file: " .. tostring(rename_err)
	end
	return true
end

-- Write arbitrary bytes to `path` without exposing a partially written target.
-- Returns true on success, or nil plus an actionable error string.
function M.write_binary_atomic(path, data)
	if type(path) ~= "string" or path == "" then
		return nil, "target path is empty"
	end
	if type(data) ~= "string" then
		return nil, "binary data must be a string"
	end

	local temp = M.temp_path(path)
	local fd, open_err = uv.fs_open(temp, "w", 384) -- 0600
	if not fd then
		return nil, "cannot open temporary file: " .. tostring(open_err)
	end

	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, fd)
			cleanup(temp)
			return nil, "cannot write temporary file: " .. tostring(write_err or "zero-byte write")
		end
		offset = offset + written
	end

	local closed, close_err = uv.fs_close(fd)
	if not closed then
		cleanup(temp)
		return nil, "cannot close temporary file: " .. tostring(close_err)
	end

	return M.replace_atomic(temp, path)
end

return M
