local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	return contents
end

local versions = require("config.toolchain").versions
local workflow = read_file(repo .. "/.github/workflows/check-config.yml")

assert(workflow:find("ubuntu%-24%.04"), "Linux runner is missing")
assert(workflow:find("macos%-15"), "macOS runner is missing")
assert(workflow:find("${{ runner.arch }}", 1, true), "cache key does not distinguish runner architecture")
assert(workflow:find("version: v" .. versions.neovim, 1, true), "workflow Neovim pin differs from toolchain")
assert(workflow:find("permissions:\n  contents: read", 1, true), "workflow permissions are not read-only")
assert(
	workflow:find("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", 1, true),
	"checkout action is not pinned"
)
assert(workflow:find("actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae", 1, true), "cache action is not pinned")
assert(
	workflow:find("rhysd/action-setup-vim@febef33995d6649302e9d88dda81e071b68f16a7", 1, true),
	"Neovim setup action is not pinned"
)

local installer = read_file(repo .. "/scripts/install-ci-tools")
for _, name in ipairs({ "stylua", "shellcheck", "actionlint", "tree_sitter" }) do
	assert(
		installer:find(name, 1, true) or name == "tree_sitter",
		"validator is absent from release installer: " .. name
	)
end
assert(installer:find("config.toolchain", 1, true), "validator metadata is not derived from config.toolchain")
assert(installer:find("expected_sha", 1, true), "release SHA-256 is not verified")
assert(installer:find("mv -f", 1, true), "validators are not atomically promoted")
for _, forbidden in ipairs({ "cargo install", "go install", "npm install" }) do
	assert(not installer:find(forbidden, 1, true), "validator installer invokes a package manager: " .. forbidden)
end

local bootstrap = read_file(repo .. "/scripts/bootstrap-config")
local preflight = assert(bootstrap:find("tree_sitter_actual", 1, true), "tree-sitter preflight is missing")
local restore = assert(bootstrap:find("Restoring plugins", 1, true), "plugin restore marker is missing")
assert(preflight < restore, "parser prerequisites are checked after plugin network restore")
assert(bootstrap:find("command -v cc", 1, true), "parser compiler preflight is missing")

local gate = read_file(repo .. "/scripts/check-config")
assert(gate:find("TREE_SITTER_BIN", 1, true), "canonical gate does not validate tree-sitter")
assert(gate:find("command -v cc", 1, true), "canonical gate does not require cc")
assert(gate:find("tool_paths_spec", 1, true), "canonical gate omits tool_paths_spec")
assert(gate:find("menu_lifecycle_spec", 1, true), "canonical gate omits the real menu lifecycle regression")

print("ci_spec: workflow, prebuilt validators, parser preflight, and offline gate match the manifest")
