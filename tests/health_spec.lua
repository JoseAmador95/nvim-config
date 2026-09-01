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
	"verified shims > local_config.path > ~/.local/bin > host PATH > managed > Mason",
	"state_summary()",
	"Mason receipts",
	"Managed release platform/prerequisites",
	"record.detail",
	"Tool failures never auto-retry",
	"Startup is local probe/plan/attest only",
	":NvimConfigToolsInstall",
	"tree-sitter",
	"Tree-sitter parser compilation",
	"Rust language intelligence (host/user only)",
	"managed and Mason copies are intentionally ignored",
	"CMake language intelligence",
	"Git terminal UI",
	"Dev Containers CLI editor lifecycle",
	"Install @devcontainers/cli explicitly",
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
assert(
	select(1, health._path_origin(require("config.tool_paths").verified_shim_bin() .. "/tool", {})) == "verified-shim"
)
assert(select(1, health._path_origin(require("config.tool_paths").managed_bin() .. "/tool", {})) == "managed")
assert(select(1, health._path_origin(require("config.tool_paths").mason_bin() .. "/tool", {})) == "mason")

local original_mason_root = vim.env.NVIM_CONFIG_MASON_ROOT
local mason_root = vim.fn.tempname()
vim.env.NVIM_CONFIG_MASON_ROOT = mason_root
local receipt_dir = mason_root .. "/packages/clangd"
assert(vim.fn.mkdir(receipt_dir, "p") == 1)
local receipt = receipt_dir .. "/mason-receipt.json"
local version = require("config.toolchain").mason_entry("clangd").version
local source = receipt_dir .. "/clangd"
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, source) == 0)
assert(vim.uv.fs_chmod(source, tonumber("755", 8)))
assert(vim.fn.mkdir(mason_root .. "/bin", "p") == 1)
assert(vim.uv.fs_symlink("../packages/clangd/clangd", mason_root .. "/bin/clangd"))
assert(vim.fn.writefile({
	vim.json.encode({
		name = "clangd",
		schema_version = "2.0",
		source = { id = "pkg:github/clangd/clangd@" .. version },
		links = { bin = { clangd = "clangd" }, share = {}, opt = {} },
	}),
}, receipt) == 0)
local private_dir = mason_root .. "/.verified-tools/receipts"
assert(vim.fn.mkdir(private_dir, "p", tonumber("700", 8)) == 1)
local private = private_dir .. "/clangd.json"
assert(
	vim.fn.writefile({ vim.json.encode({ package = "clangd", version = version, source_version = version }) }, private)
		== 0
)
assert(vim.uv.fs_chmod(private, tonumber("600", 8)))
local status, actual = health._mason_receipt_status("clangd", version)
assert(
	status == "exact" and actual == version,
	"exact Mason receipt was not recognized: " .. vim.inspect({ status, actual })
)
status, actual = health._mason_receipt_status("clangd", "9.9.9")
assert(status == "wrong" and actual == version, "wrong Mason receipt did not report the installed pin")
assert(vim.fn.writefile({ "{" }, receipt) == 0)
assert(health._mason_receipt_status("clangd", version) == "corrupt", "corrupt Mason receipt was accepted")
assert(health._mason_receipt_status("missing", version) == "missing", "missing Mason receipt was not reported")
vim.env.NVIM_CONFIG_MASON_ROOT = original_mason_root
vim.fn.delete(mason_root, "rf")

print("health_spec: PATH, pins, one-shot state, managers, and validator diagnostics are documented")
vim.cmd("quitall!")
