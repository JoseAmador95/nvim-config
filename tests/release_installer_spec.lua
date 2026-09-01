vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, function(failure)
		return debug.traceback(tostring(failure), 2)
	end)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
local original_tools_root = vim.env.NVIM_CONFIG_TOOLS_ROOT
vim.env.NVIM_CONFIG_TOOLS_ROOT = vim.env.RELEASE_INSTALLER_EXCHANGE_CRASH_ROOT
	or vim.env.RELEASE_INSTALLER_INITIAL_CRASH_ROOT
	or vim.fs.joinpath(fixture, "managed")
package.loaded["config.tool_paths"] = nil
package.loaded["config.release_installer"] = nil
local paths = require("config.tool_paths")
local installer = require("config.release_installer")
local manifest = require("config.toolchain")
local default_run = installer._run
local fs = require("config.fs")
local ffi = require("ffi")
pcall(
	ffi.cdef,
	[[
		struct timespec { long tv_sec; long tv_nsec; };
		int utimensat(int fd, const char *path, const struct timespec times[2], int flags);
	]]
)
local host_bin = fixture .. "/host-bin"
assert(vim.fn.mkdir(host_bin, "p") == 1)
for _, name in ipairs({ "curl", "sha256sum", "shasum", "tar", "unzip", "gzip", "java", "mmdflux" }) do
	local path = host_bin .. "/" .. name
	assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path) == 0)
	assert(vim.uv.fs_chmod(path, tonumber("755", 8)))
end

local function fake_external(host_tools)
	host_tools = host_tools or {}
	installer._external = function(name)
		if host_tools[name] then
			return host_bin .. "/" .. name
		end
		if vim.tbl_contains({ "curl", "sha256sum", "shasum", "tar", "unzip", "gzip", "java" }, name) then
			return host_bin .. "/" .. name
		end
		return nil
	end
end

