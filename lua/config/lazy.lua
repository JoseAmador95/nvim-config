-- lua/config/lazy.lua
-- Bootstrap lazy.nvim and load plugin specs from lua/plugins/

local fn = vim.fn
local uv = vim.uv
local lazypath = fn.stdpath("data") .. "/lazy/lazy.nvim"

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.lazy source")
source = uv.fs_realpath(source) or fn.fnamemodify(source, ":p")
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local lazy_lock = require("config.lazy_lock")
local lazy_attestation = require("config.lazy_attestation")
local locked_lazy, locked_lazy_err = lazy_lock.plugin(repo_root, "lazy.nvim")
if not locked_lazy then
	error("Cannot resolve the locked lazy.nvim bootstrap: " .. tostring(locked_lazy_err))
end

local function git_environment()
	local environment = {}
	for name, value in pairs(fn.environ()) do
		if not name:match("^GIT_") then
			environment[name] = value
		end
	end
	environment.GIT_OPTIONAL_LOCKS = "0"
	return environment
end

local function start_git(arguments)
	assert(arguments[1] == "git", "run_git expects a git command")
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
	}
	vim.list_extend(command, vim.list_slice(arguments, 2))
	return vim.system(command, { text = true, env = git_environment(), clear_env = true })
end

local function finish_git(process)
	local result = process:wait()
	local stdout = vim.trim(result.stdout or "")
	local detail = vim.trim(table.concat({ result.stdout or "", result.stderr or "" }, "\n"))
	if detail == "" then
		detail = "git produced no command output"
	end
	return result.code, stdout, detail
end

local function run_git(arguments)
	return finish_git(start_git(arguments))
end

local function remove_bootstrap(path)
	pcall(fn.delete, path, "rf")
end

local validate_lazy_checkout

local function bootstrap_lazy()
	local parent = vim.fs.dirname(lazypath)
	fn.mkdir(parent, "p", tonumber("700", 8))
	local staging = ("%s.bootstrap.%d.%s"):format(lazypath, uv.os_getpid(), tostring(uv.hrtime()))

	local clone_code, _, clone_detail = run_git({
		"git",
		"clone",
		"--filter=blob:none",
		"--branch=" .. locked_lazy.branch,
		"--single-branch",
		"--no-checkout",
		"https://github.com/folke/lazy.nvim",
		staging,
	})
	if clone_code ~= 0 or not uv.fs_stat(staging) then
		remove_bootstrap(staging)
		error(
			("Failed to bootstrap lazy.nvim at %s (git exit %s): %s\nCheck Git/network access, then retry."):format(
				lazypath,
				tostring(clone_code),
				clone_detail
			)
		)
	end

	local checkout_code, _, checkout_detail = run_git({
		"git",
		"-C",
		staging,
		"checkout",
		"--detach",
		locked_lazy.commit,
	})
	if checkout_code ~= 0 then
		remove_bootstrap(staging)
		error(
			("Failed to check out locked lazy.nvim commit %s (git exit %s): %s"):format(
				locked_lazy.commit,
				tostring(checkout_code),
				checkout_detail
			)
		)
	end

	local branch_code, _, branch_detail = run_git({
		"git",
		"-C",
		staging,
		"symbolic-ref",
		"refs/remotes/origin/HEAD",
		"refs/remotes/origin/" .. locked_lazy.branch,
	})
	if branch_code ~= 0 then
		remove_bootstrap(staging)
		error("Could not record lazy.nvim's locked branch: " .. branch_detail)
	end
	local staged_ok, staged_err = validate_lazy_checkout(staging, { allow_cache = false })
	if not staged_ok then
		remove_bootstrap(staging)
		error("Refusing to promote an invalid lazy.nvim bootstrap: " .. tostring(staged_err))
	end

	local renamed, rename_err = uv.fs_rename(staging, lazypath)
	if not renamed then
		remove_bootstrap(staging)
		error(("Could not promote the locked lazy.nvim checkout to %s: %s"):format(lazypath, tostring(rename_err)))
	end
end

local function remediation()
	return (
		"The existing checkout was not changed. Move it aside and restart Neovim, "
		.. "or run %s/scripts/bootstrap-config with an isolated --xdg-root."
	):format(repo_root)
end

