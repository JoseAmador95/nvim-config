vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	return contents
end

local source = read_file(repo .. "/lua/nvimconfig/health.lua")
local local_source = read_file(repo .. "/lua/localconfig/health.lua")

for _, required in ipairs({
	"PATH precedence contract",
	"Mise launchers > local_config.path > ~/.local/bin > host PATH",
	":NvimConfigToolsInstall",
	":NvimConfigMiseInstall",
	"~/.local/share/mise/installs",
	"Rust language intelligence (host/user only)",
	"Tree-sitter parser compilation",
	"Git terminal UI",
}) do
	assert(source:find(required, 1, true), "health contract is missing: " .. required)
end

for _, forbidden in ipairs({
	"CodeCompanion",
	"ACP",
	"gofumpt",
	"gopls",
	'"go"',
	"vim.system",
	'require("config.tool_bootstrap")',
	'require("config.release_installer")',
	'require("config.pager")',
	"pcall(require, product.module)",
}) do
	assert(not source:find(forbidden, 1, true), "health contains an activating/probing dependency: " .. forbidden)
end
assert(not local_source:find("require", 1, true), "localconfig health still activates its runtime adapter")

package.loaded["nvimconfig.health"] = nil
local health = require("nvimconfig.health")
assert(type(health.check) == "function", "health module is not loadable")

