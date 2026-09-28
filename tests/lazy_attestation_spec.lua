vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

local attestation = require("config.lazy_attestation")
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
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))

local function checkout(name, symbolic)
	local root = fixture .. "/" .. name
	local git_dir = root .. "/.git"
	local head = vim.fn.sha256(name):sub(1, 40)
	assert(vim.fn.mkdir(git_dir .. "/refs/heads", "p", tonumber("700", 8)) == 1)
	assert(vim.fn.mkdir(root .. "/lua/lazy", "p", tonumber("700", 8)) == 1)
	assert(vim.fn.mkdir(root .. "/doc", "p", tonumber("700", 8)) == 1)
	assert(vim.fn.writefile({ "index-material" }, git_dir .. "/index", "b") == 0)
	if symbolic then
		assert(vim.fn.writefile({ "ref: refs/heads/main" }, git_dir .. "/HEAD", "b") == 0)
		assert(vim.fn.writefile({ head }, git_dir .. "/refs/heads/main", "b") == 0)
	else
		assert(vim.fn.writefile({ head }, git_dir .. "/HEAD", "b") == 0)
	end
	assert(vim.fn.writefile({ "return true" }, root .. "/lua/lazy/init.lua", "b") == 0)
	assert(vim.fn.writefile({ "ignored-plugin.lua" }, root .. "/.gitignore", "b") == 0)
	assert(vim.fn.writefile({ "help\tlazy.txt" }, root .. "/doc/tags", "b") == 0)
	return assert(vim.uv.fs_realpath(root)), head
end

local function prime_checkout(root, head, cache)
	local hit, status = attestation.checkout_begin({ root = root, head = head, cache_path = cache })
	assert(hit == false and type(status.snapshot) == "table", status.reason)
	local committed, commit_status = attestation.checkout_commit({
		root = root,
		head = head,
		before = status.snapshot,
		cache_path = cache,
	})
	assert(committed and commit_status.cached, commit_status.reason)
end

test("metadata cache hits avoid the authoritative flag scan", function()
	local root, head = checkout("metadata-cache-hit", true)
	local cache = fixture .. "/attestation/cache.json"
	local scans = 0
	local function run_git()
		scans = scans + 1
		return 0, "", ""
	end

	local first, first_status = attestation.verify({
		root = root,
		head = head,
		cache_path = cache,
		run_git = run_git,
	})
	assert(first and first_status.cache_hit == false and scans == 1)
	assert(vim.uv.fs_lstat(cache), "positive attestation was not cached")

	local cached, cached_status = attestation.verify({
		root = root,
		head = head,
		cache_path = cache,
		run_git = run_git,
	})
	assert(cached and cached_status.cache_hit == true)
	assert(scans == 1, "cache hit repeated the authoritative flag scan")

	local second, second_status = attestation.verify({
		root = root,
		head = head,
		cache_path = cache,
		allow_cache = false,
		run_git = run_git,
	})
	assert(second and second_status.cache_hit == false)
	assert(scans == 2, "allow_cache=false accepted the positive cache")
end)

test("index replacement invalidates the metadata cache even at the same size", function()
	local root = fixture .. "/metadata"
	local git_dir = root .. "/.git"
	local cache = fixture .. "/metadata-cache/cache.json"
	assert(vim.fn.mkdir(git_dir, "p") == 1)
	assert(vim.fn.writefile({ "before" }, git_dir .. "/index", "b") == 0)
	local scans = 0
	local function run_git()
		scans = scans + 1
		return 0, "", ""
	end
	assert(attestation.verify({
		root = root,
		head = string.rep("b", 40),
		cache_path = cache,
		run_git = run_git,
	}))
	assert(attestation.verify({
		root = root,
		head = string.rep("b", 40),
		cache_path = cache,
		run_git = run_git,
	}))
	assert(scans == 1, "unchanged index missed the metadata cache")

	local replacement = git_dir .. "/replacement"
	assert(vim.fn.writefile({ "after!" }, replacement, "b") == 0)
	assert(vim.uv.fs_rename(replacement, git_dir .. "/index"))
	local verified, status = attestation.verify({
		root = root,
		head = string.rep("b", 40),
		cache_path = cache,
		run_git = run_git,
	})
	assert(verified and status.cache_hit == false)
	assert(scans == 2, "same-size index replacement reused stale hidden-flag authority")
end)

test("regular reads are bound to the identity used by the caller", function()
	local path = fixture .. "/index"
	assert(vim.fn.writefile({ "before" }, path, "b") == 0)
	local expected = assert(vim.uv.fs_lstat(path))
	assert(vim.fn.writefile({ "replacement with a different identity snapshot" }, path, "b") == 0)
	assert(attestation._read_regular(path, 1024, expected) == nil, "changed index material was accepted")
end)

