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

for _, required in ipairs({
	"PATH precedence contract",
	"local_config.path > ~/.local/bin > inherited host PATH > managed tools > Mason",
	'state_summary("Managed"',
	'state_summary("Mason"',
	"Mason receipts",
	"Managed release platform/prerequisites",
	"record.detail",
	"automatic failures will not retry",
	"mason.auto_install=false",
	":NvimConfigToolsInstall",
	":MasonToolsInstallSync",
	"tree-sitter",
	"Tree-sitter parser compilation",
	"Rust language intelligence (host/user only)",
	"managed and Mason copies are intentionally ignored",
	"CMake language intelligence",
	"Git terminal UI",
	"latest-stable DevPod container editor",
	"verifies it against GitHub's latest stable release",
	"scripts/devpod-nvim up",
}) do
	assert(source:find(required, 1, true), "health contract is missing: " .. required)
end

for _, manager in ipairs({ '"prebuilt"', '"npm"', '"pypi"' }) do
	assert(source:find(manager, 1, true), "health manager inventory is missing: " .. manager)
end

for _, forbidden in ipairs({ "CodeCompanion", "ACP", "gofumpt", "gopls", '"go"' }) do
	assert(not source:find(forbidden, 1, true), "health contains removed or package-manager guidance: " .. forbidden)
end

package.loaded["nvimconfig.health"] = nil
local health = require("nvimconfig.health")
assert(type(health.check) == "function", "health module is not loadable")
assert(select(1, health._path_origin("/tmp/custom/bin/tool", { ["/tmp/custom/bin"] = true })) == "local_config")
assert(select(1, health._path_origin(vim.fn.expand("~/.local/bin/tool"), {})) == "user-local")
assert(select(1, health._path_origin(require("config.tool_paths").managed_bin() .. "/tool", {})) == "managed")
assert(select(1, health._path_origin(require("config.tool_paths").mason_bin() .. "/tool", {})) == "mason")

local original_mason_root = vim.env.NVIM_CONFIG_MASON_ROOT
local mason_root = vim.fn.tempname()
vim.env.NVIM_CONFIG_MASON_ROOT = mason_root
local receipt_dir = mason_root .. "/packages/example"
assert(vim.fn.mkdir(receipt_dir, "p") == 1)
local receipt = receipt_dir .. "/mason-receipt.json"
assert(vim.fn.writefile({ vim.json.encode({ source = { id = "pkg:github/example/example@1.2.3" } }) }, receipt) == 0)
local status, actual = health._mason_receipt_status("example", "1.2.3")
assert(status == "exact" and actual == "1.2.3", "exact Mason receipt was not recognized")
status, actual = health._mason_receipt_status("example", "9.9.9")
assert(status == "wrong" and actual == "1.2.3", "wrong Mason receipt did not report the installed pin")
assert(vim.fn.writefile({ "{" }, receipt) == 0)
assert(health._mason_receipt_status("example", "1.2.3") == "corrupt", "corrupt Mason receipt was accepted")
assert(health._mason_receipt_status("missing", "1.2.3") == "missing", "missing Mason receipt was not reported")
vim.env.NVIM_CONFIG_MASON_ROOT = original_mason_root
vim.fn.delete(mason_root, "rf")

print("health_spec: PATH, pins, one-shot state, managers, and validator diagnostics are documented")
vim.cmd("quitall!")