local function digest_fd(fd)
	local stat = assert(vim.uv.fs_fstat(fd))
	local chunks = {}
	local offset = 0
	while offset < stat.size do
		local chunk = assert(vim.uv.fs_read(fd, math.min(64 * 1024, stat.size - offset), offset))
		assert(#chunk > 0, "short inherited-fd read")
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
	end
	return vim.fn.sha256(table.concat(chunks))
end

local function fake_runner(plan, options)
	options = options or {}
	local fixture_sha256 = options.bad_checksum and string.rep("0", 64) or vim.fn.sha256("archive")
	manifest.managed_tools[plan.name].assets[plan.target].sha256 = fixture_sha256
	plan.entry.assets[plan.target].sha256 = fixture_sha256
	plan.asset.sha256 = fixture_sha256
	plan.layout = manifest.release_layout(plan.entry, plan.asset)
	local archive_hash_count = 0
	local download_path
	local state = { archive_hash_count = 0, extraction_count = 0, promoted_hash_count = 0 }
	installer._run = function(command, run_options, callback)
		run_options = run_options or {}
		local name = vim.fs.basename(command[1])
		if name == "curl" then
			local output
			for index, arg in ipairs(command) do
				if arg == "--output" then
					output = command[index + 1]
				end
			end
			assert(output, "curl output path missing")
			download_path = output
			assert(vim.fn.writefile({ "archive" }, output, "b") == 0)
			if options.hardlink_archive then
				assert(vim.uv.fs_link(output, fixture .. "/archive-hardlink-" .. tostring(vim.uv.hrtime())))
			end
			callback({ code = options.download_failure and 22 or 0, stdout = "", stderr = "secret output" })
		elseif name == "sha256sum" or name == "shasum" then
			local path = command[#command]
			local is_archive = run_options.bound_archive == true
				or path == vim.fs.joinpath(vim.fs.dirname(path), plan.asset.archive)
			if is_archive then
				archive_hash_count = archive_hash_count + 1
				state.archive_hash_count = archive_hash_count
			else
				state.promoted_hash_count = state.promoted_hash_count + 1
			end
			if options.fail_promoted_hash and not is_archive then
				callback({ code = 1, stdout = "", stderr = "injected promoted hash failure" })
				return
			end
			local actual = is_archive and digest_fd(assert(run_options.inherited_fd).fd)
				or vim.fn.sha256(assert(fs.read_binary(path)))
			if options.lie_about_archive_hash and is_archive then
				actual = string.rep("f", 64)
			end
			if options.swap_download_during_hash_callback and is_archive then
				local parked = vim.fs.joinpath(fixture, "parked-download-" .. tostring(vim.uv.hrtime()))
				assert(vim.uv.fs_rename(download_path, parked))
				assert(vim.fn.writefile({ "malicious archive" }, download_path, "b") == 0)
				state.parked_download = parked
			end
			callback({
				code = 0,
				stdout = actual .. "  archive\n",
				stderr = "",
			})
		elseif name == "gzip" then
			state.extraction_count = state.extraction_count + 1
			assert(run_options.inherited_fd, "gzip was not bound to an archive descriptor")
			assert(command[3] == "/dev/fd/3")
			callback({ code = 0, stdout = "new-binary", stderr = "" })
		elseif name == "tar" or name == "unzip" then
			state.extraction_count = state.extraction_count + 1
			assert(run_options.inherited_fd, "extractor was not bound to an archive descriptor")
			assert(command[3] == "/dev/fd/3")
			local parked_download
			if options.swap_download_during_extract then
				parked_download = download_path .. ".extract-parked"
				assert(vim.uv.fs_rename(download_path, parked_download))
				assert(vim.fn.writefile({ "malicious archive" }, download_path, "b") == 0)
			end
			local destination
			local marker = name == "tar" and "-C" or "-d"
			for index, arg in ipairs(command) do
				if arg == marker then
					destination = command[index + 1]
				end
			end
			local target = vim.fs.joinpath(destination, plan.asset.member)
			assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
			assert(vim.fn.writefile({ "new-binary" }, target, "b") == 0)
			if options.hardlink_member then
				assert(vim.uv.fs_link(target, fixture .. "/member-hardlink-" .. tostring(vim.uv.hrtime())))
			end
			if options.mutate_archive_on_extract then
				assert(run_options.inherited_fd, "extractor was not bound to an archive descriptor")
				assert(vim.uv.fs_write(run_options.inherited_fd.fd, "changed archive", 0))
			end
			if parked_download then
				assert(vim.uv.fs_unlink(download_path))
				assert(vim.uv.fs_rename(parked_download, download_path))
			end
			callback({ code = 0, stdout = "", stderr = "" })
		else
			error("unexpected fake command: " .. vim.inspect(command))
		end
	end
	return state
end

if vim.env.RELEASE_INSTALLER_EXCHANGE_CRASH_CHILD == "1" then
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	fake_runner(plan)
	local ready = assert(vim.env.RELEASE_INSTALLER_EXCHANGE_CRASH_READY)
	local saw_visible_incumbent = false
	installer._set_test_hook(function(phase, details)
		if phase == "before_publish_link" then
			assert(vim.fn.readfile(details.target, "b")[1] == "old-binary")
			saw_visible_incumbent = true
			return
		end
		if phase ~= "after_target_exchange" then
			return
		end
		assert(saw_visible_incumbent, "exchange did not observe the visible incumbent")
		assert(vim.fn.readfile(details.target, "b")[1] == "new-binary")
		assert(vim.fn.readfile(details.recovery, "b")[1] == "old-binary")
		assert(vim.fn.writefile({ details.recovery, details.target }, ready) == 0)
		vim.wait(60_000, function()
			return false
		end, 100)
		error("exchange crash child was not killed")
	end)
	installer.install(plan, function()
		error("exchange crash child unexpectedly completed")
	end)
	error("exchange crash child unexpectedly returned")
end

if vim.env.RELEASE_INSTALLER_INITIAL_CRASH_CHILD == "1" then
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	fake_runner(plan)
	local ready = assert(vim.env.RELEASE_INSTALLER_INITIAL_CRASH_READY)
	installer._set_test_hook(function(phase, details)
		if phase ~= "after_initial_publish" then
			return
		end
		local stat = assert(vim.uv.fs_lstat(details.target))
		assert(stat.nlink == 1, "initial publication retained a second executable link")
		assert(vim.fn.writefile({ details.target }, ready) == 0)
		vim.wait(60_000, function()
			return false
		end, 100)
		error("initial publication crash child was not killed")
	end)
	installer.install(plan, function()
		error("initial publication crash child unexpectedly completed")
	end)
	error("initial publication crash child unexpectedly returned")
end

local function with_test_hook(hook, callback)
	installer._set_test_hook(hook)
	local ok, first, second = xpcall(callback, debug.traceback)
	installer._set_test_hook(nil)
	assert(ok, first)
	return first, second
end

local function restore_times(path, stat)
	local times = ffi.new("struct timespec[2]")
	times[0].tv_sec = stat.atime.sec
	times[0].tv_nsec = stat.atime.nsec
	times[1].tv_sec = stat.mtime.sec
	times[1].tv_nsec = stat.mtime.nsec
	local at_fdcwd = vim.uv.os_uname().sysname == "Darwin" and -2 or -100
	assert(ffi.C.utimensat(at_fdcwd, path, times, 0) == 0, "utimensat failed: " .. tostring(ffi.errno()))
end

test("eligibility is side-effect free and honors external tools and force", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external({ mmdflux = true })
	local plan, reason = installer.plan("mmdflux")
	assert(plan == nil and reason == "external")
	plan = assert(installer.plan("mmdflux", { force = true }))
	assert(plan.target == "darwin-arm64")
	assert(vim.uv.fs_stat(paths.managed_root()) == nil, "eligibility created the managed root")

	installer._platform = function()
		return "Linux", "arm64"
	end
	fake_external()
	plan, reason = installer.plan("mmdflux")
	assert(plan == nil and reason == "unsupported")
	assert(vim.uv.fs_stat(paths.managed_root()) == nil)
end)

test("default runner inherits a pinned descriptor as child fd 3", function()
	local path = vim.fs.joinpath(fixture, "descriptor-runner-probe")
	assert(vim.fn.writefile({ "descriptor-bytes" }, path, "b") == 0)
	local fd = assert(vim.uv.fs_open(path, "r", 0))
	assert(vim.uv.fs_unlink(path))
	local completed
	local process = assert(default_run({ "/usr/bin/shasum", "-a", "256", "/dev/fd/3" }, {
		inherited_fd = { child_fd = 3, fd = fd },
		text = true,
	}, function(result)
		completed = result
	end))
	assert(process)
	assert(vim.wait(5000, function()
		return completed ~= nil
	end, 10))
	assert(completed.code == 0, tostring(completed.stderr))
	assert(completed.stdout:match("^([0-9a-f]+)") == vim.fn.sha256("descriptor-bytes"))
	assert(vim.uv.fs_close(fd))
end)

test("symlinked staging roots and hard-linked inputs fail closed", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external()
	local plan = assert(installer.plan("mmdflux"))
	local staging = vim.fs.joinpath(plan.install_root, "staging")
	assert(vim.fn.mkdir(plan.install_root, "p") >= 0)
	vim.fn.delete(staging, "rf")
	local outside = fixture .. "/outside-staging"
	assert(vim.fn.mkdir(outside, "p") >= 0)
	assert(vim.uv.fs_symlink(outside, staging))
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end) == false)
	assert(success == false and reason:find("unsafe", 1, true))
	assert(vim.uv.fs_lstat(staging).type == "link")
	assert(vim.uv.fs_unlink(staging))

	fake_runner(plan, { hardlink_archive = true })
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == false and reason == "download-failed")
end)

