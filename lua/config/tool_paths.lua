local M = {}

local function nonempty(value)
	return value ~= nil and value ~= ""
end

local function join(...)
	return vim.fs.joinpath(...)
end

local function expand(path)
	if not nonempty(path) then
		return nil
	end
	return vim.fs.normalize(vim.fn.expand(path))
end

local function xdg_root(variable, fallback)
	local configured = vim.env[variable]
	if nonempty(configured) then
		return expand(configured)
	end
	return expand(fallback)
end

-- Both the full editor and NVIMPAGER_FILETYPE profile deliberately share the
-- primary `nvim` roots. stdpath() cannot provide that contract while
-- NVIM_APPNAME=nvimpager, so derive it from XDG instead.
function M.primary_data_root()
	if nonempty(vim.env.NVIM_CONFIG_PRIMARY_DATA_ROOT) then
		return expand(vim.env.NVIM_CONFIG_PRIMARY_DATA_ROOT)
	end
	return join(xdg_root("XDG_DATA_HOME", "~/.local/share"), "nvim")
end

function M.primary_state_root()
	if nonempty(vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT) then
		return expand(vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT)
	end
	return join(xdg_root("XDG_STATE_HOME", "~/.local/state"), "nvim")
end

function M.managed_root()
	if nonempty(vim.env.NVIM_CONFIG_TOOLS_ROOT) then
		return expand(vim.env.NVIM_CONFIG_TOOLS_ROOT)
	end
	return join(M.primary_data_root(), "nvim-tools")
end

function M.managed_bin()
	return join(M.managed_root(), "bin")
end

function M.mason_root()
	if nonempty(vim.env.NVIM_CONFIG_MASON_ROOT) then
		return expand(vim.env.NVIM_CONFIG_MASON_ROOT)
	end
	return join(M.primary_data_root(), "mason")
end

function M.mason_bin()
	return join(M.mason_root(), "bin")
end

function M.verified_shim_bin()
	return join(M.primary_state_root(), "verified-tools", "shims", "bin")
end

local function within(path, root)
	path = expand(path)
	root = expand(root)
	if not path or not root then
		return false
	end
	root = root:gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.is_managed_path(path)
	return within(path, M.managed_root())
end

function M.is_mason_path(path)
	return within(path, M.mason_root())
end

function M.is_verified_shim_path(path)
	return within(path, M.verified_shim_bin())
end

local function split_path(path)
	local parts = {}
	for part in tostring(path or ""):gmatch("[^:]+") do
		parts[#parts + 1] = part
	end
	return parts
end

local function append_unique(parts, seen, path)
	path = expand(path)
	if not path or seen[path] then
		return
	end
	seen[path] = true
	parts[#parts + 1] = path
end

function M.compose_segments(local_paths, inherited)
	local parts = {}
	local seen = {}

	for _, path in ipairs(local_paths or {}) do
		append_unique(parts, seen, path)
	end
	append_unique(parts, seen, "~/.local/bin")
	append_unique(parts, seen, M.verified_shim_bin())

	for _, path in ipairs(split_path(inherited)) do
		if not M.is_managed_path(path) and not M.is_mason_path(path) and not M.is_verified_shim_path(path) then
			append_unique(parts, seen, path)
		end
	end

	append_unique(parts, seen, M.managed_bin())
	append_unique(parts, seen, M.mason_bin())
	return parts
end

function M.compose(local_paths, inherited)
	return table.concat(M.compose_segments(local_paths, inherited), ":")
end

function M.apply(local_paths)
	vim.env.PATH = M.compose(local_paths, vim.env.PATH)
	return vim.env.PATH
end

local function acceptable_external(path)
	if not path or M.is_managed_path(path) or M.is_mason_path(path) or M.is_verified_shim_path(path) then
		return nil
	end
	local realpath = vim.uv.fs_realpath(path)
	if realpath and (M.is_managed_path(realpath) or M.is_mason_path(realpath) or M.is_verified_shim_path(realpath)) then
		return nil
	end
	return vim.fn.executable(path) == 1 and path or nil
end

-- Locate a host/user executable while deliberately ignoring config-managed and
-- Mason shims. This lets installers decide whether a tool is already supplied
-- externally before they claim a one-shot attempt.
function M.external_executable(name, path)
	if not nonempty(name) then
		return nil
	end
	if name:find("/", 1, true) then
		return acceptable_external(expand(name))
	end
	for _, directory in ipairs(split_path(path or vim.env.PATH)) do
		local candidate = acceptable_external(join(expand(directory), name))
		if candidate then
			return candidate
		end
	end
	return nil
end

return M
