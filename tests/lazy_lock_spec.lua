vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local root = vim.fn.tempname()
assert(vim.fn.mkdir(root, "p") == 1, "could not create lock fixture")
local source = root .. "/lazy-lock.json"
local lazy_commit = "0123456789012345678901234567890123456789"
local original = ('{\n  "lazy.nvim": { "branch": "main", "commit": "%s" }\n}\n'):format(lazy_commit)
assert(require("config.fs").write_binary_atomic(source, original))

local resolver = require("config.lazy_lock")
local entry, entry_err = resolver.plugin(root, "lazy.nvim")
assert(entry, entry_err)
assert(entry.branch == "main", "locked branch was not preserved")
assert(entry.commit == lazy_commit, "locked commit was not preserved")
local missing, missing_err = resolver.plugin(root, "missing.nvim")
assert(missing == nil, "missing lock entry unexpectedly resolved")
assert(missing_err:find("has no entry", 1, true), "missing lock entry error is not actionable")
assert(
	resolver.resolve(root, false, { state_root = root .. "/state" }) == vim.fs.normalize(source),
	"editor lock path changed"
)

local working = root .. "/working-lock.json"
assert(require("config.fs").write_binary_atomic(working, original))
local previous_override = vim.env.NVIM_CONFIG_LAZY_LOCKFILE
vim.env.NVIM_CONFIG_LAZY_LOCKFILE = working
assert(
	resolver.resolve(root, false, { state_root = root .. "/state" }) == vim.fs.normalize(working),
	"bootstrap lock override was ignored"
)
vim.env.NVIM_CONFIG_LAZY_LOCKFILE = previous_override

local pager_lock = resolver.resolve(root, true, { state_root = root .. "/state" })
assert(pager_lock ~= source, "pager received the writable editor lock")
assert(require("config.fs").read_binary(pager_lock) == original, "pager lock copy changed bytes")

assert(require("config.fs").write_binary_atomic(pager_lock, "{}\n"))
assert(require("config.fs").read_binary(source) == original, "pager lock mutation reached the editor lock")

vim.fn.delete(root, "rf")
print("lazy_lock_spec: profile lock isolation passed")
vim.cmd("quitall!")