test("hard-linked members and archive mutation never reach promotion", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local success, reason
	fake_runner(plan, { hardlink_member = true })
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == false and reason == "candidate-unsafe")
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")

	fake_runner(plan, { mutate_archive_on_extract = true })
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == false and reason:find("archive%-changed"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
end)

test("checksum failure preserves the previous executable", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external()
	local plan = assert(installer.plan("mmdflux"))
	assert(vim.fn.mkdir(paths.managed_bin(), "p") == 1)
	local target = vim.fs.joinpath(paths.managed_bin(), "mmdflux")
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan, { bad_checksum = true })
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == false and reason == "checksum-mismatch")
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
	local staging = vim.fs.joinpath(paths.managed_root(), "staging")
	assert(#vim.fn.glob(staging .. "/*", false, true) == 0, "failed staging was not cleaned")
end)

test("external and descriptor-bound hashes must agree", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external()
	local plan = assert(installer.plan("mmdflux"))
	local target = vim.fs.joinpath(paths.managed_bin(), "mmdflux")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan, { lie_about_archive_hash = true })
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == false and reason == "hash-disagreement", tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
end)

test("candidate pathname exchange cannot publish or replace the stable executable", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "before_publish_link" and details.target == target then
			assert(vim.uv.fs_unlink(details.source))
			assert(vim.fn.writefile({ "substituted" }, details.source, "b") == 0)
			assert(vim.uv.fs_chmod(details.source, tonumber("755", 8)))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("candidate%-changed"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
end)

test("same-size same-mtime candidate rewrites fail the final content CAS", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "before_publish_link" and details.target == target then
			local before = assert(vim.uv.fs_lstat(details.source))
			assert(vim.fn.writefile({ "bad-binary" }, details.source, "b") == 0)
			restore_times(details.source, before)
			local after = assert(vim.uv.fs_lstat(details.source))
			assert(after.size == before.size)
			assert(after.mtime.sec == before.mtime.sec and after.mtime.nsec == before.mtime.nsec)
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("candidate%-changed"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
end)

test("target replacement between snapshot and promotion is preserved", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "before_target_reserve" and details.target == target then
			assert(vim.uv.fs_unlink(target))
			assert(vim.fn.writefile({ "rival-before-publish" }, target, "b") == 0)
			assert(vim.uv.fs_chmod(target, tonumber("755", 8)))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("target%-changed"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "rival-before-publish")
end)

test("same-size same-mtime incumbent rewrites fail before the exchange syscall", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "before_target_exchange" and details.target == target then
			local before = assert(vim.uv.fs_lstat(target))
			assert(vim.fn.writefile({ "bad-binary" }, target, "b") == 0)
			restore_times(target, before)
			local after = assert(vim.uv.fs_lstat(target))
			assert(after.size == before.size)
			assert(after.mtime.sec == before.mtime.sec and after.mtime.nsec == before.mtime.nsec)
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("target%-changed"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "bad-binary")
end)

test("target replacement after exact validation is rolled back to the actual rival", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	local parked = vim.fs.joinpath(plan.install_root, "bin", "plantuml.parked-old")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "at_target_exchange_syscall" and details.target == target then
			assert(vim.uv.fs_rename(target, parked))
			assert(vim.fn.writefile({ "rival-at-syscall" }, target, "b") == 0)
			assert(vim.uv.fs_chmod(target, tonumber("755", 8)))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("exact target CAS mismatch", 1, true), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "rival-at-syscall")
	assert(vim.fn.readfile(parked, "b")[1] == "old-binary")
end)

test("a symlink introduced at the exchange boundary is restored without following it", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	local parked = vim.fs.joinpath(plan.install_root, "bin", "plantuml.parked-before-symlink")
	local outside = vim.fs.joinpath(fixture, "outside-rival")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	assert(vim.fn.writefile({ "outside-unchanged" }, outside, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "at_target_exchange_syscall" and details.target == target then
			assert(vim.uv.fs_rename(target, parked))
			assert(vim.uv.fs_symlink(outside, target))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("exact target CAS mismatch", 1, true), tostring(reason))
	assert(assert(vim.uv.fs_lstat(target)).type == "link", "boundary symlink was not restored")
	assert(vim.uv.fs_readlink(target) == outside, "boundary symlink destination changed")
	assert(vim.fn.readfile(outside, "b")[1] == "outside-unchanged")
	assert(vim.fn.readfile(parked, "b")[1] == "old-binary")
	assert(vim.uv.fs_unlink(target))
	assert(vim.uv.fs_rename(parked, target))
end)

test("target parent swap after validation cannot redirect publication", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	local target_parent = vim.fs.dirname(target)
	assert(vim.fn.mkdir(target_parent, "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local parked_parent = fixture .. "/validated-bin-" .. tostring(vim.uv.hrtime())
	local outside_parent = fixture .. "/outside-bin-" .. tostring(vim.uv.hrtime())
	assert(vim.fn.mkdir(outside_parent, "p") == 1)
	local outside_target = vim.fs.joinpath(outside_parent, "plantuml")
	assert(vim.fn.writefile({ "outside-rival" }, outside_target, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "target_parent_validated" and details.target == target then
			assert(vim.uv.fs_rename(target_parent, parked_parent))
			assert(vim.uv.fs_symlink(outside_parent, target_parent))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	local swapped_kind = assert(vim.uv.fs_lstat(target_parent)).type
	local rival_contents = vim.fn.readfile(outside_target, "b")[1]
	local original_contents = vim.fn.readfile(vim.fs.joinpath(parked_parent, "plantuml"), "b")[1]
	local quarantines = vim.fn.glob(parked_parent .. "/.plantuml.*", false, true)
	assert(vim.uv.fs_unlink(target_parent))
	assert(vim.uv.fs_rename(parked_parent, target_parent))
	assert(success == false and reason == "target-parent-changed")
	assert(swapped_kind == "link", "competing parent was replaced")
	assert(rival_contents == "outside-rival", "publication escaped through the swapped parent")
	assert(original_contents == "old-binary", "validated parent was mutated after it moved")
	assert(#quarantines == 0, "parent drift left a module quarantine")
end)

test("target tree ancestor swap cannot redirect mkdir or chmod", function()
	installer._platform = function()
		return "Darwin", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	assert(plan.asset.kind == "jar")
	local share = vim.fs.joinpath(plan.install_root, "share")
	assert(vim.fn.mkdir(share, "p") >= 0)
	assert(vim.fn.writefile({ "validated-parent" }, vim.fs.joinpath(share, "sentinel"), "b") == 0)
	local parked_share = fixture .. "/validated-share-" .. tostring(vim.uv.hrtime())
	local outside_share = fixture .. "/outside-share-" .. tostring(vim.uv.hrtime())
	assert(vim.fn.mkdir(outside_share, "p") == 1)
	local outside_sentinel = vim.fs.joinpath(outside_share, "sentinel")
	assert(vim.fn.writefile({ "outside-rival" }, outside_sentinel, "b") == 0)
	local outside_child_path = vim.fs.joinpath(outside_share, "plantuml")
	assert(vim.fn.mkdir(outside_child_path, "p") == 1)
	assert(vim.uv.fs_chmod(outside_child_path, tonumber("700", 8)))
	local outside_child_sentinel = vim.fs.joinpath(outside_child_path, "sentinel")
	assert(vim.fn.writefile({ "outside-child-rival" }, outside_child_sentinel, "b") == 0)
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "before_target_tree_step" and details.parent == share and details.segment == "plantuml" then
			assert(vim.uv.fs_rename(share, parked_share))
			assert(vim.uv.fs_symlink(outside_share, share))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	local swapped_kind = assert(vim.uv.fs_lstat(share)).type
	local rival_contents = vim.fn.readfile(outside_sentinel, "b")[1]
	local original_contents = vim.fn.readfile(vim.fs.joinpath(parked_share, "sentinel"), "b")[1]
	local outside_child_mode = assert(vim.uv.fs_lstat(outside_child_path)).mode % 512
	local outside_child_contents = vim.fn.readfile(outside_child_sentinel, "b")[1]
	local parked_child = vim.uv.fs_lstat(vim.fs.joinpath(parked_share, "plantuml"))
	assert(vim.uv.fs_unlink(share))
	assert(vim.uv.fs_rename(parked_share, share))
	assert(success == false and reason == "artifact-target-parent-changed")
	assert(swapped_kind == "link", "competing ancestor was replaced")
	assert(rival_contents == "outside-rival", "target tree creation escaped through the swapped ancestor")
	assert(original_contents == "validated-parent", "moved validated ancestor was chmodded or populated")
	assert(outside_child_mode == 448, "target tree creation chmodded the competing directory")
	assert(outside_child_contents == "outside-child-rival", "target tree creation mutated the competing directory")
	assert(parked_child == nil, "target tree creation populated the moved validated ancestor")
end)

test("no-clobber publication preserves a late rival", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	if vim.uv.fs_lstat(target) then
		assert(vim.uv.fs_unlink(target))
	end
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "at_initial_publish_syscall" and details.target == target then
			assert(vim.uv.fs_lstat(target) == nil)
			assert(vim.fn.writefile({ "rival-at-publish" }, target, "b") == 0)
			assert(vim.uv.fs_chmod(target, tonumber("755", 8)))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("promote%-failed"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "rival-at-publish")
end)

test("initial no-clobber publication survives abrupt exit with one executable link", function()
	local initial_root = vim.fs.joinpath(fixture, "initial-crash-managed")
	local target = vim.fs.joinpath(initial_root, "bin", "plantuml")
	local ready = vim.fs.joinpath(fixture, "initial-crash.ready")
	local child = vim.system(
		{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/release_installer_spec.lua" },
		{
			env = {
				RELEASE_INSTALLER_INITIAL_CRASH_CHILD = "1",
				RELEASE_INSTALLER_INITIAL_CRASH_READY = ready,
				RELEASE_INSTALLER_INITIAL_CRASH_ROOT = initial_root,
			},
			text = true,
		}
	)
	local ready_ok = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 1)
	if not ready_ok then
		child:kill(9)
		local failed = child:wait(5000)
		error("initial publication child did not reach the barrier: " .. tostring(failed.stderr))
	end
	local published = vim.fn.readfile(ready)[1]
	assert(vim.uv.fs_realpath(published) == vim.uv.fs_realpath(target))
	local stat = assert(vim.uv.fs_lstat(target))
	assert(stat.nlink == 1, "initial target retained a staging hardlink")
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "initial publication child was not killed")
	stat = assert(vim.uv.fs_lstat(target))
	assert(stat.nlink == 1, "abrupt exit changed initial target link count")
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	assert(vim.fn.delete(initial_root, "rf") == 0)
end)

test("rollback refuses a changed target and retains the exact previous executable", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local old_identity = assert(vim.uv.fs_lstat(target))
	fake_runner(plan)
	local success, reason
	local recovery
	assert(with_test_hook(function(phase, details)
		if phase == "after_target_exchange" and details.target == target then
			recovery = details.recovery
			assert(vim.fn.readfile(recovery, "b")[1] == "old-binary")
			assert(vim.uv.fs_unlink(target))
			assert(vim.fn.writefile({ "rival-during-rollback" }, target, "b") == 0)
			assert(vim.uv.fs_chmod(target, tonumber("755", 8)))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("previous%-retained"), tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "rival-during-rollback")
	local retained = assert(
		vim.uv.fs_lstat(recovery),
		"missing rollback recovery; staging="
			.. vim.inspect(vim.fn.glob(plan.install_root .. "/staging/**", false, true))
	)
	assert(retained.dev == old_identity.dev and retained.ino == old_identity.ino)
	assert(vim.fn.readfile(recovery, "b")[1] == "old-binary")
end)

test("existing target exchange remains visible and preserves OLD across abrupt exit", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local crash_root = vim.fs.joinpath(fixture, "crash-managed")
	local target = vim.fs.joinpath(crash_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local old_identity = assert(vim.uv.fs_lstat(target))
	local ready = vim.fs.joinpath(fixture, "exchange-crash.ready")
	local child = vim.system(
		{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/release_installer_spec.lua" },
		{
			env = {
				RELEASE_INSTALLER_EXCHANGE_CRASH_CHILD = "1",
				RELEASE_INSTALLER_EXCHANGE_CRASH_READY = ready,
				RELEASE_INSTALLER_EXCHANGE_CRASH_ROOT = crash_root,
			},
			text = true,
		}
	)
	local target_was_missing = false
	local ready_ok = vim.wait(5000, function()
		if vim.uv.fs_lstat(target) == nil then
			target_was_missing = true
		end
		return vim.uv.fs_lstat(ready) ~= nil
	end, 1)
	if not ready_ok then
		child:kill(9)
		local failed = child:wait(5000)
		error("exchange crash child did not reach the barrier: " .. tostring(failed.stderr))
	end
	assert(not target_was_missing, "target became absent while the child exchanged OLD and NEW")
	local details = vim.fn.readfile(ready)
	local recovery = assert(details[1])
	assert(
		vim.uv.fs_realpath(details[2]) == vim.uv.fs_realpath(target),
		("exchange child published a different target: %s != %s"):format(details[2], target)
	)
	assert(vim.fn.readfile(target, "b")[1] == "new-binary", "target was absent or stale after exchange")
	local retained = assert(vim.uv.fs_lstat(recovery))
	assert(retained.dev == old_identity.dev and retained.ino == old_identity.ino)
	assert(vim.fn.readfile(recovery, "b")[1] == "old-binary")
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "exchange crash child was not killed")
	assert(vim.fn.readfile(target, "b")[1] == "new-binary", "abrupt exit removed the visible target")
	retained = assert(vim.uv.fs_lstat(recovery))
	assert(retained.dev == old_identity.dev and retained.ino == old_identity.ino)
	assert(vim.fn.readfile(recovery, "b")[1] == "old-binary")
	assert(vim.fn.delete(crash_root, "rf") == 0)
end)

test("successful exchange rolls back atomically when post-exchange validation fails", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local old_identity = assert(vim.uv.fs_lstat(target))
	fake_runner(plan)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "after_target_exchange" and details.target == target then
			error("injected post-exchange failure")
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("exchange%-hook%-failed"), tostring(reason))
	local restored = assert(vim.uv.fs_lstat(target))
	assert(restored.dev == old_identity.dev and restored.ino == old_identity.ino)
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
end)

test("cleanup replacement retains OLD and does not turn a committed NEW into failure", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local old_identity = assert(vim.uv.fs_lstat(target))
	fake_runner(plan)
	local success, reason
	local evidence
	local recovery
	local parked_old = vim.fs.joinpath(fixture, "cleanup-previous-" .. tostring(vim.uv.hrtime()))
	local rival_identity
	assert(with_test_hook(function(phase, details)
		if phase == "before_previous_cleanup" and details.target == target then
			recovery = details.recovery
			assert(vim.uv.fs_rename(recovery, parked_old))
			assert(vim.fn.writefile({ "cleanup-rival" }, recovery, "b") == 0)
			rival_identity = assert(vim.uv.fs_lstat(recovery))
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success = ok
			if ok then
				evidence = err
			else
				reason = err
			end
		end)
	end))
	assert(success == true, tostring(reason))
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	local retained_old = assert(vim.uv.fs_lstat(parked_old))
	assert(retained_old.dev == old_identity.dev and retained_old.ino == old_identity.ino)
	assert(vim.fn.readfile(parked_old, "b")[1] == "old-binary")
	local retained_rival = assert(
		vim.uv.fs_lstat(recovery),
		"missing cleanup rival; staging=" .. vim.inspect(vim.fn.glob(plan.install_root .. "/staging/**", false, true))
	)
	assert(retained_rival.dev == rival_identity.dev and retained_rival.ino == rival_identity.ino)
	assert(vim.fn.readfile(recovery, "b")[1] == "cleanup-rival")
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("previous%-retained") ~= nil
	end))
end)

test("quarantined cleanup replacement retains both OLD and the rival", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local parked_old = vim.fs.joinpath(fixture, "quarantined-old-" .. tostring(vim.uv.hrtime()))
	local rival_path
	local success, evidence
	assert(with_test_hook(function(phase, details)
		if phase == "before_quarantined_unlink" and details.label == "previous-target" then
			rival_path = details.path
			assert(vim.uv.fs_rename(details.path, parked_old))
			assert(vim.fn.writefile({ "cleanup-rival" }, details.path, "b") == 0)
		end
	end, function()
		return installer.install(plan, function(ok, value)
			success, evidence = ok, value
		end)
	end))
	assert(success == true, tostring(evidence))
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	assert(vim.fn.readfile(parked_old, "b")[1] == "old-binary")
	assert(vim.fn.readfile(rival_path, "b")[1] == "cleanup-rival")
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("quarantine%-retained") ~= nil
	end))
end)

test("committed fsync and close failures remain success with bounded warnings", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local success, evidence
	assert(with_test_hook(function(phase, details)
		if phase == "before_fd_sync" and details.label == "target-exchange-parent" then
			error("injected\npostcommit fsync failure")
		end
		if phase == "before_promotion_close" and details.label == "candidate-parent" then
			error("injected postcommit close failure")
		end
	end, function()
		return installer.install(plan, function(ok, value)
			success, evidence = ok, value
		end)
	end))
	assert(success == true, tostring(evidence))
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	assert(type(evidence.warnings) == "table" and #evidence.warnings >= 2 and #evidence.warnings <= 32)
	assert(vim.iter(evidence.warnings):all(function(warning)
		return #warning <= 512 and not warning:find("[%z\1-\31\127]")
	end))
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("target%-exchange%-parent") ~= nil
	end))
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("recovery=", 1, true) ~= nil
	end))
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("stage%-retained") ~= nil
	end))
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("close%-warning") ~= nil
	end))
