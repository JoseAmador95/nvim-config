-- Exact, non-pruning Lazy checkout reconciliation for explicit provisioning.
local M = {}

local fs = require("config.fs")
local uv = vim.uv

local function git_environment()
	local environment = {}
	for name, value in pairs(vim.fn.environ()) do
		if not name:match("^GIT_") then
			environment[name] = value
		end
	end
	environment.GIT_OPTIONAL_LOCKS = "0"
	return environment
end

local function run_git(path, arguments)
	local command = {
		"git",
		"--no-pager",
		"-c",
		"core.fsmonitor=false",
		"-c",
		"core.hooksPath=/dev/null",
		"-c",
		"diff.external=",
		"-c",
		"core.attributesFile=/dev/null",
		"-C",
		path,
	}
	vim.list_extend(command, arguments)
	local result = vim.system(command, { text = true, env = git_environment(), clear_env = true }):wait(30000)
	return result.code, result.stdout or "", vim.trim((result.stdout or "") .. "\n" .. (result.stderr or ""))
end

local function permitted_status(raw)
	for entry in raw:gmatch("[^%z]+") do
		if entry ~= "!! doc/tags" and entry ~= "?? doc/tags" then
			return false
		end
	end
	return true
end

function M.checkout(name, directory, expected)
	local stat = uv.fs_lstat(directory)
	local real = stat and stat.type == "directory" and uv.fs_realpath(directory) or nil
	if not real or vim.fs.normalize(real) ~= vim.fs.normalize(directory) then
		return { name = name, expected = expected, actual = vim.NIL, exact = false, problem = "unsafe-root" }
	end
	local identity_code, identity = run_git(directory, { "rev-parse", "--show-toplevel", "--verify", "HEAD^{commit}" })
	local top, head = identity:match("^(.-)\n([0-9a-f]+)\n?$")
	local top_real = top and uv.fs_realpath(vim.trim(top)) or nil
	if identity_code ~= 0 or not top_real or vim.fs.normalize(top_real) ~= vim.fs.normalize(real) then
		return { name = name, expected = expected, actual = vim.NIL, exact = false, problem = "invalid-git" }
	end
	local status_code, status =
		run_git(directory, { "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching" })
	local flags_code, flags = run_git(directory, { "ls-files", "-v", "-z" })
	local hidden = false
	if flags_code == 0 then
		for entry in flags:gmatch("[^%z]+") do
			local tag = entry:sub(1, 1)
			hidden = hidden or tag == "S" or tag:match("%l") ~= nil
		end
	end
	local problem
	if vim.trim(head or "") ~= expected then
		problem = "wrong-commit"
	elseif status_code ~= 0 or not permitted_status(status) then
		problem = "dirty"
	elseif flags_code ~= 0 or hidden then
		problem = "hidden-index-flags"
	end
	return {
		name = name,
		expected = expected,
		actual = head and vim.trim(head) or vim.NIL,
		exact = problem == nil,
		problem = problem or vim.NIL,
	}
end

local function read_lock()
	local root = assert(vim.env.NVIM_CONFIG_ROOT, "NVIM_CONFIG_ROOT is required")
	local raw, err = fs.read_binary(vim.fs.joinpath(root, "lazy-lock.json"))
	assert(raw, "cannot read lazy-lock.json: " .. tostring(err))
	local ok, lock = pcall(vim.json.decode, raw)
	assert(ok and type(lock) == "table", "lazy-lock.json is invalid")
	return lock
end

local function same_list(left, right)
	return vim.deep_equal(left or {}, right or {})
end

function M.inventory()
	local lock = read_lock()
	local required = {}
	local required_set = {}
	local problems = {}
	for _, plugin in pairs(require("lazy").plugins()) do
		if plugin.url and not (plugin._ and plugin._.is_local) then
			local entry = lock[plugin.name]
			local expected = type(entry) == "table" and entry.commit or nil
			local item
			if type(expected) ~= "string" or not expected:match("^[0-9a-f]+$") or #expected ~= 40 then
				item = {
					name = plugin.name,
					expected = vim.NIL,
					actual = vim.NIL,
					exact = false,
					problem = "unlocked",
				}
			else
				item = M.checkout(plugin.name, plugin.dir, expected)
			end
			required[#required + 1] = item
			required_set[plugin.name] = true
			if not item.exact then
				problems[#problems + 1] = plugin.name .. ":" .. tostring(item.problem)
			end
		end
	end
	table.sort(required, function(left, right)
		return left.name < right.name
	end)
	table.sort(problems)
	local extras = {}
	local root = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")
	local root_stat = uv.fs_lstat(root)
	if root_stat and root_stat.type == "directory" then
		for name, kind in vim.fs.dir(root) do
			if kind == "directory" and not required_set[name] then
				extras[#extras + 1] = name
			end
		end
	end
	table.sort(extras)
	return { required = required, exact = #problems == 0, problems = problems, extras = extras }
end

function M.provision(opts)
	opts = opts or {}
	local before = M.inventory()
	if before.exact then
		return true, before, vim.env.NVIM_CONFIG_PROVISION_BOOTSTRAPPED == "1"
	end
	if opts.allow_network ~= true then
		return false, before, false, "offline"
	end
	local ok, restore_err = pcall(function()
		return require("lazy").restore({ wait = true, show = false })
	end)
	if not ok then
		return false, before, true, tostring(restore_err)
	end
	local after = M.inventory()
	if not same_list(before.extras, after.extras) then
		after.exact = false
		after.problems[#after.problems + 1] = "extras-not-preserved"
		table.sort(after.problems)
	end
	return after.exact, after, true, after.exact and nil or "plugin checkouts remain inexact"
end

return M
