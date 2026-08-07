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

print("ci_spec: workflow pins and platform matrix match the toolchain manifest")