end)

test("durability barriers cover staged data and every publication parent mutation", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan)
	local labels = {}
	local success, evidence
	assert(with_test_hook(function(phase, details)
		if phase == "before_fd_sync" then
			labels[details.label] = true
		end
	end, function()
		return installer.install(plan, function(ok, value)
			success, evidence = ok, value
		end)
	end))
	assert(success == true, tostring(evidence))
	for _, label in ipairs({
		"mkdir-parent",
		"archive",
		"archive-parent",
		"archive-copy-parent",
		"archive-copy",
		"archive-anonymize-parent",
		"candidate",
		"candidate-pin-parent",
		"candidate-metadata",
		"target-exchange-parent",
		"previous-target-cleanup-reserve-parent",
		"previous-target-cleanup-parent",
		"stage-cleanup-reserve-parent",
		"stage-cleanup-parent",
	}) do
		assert(labels[label], "missing durability barrier: " .. label)
	end
end)

test("archive pathname swaps cannot change descriptor-bound verification or extraction", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local state = fake_runner(plan, { swap_download_during_extract = true })
	local success, evidence
	assert(installer.install(plan, function(ok, value)
		success, evidence = ok, value
	end))
	assert(success == true, tostring(evidence))
	assert(state.archive_hash_count == 1, "archive verification was repeated through a pathname")
	assert(state.extraction_count == 1)
	assert(state.promoted_hash_count == 0, "promoted evidence was read back through a pathname")
	assert(evidence.artifacts["bin/plantuml"] == vim.fn.sha256("new-binary"))
end)