test("aggregate index material remains bounded", function()
	local root = fixture .. "/bounded"
	local git_dir = root .. "/.git"
	assert(vim.fn.mkdir(git_dir, "p") == 1)
	local index = assert(vim.uv.fs_open(git_dir .. "/index", "w", tonumber("600", 8)))
	assert(vim.uv.fs_ftruncate(index, 8 * 1024 * 1024 + 1))
	assert(vim.uv.fs_close(index))
	local shared = assert(vim.uv.fs_open(git_dir .. "/sharedindex." .. string.rep("a", 40), "w", tonumber("600", 8)))
	assert(vim.uv.fs_ftruncate(shared, 8 * 1024 * 1024 + 1))
	assert(vim.uv.fs_close(shared))
	local snapshot, err = attestation._index_snapshot(root)
	assert(snapshot == nil and err:find("cache bound", 1, true), tostring(err))
end)

test("complete checkout cache hit is subprocess-free authority", function()
	local root, head = checkout("a-checkout", true)
	local cache = fixture .. "/a-cache/cache.json"
	prime_checkout(root, head, cache)

	local original_system = vim.system
	local original_dir = vim.fs.dir
	local subprocesses = 0
	local directory_enumerations = 0
	vim.system = function(...)
		subprocesses = subprocesses + 1
		return original_system(...)
	end
	vim.fs.dir = function(...)
		directory_enumerations = directory_enumerations + 1
		return original_dir(...)
	end
	local hit, status = attestation.checkout_begin({ root = root, head = head, cache_path = cache })
	vim.system = original_system
	vim.fs.dir = original_dir
	assert(hit and status.cache_hit == true)
	assert(subprocesses == 0, "checkout cache hit spawned an external process")
	assert(directory_enumerations == 0, "checkout cache hit enumerated a directory")

	-- The sole authoritative Git exception is normalized out without making the
	-- rest of the worktree mutable authority.
	assert(vim.fn.writefile({ "updated-help\tlazy.txt" }, root .. "/doc/tags", "b") == 0)
	assert(attestation.checkout_begin({ root = root, head = head, cache_path = cache }))
end)

test("cache miss enumerates the worktree once before and once after Git authority", function()
	local root, head = checkout("b-bounded-miss", false)
	local cache = fixture .. "/b-bounded-miss-cache/cache.json"
	local original_dir = vim.fs.dir
	local root_enumerations = 0
	vim.fs.dir = function(path, ...)
		if vim.fs.normalize(path) == root then
			root_enumerations = root_enumerations + 1
		end
		return original_dir(path, ...)
	end
	local hit, status = attestation.checkout_begin({ root = root, head = head, cache_path = cache })
	assert(hit == false and status.snapshot)
	assert(root_enumerations == 1, "cache miss repeated its pre-authority root enumeration")
	local committed, commit_status = attestation.checkout_commit({
		root = root,
		head = head,
		before = status.snapshot,
		cache_path = cache,
	})
	vim.fs.dir = original_dir
	assert(committed and commit_status.cached, commit_status.reason)
	assert(root_enumerations == 2, "cache miss repeated an exhaustive worktree snapshot")
end)

test("cache-disabled staging validation never publishes a movable receipt", function()
	local root, head = checkout("c-no-staging-receipt", false)
	local cache = fixture .. "/c-no-staging-receipt-cache/cache.json"
	local hit, status = attestation.checkout_begin({
		root = root,
		head = head,
		cache_path = cache,
		allow_cache = false,
	})
	assert(hit == false and status.snapshot)
	local committed, commit_status = attestation.checkout_commit({
		root = root,
		head = head,
		before = status.snapshot,
		cache_path = cache,
		allow_cache = false,
	})
	assert(committed and commit_status.cached == false)
	assert(vim.uv.fs_lstat(cache) == nil, "cache-disabled staging validation wrote a receipt")
end)

test("tracked, ignored, untracked, index, and HEAD drift all invalidate fast authority", function()
	local cases = {
		{
			name = "d-tracked",
			mutate = function(root)
				assert(vim.fn.writefile({ "return nil" }, root .. "/lua/lazy/init.lua", "b") == 0)
			end,
		},
		{
			name = "e-ignored",
			mutate = function(root)
				assert(vim.fn.writefile({ "ignored" }, root .. "/ignored-plugin.lua", "b") == 0)
			end,
		},
		{
			name = "f-untracked",
			mutate = function(root)
				assert(vim.fn.writefile({ "untracked" }, root .. "/unexpected.lua", "b") == 0)
			end,
		},
		{
			name = "g-index",
			mutate = function(root)
				local replacement = root .. "/.git/index.replacement"
				assert(vim.fn.writefile({ "changed-index" }, replacement, "b") == 0)
				assert(vim.uv.fs_rename(replacement, root .. "/.git/index"))
			end,
		},
		{
			name = "h-head",
			mutate = function(root)
				assert(vim.fn.writefile({ string.rep("0", 40) }, root .. "/.git/refs/heads/main", "b") == 0)
			end,
		},
	}
	for _, case in ipairs(cases) do
		local root, head = checkout(case.name, true)
		local cache = fixture .. "/" .. case.name .. "-cache/cache.json"
		prime_checkout(root, head, cache)
		case.mutate(root)
		local hit = attestation.checkout_begin({ root = root, head = head, cache_path = cache })
		assert(hit == false, case.name .. " drift retained fast checkout authority")
	end
end)

