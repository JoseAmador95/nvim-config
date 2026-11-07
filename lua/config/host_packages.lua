-- Install hints for host dependencies, shown by :checkhealth nvimconfig.
--
-- Detection only reads os-release and PATH; it never runs a package manager.
-- Package names were checked against the Ubuntu, Fedora and Homebrew archives.
-- A distribution gets an install command only where the package exists: a
-- table such as `{ "lazygit", ubuntu = "26.04" }` names the first release that
-- ships it, so older releases fall back to Homebrew or the upstream download.
local M = {}

local uv = vim.uv

-- Fields: `apt`/`dnf`/`brew` package names, `macos` commands shown before
-- Homebrew, `macos_brew = false` when Homebrew cannot provide the command on
-- macOS, `rustup` when rustup can install it, `fallback` when no package
-- manager applies and `label` to name the dependency in generic advice.
M.packages = {
	git = {
		macos = "xcode-select --install",
		apt = "git",
		dnf = "git",
		brew = "git",
	},
	cc = {
		label = "a C compiler",
		macos = "xcode-select --install",
		apt = "build-essential",
		dnf = "gcc",
	},
	sqlite3 = {
		-- Homebrew's sqlite is keg-only on macOS because the system ships one.
		macos = "macOS ships /usr/bin/sqlite3: make sure /usr/bin is on PATH",
		macos_brew = false,
		apt = "sqlite3",
		dnf = "sqlite",
		brew = "sqlite",
	},
	["rsvg-convert"] = {
		apt = "librsvg2-bin",
		dnf = "librsvg2-tools",
		brew = "librsvg",
	},
	lazygit = {
		apt = { "lazygit", ubuntu = "26.04", debian = "13" },
		brew = "lazygit",
		fallback = "Download a release binary: https://github.com/jesseduffield/lazygit/releases",
	},
	nvimpager = {
		apt = { "nvimpager", ubuntu = "26.10" },
		brew = "nvimpager",
		fallback = "Install it from source: https://github.com/lucc/nvimpager",
	},
	["rust-analyzer"] = {
		rustup = "rustup component add rust-analyzer",
		apt = { "rust-analyzer", ubuntu = "26.10" },
		dnf = { "rust-analyzer", fedora = "40" },
		brew = "rust-analyzer",
		fallback = "Install rustup (https://rustup.rs), then run: rustup component add rust-analyzer",
	},
	neovim = {
		brew = "neovim",
		fallback = "Download Neovim 0.12 or newer: https://github.com/neovim/neovim/releases",
	},
}

local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	return text
end

local function list(value)
	if value == nil then
		return {}
	end
	return type(value) == "table" and value or { value }
end

local function version_at_least(version, minimum)
	local have = vim.split(version or "", ".", { plain = true })
	local need = vim.split(minimum, ".", { plain = true })
	if not tonumber(have[1]) then
		return false
	end
	for index = 1, math.max(#have, #need) do
		local a, b = tonumber(have[index]) or 0, tonumber(need[index]) or 0
		if a ~= b then
			return a > b
		end
	end
	return true
end

local function package_for(value, platform)
	if type(value) == "string" then
		return value
	end
	if type(value) ~= "table" then
		return nil
	end
	local minimum = platform.distro and value[platform.distro]
	if minimum and version_at_least(platform.version, minimum) then
		return value[1]
	end
	return nil
end

local function generic(name, spec)
	local names, all_same = {}, true
	for _, source in ipairs({ { "Debian/Ubuntu", spec.apt }, { "Fedora", spec.dnf }, { "Homebrew", spec.brew } }) do
		local package = type(source[2]) == "table" and source[2][1] or source[2]
		if type(package) == "string" then
			names[#names + 1] = source[1] .. ": " .. package
			all_same = all_same and package == name
		end
	end
	local subject = spec.label or name
	if #names == 0 or (all_same and not spec.label) then
		return ("Install %s with your package manager"):format(subject)
	end
	return ("Install %s with your package manager (%s)"):format(subject, table.concat(names, "; "))
end

---@param text string?
---@return table<string, string>
function M.parse_os_release(text)
	local fields = {}
	for line in (text or ""):gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([%w_]+)=(.*)$")
		if key then
			fields[key] = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
		end
	end
	return fields
end

---Describe the host without starting processes.
---@param opts? { sysname?: string, os_release?: string, exepath?: fun(name: string): string }
---@return { os: "macos"|"linux"|"other", name: string, manager?: "apt"|"dnf", distro?: string, version?: string, brew: boolean, rustup: boolean }
function M.detect(opts)
	opts = opts or {}
	local exepath = opts.exepath or vim.fn.exepath
	local sysname = opts.sysname or uv.os_uname().sysname
	local platform = { brew = exepath("brew") ~= "", rustup = exepath("rustup") ~= "" }
	if sysname == "Darwin" then
		platform.os, platform.name = "macos", "macOS"
		return platform
	end
	if sysname ~= "Linux" then
		platform.os, platform.name = "other", sysname
		return platform
	end
	platform.os = "linux"
	local release =
		M.parse_os_release(opts.os_release or read_file("/etc/os-release") or read_file("/usr/lib/os-release"))
	platform.name = release.PRETTY_NAME or release.NAME or "Linux"
	local id = (release.ID or ""):lower()
	local family = {}
	for word in (id .. " " .. (release.ID_LIKE or "")):lower():gmatch("%S+") do
		family[word] = true
	end
	if family.debian or family.ubuntu then
		platform.manager = "apt"
	elseif family.fedora then
		platform.manager = "dnf"
	end
	-- Release gates only apply to the distributions they were checked for.
	if id == "ubuntu" or id == "debian" or id == "fedora" then
		platform.distro, platform.version = id, release.VERSION_ID
	end
	return platform
end

---@param platform table from `detect()`
---@return string
function M.describe(platform)
	local tools = {}
	if platform.os == "macos" then
		tools[1] = platform.brew and "Homebrew" or "Homebrew (not installed: https://brew.sh)"
	else
		tools[#tools + 1] = platform.manager
		tools[#tools + 1] = platform.brew and "Homebrew" or nil
	end
	if #tools == 0 then
		return platform.name .. "; no apt, dnf or Homebrew found, so fixes name the packages"
	end
	return ("%s; fixes use %s"):format(platform.name, table.concat(tools, " or "))
end

---Commands that install `name` on this platform, best first.
---@param name string key of `M.packages`
---@param platform table from `detect()`
---@return string[]
function M.advice(name, platform)
	local spec = assert(M.packages[name], "unknown host package: " .. tostring(name))
	local commands = {}
	local function add(command)
		if command and not vim.tbl_contains(commands, command) then
			commands[#commands + 1] = command
		end
	end
	if spec.rustup and platform.rustup then
		add(spec.rustup)
	end
	if platform.os == "macos" then
		for _, command in ipairs(list(spec.macos)) do
			add(command)
		end
		if spec.brew and spec.macos_brew ~= false then
			add("brew install " .. spec.brew)
		end
	elseif platform.os == "linux" then
		local package = platform.manager and package_for(spec[platform.manager], platform)
		if package then
			add(("sudo %s install %s"):format(platform.manager, package))
		end
		if spec.brew and platform.brew then
			add("brew install " .. spec.brew)
		end
	end
	if #commands == 0 then
		add(spec.fallback or generic(name, spec))
	end
	for index = 2, #commands do
		commands[index] = "Or: " .. commands[index]
	end
	return commands
end

return M
