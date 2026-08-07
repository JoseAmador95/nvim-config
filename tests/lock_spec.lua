local function fail(message)
	error("lock_spec: " .. message, 0)
end

local function read_file(path)
	local fd, open_err = io.open(path, "rb")
	if not fd then
		fail(("cannot open %s: %s"):format(path, tostring(open_err)))
	end
	local contents = fd:read("*a")
	fd:close()
	return contents
end

local repo_root = vim.env.NVIM_CONFIG_ROOT
if not repo_root or repo_root == "" then
	repo_root = vim.fn.getcwd()
end
repo_root = vim.fs.normalize(repo_root)

local plugin_root = vim.env.NVIM_CONFIG_PLUGIN_ROOT
if not plugin_root or plugin_root == "" then
	plugin_root = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")
end
plugin_root = vim.fs.normalize(plugin_root)

local lock_path = vim.fs.joinpath(repo_root, "lazy-lock.json")
local ok, lock = pcall(vim.json.decode, read_file(lock_path))
if not ok or type(lock) ~= "table" then
	fail("invalid lazy-lock.json: " .. tostring(lock))
end

local names = vim.tbl_keys(lock)
table.sort(names)

local errors = {}
for _, name in ipairs(names) do
	local expected = lock[name] and lock[name].commit
	local path = vim.fs.joinpath(plugin_root, name)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "directory" then
		errors[#errors + 1] = ("%s is missing at %s"):format(name, path)
	elseif type(expected) ~= "string" or #expected ~= 40 or not expected:match("^[0-9a-f]+$") then
		errors[#errors + 1] = ("%s does not have a full 40-character lock commit"):format(name)
	else
		local result = vim.system({ "git", "-C", path, "rev-parse", "HEAD" }, { text = true }):wait(10000)
		local actual = vim.trim(result.stdout or "")
		if result.code ~= 0 then
			errors[#errors + 1] = ("%s is not a readable Git checkout: %s"):format(name, vim.trim(result.stderr or ""))
		elseif actual ~= expected then
			errors[#errors + 1] = ("%s: lock=%s checkout=%s"):format(name, expected, actual)
		end
	end
end

if #errors > 0 then
	fail("plugin lock is not restored:\n  - " .. table.concat(errors, "\n  - "))
end

print(("lock_spec: %d plugin checkouts match lazy-lock.json"):format(#names))
