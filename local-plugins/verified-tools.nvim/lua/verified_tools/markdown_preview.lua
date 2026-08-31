local M = {}

function M.expected_name()
	local uname = vim.uv.os_uname()
	if uname.sysname == "Darwin" and (uname.machine == "arm64" or uname.machine == "aarch64") then
		return "markdown-preview-macos-arm64"
	elseif uname.sysname == "Darwin" then
		return "markdown-preview-macos"
	elseif uname.sysname == "Linux" then
		return "markdown-preview-linux"
	end
	return nil
end

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.repair(plugin_root, record)
	local name = M.expected_name()
	if not name or type(record) ~= "table" or record.status ~= "succeeded" then
		return nil, "attested tool is unavailable"
	end
	local identity = record.identity
	local attestation = record.attestation
	if type(identity) ~= "table" or identity.name ~= "markdown-preview" or type(attestation) ~= "table" then
		return nil, "attested tool identity is invalid"
	end
	if attestation.digest ~= identity.digest or type(attestation.path) ~= "string" then
		return nil, "attested tool digest is invalid"
	end
	local managed = vim.fs.normalize(attestation.path)
	if not contained(managed, identity.install_root) then
		return nil, "attested binary escaped its install root"
	end
	local managed_stat = vim.uv.fs_lstat(managed)
	if not managed_stat or managed_stat.type ~= "file" or vim.fn.executable(managed) ~= 1 then
		return nil, "attested binary is not executable"
	end
	local canonical_root = vim.uv.fs_realpath(plugin_root)
	if not canonical_root then
		return nil, "markdown-preview plugin root is unavailable"
	end
	local bin = vim.fs.joinpath(canonical_root, "app", "bin")
	local bin_stat = vim.uv.fs_lstat(bin)
	if not bin_stat or bin_stat.type ~= "directory" then
		return nil, "markdown-preview bin directory is unsafe"
	end
	local link = vim.fs.joinpath(bin, name)
	if not contained(link, canonical_root) then
		return nil, "markdown-preview link escaped the plugin root"
	end
	local current = vim.uv.fs_lstat(link)
	if current then
		if current.type ~= "link" then
			return nil, "refusing to replace a non-symlink markdown-preview binary"
		end
		if vim.uv.fs_readlink(link) == managed then
			return true
		end
	end
	local temp = link .. ".tmp." .. tostring(vim.uv.os_getpid()) .. "." .. tostring(vim.uv.hrtime())
	local created, create_err = vim.uv.fs_symlink(managed, temp)
	if not created then
		return nil, "could not create markdown-preview symlink: " .. tostring(create_err)
	end
	local promoted, promote_err = vim.uv.fs_rename(temp, link)
	if not promoted then
		pcall(vim.uv.fs_unlink, temp)
		return nil, "could not promote markdown-preview symlink: " .. tostring(promote_err)
	end
	return true
end

return M