test("same-inode mutation between cached identity rounds cannot retain authority", function()
	local root, head = checkout("i-tree-race", false)
	local cache = fixture .. "/i-tree-race-cache/cache.json"
	prime_checkout(root, head, cache)
	local target = root .. "/lua/lazy/init.lua"
	local directory = root .. "/lua/lazy"
	local before_file = assert(vim.uv.fs_lstat(target))
	local before_directory = assert(vim.uv.fs_lstat(directory))
	local original_lstat = vim.uv.fs_lstat
	local validation_rounds = 0
	vim.uv.fs_lstat = function(path, callback)
		if vim.fs.normalize(path) == root and callback ~= nil then
			validation_rounds = validation_rounds + 1
			if validation_rounds == 2 then
				assert(vim.fn.writefile({ "return nil " }, target, "b") == 0)
				assert(vim.uv.fs_utime(target, before_file.mtime.sec + 1, before_file.mtime.sec + 1))
			end
		end
		return original_lstat(path, callback)
	end
	local ok, hit, status = xpcall(function()
		return attestation.checkout_begin({ root = root, head = head, cache_path = cache })
	end, debug.traceback)
	vim.uv.fs_lstat = original_lstat
	assert(ok, hit)
	assert(
		hit == false and status.snapshot ~= nil,
		vim.inspect({ hit = hit, rounds = validation_rounds, reason = status.reason, snapshot = status.snapshot ~= nil })
	)
	assert(validation_rounds == 2, "cached identities were not validated twice")
	local after_file = assert(vim.uv.fs_lstat(target))
	local after_directory = assert(vim.uv.fs_lstat(directory))
	assert(before_file.ino == after_file.ino and before_file.size == after_file.size)
	assert(before_directory.mtime.sec == after_directory.mtime.sec)
	assert(before_directory.mtime.nsec == after_directory.mtime.nsec)
end)

test("checkout cache races and hostile cache metadata fail closed", function()
	local root, head = checkout("j-race", false)
	local cache = fixture .. "/j-cache/cache.json"
	local hit, status = attestation.checkout_begin({ root = root, head = head, cache_path = cache })
	assert(hit == false and status.snapshot)
	assert(vim.fn.writefile({ "changed" }, root .. "/lua/lazy/init.lua", "b") == 0)
	local committed, commit_err = attestation.checkout_commit({
		root = root,
		head = head,
		before = status.snapshot,
		cache_path = cache,
	})
	assert(committed == nil and commit_err.kind == "checkout-changed")

	root, head = checkout("k-hostile", false)
	cache = fixture .. "/k-cache/cache.json"
	prime_checkout(root, head, cache)
	assert(vim.uv.fs_chmod(cache, tonumber("644", 8)))
	assert(attestation.checkout_begin({ root = root, head = head, cache_path = cache }) == false)
	assert(vim.uv.fs_chmod(cache, tonumber("600", 8)))
	local outside = fixture .. "/outside-cache.json"
	assert(vim.fn.writefile({ vim.json.encode({ safe_checkout = true }) }, outside, "b") == 0)
	assert(vim.uv.fs_unlink(cache))
	assert(vim.uv.fs_symlink(outside, cache))
	assert(attestation.checkout_begin({ root = root, head = head, cache_path = cache }) == false)

	local metadata_root, metadata_head = checkout("l-shared-metadata", false)
	assert(vim.uv.fs_chmod(metadata_root .. "/.git", tonumber("770", 8)))
	local metadata_hit, metadata_status = attestation.checkout_begin({
		root = metadata_root,
		head = metadata_head,
		cache_path = fixture .. "/l-cache/cache.json",
	})
	assert(metadata_hit == false and metadata_status.snapshot == nil)
	assert(metadata_status.reason:find("Git metadata", 1, true), metadata_status.reason)

	local record_root, record_head = checkout("m-hostile-record", false)
	local record_cache = fixture .. "/m-cache/cache.json"
	prime_checkout(record_root, record_head, record_cache)
	local record = vim.json.decode(table.concat(vim.fn.readfile(record_cache), "\n"))
	local outside_git = fixture .. "/outside-git"
	record.snapshot.index.git_dir = outside_git
	assert(vim.fn.writefile({ vim.json.encode(record) }, record_cache, "b") == 0)
	assert(vim.uv.fs_chmod(record_cache, tonumber("600", 8)))
	local original_lstat = vim.uv.fs_lstat
	local outside_inspected = false
	vim.uv.fs_lstat = function(path, callback)
		if vim.fs.normalize(path) == outside_git then
			outside_inspected = true
		end
		return original_lstat(path, callback)
	end
	local record_hit = attestation.checkout_begin({
		root = record_root,
		head = record_head,
		cache_path = record_cache,
	})
	vim.uv.fs_lstat = original_lstat
	assert(record_hit == false, "hostile cached path retained checkout authority")
	assert(not outside_inspected, "hostile cached path was inspected outside the checkout")
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("lazy_attestation_spec: %d tests passed", count))
vim.cmd("quitall!")
