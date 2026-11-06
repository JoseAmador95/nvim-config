-- Installed Lazy plugins against the lockfile. git_head() and inspect() only
-- read files (no Git process, no Lazy task, no mutation), so :checkhealth can
-- use them. restore_locked() is the startup repair config.lazy runs before Lazy
-- loads any plugin.
local M = {}

local uv = vim.uv

local function read_first_line(path)
	local fd = io.open(path, "rb")
	if not fd then
		return nil
	end
	local line = fd:read("*l")
	fd:close()
	return line
end

---Return a checkout's HEAD commit by reading its Git files.
---@param dir string
---@return string?
function M.git_head(dir)
	local git_dir = dir .. "/.git"
	local stat = uv.fs_stat(git_dir)
	if stat and stat.type == "file" then
		local pointer = read_first_line(git_dir)
		git_dir = pointer and pointer:match("^gitdir: (.+)$")
		if not git_dir then
			return nil
		end
		if git_dir:sub(1, 1) ~= "/" then
			git_dir = dir .. "/" .. git_dir
		end
	end
	local head = read_first_line(git_dir .. "/HEAD")
	if not head then
		return nil
	end
	local ref = head:match("^ref: (.+)$")
	if not ref then
		return head:match("^(%x+)$")
	end
	local value = read_first_line(git_dir .. "/" .. ref)
	if value then
		return value:match("^(%x+)")
	end
	local packed = io.open(git_dir .. "/packed-refs", "rb")
	if not packed then
		return nil
	end
	for line in packed:lines() do
		local sha, name = line:match("^(%x+) (.+)$")
		if name == ref then
			packed:close()
			return sha
		end
	end
	packed:close()
	return nil
end

local function read_lock(path)
	local fd = path and io.open(path, "rb") or nil
	if not fd then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, fd:read("*a"))
	fd:close()
	return ok and type(decoded) == "table" and decoded or {}
end

---Move installed checkouts that are at another commit to their locked commit,
---fetching it first when it is not present. A checkout that cannot be moved is
---left as it is and reported.
---@param entries table<string, { commit: string }>
---@param root string Lazy's plugin root
---@param run_git fun(argv: string[]): integer Returns the exit code.
---@param skip? table<string, boolean>
---@return string[] restored
---@return string[] failed
function M.restore_locked(entries, root, run_git, skip)
	local restored, failed = {}, {}
	local names = vim.tbl_keys(entries)
	table.sort(names)
	for _, name in ipairs(names) do
		local entry = entries[name]
		local locked = type(entry) == "table" and entry.commit or nil
		if not (skip and skip[name]) and type(locked) == "string" and locked:match("^%x+$") then
			local dir = root .. "/" .. name
			local head = M.git_head(dir)
			if head and head ~= locked then
				local ok = run_git({ "git", "-C", dir, "cat-file", "-e", locked .. "^{commit}" }) == 0
					or run_git({
							"git",
							"-C",
							dir,
							"fetch",
							"--quiet",
							"--filter=blob:none",
							"--no-tags",
							"origin",
							locked,
						})
						== 0
				ok = ok and run_git({ "git", "-C", dir, "checkout", "--quiet", "--detach", locked }) == 0
				local target = ok and restored or failed
				target[#target + 1] = name
			end
		end
	end
	return restored, failed
end

---Inspect the plugins Lazy knows about in this session.
---@return { loaded: boolean, lockfile?: string, total: integer, missing: string[], drift: { name: string, head: string, locked: string }[] }
function M.inspect()
	local result = { loaded = false, total = 0, missing = {}, drift = {} }
	local lazy_config = package.loaded["lazy.core.config"]
	if type(lazy_config) ~= "table" or type(lazy_config.plugins) ~= "table" then
		return result
	end
	result.loaded = true
	result.lockfile = type(lazy_config.options) == "table" and lazy_config.options.lockfile or nil
	local lock = read_lock(result.lockfile)
	local names = vim.tbl_keys(lazy_config.plugins)
	table.sort(names)
	for _, name in ipairs(names) do
		local plugin = lazy_config.plugins[name]
		local internal = type(plugin._) == "table" and plugin._ or {}
		if not internal.is_local and type(plugin.dir) == "string" then
			result.total = result.total + 1
			local locked = type(lock[name]) == "table" and lock[name].commit or nil
			if not internal.installed then
				result.missing[#result.missing + 1] = name
			elseif type(locked) == "string" then
				local head = M.git_head(plugin.dir)
				if head and head ~= locked then
					result.drift[#result.drift + 1] = { name = name, head = head, locked = locked }
				end
			end
		end
	end
	return result
end

return M