validate_lazy_checkout = function(path, options)
	options = options or {}
	local suffix = options.remediation == true and "\n" .. remediation() or ""
	local checkout_real = uv.fs_realpath(path)
	if not checkout_real then
		return nil, ("Cannot resolve lazy.nvim checkout at %s.%s"):format(path, suffix)
	end
	checkout_real = vim.fs.normalize(checkout_real)
	local cache_allowed = options.allow_cache ~= false
	local cache_hit, cache_status = lazy_attestation.checkout_begin({
		root = checkout_real,
		head = locked_lazy.commit,
		allow_cache = cache_allowed,
	})
	if cache_allowed and cache_hit then
		return true
	end
	local checkout_before = cache_status.snapshot

	-- These two read-only inspections are independent. Starting both before
	-- waiting preserves the exact fail-closed checks while avoiding serial Git
	-- process and filesystem latency on remote HOME directories.
	local identity_process =
		start_git({ "git", "-C", path, "rev-parse", "--show-toplevel", "--verify", "HEAD^{commit}" })
	local status_process = start_git({
		"git",
		"-C",
		path,
		"status",
		"--porcelain=v1",
		"-z",
		"--untracked-files=all",
		"--ignored=matching",
	})
	local identity_code, identity, identity_detail = finish_git(identity_process)
	local status_code, changes, status_detail = finish_git(status_process)
	local top, head = identity:match("^(.-)\n([0-9a-f]+)$")
	local top_real = identity_code == 0 and top and uv.fs_realpath(top) or nil
	if not top_real or vim.fs.normalize(top_real) ~= checkout_real then
		return nil,
			("Refusing lazy.nvim repository redirection at %s (git top-level: %s).%s"):format(
				path,
				identity_code == 0 and tostring(top) or identity_detail,
				suffix
			)
	end

	if head ~= locked_lazy.commit then
		return nil,
			("Refusing to load lazy.nvim from %s: expected locked commit %s, got %s.%s"):format(
				path,
				locked_lazy.commit,
				head,
				suffix
			)
	end

	if status_code ~= 0 then
		return nil, ("Cannot inspect lazy.nvim worktree at %s: %s.%s"):format(path, status_detail, suffix)
	end
	if changes ~= "" then
		for change in changes:gmatch("[^%z]+") do
			-- Neovim's helptags generation creates this ignored, non-executable
			-- index file during normal plugin startup.
			if change ~= "!! doc/tags" then
				return nil, ("Refusing modified lazy.nvim checkout at %s (%s).%s"):format(path, change, suffix)
			end
		end
	end

	local flags_ok, flags_err = lazy_attestation.verify({
		root = checkout_real,
		head = head,
		run_git = run_git,
		allow_cache = options.allow_cache ~= false,
	})
	if not flags_ok then
		if flags_err.kind == "hidden-index-flags" then
			return nil,
				("Refusing lazy.nvim checkout with hidden index flags at %s (%s).%s"):format(
					path,
					flags_err.entry,
					suffix
				)
		elseif flags_err.kind == "inspect-failed" then
			return nil,
				("Cannot inspect lazy.nvim index flags at %s (git exit %s): %s%s"):format(
					path,
					tostring(flags_err.code),
					flags_err.detail,
					suffix
				)
		end
		return nil, ("lazy.nvim index changed while inspecting hidden flags at %s.%s"):format(path, suffix)
	end
	local cached_ok, cached_err = lazy_attestation.checkout_commit({
		root = checkout_real,
		head = head,
		before = checkout_before,
		allow_cache = cache_allowed,
	})
	if not cached_ok then
		return nil,
			("lazy.nvim checkout changed while establishing startup authority at %s (%s).%s"):format(
				path,
				tostring(cached_err and cached_err.detail or "unknown metadata race"),
				suffix
			)
	end
	return true
end

local lazy_stat = uv.fs_stat(lazypath)
if not lazy_stat then
	if vim.env.NVIM_CONFIG_BOOTSTRAP ~= "1" then
		error(
			("lazy.nvim is missing at %s; run scripts/bootstrap-config explicitly before starting Neovim"):format(
				lazypath
			)
		)
	end
	bootstrap_lazy()
	lazy_stat = uv.fs_stat(lazypath)
end
if lazy_stat.type ~= "directory" then
	error("Cannot use lazy.nvim path " .. lazypath .. ": destination is not a directory")
end
local checkout_ok, checkout_err = validate_lazy_checkout(lazypath, { remediation = true })
if not checkout_ok then
	error(checkout_err)
end
vim.opt.rtp:prepend(lazypath)

