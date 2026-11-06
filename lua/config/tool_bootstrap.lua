-- Thin editor adapter. Mise owns package installation and dependency resolution.
local M = {}
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local uv = vim.uv
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local runner = root .. "/scripts/mise"
local launchers = {}

M._system = vim.system
M._notify = vim.notify

local function target()
	local uname = uv.os_uname()
	return manifest.target_key(uname.sysname, uname.machine)
end

local function quote(value)
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function notify(message, level)
	M._notify(message, level or vim.log.levels.INFO, { title = "Mise" })
end

local function launcher(name, command)
	local entry = manifest.tools[name]
	if not entry or not vim.tbl_contains(entry.commands, command) then
		return nil, "Unknown catalog command: " .. tostring(name) .. "/" .. tostring(command)
	end
	if not manifest.supported(name, target()) then
		return nil, name .. " is unsupported on " .. tostring(target())
	end
	local path = paths.managed_bin() .. "/" .. command
	if launchers[path] and vim.fn.executable(path) == 1 then
		return path
	end
	local request = vim.tbl_map(quote, manifest.request_tools(name))
	local prefix = quote(runner) .. " exec " .. table.concat(request, " ") .. " -- "
	local body = "#!/bin/sh\nexec " .. prefix .. quote(command) .. ' "$@"\n'
	if name == "plantuml" and target() == "macos-x64" then
		body = "#!/bin/sh\nset -eu\n"
			.. prefix
			.. "/usr/bin/true\n"
			.. "jar=$("
			.. quote(runner)
			.. " which plantuml.jar)\n"
			.. "exec "
			.. prefix
			.. 'java -jar "$jar" "$@"\n'
	end
	local existing = io.open(path, "rb")
	if existing then
		local same = existing:read(#body + 1) == body
		existing:close()
		if same and vim.fn.executable(path) == 1 then
			launchers[path] = true
			return path
		end
	end
	vim.fn.mkdir(paths.managed_bin(), "p", 448)
	local temporary = path .. "." .. tostring(uv.os_getpid()) .. ".tmp"
	local fd, err = uv.fs_open(temporary, "w", 448)
	if not fd then
		return nil, err
	end
	local written, write_err = uv.fs_write(fd, body, 0)
	uv.fs_close(fd)
	if written ~= #body then
		uv.fs_unlink(temporary)
		return nil, write_err or "could not write Mise launcher"
	end
	local ok, rename_err = uv.fs_rename(temporary, path)
	if not ok then
		uv.fs_unlink(temporary)
		return nil, rename_err
	end
	launchers[path] = true
	return path, nil, true
end

function M.resolve(name, command)
	if vim.fn.executable("mise") ~= 1 then
		return nil, "Mise is missing; install it or run :NvimConfigMiseInstall"
	end
	return launcher(name, command)
end

local function run(args, opts)
	local argv = { runner }
	vim.list_extend(argv, args)
	local result =
		M._system(argv, { text = true, env = { NVIM_CONFIG_OFFLINE = opts and opts.allow_network and "0" or "1" } })
			:wait(opts and opts.timeout or 30000)
	if result.code ~= 0 then
		return nil, result.stderr ~= "" and result.stderr or "Mise command failed"
	end
	return result.stdout
end

-- Read-only inventory. No version probe executes an installed tool.
function M.inventory()
	local mise =
		{ path = vim.fn.exepath("mise"), version = vim.NIL, minimum = manifest.versions.mise, supported = false }
	local tools = {}
	for _, name in ipairs(manifest.tool_order) do
		local entry = manifest.tools[name]
		tools[name] = {
			expected_version = entry.version,
			installed_version = vim.NIL,
			path = vim.NIL,
			status = manifest.supported(name, target()) and "missing" or "unsupported",
		}
	end
	if mise.path == "" then
		return { mise = mise, tools = tools, extras = {} }, "Mise is missing; run :NvimConfigMiseInstall"
	end
	local version, version_err = run({ "version", "--json" })
	local decoded, value = pcall(vim.json.decode, version or "")
	local actual = decoded and (type(value) == "table" and value.version or value) or nil
	if type(actual) ~= "string" then
		return { mise = mise, tools = tools, extras = {} }, version_err or "Cannot read Mise version"
	end
	mise.version = actual:match("%d+%.%d+%.%d+") or actual
	mise.supported = vim.version.ge(mise.version, mise.minimum)
	if not mise.supported then
		return { mise = mise, tools = tools, extras = {} }, "Mise " .. mise.minimum .. " or newer is required"
	end
	local raw, err = run({ "ls", "--json" })
	local ok, data = pcall(vim.json.decode, raw or "")
	if not ok or type(data) ~= "table" then
		return { mise = mise, tools = tools, extras = {} }, err or "Invalid Mise inventory"
	end
	local extras = {}
	for name, versions in pairs(data) do
		for _, item in ipairs(versions) do
			local required = tools[name]
			local version_string = tostring(item.version):gsub("^v", "")
			if required and required.status ~= "unsupported" and version_string == required.expected_version then
				if item.installed and item.active then
					required.installed_version = version_string
					required.path = item.install_path or vim.NIL
					required.status = "ready"
				end
			elseif item.installed then
				extras[#extras + 1] = name .. "@" .. tostring(item.version)
			end
		end
	end
	table.sort(extras)
	return { mise = mise, tools = tools, extras = extras }
end

local function selected(target_name)
	if target_name ~= "all" then
		if not manifest.tools[target_name] then
			return nil, "Unknown catalog tool: " .. target_name
		end
		if not manifest.supported(target_name, target()) then
			return nil, target_name .. " is unsupported on " .. tostring(target())
		end
		return manifest.request_tools(target_name)
	end
	local names = {}
	for _, name in ipairs(manifest.tool_order) do
		if manifest.supported(name, target()) then
			names[#names + 1] = name
		end
	end
	return names
end

local function publish(names)
	local changed = false
	for _, name in ipairs(names) do
		for _, command in ipairs(manifest.tools[name].commands) do
			local path, err, written = launcher(name, command)
			if not path then
				return nil, err, changed
			end
			changed = changed or written == true
		end
	end
	return true, nil, changed
end

function M.provision_exact(opts)
	opts = opts or {}
	local before, err = M.inventory()
	if err then
		return false, before, false, err, "mise"
	end
	local names = assert(selected("all"))
	local missing = {}
	for _, name in ipairs(names) do
		if before.tools[name].status ~= "ready" then
			missing[#missing + 1] = name
		end
	end
	if #missing > 0 and opts.allow_network then
		local args = { "install", "--locked" }
		vim.list_extend(args, missing)
		local _, install_err = run(args, opts)
		local after = M.inventory()
		if install_err then
			return false, after, not vim.deep_equal(before.tools, after.tools), install_err, "tools"
		end
	end
	local after, inventory_err = M.inventory()
	local changed = not vim.deep_equal(before.tools, after.tools)
	if inventory_err then
		return false, after, changed, inventory_err, "mise"
	end
	for _, name in ipairs(manifest.tool_order) do
		local status = after.tools[name].status
		if status ~= "ready" then
			return false,
				after,
				changed,
				name .. ": " .. status,
				status == "unsupported" and "unsupported-platform" or "tools"
		end
	end
	local ok, publish_err, published = publish(names)
	return ok == true, after, changed or published, publish_err, "tools"
end

function M.install(target_name, force)
	if vim.env.NVIM_CONFIG_OFFLINE == "1" then
		notify("Tool installation is disabled offline", vim.log.levels.WARN)
		return false
	end
	if vim.fn.executable("mise") ~= 1 then
		notify("Mise is missing; run :NvimConfigMiseInstall", vim.log.levels.ERROR)
		return false
	end
	local names, err = selected(target_name or "all")
	if not names then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	local args = { runner, "install", "--locked" }
	if force then
		args[#args + 1] = "--force"
	end
	vim.list_extend(args, names)
	notify("Installing locked tools: " .. table.concat(names, ", "))
	M._system(
		args,
		{ text = true },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				notify(result.stderr, vim.log.levels.ERROR)
				return
			end
			local ok, publish_err = publish(names)
			notify(ok and "Locked tools installed" or publish_err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
		end)
	)
	return true
end

---Install the pinned Mise asynchronously. `on_done(ok, detail)` replaces the
---default result notification.
---@param on_done? fun(ok: boolean, detail: string)
function M.install_mise(on_done)
	if vim.env.NVIM_CONFIG_OFFLINE == "1" then
		notify("Mise installation is disabled offline", vim.log.levels.WARN)
		return false
	end
	M._system(
		{ root .. "/scripts/install-mise" },
		{ text = true },
		vim.schedule_wrap(function(result)
			local ok = result.code == 0
			local detail = vim.trim(ok and result.stdout or result.stderr or "")
			if on_done then
				on_done(ok, detail ~= "" and detail or ("install-mise exited with " .. tostring(result.code)))
				return
			end
			notify(ok and result.stdout or result.stderr, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
		end)
	)
	return true
end

-- Upstream Markdown Preview accepts only its app/bin executable path.
function M.markdown_preview(plugin_root)
	local path, err = launcher("markdown-preview", "markdown-preview")
	if not path then
		return nil, err
	end
	local platform = ({ ["macos-arm64"] = "macos-arm64", ["macos-x64"] = "macos", ["linux-x64"] = "linux" })[target()]
	local destination = plugin_root .. "/app/bin/markdown-preview-" .. platform
	vim.fn.mkdir(vim.fs.dirname(destination), "p")
	local stat = uv.fs_lstat(destination)
	if stat and stat.type == "link" then
		if uv.fs_readlink(destination) == path then
			return true
		end
		assert(uv.fs_unlink(destination))
	elseif stat then
		if uv.fs_lstat(destination .. ".pre-mise") then
			return nil, "Markdown Preview backup already exists: " .. destination .. ".pre-mise"
		end
		assert(uv.fs_rename(destination, destination .. ".pre-mise"))
	end
	return uv.fs_symlink(path, destination)
end

return M
