local root = assert(vim.env.NVIM_CONFIG_ROOT)
local pin = dofile(root .. "/lua/config/toolchain.lua").test_dependencies.mini_test
local directory = assert(arg[1], "test dependency directory is required")
assert(directory:sub(1, 1) == "/" and directory ~= "/", "test dependency directory must be absolute")
local path = directory .. "/mini.test"

local function git(...)
	local result = vim.system({ "git", "-C", path, ... }, { text = true }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout)
end

if vim.fn.isdirectory(path .. "/.git") == 0 then
	assert(vim.fn.getftype(path) == "", "test dependency destination is not a Git checkout: " .. path)
	vim.fn.mkdir(path, "p")
	git("init", "--quiet")
end
assert(git("status", "--porcelain") == "", "refusing to replace modified mini.test checkout")
local head = vim.system({ "git", "-C", path, "rev-parse", "HEAD" }, { text = true }):wait()
if head.code ~= 0 or vim.trim(head.stdout) ~= pin.commit then
	git("fetch", "--depth", "1", pin.url, pin.commit)
	git("checkout", "--detach", pin.commit)
end
assert(git("rev-parse", "HEAD") == pin.commit, "mini.test commit mismatch")
print(("Installed mini.test %s (%s) in %s"):format(pin.version, pin.commit, path))
