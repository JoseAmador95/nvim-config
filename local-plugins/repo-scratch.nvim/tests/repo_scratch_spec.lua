vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/repo-scratch.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

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

local fixture = vim.fn.tempname()
local state = fixture .. "/state/scratch"
local now = 2_000_000_000
local scratch = require("repo_scratch")
local setup_ok, setup_err = scratch.setup({
	state_root = state,
	now = function()
		return now
	end,
	lease_seconds = 60,
	max_age_seconds = 30 * 24 * 60 * 60,
})
assert(setup_ok, setup_err)
state = vim.uv.fs_realpath(state) or state

local key = { repo_identity = "/repo/logical", ref = "refs/heads/feature/complete-name" }

test("state and files are private and keys use the complete ref", function()
	local handle, err = scratch.open({ key = key })
	assert(handle, vim.inspect(err))
	assert(bit.band(vim.uv.fs_stat(state).mode, 511) == tonumber("700", 8))
	assert(bit.band(vim.uv.fs_stat(handle.path).mode, 511) == tonumber("600", 8))
	assert(handle.path:match(vim.fn.sha256(key.repo_identity .. "\0" .. key.ref) .. "%.md$"))
	assert(scratch.release(handle))

	local detached = scratch.open({ key = { repo_identity = key.repo_identity, ref = string.rep("a", 40) } })
	assert(detached and detached.path ~= handle.path)
	assert(scratch.release(detached))
end)

test("CAS conflicts never overwrite external changes", function()
	local handle = assert(scratch.open({ key = key }))
	local saved = assert(scratch.save(handle, "first\n"))
	vim.fn.writefile({ "external" }, saved.path)
	local result, conflict = scratch.save(saved, "ours\n")
	assert(result == nil and conflict.kind == "conflict")
	assert(conflict.current == "external\n" and conflict.proposed == "ours\n")
	assert(table.concat(vim.fn.readfile(saved.path), "\n") .. "\n" == "external\n")
	assert(scratch.release(saved))
end)

test("leases reject concurrent ownership and allow explicit release", function()
	local first = assert(scratch.open({ key = key }))
	local second, err = scratch.open({ key = key })
	assert(second == nil and err.kind == "leased")
	assert(scratch.renew(first))
	assert(scratch.release(first))
	local reopened = assert(scratch.open({ key = key }))
	assert(scratch.release(reopened))
end)

test("known legacy content is adopted in place without duplication", function()
	local legacy_key = { repo_identity = "/repo/legacy", ref = "refs/heads/main" }
	local legacy_id = vim.fn.sha256("legacy-fixture")
	local legacy_path = state .. "/" .. legacy_id .. ".md"
	vim.fn.writefile({ "legacy content" }, legacy_path)
	local handle = assert(scratch.open({ key = legacy_key, legacy_ids = { legacy_id } }))
	assert(handle.path == legacy_path and handle.adopted == true)
	assert(handle.content == "legacy content\n")
	local canonical = state .. "/" .. vim.fn.sha256(legacy_key.repo_identity .. "\0" .. legacy_key.ref) .. ".md"
	assert(vim.uv.fs_stat(canonical) == nil)
	assert(scratch.release(handle))
end)

test("prune removes only managed expired files", function()
	local managed = assert(scratch.open({ key = { repo_identity = "/repo/old", ref = "refs/heads/old" } }))
	assert(scratch.release(managed))
	local unknown = state .. "/" .. vim.fn.sha256("unknown") .. ".md"
	vim.fn.writefile({ "unknown" }, unknown)
	local corrupt = state .. "/" .. vim.fn.sha256("corrupt") .. ".md"
	vim.fn.writefile({ "corrupt" }, corrupt)
	vim.fn.writefile({ "{" }, corrupt .. ".meta")
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(managed.path, stale, stale)
	vim.uv.fs_utime(unknown, stale, stale)
	vim.uv.fs_utime(corrupt, stale, stale)
	local removed = assert(scratch.prune())
	assert(vim.tbl_contains(removed, managed.path))
	assert(vim.uv.fs_stat(managed.path) == nil)
	assert(vim.uv.fs_stat(unknown), "unknown legacy file was pruned")
	assert(vim.uv.fs_stat(corrupt), "corrupt/unowned file was pruned")
end)

test("active and preserved managed files survive pruning", function()
	local active = assert(scratch.open({ key = { repo_identity = "/repo/active", ref = "refs/heads/a" } }))
	local preserved = assert(scratch.open({ key = { repo_identity = "/repo/preserved", ref = "refs/heads/p" } }))
	assert(scratch.release(preserved))
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(active.path, stale, stale)
	vim.uv.fs_utime(preserved.path, stale, stale)
	local removed = assert(scratch.prune({ preserved.path }))
	assert(#removed == 0)
	assert(vim.uv.fs_stat(active.path) and vim.uv.fs_stat(preserved.path))
	assert(scratch.release(active))
end)

test("symlinked state entries fail closed", function()
	local target = state .. "/target.md"
	local linked = state .. "/linked.md"
	vim.fn.writefile({ "target" }, target)
	assert(vim.uv.fs_symlink(target, linked))
	local removed, err = scratch.prune()
	assert(removed == nil and err:match("symlinked"))
	assert(scratch._private_file(linked, "scratch") == nil)
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("repo_scratch_spec: %d tests passed"):format(count))
