vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/verified-tools.nvim")
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	repo .. "/local-plugins/verified-tools.nvim/lua/?.lua",
	repo .. "/local-plugins/verified-tools.nvim/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local module = require("verified_tools.markdown_preview")
local repair = module.repair
local name = module.expected_name()
local fixture = vim.fn.tempname()
local plugin = fixture .. "/plugin"
local managed_root = fixture .. "/managed"
local managed = managed_root .. "/bin/markdown-preview"
assert(vim.fn.mkdir(plugin .. "/app/bin", "p") == 1)
assert(vim.fn.mkdir(managed_root .. "/bin", "p") == 1)
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, managed) == 0)
assert(vim.uv.fs_chmod(managed, tonumber("700", 8)))

local function record(path, digest)
	return {
		status = "succeeded",
		identity = {
			name = "markdown-preview",
			digest = digest or "sha256:expected",
			install_root = managed_root,
		},
		attestation = { path = path or managed, digest = digest or "sha256:expected" },
	}
end

test("only the expected ignored markdown-preview link is repaired", function()
	assert(name, "platform has no markdown-preview binary name")
	local ok, err = repair(plugin, record())
	assert(ok, err)
	local link = plugin .. "/app/bin/" .. name
	assert(assert(vim.uv.fs_lstat(link)).type == "link")
	assert(vim.uv.fs_readlink(link) == vim.fs.normalize(managed))
	assert(repair(plugin, record()))
end)

test("regular targets and attested paths outside containment fail closed", function()
	local link = plugin .. "/app/bin/" .. name
	assert(vim.uv.fs_unlink(link))
	assert(vim.fn.writefile({ "user content" }, link) == 0)
	local ok, err = repair(plugin, record())
	assert(not ok and err:find("non%-symlink"))
	assert(vim.fn.readfile(link)[1] == "user content")

	assert(vim.uv.fs_unlink(link))
	local outside = fixture .. "/outside"
	assert(vim.fn.writefile({ "#!/bin/sh" }, outside) == 0)
	assert(vim.uv.fs_chmod(outside, tonumber("700", 8)))
	ok, err = repair(plugin, record(outside))
	assert(not ok and err:find("escaped", 1, true))
	assert(vim.uv.fs_lstat(link) == nil)
end)

test("digest mismatch and hostile bin symlink are rejected", function()
	local bad = record()
	bad.attestation.digest = "sha256:other"
	assert(not repair(plugin, bad))

	local other_plugin = fixture .. "/other-plugin"
	local outside_bin = fixture .. "/outside-bin"
	assert(vim.fn.mkdir(other_plugin .. "/app", "p") == 1)
	assert(vim.fn.mkdir(outside_bin, "p") == 1)
	assert(vim.uv.fs_symlink(outside_bin, other_plugin .. "/app/bin"))
	local ok, err = repair(other_plugin, record())
	assert(not ok and err:find("unsafe", 1, true))
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("verified_tools_host_spec: %d tests passed", count))
vim.cmd("quitall!")
