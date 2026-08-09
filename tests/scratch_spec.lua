vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p", tonumber("700", 8))
fixture = vim.uv.fs_realpath(fixture) or fixture
local old = fixture .. "/old.md"
local active = fixture .. "/active.md"
local recent = fixture .. "/recent.md"
local version = fixture .. "/.version"
for _, path in ipairs({ old, active, recent, version }) do
	vim.fn.writefile({ path }, path)
	vim.uv.fs_chmod(path, tonumber("644", 8))
end
local stale = os.time() - (31 * 24 * 60 * 60)
vim.uv.fs_utime(old, stale, stale)
vim.uv.fs_utime(active, stale, stale)
vim.uv.fs_utime(version, stale, stale)
local buf = vim.fn.bufadd(active)
vim.fn.bufload(buf)

require("config.scratch")._prune(fixture)
assert(vim.uv.fs_stat(old) == nil, "inactive scratch older than 30 days was retained")
assert(vim.uv.fs_stat(active), "open scratch was pruned")
assert(vim.uv.fs_stat(version), "scratch state version was pruned")
assert(vim.uv.fs_stat(recent), "recent scratch was pruned")
for _, path in ipairs({ active, recent, version }) do
	assert(bit.band(vim.uv.fs_stat(path).mode, 511) == tonumber("600", 8), path .. " is not private")
end

local linked = fixture .. "/linked.md"
assert(vim.uv.fs_symlink(active, linked))
local ok, err = require("config.scratch")._prune(fixture)
assert(ok == nil and err:find("symlinked", 1, true), "symlinked scratch state did not fail closed")
assert(require("config.scratch")._private_file(linked, "scratch file") == nil, "symlinked target was accepted")

vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(fixture, "rf")
print("scratch_spec: private modes and 30-day inactive pruning passed")
vim.cmd("quitall!")