test("JAR hash callback pathname swaps cannot substitute the verified artifact", function()
	installer._platform = function()
		return "Darwin", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local state = fake_runner(plan, { swap_download_during_hash_callback = true })
	local success, evidence
	assert(installer.install(plan, function(ok, value)
		success, evidence = ok, value
	end))
	assert(success == true, tostring(evidence))
	assert(state.archive_hash_count == 1, "a second pathname hash was still used")
	assert(state.promoted_hash_count == 0)
	local relative = plan.layout.artifacts[1]
	local artifact = vim.fs.joinpath(plan.install_root, relative)
	assert(vim.fn.readfile(artifact, "b")[1] == "archive")
	assert(evidence.artifacts[relative] == vim.fn.sha256("archive"))
	assert(vim.fn.readfile(state.parked_download, "b")[1] == "archive")
	assert(vim.uv.fs_unlink(state.parked_download))
end)

test("success evidence uses the precommit candidate digest after target replacement", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	local target = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	local state = fake_runner(plan, { fail_promoted_hash = true })
	local success, evidence
	assert(with_test_hook(function(phase)
		if phase == "before_success_evidence" then
			assert(vim.uv.fs_unlink(target))
			assert(vim.fn.writefile({ "rival-binary" }, target, "b") == 0)
			assert(vim.uv.fs_chmod(target, tonumber("755", 8)))
		end
	end, function()
		return installer.install(plan, function(ok, value)
			success, evidence = ok, value
		end)
	end))
	assert(success == true, tostring(evidence))
	assert(state.promoted_hash_count == 0, "postcommit path hash was invoked")
	assert(evidence.artifacts["bin/plantuml"] == vim.fn.sha256("new-binary"))
	assert(evidence.artifacts["bin/plantuml"] ~= vim.fn.sha256("rival-binary"))
	assert(vim.fn.readfile(target, "b")[1] == "rival-binary")
end)

