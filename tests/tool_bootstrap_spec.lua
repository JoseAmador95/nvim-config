vim.o.shadafile = "NONE"
vim.o.swapfile = false
local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
local uv = vim.uv
local home = vim.fn.tempname()
assert(vim.fn.mkdir(home, "p", 448) == 1)
home = assert(uv.fs_realpath(home))
local old = {
	HOME = vim.env.HOME,
	PATH = vim.env.PATH,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
	MISE_NODE_VERSION = vim.env.MISE_NODE_VERSION,
}
vim.env.HOME = home
vim.env.PATH = home .. "/.local/bin:/usr/bin:/bin"
vim.env.NVIM_CONFIG_OFFLINE = nil
vim.env.MISE_NODE_VERSION = "1.0.0"
vim.fn.mkdir(home .. "/.local/bin", "p")
vim.fn.mkdir(home .. "/project with spaces", "p")
local fake = home .. "/.local/bin/mise"
vim.fn.writefile({
	"#!/bin/sh",
	'printf "%s\\0" "$PWD" "$MISE_GLOBAL_CONFIG_FILE" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "${MISE_NODE_VERSION-unset}" "$@" > "$HOME/trace"',
	'case "$1" in where) exit 1 ;; esac',
	'case "$2" in difftastic) printf "%s\\n" "structural result"; exit 0 ;; esac',
	"cat",
}, fake)
assert(vim.fn.setfperm(fake, "rwx------") == 1)
local bootstrap = require("config.tool_bootstrap")
local manifest = require("config.toolchain")
local structural_diff = require("config.review_structural_diff")

local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })
local function trace()
	local f = assert(io.open(home .. "/trace", "rb"))
	local value = f:read("*a")
	f:close()
	return vim.split(value, "\0", { plain = true, trimempty = true })
end

T["resolving an absent tool prepares only a launcher inside ~/.local"] = function()
	local path = assert(bootstrap.resolve("jq", "jq"))
	assert(path == home .. "/.local/share/mise/nvim-bin/jq")
	assert(not uv.fs_stat(home .. "/trace"), "resolution executed Mise")
	assert(not bootstrap.resolve("gumtree", "gumtree"))
	assert(not bootstrap.resolve("jq", "bash"))
end

T["launcher preserves cwd, argv and protocol streams and isolates tool selection"] = function()
	local path = assert(bootstrap.resolve("jq", "jq"))
	local result = vim.system(
		{ path, "one two", "$(literal)", "a'b" },
		{ text = true, cwd = home .. "/project with spaces", stdin = "protocol bytes\n" }
	):wait(5000)
	assert(result.code == 0, result.stderr)
	assert(result.stdout == "protocol bytes\n", "launcher polluted stdout")
	local values = trace()
	assert(values[1] == home .. "/project with spaces")
	assert(values[2] == repo .. "/mise.toml")
	assert(values[3] == home .. "/.local/share/mise")
	assert(values[4] == home .. "/.local/state/mise")
	assert(values[5] == "unset")
	assert(vim.deep_equal(vim.list_slice(values, 6), { "exec", "jq", "--", "jq", "one two", "$(literal)", "a'b" }))
end

T["offline absence fails before exec and cannot fall back to a host command"] = function()
	local result = vim.system(
		{ assert(bootstrap.resolve("jq", "jq")), "--version" },
		{ text = true, env = { NVIM_CONFIG_OFFLINE = "1" } }
	):wait(5000)
	assert(result.code ~= 0)
	assert(trace()[6] == "where")
end

