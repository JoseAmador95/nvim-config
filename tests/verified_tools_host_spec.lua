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

local function with_uv_override(name, replacement, callback)
	local original = vim.uv[name]
	vim.uv[name] = function(...)
		return replacement(original, ...)
	end
	local returned
	local ok, err = xpcall(function()
		local function capture(...)
			returned = { n = select("#", ...), ... }
		end
		capture(callback())
	end, debug.traceback)
	vim.uv[name] = original
	assert(ok, err)
	return unpack(returned, 1, returned.n)
end

local function same_object(left, right)
	return left and right and left.dev == right.dev and left.ino == right.ino and left.type == right.type
end

local module = require("verified_tools.markdown_preview")
local name = module.expected_name()
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local plugin = fixture .. "/plugin"
local managed_root = fixture .. "/managed"
local managed = managed_root .. "/bin/markdown-preview"
assert(vim.fn.mkdir(plugin .. "/app/bin", "p") == 1)
assert(vim.fn.mkdir(managed_root .. "/bin", "p") == 1)

local function write_managed(contents)
	assert(vim.fn.writefile({ contents or "#!/bin/sh\nexit 0" }, managed, "b") == 0)
	assert(vim.uv.fs_chmod(managed, tonumber("700", 8)))
end
write_managed()

local function current_fingerprint()
	local stat = assert(vim.uv.fs_lstat(managed))
	local data = assert(require("config.fs").read_binary(managed))
	return {
		path = assert(vim.uv.fs_realpath(managed)),
		dev = stat.dev,
		ino = stat.ino,
		size = stat.size,
		mtime_sec = stat.mtime.sec,
		mtime_nsec = stat.mtime.nsec,
		sha256 = vim.fn.sha256(data),
	}
end

local function record()
	return {
		status = "succeeded",
		identity = {
			backend = "release",
			name = "markdown-preview",
			install_root = managed_root,
		},
		plan = {
			manifest = {
				integrity = {
					kind = "release-sha256",
					commands = { ["markdown-preview"] = "bin/markdown-preview" },
				},
			},
		},
		proof = {
			kind = "release-sha256",
			commands = { ["markdown-preview"] = current_fingerprint() },
		},
	}
end

test("only the expected ignored markdown-preview link is repaired", function()
	assert(name, "platform has no markdown-preview binary name")
	local ok, err = module.repair(plugin, record())
	assert(ok, err)
	local link = plugin .. "/app/bin/" .. name
	assert(assert(vim.uv.fs_lstat(link)).type == "link")
	assert(vim.uv.fs_readlink(link) == managed)
	assert(module.repair(plugin, record()))
end)

test("regular files and stale symlinks are never clobbered", function()
	local link = plugin .. "/app/bin/" .. name
	assert(vim.uv.fs_unlink(link))
	assert(vim.fn.writefile({ "user content" }, link) == 0)
	local ok, err = module.repair(plugin, record())
	assert(not ok and err:find("existing", 1, true))
	assert(vim.fn.readfile(link)[1] == "user content")
	assert(vim.uv.fs_unlink(link))
	assert(vim.uv.fs_symlink("/tmp/not-the-managed-tool", link))
	ok, err = module.repair(plugin, record())
	assert(not ok and err:find("existing", 1, true))
	assert(vim.uv.fs_readlink(link) == "/tmp/not-the-managed-tool")
	assert(vim.uv.fs_unlink(link))
end)

test("fingerprint drift and hard-linked executables fail closed", function()
	local stale = record()
	write_managed("#!/bin/sh\nexit 9")
	local ok, err = module.repair(plugin, stale)
	assert(not ok and err:find("fingerprint", 1, true))
	write_managed()
	local hardlink = fixture .. "/managed-hardlink"
	assert(vim.uv.fs_link(managed, hardlink))
	ok, err = module.repair(plugin, record())
	assert(not ok and err:find("private regular", 1, true))
	assert(vim.uv.fs_unlink(hardlink))
end)

test("symlinked plugin ancestors are rejected", function()
	local other_plugin = fixture .. "/other-plugin"
	local outside_bin = fixture .. "/outside-bin"
	assert(vim.fn.mkdir(other_plugin .. "/app", "p") == 1)
	assert(vim.fn.mkdir(outside_bin, "p") == 1)
	assert(vim.uv.fs_symlink(outside_bin, other_plugin .. "/app/bin"))
	local ok, err = module.repair(other_plugin, record())
	assert(not ok and err:find("unsafe", 1, true))
end)

test("a bin-directory swap cannot redirect publication outside the plugin", function()
	local bin = plugin .. "/app/bin"
	local saved_bin = plugin .. "/app/bin.before-race"
	local outside_bin = fixture .. "/outside-race"
	assert(vim.fn.mkdir(outside_bin, "p") == 1)
	local bin_identity = assert(vim.uv.fs_lstat(bin))
	local directory_stats = 0
	local swapped = false
	local ok, err = with_uv_override("fs_fstat", function(original, fd)
		local stat, stat_err = original(fd)
		if same_object(stat, bin_identity) then
			directory_stats = directory_stats + 1
			if directory_stats == 3 then
				assert(vim.uv.fs_rename(bin, saved_bin))
				assert(vim.uv.fs_symlink(outside_bin, bin))
				swapped = true
			end
		end
		return stat, stat_err
	end, function()
		return module.repair(plugin, record())
	end)
	assert(swapped, "race injection did not swap the validated bin directory")
	assert(not ok and err:find("changed during", 1, true), tostring(err))
	assert(vim.uv.fs_lstat(outside_bin .. "/" .. name) == nil, "publication followed the hostile bin symlink")
	assert(vim.uv.fs_lstat(saved_bin .. "/" .. name) == nil, "descriptor-relative rollback left a symlink")
	assert(vim.uv.fs_unlink(bin))
	assert(vim.uv.fs_rename(saved_bin, bin))
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