test("verified native archive atomically promotes the exact member", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	assert(plan.asset.kind == "zip", "native PlantUML asset was replaced by the JAR path")
	fake_runner(plan)
	local success, reason
	local evidence
	assert(installer.install(plan, function(ok, err)
		success = ok
		if ok then
			evidence = err
		else
			reason = err
		end
	end))
	assert(success == true)
	assert(reason == nil, "successful native promotion returned a failure reason")
	assert(evidence.kind == "release-install-evidence")
	assert(evidence.archive_sha256 == plan.asset.sha256)
	assert(evidence.artifacts["bin/plantuml"] == vim.fn.sha256("new-binary"))
	local target = vim.fs.joinpath(paths.managed_bin(), "plantuml")
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	assert(assert(vim.uv.fs_stat(target)).mode % 512 == 493, "native executable is not 0755")
end)

test("verified JAR is versioned and exposed through an atomic wrapper", function()
	installer._platform = function()
		return "Darwin", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	assert(plan.asset.kind == "jar")
	fake_runner(plan)
	local success, reason
	local evidence
	assert(installer.install(plan, function(ok, err)
		success = ok
		if ok then
			evidence = err
		else
			reason = err
		end
	end))
	assert(success == true)
	assert(reason == nil, "successful JAR promotion returned a failure reason")
	assert(evidence.artifacts[plan.layout.artifacts[1]])
	assert(evidence.artifacts["bin/plantuml"])
	local artifact =
		vim.fs.joinpath(paths.managed_root(), "share", "plantuml", "1.2026.6", plan.asset.sha256, "plantuml.jar")
	assert(vim.fn.filereadable(artifact) == 1, "versioned JAR was not promoted")
	local wrapper_path = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	local wrapper = table.concat(vim.fn.readfile(wrapper_path), "\n")
	assert(wrapper:find("exec java %-jar", 1) and wrapper:find(artifact, 1, true))
	assert(wrapper:find('"%$@"'), "wrapper does not forward argv")
	assert(assert(vim.uv.fs_stat(wrapper_path)).mode % 512 == 493)
end)

