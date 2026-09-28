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

local function write_exact(path, contents, mode)
	local fd = assert(vim.uv.fs_open(path, "w", mode or tonumber("700", 8)))
	assert(vim.uv.fs_write(fd, contents, 0) == #contents)
	assert(vim.uv.fs_close(fd))
	assert(vim.uv.fs_chmod(path, mode or tonumber("700", 8)))
	return path
end

local function quarantine_entries()
	return vim.tbl_filter(function(path)
		return not path:find("%.parked$")
	end, vim.fn.glob(plugin .. "/app/bin/." .. name .. ".verified-tools-quarantine.*", false, true))
end

local function current_fingerprint()
	local stat = assert(vim.uv.fs_lstat(managed))
	local data = assert(require("config.fs").read_binary(managed))
	return {
		path = assert(vim.uv.fs_realpath(managed)),
		dev = stat.dev,
		ino = stat.ino,
		size = stat.size,
		mode = stat.mode,
		uid = stat.uid,
		gid = stat.gid,
		mtime_sec = stat.mtime.sec,
		mtime_nsec = stat.mtime.nsec,
		ctime_sec = stat.ctime.sec,
		ctime_nsec = stat.ctime.nsec,
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

test("idempotent bridge success revalidates the exact link and managed fingerprint", function()
	local link = plugin .. "/app/bin/" .. name
	local first = assert(vim.uv.fs_lstat(link))
	local baseline = record()
	module._set_test_hook(function(phase)
		if phase == "before_existing_link_revalidate" then
			assert(vim.uv.fs_unlink(link))
			assert(vim.uv.fs_symlink(managed, link))
		end
	end)
	local ok, err = module.repair(plugin, baseline)
	module._set_test_hook(nil)
	local rival = assert(vim.uv.fs_lstat(link))
	assert(not ok and err:find("changed", 1, true), tostring(err))
	assert(not same_object(first, rival), "same-target rival retained the original symlink inode")
	assert(vim.uv.fs_readlink(link) == managed, "same-target rival was clobbered")

	local contents = assert(require("config.fs").read_binary(managed))
	baseline = record()
	module._set_test_hook(function(phase)
		if phase == "before_existing_link_revalidate" then
			write_exact(managed, "#!/bin/sh\nexit 7\n")
		end
	end)
	ok, err = module.repair(plugin, baseline)
	module._set_test_hook(nil)
	assert(not ok and err:find("fingerprint", 1, true), tostring(err))
	assert(vim.uv.fs_readlink(link) == managed, "managed drift clobbered the existing bridge")
	write_exact(managed, contents)
end)

test("mismatched regular files and stale symlinks are never clobbered", function()
	local link = plugin .. "/app/bin/" .. name
	assert(vim.uv.fs_unlink(link))
	assert(vim.fn.writefile({ "user content" }, link) == 0)
	assert(vim.uv.fs_chmod(link, tonumber("700", 8)))
	local ok, err = module.repair(plugin, record())
	assert(not ok and err:find("non%-identical"))
	assert(vim.fn.readfile(link)[1] == "user content")
	assert(vim.uv.fs_unlink(link))
	assert(vim.uv.fs_symlink("/tmp/not-the-managed-tool", link))
	ok, err = module.repair(plugin, record())
	assert(not ok and err:find("existing", 1, true))
	assert(vim.uv.fs_readlink(link) == "/tmp/not-the-managed-tool")
	assert(vim.uv.fs_unlink(link))
end)

test("an exact private single-link legacy executable is safely adopted", function()
	local link = plugin .. "/app/bin/" .. name
	local contents = assert(require("config.fs").read_binary(managed))
	write_exact(link, contents)
	local hardlink = fixture .. "/legacy-hardlink"
	assert(vim.uv.fs_link(link, hardlink))
	local ok, err = module.repair(plugin, record())
	assert(not ok and err:find("safe single%-link", 1))
	assert(vim.uv.fs_lstat(link).type == "file")
	assert(vim.uv.fs_unlink(hardlink))
	assert(vim.uv.fs_chmod(link, tonumber("722", 8)))
	local unsafe = assert(vim.uv.fs_lstat(link))
	ok, err = module.repair(plugin, record())
	local retained = assert(vim.uv.fs_lstat(link))
	assert(not ok and err:find("safe single%-link", 1))
	assert(same_object(unsafe, retained) and retained.mode == unsafe.mode)
	assert(require("config.fs").read_binary(link) == contents)
	assert(vim.uv.fs_chmod(link, tonumber("700", 8)))
	assert(module.repair(plugin, record()))
	assert(vim.uv.fs_lstat(link).type == "link")
	assert(vim.uv.fs_readlink(link) == managed)
	assert(#quarantine_entries() == 0)
end)

test("a quarantine race never restores a rival at the public path", function()
	local link = plugin .. "/app/bin/" .. name
	assert(vim.uv.fs_unlink(link))
	local contents = assert(require("config.fs").read_binary(managed))
	write_exact(link, contents)
	local parked
	module._set_test_hook(function(phase, details)
		if phase == "before_legacy_publish" then
			parked = details.quarantine .. ".parked"
			assert(vim.uv.fs_rename(details.quarantine, parked))
			write_exact(details.quarantine, "#!/bin/sh\nexit 9\n")
		end
	end)
	local ok, err = module.repair(plugin, record())
	module._set_test_hook(nil)
	assert(not ok and err:find("quarantine retained at", 1, true), tostring(err))
	assert(vim.uv.fs_lstat(link).type == "link", "a quarantine race removed the verified managed bridge")
	assert(vim.uv.fs_readlink(link) == managed, "a changed quarantine was restored to the public path")
	local retained = quarantine_entries()
	assert(#retained == 1 and require("config.fs").read_binary(retained[1]) == "#!/bin/sh\nexit 9\n")
	assert(require("config.fs").read_binary(parked) == contents)
	assert(vim.uv.fs_unlink(retained[1]))
	assert(vim.uv.fs_unlink(parked))
	assert(vim.uv.fs_unlink(link))
end)

test("a publication competitor is preserved without clobbering", function()
	local link = plugin .. "/app/bin/" .. name
	local contents = assert(require("config.fs").read_binary(managed))
	write_exact(link, contents)
	module._set_test_hook(function(phase, details)
		if phase == "before_legacy_publish" then
			write_exact(details.path, "#!/bin/sh\nexit 8\n")
		end
	end)
	local ok, err = module.repair(plugin, record())
	module._set_test_hook(nil)
	assert(not ok and err:find("quarantine retained at", 1, true), tostring(err))
	assert(vim.uv.fs_lstat(link).type == "file")
	assert(require("config.fs").read_binary(link) == "#!/bin/sh\nexit 8\n")
	local retained = quarantine_entries()
	assert(#retained == 1 and require("config.fs").read_binary(retained[1]) == contents)
	assert(err:find(retained[1], 1, true), "recovery error omitted the exact quarantine path")
	assert(vim.uv.fs_unlink(link))
	assert(vim.uv.fs_unlink(retained[1]))
end)

test("a bin swap before cleanup rolls the exact legacy executable back", function()
	local bin = plugin .. "/app/bin"
	local link = bin .. "/" .. name
	local saved_bin = plugin .. "/app/bin.cleanup-race"
	local outside_bin = fixture .. "/outside-cleanup-race"
	assert(vim.fn.mkdir(outside_bin, "p") == 1)
	local contents = assert(require("config.fs").read_binary(managed))
	write_exact(link, contents)
	module._set_test_hook(function(phase)
		if phase == "before_legacy_cleanup" then
			assert(vim.uv.fs_rename(bin, saved_bin))
			assert(vim.uv.fs_symlink(outside_bin, bin))
		end
	end)
	local ok, err = module.repair(plugin, record())
	module._set_test_hook(nil)
	assert(not ok and err:find("changed before cleanup", 1, true), tostring(err))
	assert(vim.uv.fs_lstat(outside_bin .. "/" .. name) == nil)
	assert(vim.uv.fs_lstat(saved_bin .. "/" .. name).type == "file")
	assert(require("config.fs").read_binary(saved_bin .. "/" .. name) == contents)
	assert(vim.uv.fs_unlink(bin))
	assert(vim.uv.fs_rename(saved_bin, bin))
	assert(vim.uv.fs_unlink(link))
end)

test("managed drift before cleanup preserves the exact legacy executable", function()
	local link = plugin .. "/app/bin/" .. name
	local contents = assert(require("config.fs").read_binary(managed))
	write_exact(link, contents)
	local baseline = record()
	module._set_test_hook(function(phase)
		if phase == "before_legacy_cleanup" then
			write_exact(managed, "#!/bin/sh\nexit 7\n")
		end
	end)
	local ok, err = module.repair(plugin, baseline)
	module._set_test_hook(nil)
	assert(not ok and err:find("changed before cleanup", 1, true), tostring(err))
	assert(vim.uv.fs_lstat(link).type == "file")
	assert(require("config.fs").read_binary(link) == contents)
	write_exact(managed, contents)
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
	local safe = record()
	assert(vim.uv.fs_chmod(managed, tonumber("777", 8)))
	ok, err = module.repair(plugin, safe)
	assert(not ok and err:find("private regular", 1, true))
	assert(vim.uv.fs_lstat(managed).mode % 512 == tonumber("777", 8))
	assert(vim.uv.fs_chmod(managed, tonumber("700", 8)))
end)

test("symlinked plugin ancestors are rejected", function()
	local other_plugin = fixture .. "/other-plugin"
	local outside_bin = fixture .. "/outside-bin"
	assert(vim.fn.mkdir(other_plugin .. "/app", "p") == 1)
	assert(vim.fn.mkdir(outside_bin, "p") == 1)
	assert(vim.uv.fs_symlink(outside_bin, other_plugin .. "/app/bin"))
	local ok, err = module.repair(other_plugin, record())
	assert(not ok and err:find("unsafe", 1, true))
	local bin = plugin .. "/app/bin"
	assert(vim.uv.fs_chmod(bin, tonumber("777", 8)))
	ok, err = module.repair(plugin, record())
	assert(not ok and err:find("unsafe", 1, true))
	assert(vim.uv.fs_chmod(bin, tonumber("700", 8)))
end)

test("a bin-directory swap cannot redirect publication outside the plugin", function()
	local bin = plugin .. "/app/bin"
	local link = bin .. "/" .. name
	if vim.uv.fs_lstat(link) then
		assert(vim.uv.fs_unlink(link))
	end
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
	assert(not ok and err:find("changed", 1, true), tostring(err))
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
