-- Canonical Git-repository and contained-path helpers shared by review tools.
local M = {}

local uv = vim.uv

local GIT_ROUTING_ENV = {
	"GIT_ALTERNATE_OBJECT_DIRECTORIES",
	"GIT_CEILING_DIRECTORIES",
	"GIT_COMMON_DIR",
	"GIT_CONFIG",
	"GIT_CONFIG_COUNT",
	"GIT_CONFIG_PARAMETERS",
	"GIT_DIR",
	"GIT_GRAFT_FILE",
	"GIT_IMPLICIT_WORK_TREE",
	"GIT_INDEX_FILE",
	"GIT_NAMESPACE",
	"GIT_OBJECT_DIRECTORY",
	"GIT_PREFIX",
	"GIT_REPLACE_REF_BASE",
	"GIT_SHALLOW_FILE",
	"GIT_WORK_TREE",
}

local GIT_SAFETY_ENV = {
	{ name = "GIT_OPTIONAL_LOCKS", value = "0" },
	{ name = "GIT_NO_LAZY_FETCH", value = "1" },
	{ name = "GIT_NO_REPLACE_OBJECTS", value = "1" },
	{ name = "GIT_GRAFT_FILE", value = "/dev/null/nvim-review-grafts" },
	{ name = "GIT_SHALLOW_FILE", value = "/dev/null/nvim-review-shallow" },
}

---Return the Git environment that preserves the stored object graph.
---@return table<string, string>
function M.git_safety_environment()
	local environment = {}
	for _, item in ipairs(GIT_SAFETY_ENV) do
		environment[item.name] = item.value
	end
	return environment
end

local function git_environment()
	local environment = vim.fn.environ()
	for _, name in ipairs(GIT_ROUTING_ENV) do
		environment[name] = nil
	end
	for name, value in pairs(M.git_safety_environment()) do
		environment[name] = value
	end
	return environment
end

---Prefix a Git command with an environment that cannot redirect repositories.
---@param command? string[]
---@return string[]
function M.clean_git_command(command)
	local isolated = { "env" }
	for _, name in ipairs(GIT_ROUTING_ENV) do
		isolated[#isolated + 1] = "-u"
		isolated[#isolated + 1] = name
	end
	for _, item in ipairs(GIT_SAFETY_ENV) do
		isolated[#isolated + 1] = item.name .. "=" .. item.value
	end
	vim.list_extend(isolated, command or { "git" })
	return isolated
end

---Return the first inherited variable that can redirect Git to another repository.
---@return string?
function M.git_routing_variable()
	for _, name in ipairs(GIT_ROUTING_ENV) do
		if vim.env[name] ~= nil then
			return name
		end
	end
	return nil
end

local function default_git(command)
	return vim.system(command, { text = true, env = git_environment(), clear_env = true }):wait()
end

local function canonical_directory(path)
	local expanded = vim.fn.fnamemodify(path, ":p")
	local stat = uv.fs_stat(expanded)
	if not stat or stat.type ~= "directory" then
		expanded = vim.fs.dirname(expanded)
	end
	return uv.fs_realpath(expanded) or vim.fs.normalize(expanded)
end

local function is_contained(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function relative_has_traversal(path)
	for segment in path:gmatch("[^/]+") do
		if segment == ".." then
			return true
		end
	end
	return false
end

function M.git(root, arguments, runner)
	local command = { "git", "-C", root }
	vim.list_extend(command, arguments)
	local result = (runner or default_git)(command)
	if not result or result.code ~= 0 then
		local reason = result and vim.trim(result.stderr or "") or "could not start Git"
		if reason == "" then
			reason = "Git exited with a nonzero status"
		end
		return nil, reason
	end
	return result.stdout or ""
end

function M.root(start, runner)
	if type(start) ~= "string" or start == "" or start:find("\0", 1, true) then
		return nil, "repository path is empty or invalid"
	end
	local directory = canonical_directory(start)
	local output, err = M.git(directory, { "rev-parse", "--show-toplevel" }, runner)
	if not output then
		return nil, "not inside a Git repository: " .. err
	end
	local candidate = vim.trim(output)
	if candidate == "" or candidate:find("\0", 1, true) or candidate:find("\n", 1, true) then
		return nil, "Git returned an invalid repository root"
	end
	local canonical = uv.fs_realpath(candidate)
	local stat = canonical and uv.fs_stat(canonical) or nil
	if not canonical or not stat or stat.type ~= "directory" then
		return nil, "Git returned a repository root that is not a directory"
	end
	return vim.fs.normalize(canonical)
end

function M.current_root(buf, runner)
	buf = buf or 0
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or uv.cwd()
	return M.root(start, runner)
end

function M.resolve_relative(root, relative)
	if type(relative) ~= "string" or relative == "" then
		return nil, "path must be a non-empty string"
	end
	if relative:find("\0", 1, true) then
		return nil, "path contains a NUL byte"
	end
	if relative:sub(1, 1) == "/" or relative:match("^%a:[/\\]") or relative:sub(1, 1) == "\\" then
		return nil, "path must be repository-relative"
	end
	if relative_has_traversal(relative) then
		return nil, "path traversal is not allowed"
	end

	local canonical_root = uv.fs_realpath(root)
	if not canonical_root then
		return nil, "repository root does not exist"
	end
	canonical_root = vim.fs.normalize(canonical_root)
	local lexical = vim.fs.normalize(vim.fs.joinpath(canonical_root, relative))
	local resolved = uv.fs_realpath(lexical)
	if not resolved then
		return nil, "path does not exist"
	end
	resolved = vim.fs.normalize(resolved)
	if not is_contained(canonical_root, resolved) then
		return nil, "path resolves outside the repository"
	end
	local stat = uv.fs_stat(resolved)
	if not stat or stat.type ~= "file" then
		return nil, "path is not a regular file"
	end
	return lexical, resolved
end

function M.relative_existing(root, path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
		return nil, "path is empty or invalid"
	end
	local canonical_root = uv.fs_realpath(root)
	local resolved = uv.fs_realpath(vim.fn.fnamemodify(path, ":p"))
	if not canonical_root or not resolved then
		return nil, "path does not exist"
	end
	canonical_root = vim.fs.normalize(canonical_root)
	resolved = vim.fs.normalize(resolved)
	if not is_contained(canonical_root, resolved) or resolved == canonical_root then
		return nil, "path resolves outside the repository"
	end
	local stat = uv.fs_stat(resolved)
	if not stat or stat.type ~= "file" then
		return nil, "path is not a regular file"
	end
	return resolved:sub(#canonical_root + 2), resolved
end

function M.contains(root, path)
	local canonical_root = uv.fs_realpath(root)
	local resolved = uv.fs_realpath(path)
	if not canonical_root or not resolved then
		return false
	end
	return is_contained(vim.fs.normalize(canonical_root), vim.fs.normalize(resolved))
end

return M
