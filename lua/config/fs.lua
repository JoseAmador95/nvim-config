-- Small filesystem helpers shared by configuration modules.
local M = {}

local uv = vim.uv

local function cleanup(path)
	if path then
		pcall(uv.fs_unlink, path)
	end
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

	local temp = ("%s.tmp.%d.%s"):format(path, uv.os_getpid(), tostring(uv.hrtime()))
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

	local renamed, rename_err = uv.fs_rename(temp, path)
	if not renamed then
		cleanup(temp)
		return nil, "cannot replace target file: " .. tostring(rename_err)
	end

	return true
end

return M