test("JAR wrapper promotion failure leaves the previous stable command intact", function()
	installer._platform = function()
		return "Darwin", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	fake_runner(plan)
	assert(vim.fn.mkdir(paths.managed_bin(), "p") >= 0)
	local wrapper_path = vim.fs.joinpath(plan.install_root, "bin", "plantuml")
	local old_wrapper = "#!/bin/sh\nexec java -jar '/old/artifact.jar' \"$@\"\n"
	assert(vim.fn.writefile(vim.split(old_wrapper, "\n", { plain = true }), wrapper_path, "b") == 0)
	local success, reason
	assert(with_test_hook(function(phase, details)
		if phase == "before_publish_link" and details.target == wrapper_path then
			error("injected wrapper failure")
		end
	end, function()
		return installer.install(plan, function(ok, err)
			success, reason = ok, err
		end)
	end))
	assert(success == false and reason:find("wrapper%-promote%-failed"))
	assert(table.concat(vim.fn.readfile(wrapper_path), "\n") == vim.trim(old_wrapper))
end)

test("cleanup ancestor swap never recursively deletes the replacement", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external()
	local plan = assert(installer.plan("mmdflux"))
	local child_callback
	installer._run = function(command, _, callback)
		assert(vim.fs.basename(command[1]) == "curl")
		child_callback = callback
		return { kill = function() end }
	end
	local outside = fixture .. "/cleanup-outside-" .. tostring(vim.uv.hrtime())
	assert(vim.fn.mkdir(outside, "p") == 1)
	local outside_sentinel = vim.fs.joinpath(outside, "sentinel")
	assert(vim.fn.writefile({ "outside-rival" }, outside_sentinel, "b") == 0)
	local stage_path
	local parked_stage = fixture .. "/cleanup-parked-" .. tostring(vim.uv.hrtime())
	installer._set_test_hook(function(phase, details)
		if phase == "before_stage_cleanup" then
			stage_path = details.stage
			assert(vim.uv.fs_rename(stage_path, parked_stage))
			assert(vim.uv.fs_symlink(outside, stage_path))
		end
	end)
	local success, reason
	local controller = assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	controller.cancel()
	child_callback({ code = 143, stdout = "", stderr = "" })
	installer._set_test_hook(nil)
	local swapped_kind = assert(vim.uv.fs_lstat(stage_path)).type
	local rival_contents = vim.fn.readfile(outside_sentinel, "b")[1]
	local parked_kind = assert(vim.uv.fs_lstat(parked_stage)).type
	assert(vim.uv.fs_unlink(stage_path))
	assert(vim.uv.fs_rename(parked_stage, stage_path))
	assert(vim.fn.delete(stage_path, "rf") == 0)
	assert(success == false and reason == "cancelled")
	assert(swapped_kind == "link", "cleanup removed the competing stage entry")
	assert(rival_contents == "outside-rival", "cleanup recursively deleted through the swapped ancestor")
	assert(parked_kind == "directory", "cleanup removed the descriptor-pinned stage")
end)