local catalog = health._tool_contract()
assert(#catalog == #require("config.toolchain").tool_order)
for _, item in ipairs(catalog) do
	assert(item.name ~= "gumtree" and item.backend and item.version ~= "latest")
end

local products = health._local_product_status()
assert(#products == 16, "health does not aggregate every local product")
for _, product in ipairs(products) do
	assert(product.loaded == false, product.name .. " was activated by observational inventory")
	assert(product.observational == true, product.name .. " missing observational marker")
	assert(product.error == nil, product.name .. " was reported broken merely because it was not loaded")
	assert(package.loaded[product.module] == nil, product.name .. " crossed its first-use boundary")
end

local fake_status = { configured = true, nested = { value = 1 } }
local fake_config = { enabled = true }
local first_module = products[1].module
local original_first = package.loaded[first_module]
package.loaded[first_module] = {
	status = function()
		return fake_status
	end,
	effective_config = function()
		return fake_config
	end,
}
products = health._local_product_status()
assert(products[1].loaded and products[1].status.nested.value == 1, "loaded product status was not observed")
products[1].status.nested.value = 2
products[1].effective_config.enabled = false
products = health._local_product_status()
assert(products[1].status.nested.value == 1, "health returned shared plugin status")
assert(products[1].effective_config.enabled == true, "health returned shared plugin configuration")
package.loaded[first_module] = original_first

local module_names =
	{ "config.local_config", "config.tool_bootstrap", "config.release_installer", "config.pager", "verified_tools" }
for _, product in ipairs(products) do
	module_names[#module_names + 1] = product.module
end
local originals = {}
local attempted_loads = {}
for _, name in ipairs(module_names) do
	if not originals[name] then
		originals[name] = { loaded = package.loaded[name], preload = package.preload[name] }
		package.loaded[name] = nil
		package.preload[name] = function()
			attempted_loads[#attempted_loads + 1] = name
			error("health attempted to load " .. name)
		end
	end
end

local original_system = vim.system
local system_calls = 0
vim.system = function()
	system_calls = system_calls + 1
	error("health started a process")
end
local mutation_calls = {}
local mutation_functions = {
	{ owner = vim.fn, name = "delete" },
	{ owner = vim.fn, name = "mkdir" },
	{ owner = vim.fn, name = "rename" },
	{ owner = vim.fn, name = "setfperm" },
	{ owner = vim.fn, name = "writefile" },
	{ owner = vim.uv, name = "fs_chmod" },
	{ owner = vim.uv, name = "fs_copyfile" },
	{ owner = vim.uv, name = "fs_link" },
	{ owner = vim.uv, name = "fs_mkdir" },
	{ owner = vim.uv, name = "fs_rename" },
	{ owner = vim.uv, name = "fs_rmdir" },
	{ owner = vim.uv, name = "fs_symlink" },
	{ owner = vim.uv, name = "fs_unlink" },
	{ owner = vim.uv, name = "fs_write" },
}
for _, mutation in ipairs(mutation_functions) do
	mutation.original = mutation.owner[mutation.name]
	local name = mutation.name
	mutation.owner[name] = function()
		mutation_calls[#mutation_calls + 1] = name
		error("health attempted mutation through " .. name)
	end
end
local original_health = {}
local emitted = {}
for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
	original_health[kind] = vim.health[kind]
	vim.health[kind] = function(message)
		emitted[#emitted + 1] = { kind = kind, message = tostring(message) }
	end
end

local check_ok, check_err = pcall(health.check)
assert(check_ok, check_err)
assert(system_calls == 0, "health executed an external probe")
assert(#mutation_calls == 0, "health attempted filesystem mutation: " .. vim.inspect(mutation_calls))
assert(#attempted_loads == 0, "health activated runtime modules: " .. vim.inspect(attempted_loads))
assert(#emitted > 0, "health emitted no observations")
assert(
	vim.iter(emitted):any(function(item)
		return item.message == "devcontainers-cli@0.89.0 (npm:@devcontainers/cli)"
	end),
	"health omitted the exact Mise catalog entry"
)

package.loaded["localconfig.health"] = nil
local local_health = require("localconfig.health")
local before = #emitted
local_health.check()
assert(#attempted_loads == 0, "localconfig health loaded config.local_config")
assert(
	#emitted > before and emitted[#emitted].message:find("did not activate", 1, true),
	"unloaded local config was unclear"
)

local observed_path = vim.fn.tempname()
package.loaded["config.local_config"] = {
	observation = function()
		return {
			evaluated = true,
			errors = { "fixture validation error" },
			sources = { { path = observed_path, status = "absent" } },
		}
	end,
}
before = #emitted
local_health.check()
local observed_messages = {}
for index = before + 1, #emitted do
	observed_messages[#observed_messages + 1] = emitted[index].message
end
local joined = table.concat(observed_messages, "\n")
assert(joined:find(observed_path .. " (absent)", 1, true), "localconfig health lost observed source state")
assert(joined:find("fixture validation error", 1, true), "localconfig health lost observed diagnostics")

for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
	vim.health[kind] = original_health[kind]
end
vim.system = original_system
for _, mutation in ipairs(mutation_functions) do
	mutation.owner[mutation.name] = mutation.original
end
for name, value in pairs(originals) do
	package.loaded[name] = value.loaded
	package.preload[name] = value.preload
end

package.loaded["config.local_config"] = nil
local local_config = require("config.local_config")
local observation = local_config.observation()
assert(observation.evaluated == false, "observation evaluated local config")
assert(vim.tbl_isempty(observation.sources) and vim.tbl_isempty(observation.errors), "fresh observation invented state")
observation.sources[1] = { status = "mutated" }
assert(vim.tbl_isempty(local_config.observation().sources), "local config observation leaked mutable state")

assert(select(1, health._path_origin("/tmp/custom/bin/tool", { ["/tmp/custom/bin"] = true })) == "local_config")
assert(select(1, health._path_origin(vim.fn.expand("~/.local/bin/tool"), {})) == "user-local")
assert(select(1, health._path_origin(require("config.tool_paths").managed_bin() .. "/tool", {})) == "mise-launcher")
assert(select(1, health._path_origin(require("config.tool_paths").managed_root() .. "/installs/tool", {})) == "managed")
assert(select(1, health._path_origin(require("config.tool_paths").mason_bin() .. "/tool", {})) == "mason")

print("health_spec: health observes loaded state and files without activation, probes, or writes")
vim.cmd("quitall!")