local pager = require("config.pager")
local lockfile = lazy_lock.resolve(repo_root, pager.active)

-- Give every native spec the branch already recorded in the immutable lock.
-- Fresh restores check out exact commits (detached HEAD); without this public
-- spec field Lazy may try to infer a default branch from origin/HEAD while the
-- remote is still incomplete and abort before the lock can be reproduced.
local lock_entries, lock_entries_err = lazy_lock.entries(repo_root)
if not lock_entries then
	error("Cannot read native plugin branches: " .. tostring(lock_entries_err))
end

local function spec_name(spec)
	if type(spec) == "table" and type(spec.name) == "string" then
		return spec.name
	end
	local source = type(spec) == "table" and spec[1] or spec
	if type(source) ~= "string" then
		return nil
	end
	local name = source:match("([^/]+)$") or source
	return name:gsub("%.git$", "")
end

local function pin_spec(spec)
	if type(spec) == "string" then
		local entry = lock_entries[spec_name(spec)]
		return entry and { spec, branch = entry.branch } or spec
	end
	if type(spec) ~= "table" then
		return spec
	end
	if #spec > 1 or vim.islist(spec) then
		for index, child in ipairs(spec) do
			spec[index] = pin_spec(child)
		end
		return spec
	end
	local entry = lock_entries[spec_name(spec)]
	if entry and spec.branch == nil then
		spec.branch = entry.branch
	end
	if type(spec.dependencies) == "table" then
		for index, dependency in ipairs(spec.dependencies) do
			spec.dependencies[index] = pin_spec(dependency)
		end
	end
	if type(spec.specs) == "table" then
		spec.specs = pin_spec(spec.specs)
	end
	return spec
end

local function native_editor_specs()
	local directory = vim.fs.joinpath(repo_root, "lua", "plugins")
	local files = {}
	for name, kind in vim.fs.dir(directory) do
		if kind == "file" and name:sub(-4) == ".lua" then
			files[#files + 1] = name
		end
	end
	table.sort(files)
	local result = {}
	for _, name in ipairs(files) do
		local path = vim.fs.joinpath(directory, name)
		local chunk, load_err = loadfile(path)
		if not chunk then
			error(("Could not load native plugin spec %s: %s"):format(path, tostring(load_err)))
		end
		local ok, value = pcall(chunk)
		if not ok or type(value) ~= "table" then
			error(("Invalid native plugin spec %s: %s"):format(path, tostring(value)))
		end
		result[#result + 1] = pin_spec(value)
	end
	return result
end

-- In pager mode (nvimpager) load only the minimal allowlist; skip the full
-- `{ import = "plugins" }` set and any external ~/.nvim-local.lua plugin dirs.
local specs
if pager.active then
	specs = pin_spec(pager.specs())
else
	-- Native specs from lua/plugins, plus any external dirs from ~/.nvim-local.lua.
	specs = {
		{
			name = "nvim_config_plugins",
			import = native_editor_specs,
		},
	}
	for _, dir in ipairs(require("config.local_config").get("plugins_dir", {})) do
		dir = fn.expand(dir)
		if fn.isdirectory(dir) == 1 then
			for _, file in ipairs(fn.glob(dir .. "/*.lua", true, true)) do
				-- External specs are arbitrary code that also installs plugins, so
				-- gate each file on a trust prompt (vim.secure.read).
				local contents = vim.secure.read(file)
				if contents then
					local chunk = load(contents, "@" .. file)
					local ok, spec
					if chunk then
						ok, spec = pcall(chunk)
					end
					if ok and type(spec) == "table" then
						specs[#specs + 1] = spec -- lazy flattens nested spec lists
					else
						vim.notify(
							"Failed to load plugin spec " .. file,
							vim.log.levels.WARN,
							{ title = "nvim.config" }
						)
					end
				end
			end
		end
	end
end

local runtime_paths = { repo_root }
vim.list_extend(runtime_paths, require("config.local_plugins").paths())

require("lazy").setup(specs, {
	defaults = { lazy = true }, -- lazy-load by default
	install = { missing = vim.env.NVIM_CONFIG_BOOTSTRAP == "1" },
	lockfile = lockfile,
	ui = { border = "rounded" },
	change_detection = { notify = false },
	performance = {
		rtp = {
			paths = runtime_paths,
			disabled_plugins = { "gzip", "tarPlugin", "zipPlugin", "netrwPlugin" },
		},
	},
})