test("stage quarantine replacement is retained and reported after commit", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	fake_runner(plan)
	local parked_stage = vim.fs.joinpath(fixture, "parked-clean-stage-" .. tostring(vim.uv.hrtime()))
	local rival_stage
	local success, evidence
	assert(with_test_hook(function(phase, details)
		if phase == "before_quarantined_unlink" and details.label == "stage-cleanup" then
			rival_stage = details.path
			assert(vim.uv.fs_rename(details.path, parked_stage))
			assert(vim.fn.mkdir(details.path, "p") == 1)
		end
	end, function()
		return installer.install(plan, function(ok, value)
			success, evidence = ok, value
		end)
	end))
	assert(success == true, tostring(evidence))
	assert(assert(vim.uv.fs_lstat(parked_stage)).type == "directory")
	assert(assert(vim.uv.fs_lstat(rival_stage)).type == "directory")
	assert(vim.iter(evidence.warnings):any(function(warning)
		return warning:find("stage%-cleanup%-quarantine%-retained") ~= nil
	end))
	assert(vim.fn.delete(rival_stage, "rf") == 0)
	assert(vim.fn.delete(parked_stage, "rf") == 0)
end)

test("explicit cancellation stops the active release process and cleans staging", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external()
	local plan = assert(installer.plan("mmdflux"))
	local killed = false
	local callback_called = false
	local child_callback
	local staging = vim.fs.joinpath(paths.managed_root(), "staging")
	local existing_stages = #vim.fn.glob(staging .. "/*", false, true)
	installer._run = function(command, _, callback)
		assert(vim.fs.basename(command[1]) == "curl")
		child_callback = callback
		return {
			kill = function(_, signal)
				assert(signal == 15)
				killed = true
			end,
		}
	end
	local controller = assert(installer.install(plan, function()
		callback_called = true
	end))
	assert(type(controller.cancel) == "function")
	controller.cancel()
	assert(killed and not callback_called)
	assert(
		#vim.fn.glob(staging .. "/*", false, true) == existing_stages + 1,
		"active staging was removed before child exit"
	)
	controller.cancel()
	child_callback({ code = 143, stdout = "", stderr = "" })
	assert(callback_called, "child exit did not acknowledge cancellation")
	assert(#vim.fn.glob(staging .. "/*", false, true) == existing_stages)
end)

vim.env.NVIM_CONFIG_TOOLS_ROOT = original_tools_root
package.loaded["config.tool_paths"] = nil
package.loaded["config.release_installer"] = nil
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("release_installer_spec: %d tests passed", count))
vim.cmd("quitall!")