T["structural review can launch Mise in its filtered environment and preserves offline mode"] = function()
	local function execute(operation)
		local result
		local cancel = structural_diff[operation]({
			entry = { path = "file.lua", old_text = "local value = 1\n", new_text = "local value = 2\n" },
			width = 80,
			background = "dark",
		}, function(output, err)
			result = { output = output, err = err }
		end)
		local completed = vim.wait(6000, function()
			return result ~= nil
		end, 10)
		cancel()
		assert(completed, "structural review did not complete")
		return result
	end
	for _, operation in ipairs({ "run", "analyze" }) do
		local result = execute(operation)
		assert(result.err == nil, result.err)
		assert(result.output == "structural result\n")
		local values = trace()
		assert(values[3] == home .. "/.local/share/mise")
		assert(values[6] == "exec" and values[7] == "difftastic")
	end
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	local result = execute("analyze")
	vim.env.NVIM_CONFIG_OFFLINE = nil
	assert(result.output == nil and result.err:find("exit 1", 1, true))
	assert(trace()[6] == "where", "offline review bypassed the missing-tool check")
end

T["named npm and Python launches include their pinned install dependencies"] = function()
	for _, item in ipairs({
		{ "devcontainers-cli", "devcontainer", { "node", "devcontainers-cli" } },
		{ "debugpy", "debugpy-adapter", { "python", "uv", "debugpy" } },
	}) do
		local result = vim.system({ assert(bootstrap.resolve(item[1], item[2])), "--version" }, { text = true })
			:wait(5000)
		assert(result.code == 0, result.stderr)
		local expected = { "exec" }
		vim.list_extend(expected, item[3])
		vim.list_extend(expected, { "--", item[2], "--version" })
		assert(vim.deep_equal(vim.list_slice(trace(), 6), expected))
	end
end

T["missing Mise is reported without installing it"] = function()
	vim.env.PATH = "/usr/bin:/bin"
	local path, err = bootstrap.resolve("jq", "jq")
	assert(path == nil and err:find(":NvimConfigMiseInstall", 1, true))
	vim.env.PATH = home .. "/.local/bin:/usr/bin:/bin"
end

local installed = false
local calls = {}
local configured = MiniTest.new_set({
	hooks = {
		pre_once = function()
			bootstrap._system = function(argv)
				calls[#calls + 1] = argv
				local data
				if argv[2] == "version" then
					data = { version = "2026.10.4 macos-arm64" }
				elseif argv[2] == "ls" then
					data = { unrelated = { { version = "1.0.0", installed = true } } }
					for _, name in ipairs(manifest.tool_order) do
						data[name] = {
							{
								version = manifest.tools[name].version,
								installed = installed,
								active = installed,
								install_path = home .. "/.local/share/mise/installs/" .. name .. "/version",
							},
						}
					end
				else
					assert(argv[2] == "install" and argv[3] == "--locked")
					installed = true
				end
				return {
					wait = function()
						return { code = 0, stdout = data and vim.json.encode(data) or "", stderr = "" }
					end,
				}
			end
		end,
	},
})
T["provisioning"] = configured

configured["offline provisioning inventories missing tools without consuming an install"] = function()
	local ok, inventory, changed = bootstrap.provision_exact({ allow_network = false })
	assert(not ok and not changed and inventory.tools.jq.status == "missing")
	assert(vim.deep_equal(inventory.extras, { "unrelated@1.0.0" }))
	for _, argv in ipairs(calls) do
		assert(argv[2] ~= "install")
	end
end

configured["online provisioning installs fixed versions and is idempotent"] = function()
	local ok, inventory, changed = bootstrap.provision_exact({ allow_network = true })
	assert(ok and changed and inventory.tools.jq.status == "ready")
	local second, _, again = bootstrap.provision_exact({ allow_network = false })
	assert(second and not again)
	local installs = 0
	for _, argv in ipairs(calls) do
		if argv[2] == "install" then
			installs = installs + 1
		end
	end
	assert(installs == 1)
	for _, command in ipairs({ "node", "npm", "python", "python3", "uv" }) do
		assert(not uv.fs_lstat(home .. "/.local/share/mise/nvim-bin/" .. command), "tool runtime masked the host")
	end
end

hooks.post_once = function()
	for key, value in pairs(old) do
		vim.env[key] = value
	end
	vim.env.NVIM_CONFIG_OFFLINE = old.NVIM_CONFIG_OFFLINE
	vim.env.MISE_NODE_VERSION = old.MISE_NODE_VERSION
	vim.fn.delete(home, "rf")
end

return T
