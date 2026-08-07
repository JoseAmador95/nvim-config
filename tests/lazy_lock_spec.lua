vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local root = vim.fn.tempname()
assert(vim.fn.mkdir(root, "p") == 1, "could not create lock fixture")
local source = root .. "/lazy-lock.json"
local original = '{\n  "example.nvim": { "branch": "main", "commit": "0123456789012345678901234567890123456789" }\n}\n'
assert(require("config.fs").write_binary_atomic(source, original))

local resolver = require("config.lazy_lock")
assert(
	resolver.resolve(root, false, { state_root = root .. "/state" }) == vim.fs.normalize(source),
	"editor lock path changed"
)
local pager_lock = resolver.resolve(root, true, { state_root = root .. "/state" })
assert(pager_lock ~= source, "pager received the writable editor lock")
assert(require("config.fs").read_binary(pager_lock) == original, "pager lock copy changed bytes")

assert(require("config.fs").write_binary_atomic(pager_lock, "{}\n"))
assert(require("config.fs").read_binary(source) == original, "pager lock mutation reached the editor lock")

vim.fn.delete(root, "rf")
print("lazy_lock_spec: profile lock isolation passed")
vim.cmd("quitall!")
