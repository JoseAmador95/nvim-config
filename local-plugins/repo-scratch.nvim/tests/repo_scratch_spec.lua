vim.o.shadafile = "NONE"
vim.o.swapfile = false

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local scratch = require("repo_scratch")

if vim.env.REPO_SCRATCH_EXCHANGE_CRASH_CHILD == "1" then
	local root = assert(vim.env.REPO_SCRATCH_EXCHANGE_CRASH_ROOT)
	local ready = assert(vim.env.REPO_SCRATCH_EXCHANGE_CRASH_READY)
	assert(scratch.setup({
		state_root = root,
		now = function()
			return 2_000_000_000
		end,
		lease_seconds = 60,
	}))
	local handle = assert(scratch.open({
		key = { repo_identity = "/exchange-crash", ref = "refs/heads/main" },
	}))
	scratch._set_test_hook(function(event, details)
		if event == "after_exchange" and not details.rollback and details.to == handle.path then
			assert(vim.uv.fs_lstat(handle.path), "exchange made the scratch target disappear")
			assert(vim.fn.writefile({ "ready" }, ready) == 0)
			vim.wait(60_000, function()
				return false
			end, 100)
			error("scratch exchange crash child was not killed")
		end
	end)
	scratch.save(handle, "published before crash\n")
	error("scratch exchange crash child unexpectedly completed")
end

if vim.env.REPO_SCRATCH_CLAIM_CRASH_CHILD == "1" then
	local root = assert(vim.env.REPO_SCRATCH_CLAIM_CRASH_ROOT)
	local ready = assert(vim.env.REPO_SCRATCH_CLAIM_CRASH_READY)
	assert(scratch.setup({
		state_root = root,
		now = function()
			return 2_000_000_000
		end,
		lease_seconds = 60,
	}))
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and details.from:sub(-8) == ".publish"
			and details.to:find(".md.lock.", 1, true)
		then
			assert(vim.fn.writefile({ "ready" }, ready) == 0)
			vim.wait(60_000, function()
				return false
			end, 100)
			error("scratch claim crash child was not killed")
		end
	end)
	scratch.open({ key = { repo_identity = "/claim-crash", ref = "refs/heads/main" } })
	error("scratch claim crash child unexpectedly completed")
end

if vim.env.REPO_SCRATCH_LOCK_CHILD == "1" then
	local root = assert(vim.env.REPO_SCRATCH_LOCK_ROOT)
	local ready = assert(vim.env.REPO_SCRATCH_LOCK_READY)
	local peer_ready = assert(vim.env.REPO_SCRATCH_LOCK_PEER_READY)
	local result_path = assert(vim.env.REPO_SCRATCH_LOCK_RESULT)
	assert(scratch.setup({
		state_root = root,
		now = function()
			return 2_000_000_000
		end,
		lease_seconds = 60,
	}))
	assert(vim.fn.writefile({ "ready" }, ready) == 0)
	assert(
		vim.wait(5000, function()
			return vim.uv.fs_lstat(peer_ready) ~= nil
		end, 5),
		"scratch lock child barrier timed out"
	)
	local handle, err = scratch.open({ key = { repo_identity = "/race", ref = "refs/heads/main" } })
	local result = handle and "opened" or (type(err) == "table" and err.kind or ("error:" .. tostring(err)))
	assert(vim.fn.writefile({ result }, result_path) == 0)
	vim.cmd("quitall!")
	return
end

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

test("lifecycle defaults are copied and rejected setup is non-mutating", function()
	local defaults = scratch.effective_config()
	assert(defaults.max_age_seconds == 30 * 24 * 60 * 60)
	assert(defaults.lease_seconds == 300)
	assert(scratch.status().configured == false)
	defaults.lease_seconds = 1
	assert(scratch.effective_config().lease_seconds == 300, "effective config leaked mutable state")
	local before = scratch.status()
	local ok, err = scratch.setup({ state_root = "/tmp/unused", unknown = true })
	assert(not ok and err:find("unknown option", 1, true), err)
	assert(vim.deep_equal(before, scratch.status()), "rejected setup mutated state")
end)

local fixture = vim.fn.tempname()
local state = fixture .. "/state/scratch"
local now = 2_000_000_000
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

local function read_bytes(path)
	local stat = assert(vim.uv.fs_stat(path))
	local fd = assert(vim.uv.fs_open(path, "r", 0))
	local data = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return data
end

local function write_bytes(path, data)
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_write(fd, data, 0) == #data)
	assert(vim.uv.fs_fsync(fd))
	assert(vim.uv.fs_close(fd))
end

local function descriptor_count()
	local directory = vim.uv.os_uname().sysname == "Darwin" and "/dev/fd" or "/proc/self/fd"
	return #vim.fn.readdir(directory)
end

local function arbiter_claim(path, kind, pid, token, number)
	local base = path .. ".lock"
	local claim_path
	local value = { version = 1, kind = kind, pid = pid, token = token }
	if kind == "choosing" then
		claim_path = base .. ".choosing." .. token
	else
		value.number = assert(number)
		claim_path = ("%s.ticket.%020d.%s"):format(base, number, token)
	end
	assert(vim.fn.writefile({ vim.json.encode(value) }, claim_path) == 0)
	assert(vim.uv.fs_chmod(claim_path, tonumber("600", 8)))
	return claim_path
end

local unsafe_sequence = 0
local function unsafe_lease(path, kind)
	unsafe_sequence = unsafe_sequence + 1
	if vim.uv.fs_lstat(path) then
		assert(vim.uv.fs_unlink(path))
	end
	local reference
	if kind == "corrupt" then
		assert(vim.fn.writefile({ string.char(255) .. "not-json" }, path, "b") == 0)
	elseif kind == "truncated" then
		assert(vim.fn.writefile({ '{"token":"unfinished' }, path, "b") == 0)
	elseif kind == "oversize" then
		assert(vim.fn.writefile({ string.rep("x", 4097) }, path, "b") == 0)
	elseif kind == "schema-invalid" then
		assert(vim.fn.writefile({
			vim.json.encode({
				token = vim.fn.sha256("invalid-schema"),
				pid = vim.uv.os_getpid(),
				expires_at = now + 60,
				unexpected = true,
			}),
		}, path) == 0)
	elseif kind == "symlink" then
		reference = fixture .. "/outside-lease-" .. unsafe_sequence
		assert(vim.fn.writefile({ "outside lease" }, reference) == 0)
		assert(vim.uv.fs_symlink(reference, path))
	elseif kind == "hardlink" then
		reference = fixture .. "/hardlink-lease-" .. unsafe_sequence
		assert(vim.fn.writefile({
			vim.json.encode({
				token = vim.fn.sha256("hardlink-owner"),
				pid = vim.uv.os_getpid(),
				expires_at = now + 60,
			}),
		}, reference) == 0)
		assert(vim.uv.fs_link(reference, path))
	else
		error("unknown unsafe lease fixture: " .. kind)
	end
	if kind ~= "symlink" then
		assert(vim.uv.fs_chmod(path, tonumber("600", 8)))
	end
	local before = assert(vim.uv.fs_lstat(path))
	local contents = read_bytes(path)
	return {
		assert_unchanged = function()
			local after = assert(vim.uv.fs_lstat(path))
			assert(after.dev == before.dev and after.ino == before.ino, kind .. " lease was replaced")
			assert(read_bytes(path) == contents, kind .. " lease was overwritten")
		end,
		cleanup = function()
			if vim.uv.fs_lstat(path) then
				assert(vim.uv.fs_unlink(path))
			end
			if reference and vim.uv.fs_lstat(reference) then
				assert(vim.uv.fs_unlink(reference))
			end
		end,
	}
end

local unsafe_lease_kinds = { "corrupt", "truncated", "oversize", "schema-invalid", "symlink", "hardlink" }

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

test("CAS publication preserves changes arriving at reserve and publish boundaries", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/cas-interleave", ref = "refs/heads/main" },
	}))
	local saved = assert(scratch.save(handle, "first\n"))
	local original_revision = saved.revision

	local reserve_injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_exchange"
			and not reserve_injected
			and not details.rollback
			and details.to == saved.path
		then
			reserve_injected = true
			assert(vim.fn.writefile({ "external" }, saved.path) == 0)
		end
	end)
	local called, result, conflict = xpcall(function()
		return scratch.save(saved, "ours\n")
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, result)
	assert(reserve_injected and result == nil and conflict.kind == "conflict")
	assert(read_bytes(saved.path) == "external\n", "reserve-boundary writer was clobbered")
	assert(saved.revision == original_revision, "failed CAS advanced the caller's revision")

	assert(vim.fn.writefile({ "first" }, saved.path) == 0)
	local publish_injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "after_exchange"
			and not publish_injected
			and not details.rollback
			and details.to == saved.path
			and details.from:find(".tmp.", 1, true)
		then
			publish_injected = true
			assert(vim.uv.fs_lstat(saved.path), "atomic exchange made the target disappear")
			assert(vim.fn.writefile({ "rival" }, saved.path) == 0)
		end
	end)
	called, result, conflict = xpcall(function()
		return scratch.save(saved, "ours-again\n")
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, result)
	assert(publish_injected and result == nil and conflict.kind == "conflict")
	assert(read_bytes(saved.path) == "first\n", "post-exchange rollback did not restore the incumbent")
	assert(saved.revision == original_revision, "publish conflict advanced the caller's revision")

	local recovery
	local prefix = vim.fs.basename(saved.path) .. ".tmp."
	for _, name in ipairs(vim.fn.readdir(state)) do
		if name:find(prefix, 1, true) == 1 then
			assert(not recovery, "post-exchange conflict retained more than one incumbent")
			recovery = vim.fs.joinpath(state, name)
		end
	end
	assert(recovery and read_bytes(recovery) == "rival\n", "post-exchange conflict lost the rival")
	assert(vim.uv.fs_unlink(recovery))
	assert(scratch.release(saved))
end)

test("exchange rollback restores regular and generic rivals captured at the syscall boundary", function()
	for _, kind in ipairs({ "file", "symlink", "hardlink" }) do
		local handle = assert(scratch.open({
			key = { repo_identity = "/repo/exchange-syscall-rival-" .. kind, ref = "refs/heads/main" },
		}))
		handle = assert(scratch.save(handle, "incumbent\n"))
		local original = handle.path .. ".pre-exchange"
		local rival_source = fixture .. "/exchange-rival-" .. kind
		local injected = false
		if kind ~= "file" then
			write_bytes(rival_source, kind .. " rival\n")
		end
		scratch._set_test_hook(function(event, details)
			if
				event == "before_rename_syscall"
				and details.exchange
				and not details.rollback
				and details.to == handle.path
				and not injected
			then
				injected = true
				assert(vim.uv.fs_rename(handle.path, original))
				if kind == "file" then
					write_bytes(handle.path, "file rival\n")
				elseif kind == "symlink" then
					assert(vim.uv.fs_symlink(rival_source, handle.path))
				else
					assert(vim.uv.fs_link(rival_source, handle.path))
				end
			end
		end)
		local saved, conflict = scratch.save(handle, "proposal\n")
		scratch._set_test_hook(nil)
		assert(injected and saved == nil and conflict.kind == "conflict", kind .. " rival was accepted")
		assert(read_bytes(original) == "incumbent\n", kind .. " race lost the original incumbent")
		if kind == "file" then
			assert(read_bytes(handle.path) == "file rival\n", "file rival was not restored")
		elseif kind == "symlink" then
			local current = assert(vim.uv.fs_lstat(handle.path))
			assert(current.type == "link", "symlink rival was replaced by NEW")
			assert(vim.uv.fs_readlink(handle.path) == rival_source, "wrong symlink rival was restored")
			assert(read_bytes(rival_source) == "symlink rival\n", "symlink destination was mutated")
		else
			local current = assert(vim.uv.fs_lstat(handle.path))
			local source_stat = assert(vim.uv.fs_lstat(rival_source))
			assert(
				current.dev == source_stat.dev and current.ino == source_stat.ino,
				"hardlink rival was replaced by NEW"
			)
			assert(read_bytes(handle.path) == "hardlink rival\n", "hardlink rival bytes changed")
		end
		for _, name in ipairs(vim.fn.readdir(state)) do
			assert(not name:find(vim.fs.basename(handle.path) .. ".tmp.", 1, true), kind .. " rollback leaked NEW")
		end
		assert(vim.uv.fs_unlink(handle.path))
		assert(vim.uv.fs_rename(original, handle.path))
		if kind ~= "file" then
			assert(vim.uv.fs_unlink(rival_source))
		end
		assert(scratch.release(handle))
	end
end)

test("exclusive removal reserve and claim publication preserve destination rivals", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/exclusive-destinations", ref = "refs/heads/main" },
	}))
	local saved = assert(scratch.save(handle, "incumbent\n"))
	local record_rival
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and details.exclusive
			and not record_rival
			and details.from == saved.lease_path
			and vim.fs.basename(details.to) == "record"
		then
			record_rival = details.to
			assert(vim.fn.writefile({ "record rival" }, record_rival) == 0)
			assert(vim.uv.fs_chmod(record_rival, tonumber("600", 8)))
		end
	end)
	local result, reserve_err = scratch.release(saved)
	scratch._set_test_hook(nil)
	assert(result == false and reserve_err ~= nil and record_rival, "removal reserve overwrote its destination rival")
	assert(vim.uv.fs_lstat(saved.lease_path), "failed exclusive reserve moved the lease")
	assert(read_bytes(record_rival) == "record rival\n", "failed exclusive reserve removed the record rival")
	assert(vim.uv.fs_unlink(record_rival))
	assert(vim.uv.fs_rmdir(vim.fs.dirname(record_rival)))
	assert(scratch.release(saved))

	local claim_rival
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and details.exclusive
			and not claim_rival
			and details.from:sub(-8) == ".publish"
			and details.to:find(".lock.choosing.", 1, true)
		then
			claim_rival = details.to
			assert(vim.fn.writefile({ "claim rival" }, claim_rival) == 0)
			assert(vim.uv.fs_chmod(claim_rival, tonumber("600", 8)))
		end
	end)
	local opened, claim_err = scratch.open({
		key = { repo_identity = "/repo/exclusive-claim", ref = "refs/heads/main" },
	})
	scratch._set_test_hook(nil)
	assert(opened == nil and claim_err ~= nil and claim_rival, "claim publication overwrote its destination rival")
	assert(read_bytes(claim_rival) == "claim rival\n", "failed claim publication removed the rival")
	assert(vim.uv.fs_unlink(claim_rival))
	opened = assert(scratch.open({
		key = { repo_identity = "/repo/exclusive-claim", ref = "refs/heads/main" },
	}))
	assert(scratch.release(opened))
end)

test("initial publication is a no-clobber rename", function()
	local initial_key = { repo_identity = "/repo/initial-no-clobber", ref = "refs/heads/main" }
	local initial_path =
		vim.fs.joinpath(state, vim.fn.sha256(initial_key.repo_identity .. "\0" .. initial_key.ref) .. ".md")
	local rival_created = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and not rival_created
			and details.to == initial_path
			and details.from:find(".tmp.", 1, true)
		then
			rival_created = true
			write_bytes(initial_path, "initial rival\n")
		end
	end)
	local opened, open_err = scratch.open({ key = initial_key })
	scratch._set_test_hook(nil)
	assert(opened == nil and open_err ~= nil and rival_created, "initial CAS overwrote its destination rival")
	assert(read_bytes(initial_path) == "initial rival\n", "initial CAS mutated its destination rival")
	assert(vim.uv.fs_unlink(initial_path))
	opened = assert(scratch.open({ key = initial_key }))
	assert(scratch.release(opened))
end)

test("state and claim publication validate exact staged and final bytes", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/exact-staging", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local state_stage
	scratch._set_test_hook(function(event, details)
		if event == "before_exchange" and not details.rollback and details.to == handle.path then
			state_stage = details.from
			write_bytes(state_stage, "tampered state stage\n")
		end
	end)
	local saved, save_err = scratch.save(handle, "proposal\n")
	scratch._set_test_hook(nil)
	assert(saved == nil and type(save_err) == "table" and save_err.kind == "conflict")
	assert(read_bytes(handle.path) == "incumbent\n", "tampered state stage was published")
	assert(state_stage and read_bytes(state_stage) == "tampered state stage\n", "tampered state stage was deleted")
	assert(vim.uv.fs_unlink(state_stage))
	assert(scratch.release(handle))

	local staged_claim
	local staged_final
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and details.from:sub(-8) == ".publish"
			and details.to:find(".lock.choosing.", 1, true)
		then
			staged_claim = details.from
			staged_final = details.to
			write_bytes(staged_claim, "tampered claim stage\n")
		end
	end)
	local opened, open_err = scratch.open({
		key = { repo_identity = "/repo/exact-claim-stage", ref = "refs/heads/main" },
	})
	scratch._set_test_hook(nil)
	assert(opened == nil and open_err ~= nil and staged_claim, "tampered claim stage was accepted")
	assert(read_bytes(staged_claim) == "tampered claim stage\n", "tampered claim stage was deleted")
	assert(vim.uv.fs_lstat(staged_final) == nil, "tampered claim stage became visible")
	assert(vim.uv.fs_unlink(staged_claim))

	local final_claim
	local final_bytes
	scratch._set_test_hook(function(event, details)
		if
			event == "after_rename"
			and details.from:sub(-8) == ".publish"
			and details.to:find(".lock.choosing.", 1, true)
		then
			final_claim = details.to
			final_bytes = read_bytes(final_claim)
			assert(vim.uv.fs_unlink(final_claim))
			write_bytes(final_claim, final_bytes)
		end
	end)
	opened, open_err = scratch.open({
		key = { repo_identity = "/repo/exact-claim-final", ref = "refs/heads/main" },
	})
	scratch._set_test_hook(nil)
	assert(opened == nil and open_err ~= nil and final_claim, "replacement claim inode was accepted")
	assert(read_bytes(final_claim) == final_bytes, "replacement claim was deleted")
	assert(vim.uv.fs_unlink(final_claim))
end)

test("arbiter scan rejects a byte-identical replacement of its own claim", function()
	local replacement
	local replacement_bytes
	scratch._set_test_hook(function(event, details)
		if event == "before_claim_scan" and details.phase == "choosing" and not replacement then
			replacement = details.path
			replacement_bytes = read_bytes(replacement)
			assert(vim.uv.fs_unlink(replacement))
			write_bytes(replacement, replacement_bytes)
		end
	end)
	local opened, open_err = scratch.open({
		key = { repo_identity = "/repo/own-claim-replacement", ref = "refs/heads/main" },
	})
	scratch._set_test_hook(nil)
	assert(
		opened == nil and tostring(open_err):find("owned scratch arbiter claim", 1, true),
		"own claim replacement was accepted"
	)
	assert(read_bytes(replacement) == replacement_bytes, "own claim replacement was deleted")
	assert(vim.uv.fs_unlink(replacement))
end)

test("exact exchange rollback restores the incumbent through the pinned root", function()
	local base = fixture .. "/exchange-rollback"
	local configured = base .. "/state"
	local displaced = base .. "/state-displaced"
	local outside = base .. "/outside"
	assert(vim.fn.mkdir(outside, "p", tonumber("700", 8)) == 1)
	assert(scratch.setup({
		state_root = configured,
		now = function()
			return now
		end,
		lease_seconds = 60,
		max_age_seconds = 30 * 24 * 60 * 60,
	}))
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/exchange-rollback", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local swapped = false
	scratch._set_test_hook(function(event, details)
		if event == "after_exchange" and not details.rollback and details.to == handle.path then
			swapped = true
			assert(vim.uv.fs_lstat(handle.path), "exchange target was transiently absent")
			assert(vim.uv.fs_rename(configured, displaced))
			assert(vim.uv.fs_symlink(outside, configured))
		end
	end)
	local saved, save_err = scratch.save(handle, "proposal\n")
	scratch._set_test_hook(nil)
	assert(swapped and saved == nil and type(save_err) == "table" and save_err.kind == "conflict")
	local displaced_target = vim.fs.joinpath(displaced, vim.fs.basename(handle.path))
	assert(read_bytes(displaced_target) == "incumbent\n", "exact rollback did not restore the incumbent")
	assert(#vim.fn.readdir(outside) == 0, "rollback mutated the substituted state root")
	for _, name in ipairs(vim.fn.readdir(displaced)) do
		assert(not name:find(vim.fs.basename(handle.path) .. ".tmp.", 1, true), "exact rollback leaked a proposal")
	end
	assert(vim.uv.fs_unlink(configured))
	assert(vim.uv.fs_rename(displaced, configured))
	assert(scratch.release(handle))
	assert(scratch.setup({
		state_root = state,
		now = function()
			return now
		end,
		lease_seconds = 60,
		max_age_seconds = 30 * 24 * 60 * 60,
	}))
end)

test("conditional cleanup preserves a replacement record and its original", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/cleanup-record-race", ref = "refs/heads/main" },
	}))
	local record
	local original
	scratch._set_test_hook(function(event, details)
		if
			event == "before_unlink_reserve"
			and not record
			and details.from:find(handle.lease_path .. ".cas.", 1, true) == 1
			and vim.fs.basename(details.from) == "record"
		then
			record = details.from
			original = record .. ".original"
			assert(vim.uv.fs_rename(record, original))
			write_bytes(record, "cleanup rival\n")
		end
	end)
	local released, release_err = scratch.release(handle)
	scratch._set_test_hook(nil)
	assert(released == false and release_err ~= nil and record, "conditional cleanup accepted a replacement record")
	assert(read_bytes(record) == "cleanup rival\n", "conditional cleanup deleted the replacement record")
	assert(vim.uv.fs_lstat(original), "conditional cleanup deleted the original lease record")
	assert(vim.uv.fs_unlink(record))
	assert(vim.uv.fs_rename(original, handle.lease_path))
	assert(vim.uv.fs_rmdir(vim.fs.dirname(record)))
	assert(scratch.release(handle))
end)

test("conditional cleanup restores a symlink replacement without following it", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/cleanup-symlink-race", ref = "refs/heads/main" },
	}))
	local outside = fixture .. "/cleanup-symlink-outside"
	write_bytes(outside, "outside unchanged\n")
	local record
	local original
	scratch._set_test_hook(function(event, details)
		if
			event == "before_unlink_reserve"
			and not record
			and details.from:find(handle.lease_path .. ".cas.", 1, true) == 1
			and vim.fs.basename(details.from) == "record"
		then
			record = details.from
			original = record .. ".original"
			assert(vim.uv.fs_rename(record, original))
			assert(vim.uv.fs_symlink(outside, record))
		end
	end)
	local released, release_err = scratch.release(handle)
	scratch._set_test_hook(nil)
	assert(released == false and release_err ~= nil and record, "symlink cleanup race was accepted")
	local rival = assert(vim.uv.fs_lstat(record))
	assert(rival.type == "link" and vim.uv.fs_readlink(record) == outside, "symlink replacement was not restored")
	assert(read_bytes(outside) == "outside unchanged\n", "conditional cleanup followed the symlink rival")
	assert(vim.uv.fs_lstat(original), "conditional cleanup deleted the original record")
	assert(vim.uv.fs_unlink(record))
	assert(vim.uv.fs_rename(original, handle.lease_path))
	assert(vim.uv.fs_rmdir(vim.fs.dirname(record)))
	assert(vim.uv.fs_unlink(outside))
	assert(scratch.release(handle))
end)

test("conditional directory cleanup preserves a last-moment replacement", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/cleanup-directory-race", ref = "refs/heads/main" },
	}))
	local directory
	local original
	local replacement_identity
	scratch._set_test_hook(function(event, details)
		if
			event == "before_unlink_reserve"
			and not directory
			and details.from:find(handle.lease_path .. ".cas.", 1, true) == 1
			and vim.fs.basename(details.from) ~= "record"
		then
			directory = details.from
			original = directory .. ".original"
			assert(vim.uv.fs_rename(directory, original))
			assert(vim.fn.mkdir(directory, "", tonumber("700", 8)) == 1)
			write_bytes(vim.fs.joinpath(directory, "rival-entry"), "directory rival\n")
			replacement_identity = assert(vim.uv.fs_lstat(directory))
		end
	end)
	local released, release_warning = scratch.release(handle)
	scratch._set_test_hook(nil)
	assert(released == true and tostring(release_warning):find("retained", 1, true), "committed release was hidden")
	local replacement = assert(vim.uv.fs_lstat(directory))
	assert(
		replacement.dev == replacement_identity.dev and replacement.ino == replacement_identity.ino,
		"directory cleanup deleted its replacement"
	)
	assert(vim.uv.fs_lstat(original), "directory cleanup deleted the original quarantine")
	assert(vim.uv.fs_lstat(handle.lease_path) == nil, "committed lease removal was rolled back")
	assert(read_bytes(vim.fs.joinpath(directory, "rival-entry")) == "directory rival\n")
	assert(vim.uv.fs_unlink(vim.fs.joinpath(directory, "rival-entry")))
	assert(vim.uv.fs_rmdir(directory))
	assert(vim.uv.fs_rmdir(original))
end)

test("a committed CAS advances the handle when displaced cleanup is unsafe", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/committed-cleanup-race", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local displaced
	local original
	scratch._set_test_hook(function(event, details)
		if
			event == "before_unlink"
			and details.conditional
			and not details.directory
			and not displaced
			and details.path:find(handle.path .. ".tmp.", 1, true) == 1
		then
			displaced = details.path
			original = displaced .. ".original"
			assert(vim.uv.fs_rename(displaced, original))
			write_bytes(displaced, "cleanup rival\n")
		end
	end)
	local saved, save_err = scratch.save(handle, "committed\n")
	scratch._set_test_hook(nil)
	assert(saved, "durable CAS was reported as failed: " .. vim.inspect(save_err))
	assert(saved.revision == vim.fn.sha256("committed\n"), "successful CAS did not advance the handle")
	assert(read_bytes(saved.path) == "committed\n", "cleanup failure changed committed content")
	assert(read_bytes(original) == "incumbent\n", "cleanup failure lost the displaced incumbent")
	assert(read_bytes(displaced) == "cleanup rival\n", "cleanup failure deleted a replacement artifact")
	assert(vim.uv.fs_unlink(displaced))
	assert(vim.uv.fs_unlink(original))
	assert(scratch.release(saved))
end)

test("hook failures do not leak anchored descriptors", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/hook-fd-cleanup", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local baseline = descriptor_count()
	for _ = 1, 8 do
		scratch._set_test_hook(function(event)
			if event == "before_exchange" then
				error("injected descriptor cleanup failure")
			end
		end)
		local saved, save_err = scratch.save(handle, "must not publish\n")
		scratch._set_test_hook(nil)
		assert(saved == nil and save_err ~= nil, "throwing hook did not fail closed")
		assert(descriptor_count() == baseline, "throwing hook leaked a descriptor")
	end
	assert(scratch.release(handle))
end)

test("post-syscall hook and descriptor-close failures remain committed warnings", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/committed-hook-warning", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local baseline = descriptor_count()
	local after_exchange_failed = false
	scratch._set_test_hook(function(event, details)
		if
			event == "after_exchange"
			and details.to == handle.path
			and not details.rollback
			and not after_exchange_failed
		then
			after_exchange_failed = true
			error("injected post-exchange observer failure")
		end
	end)
	local saved, save_warning = scratch.save(handle, "committed after hook\n")
	scratch._set_test_hook(nil)
	assert(saved and after_exchange_failed, "successful exchange was reported as uncommitted")
	assert(tostring(save_warning):find("after_exchange hook failed", 1, true), "post-exchange warning was lost")
	assert(
		saved.revision == vim.fn.sha256("committed after hook\n") and read_bytes(saved.path) == "committed after hook\n"
	)
	assert(descriptor_count() == baseline, "post-exchange hook failure leaked a descriptor")

	local close_failed = false
	scratch._set_test_hook(function(event, details)
		if
			event == "after_mutation_close"
			and details.operation == "exchange"
			and details.path == saved.path
			and not close_failed
		then
			close_failed = true
			error("injected post-close observer failure")
		end
	end)
	local saved_again, close_warning = scratch.save(saved, "committed after close\n")
	scratch._set_test_hook(nil)
	assert(saved_again and close_failed, "successful exchange was hidden by a close observer")
	assert(tostring(close_warning):find("mutation close hook failed", 1, true), "close warning was lost")
	assert(
		saved_again.revision == vim.fn.sha256("committed after close\n")
			and read_bytes(saved_again.path) == "committed after close\n"
	)
	assert(descriptor_count() == baseline, "post-close hook failure leaked a descriptor")
	assert(scratch.release(saved_again))
end)

test("directory fsync failures after mutations preserve committed public outcomes", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/fsync-outcomes", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local roles = {}
	local before_failed = false
	scratch._set_test_hook(function(event, details)
		if event == "before_parent_fsync" and details.operation == "exchange" and details.to == handle.path then
			roles[details.role] = true
			if details.role == "source" and not before_failed then
				before_failed = true
				error("injected pre-fsync failure")
			end
		end
	end)
	local saved, before_warning = scratch.save(handle, "committed before fsync\n")
	scratch._set_test_hook(nil)
	assert(saved and before_failed, "exchange committed before fsync was reported as failed")
	assert(roles.source and roles.target, "exchange did not attempt both exact parent fsyncs")
	assert(tostring(before_warning):find("fsync was skipped", 1, true), "pre-fsync warning was lost")
	assert(
		saved.revision == vim.fn.sha256("committed before fsync\n")
			and read_bytes(saved.path) == "committed before fsync\n"
	)

	local after_failed = false
	scratch._set_test_hook(function(event, details)
		if
			event == "after_parent_fsync"
			and details.operation == "exchange"
			and details.to == saved.path
			and details.role == "target"
			and not after_failed
		then
			after_failed = true
			error("injected post-fsync failure")
		end
	end)
	local saved_again, after_warning = scratch.save(saved, "committed after fsync\n")
	scratch._set_test_hook(nil)
	assert(saved_again and after_failed, "post-fsync observer hid a committed exchange")
	assert(tostring(after_warning):find("fsync completion hook failed", 1, true), "post-fsync warning was lost")
	assert(
		saved_again.revision == vim.fn.sha256("committed after fsync\n")
			and read_bytes(saved_again.path) == "committed after fsync\n"
	)

	local unlink_failed = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_parent_fsync"
			and details.operation == "unlink"
			and details.path:find(saved_again.lease_path .. ".cas.", 1, true) == 1
			and vim.fs.basename(details.path) == "record"
			and not unlink_failed
		then
			unlink_failed = true
			error("injected unlink fsync failure")
		end
	end)
	local released, release_warning = scratch.release(saved_again)
	scratch._set_test_hook(nil)
	assert(released and unlink_failed, "committed unlink was reported as failed")
	assert(tostring(release_warning):find("fsync was skipped", 1, true), "unlink fsync warning was lost")
	assert(vim.uv.fs_lstat(saved_again.lease_path) == nil, "committed unlink left the public lease")
end)

test("file creation fsync failure is surfaced after successful publication", function()
	local create_key = { repo_identity = "/repo/create-fsync-outcome", ref = "refs/heads/main" }
	local target = vim.fs.joinpath(state, vim.fn.sha256(create_key.repo_identity .. "\0" .. create_key.ref) .. ".md")
	local failed = false
	local rename_failed = false
	local rename_roles = {}
	scratch._set_test_hook(function(event, details)
		if
			event == "before_parent_fsync"
			and details.operation == "create"
			and details.path:find(target .. ".tmp.", 1, true) == 1
			and not failed
		then
			failed = true
			error("injected create fsync failure")
		end
		if event == "after_parent_fsync" and details.operation == "rename" and details.to == target then
			rename_roles[details.role] = true
			if details.role == "source" and not rename_failed then
				rename_failed = true
				error("injected rename fsync observer failure")
			end
		end
	end)
	local handle, warning = scratch.open({ key = create_key })
	scratch._set_test_hook(nil)
	assert(handle and failed and rename_failed, "created scratch was reported as failed")
	assert(rename_roles.source and rename_roles.target, "rename did not fsync both exact parents")
	assert(tostring(warning):find("fsync was skipped", 1, true), "create fsync warning was lost")
	assert(tostring(warning):find("fsync completion hook failed", 1, true), "rename fsync warning was lost")
	assert(vim.uv.fs_lstat(handle.path), "created scratch was not published")
	assert(scratch.release(handle))
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

test("save fails closed after lease ownership changes", function()
	local handle = assert(scratch.open({ key = { repo_identity = "/repo/lease-loss", ref = "refs/heads/main" } }))
	local before = handle.content
	local replacement = {
		token = vim.fn.sha256("replacement-owner"),
		pid = vim.uv.os_getpid(),
		expires_at = now + 60,
	}
	assert(vim.fn.writefile({ vim.json.encode(replacement) }, handle.lease_path) == 0)
	assert(vim.uv.fs_chmod(handle.lease_path, tonumber("600", 8)))
	local saved, save_err = scratch.save(handle, "must not commit\n")
	assert(not saved and save_err.kind == "lease-lost", "save ignored a changed lease owner")
	assert(
		(table.concat(vim.fn.readfile(handle.path), "\n") .. (#vim.fn.readfile(handle.path) > 0 and "\n" or ""))
			== before
	)
	assert(scratch.release(vim.tbl_extend("force", handle, { lease_token = replacement.token })))
	scratch.release(handle)
end)

test("lease claim and renewal CAS never overwrite a concurrent owner", function()
	local renew_handle = assert(scratch.open({
		key = { repo_identity = "/repo/lease-renew-race", ref = "refs/heads/main" },
	}))
	local replacement = {
		token = vim.fn.sha256("renewal-rival"),
		pid = vim.uv.os_getpid(),
		expires_at = now + 60,
	}
	local replacement_bytes = vim.json.encode(replacement) .. "\n"
	local renewal_injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_exchange"
			and not renewal_injected
			and not details.rollback
			and details.to == renew_handle.lease_path
		then
			renewal_injected = true
			assert(vim.fn.writefile({ vim.json.encode(replacement) }, renew_handle.lease_path) == 0)
		end
	end)
	local called, renewed, renew_err = xpcall(function()
		return scratch.renew(renew_handle)
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, renewed)
	assert(renewal_injected and renewed == nil and tostring(renew_err):find("changed during renewal", 1, true))
	assert(read_bytes(renew_handle.lease_path) == replacement_bytes, "renewal clobbered a concurrent owner")
	assert(scratch.release(vim.tbl_extend("force", renew_handle, { lease_token = replacement.token })))
	scratch.release(renew_handle)

	local released = assert(scratch.open({
		key = { repo_identity = "/repo/lease-claim-race", ref = "refs/heads/main" },
	}))
	assert(scratch.release(released))
	local claimant = {
		token = vim.fn.sha256("claim-rival"),
		pid = vim.uv.os_getpid(),
		expires_at = now + 60,
	}
	local claimant_bytes = vim.json.encode(claimant) .. "\n"
	local claim_injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and not claim_injected
			and details.to == released.lease_path
			and details.from:find(".tmp.", 1, true)
		then
			claim_injected = true
			assert(vim.fn.writefile({ vim.json.encode(claimant) }, released.lease_path) == 0)
		end
	end)
	local opened, open_err
	called, opened, open_err = xpcall(function()
		return scratch.open({ key = released.key })
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, opened)
	assert(claim_injected and opened == nil and open_err.kind == "leased")
	assert(read_bytes(released.lease_path) == claimant_bytes, "claim clobbered a concurrent owner")
	assert(scratch.release(vim.tbl_extend("force", released, { lease_token = claimant.token })))

	local release_handle = assert(scratch.open({
		key = { repo_identity = "/repo/lease-release-race", ref = "refs/heads/main" },
	}))
	local release_rival = {
		token = vim.fn.sha256("release-rival"),
		pid = vim.uv.os_getpid(),
		expires_at = now + 60,
	}
	local release_rival_bytes = vim.json.encode(release_rival) .. "\n"
	local release_injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and not release_injected
			and details.from == release_handle.lease_path
			and vim.fs.basename(details.to) == "record"
		then
			release_injected = true
			assert(vim.fn.writefile({ vim.json.encode(release_rival) }, release_handle.lease_path) == 0)
		end
	end)
	local released_ok, release_err
	called, released_ok, release_err = xpcall(function()
		return scratch.release(release_handle)
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, released_ok)
	assert(release_injected and released_ok == false and tostring(release_err):find("changed", 1, true))
	assert(read_bytes(release_handle.lease_path) == release_rival_bytes, "release removed a concurrent owner")
	assert(scratch.release(vim.tbl_extend("force", release_handle, { lease_token = release_rival.token })))
end)

test("failed metadata setup never unlinks a lease rival", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/meta-cleanup-race", ref = "refs/heads/main" },
	}))
	assert(scratch.release(handle))
	local meta_alias = fixture .. "/metadata-hardlink"
	assert(vim.uv.fs_link(handle.meta_path, meta_alias))
	local rival = {
		token = vim.fn.sha256("metadata-cleanup-rival"),
		pid = vim.uv.os_getpid(),
		expires_at = now + 60,
	}
	local rival_bytes = vim.json.encode(rival) .. "\n"
	local injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and not injected
			and details.from == handle.lease_path
			and vim.fs.basename(details.to) == "record"
		then
			injected = true
			assert(vim.fn.writefile({ vim.json.encode(rival) }, handle.lease_path) == 0)
		end
	end)
	local called, opened, open_err = xpcall(function()
		return scratch.open({ key = handle.key })
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, opened)
	assert(injected and opened == nil and tostring(open_err):find("hard%-linked"))
	assert(read_bytes(handle.lease_path) == rival_bytes, "metadata cleanup removed a concurrent lease")
	assert(vim.uv.fs_unlink(meta_alias))
	assert(scratch.release(vim.tbl_extend("force", handle, { lease_token = rival.token })))
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
	local stale = now - 31 * 24 * 60 * 60
	assert(vim.uv.fs_utime(handle.path, stale, stale))
	local removed = assert(scratch.prune())
	assert(
		vim.tbl_contains(removed, handle.path),
		"adopted metadata was incorrectly bound to its canonical id filename"
	)
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

test("prune reports a committed removal when arbiter release cleanup races", function()
	local managed = assert(scratch.open({
		key = { repo_identity = "/repo/prune-release-rival", ref = "refs/heads/old" },
	}))
	assert(scratch.release(managed))
	local stale = now - 31 * 24 * 60 * 60
	assert(vim.uv.fs_utime(managed.path, stale, stale))
	local record
	local original
	local claim_bytes
	scratch._set_test_hook(function(event, details)
		if
			event == "before_unlink_reserve"
			and not record
			and details.from:find(".lock.ticket.", 1, true)
			and vim.fs.basename(details.from) == "record"
		then
			record = details.from
			original = record .. ".original"
			claim_bytes = read_bytes(record)
			assert(vim.uv.fs_rename(record, original))
			write_bytes(record, claim_bytes)
		end
	end)
	local removed, warning = scratch.prune()
	scratch._set_test_hook(nil)
	assert(removed and vim.tbl_contains(removed, managed.path), "committed prune was reported as failed")
	assert(tostring(warning):find("retained recovery state", 1, true), "prune arbiter warning was lost")
	assert(vim.uv.fs_lstat(managed.path) == nil and vim.uv.fs_lstat(managed.meta_path) == nil)
	assert(read_bytes(record) == claim_bytes and read_bytes(original) == claim_bytes, "claim rival was deleted")
	assert(vim.uv.fs_unlink(record))
	assert(vim.uv.fs_unlink(original))
	assert(vim.uv.fs_rmdir(vim.fs.dirname(record)))
end)

test("prune preserves content metadata and an active lease replacing the expired snapshot", function()
	local managed = assert(scratch.open({
		key = { repo_identity = "/repo/prune-lease-race", ref = "refs/heads/old" },
	}))
	assert(scratch.release(managed))
	local expired = {
		token = vim.fn.sha256("prune-expired"),
		pid = vim.uv.os_getpid(),
		expires_at = now - 1,
	}
	assert(vim.fn.writefile({ vim.json.encode(expired) }, managed.lease_path) == 0)
	assert(vim.uv.fs_chmod(managed.lease_path, tonumber("600", 8)))
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(managed.path, stale, stale)
	local rival = {
		token = vim.fn.sha256("prune-active-rival"),
		pid = vim.uv.os_getpid(),
		expires_at = now + 60,
	}
	local rival_bytes = vim.json.encode(rival) .. "\n"
	local injected = false
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and not injected
			and details.from == managed.lease_path
			and vim.fs.basename(details.to) == "record"
		then
			injected = true
			assert(vim.fn.writefile({ vim.json.encode(rival) }, managed.lease_path) == 0)
		end
	end)
	local called, removed, prune_err = xpcall(function()
		return scratch.prune()
	end, debug.traceback)
	scratch._set_test_hook(nil)
	assert(called, removed)
	assert(injected and removed == nil and tostring(prune_err):find("changed", 1, true))
	assert(vim.uv.fs_lstat(managed.path), "prune removed content after losing the lease CAS")
	assert(vim.uv.fs_lstat(managed.meta_path), "prune removed metadata after losing the lease CAS")
	assert(read_bytes(managed.lease_path) == rival_bytes, "prune removed the active lease rival")
	assert(scratch.release(vim.tbl_extend("force", managed, { lease_token = rival.token })))
	removed = assert(scratch.prune())
	assert(vim.tbl_contains(removed, managed.path), "scratch was not pruned after releasing the rival")
end)

test("prune derives its target from metadata filename and never follows metadata.path", function()
	local managed = assert(scratch.open({ key = { repo_identity = "/repo/hostile-meta", ref = "refs/heads/old" } }))
	assert(scratch.release(managed))
	local victim = fixture .. "/outside-victim.md"
	assert(vim.fn.writefile({ "outside" }, victim) == 0)
	local metadata = assert(vim.json.decode(table.concat(vim.fn.readfile(managed.meta_path), "\n")))
	metadata.path = victim
	assert(vim.fn.writefile({ vim.json.encode(metadata) }, managed.meta_path) == 0)
	assert(vim.uv.fs_chmod(managed.meta_path, tonumber("600", 8)))
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(managed.path, stale, stale)
	local removed = assert(scratch.prune())
	assert(#removed == 0, "mismatched metadata was treated as managed")
	assert(vim.uv.fs_lstat(victim), "metadata.path deleted a file outside the state root")
	assert(vim.uv.fs_lstat(managed.path), "mismatched metadata deleted the derived scratch")
end)

test("non-adopted metadata id is bound to its scratch filename", function()
	local left = assert(scratch.open({
		key = { repo_identity = "/repo/metadata-left", ref = "refs/heads/old" },
	}))
	local right = assert(scratch.open({
		key = { repo_identity = "/repo/metadata-right", ref = "refs/heads/old" },
	}))
	assert(scratch.release(left))
	assert(scratch.release(right))
	local foreign = assert(vim.json.decode(read_bytes(right.meta_path)))
	foreign.path = left.path
	foreign.adopted = false
	write_bytes(left.meta_path, vim.json.encode(foreign) .. "\n")
	local stale = now - 31 * 24 * 60 * 60
	assert(vim.uv.fs_utime(left.path, stale, stale))
	local removed = assert(scratch.prune())
	assert(not vim.tbl_contains(removed, left.path), "foreign metadata id authorized pruning")
	assert(vim.uv.fs_lstat(left.path), "foreign metadata id deleted scratch content")
	assert(vim.uv.fs_lstat(left.meta_path), "foreign metadata id deleted metadata")
end)

test("prune skips a scratch while its live arbiter is held", function()
	local managed = assert(scratch.open({ key = { repo_identity = "/repo/arbitrated", ref = "refs/heads/old" } }))
	assert(scratch.release(managed))
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(managed.path, stale, stale)
	local token = vim.fn.sha256("live-arbiter")
	local lock = arbiter_claim(managed.path, "ticket", vim.uv.os_getpid(), token, 1)
	local removed = assert(scratch.prune())
	assert(#removed == 0 and vim.uv.fs_lstat(managed.path), "prune raced a live scratch operation")
	assert(vim.uv.fs_unlink(lock))
	removed = assert(scratch.prune())
	assert(vim.tbl_contains(removed, managed.path), "scratch was not pruned after arbiter release")
end)

test("a process crash before claim publication leaves no blocking claim", function()
	local crash_key = { repo_identity = "/claim-crash", ref = "refs/heads/main" }
	local managed = assert(scratch.open({ key = crash_key }))
	assert(scratch.release(managed))
	local ready = fixture .. "/scratch-claim-crash.ready"
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			REPO_SCRATCH_CLAIM_CRASH_CHILD = "1",
			REPO_SCRATCH_CLAIM_CRASH_ROOT = state,
			REPO_SCRATCH_CLAIM_CRASH_READY = ready,
		},
		text = true,
	})
	local ready_ok = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not ready_ok then
		child:kill(9)
		local failed = child:wait(5000)
		error("scratch claim crash child did not reach publication barrier: " .. tostring(failed.stderr))
	end
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "scratch claim crash child was not killed")

	local staged = {}
	local prefix = vim.fs.basename(managed.path) .. ".lock."
	for name in vim.fs.dir(state) do
		if name:find(prefix, 1, true) == 1 and name:sub(-8) == ".publish" then
			staged[#staged + 1] = vim.fs.joinpath(state, name)
		end
	end
	assert(#staged == 1, "crashed scratch publisher did not leave exactly one staging file")
	assert(vim.uv.fs_lstat(staged[1]:sub(1, -9)) == nil, "incomplete scratch claim became visible")

	local dead_claim = arbiter_claim(managed.path, "ticket", child.pid, vim.fn.sha256("post-crash-final"), 1)
	local opened, open_err = scratch.open({ key = crash_key })
	assert(opened, "orphan staging file blocked scratch open: " .. vim.inspect(open_err))
	assert(vim.uv.fs_lstat(dead_claim) == nil, "valid final dead scratch claim was not reclaimed")
	assert(vim.uv.fs_lstat(staged[1]), "unrecognized scratch staging orphan was treated as a claim")
	assert(scratch.release(opened))
	assert(vim.uv.fs_unlink(staged[1]))
end)

test("a process crash after exchange never leaves the scratch target missing", function()
	local crash_key = { repo_identity = "/exchange-crash", ref = "refs/heads/main" }
	local managed = assert(scratch.open({ key = crash_key }))
	managed = assert(scratch.save(managed, "incumbent before crash\n"))
	assert(scratch.release(managed))
	local ready = fixture .. "/scratch-exchange-crash.ready"
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			REPO_SCRATCH_EXCHANGE_CRASH_CHILD = "1",
			REPO_SCRATCH_EXCHANGE_CRASH_ROOT = state,
			REPO_SCRATCH_EXCHANGE_CRASH_READY = ready,
		},
		text = true,
	})
	local ready_ok = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not ready_ok then
		child:kill(9)
		local failed = child:wait(5000)
		error("scratch exchange crash child did not complete exchange: " .. tostring(failed.stderr))
	end
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "scratch exchange crash child was not killed")
	assert(read_bytes(managed.path) == "published before crash\n", "crashed exchange left a missing or partial target")

	local recovery
	local prefix = vim.fs.basename(managed.path) .. ".tmp."
	for _, name in ipairs(vim.fn.readdir(state)) do
		if name:find(prefix, 1, true) == 1 then
			assert(not recovery, "crashed exchange retained multiple incumbent copies")
			recovery = vim.fs.joinpath(state, name)
		end
	end
	assert(recovery and read_bytes(recovery) == "incumbent before crash\n", "crashed exchange lost the incumbent")

	now = now + 61
	local reopened, reopen_err = scratch.open({ key = crash_key })
	assert(reopened, "crash recovery open failed: " .. vim.inspect(reopen_err))
	assert(reopened.content == "published before crash\n", "restart observed empty scratch content")
	assert(scratch.release(reopened))
	now = now - 61
	assert(vim.uv.fs_unlink(recovery))
end)

test("two processes serialize simultaneous dead-claim reclamation", function()
	local managed = assert(scratch.open({ key = { repo_identity = "/race", ref = "refs/heads/main" } }))
	assert(scratch.release(managed))
	local child = vim.system({ "sh", "-c", "exit 0" })
	local dead_pid = child.pid
	assert(child:wait().code == 0 and type(dead_pid) == "number")
	assert(
		vim.wait(1000, function()
			local called, result, _, code = pcall(vim.uv.kill, dead_pid, 0)
			return called and result == nil and code == "ESRCH"
		end, 10),
		"child process did not become observably dead"
	)
	local stale_claim = arbiter_claim(managed.path, "ticket", dead_pid, vim.fn.sha256("dead-race"), 1)
	local left_ready = fixture .. "/scratch-left.ready"
	local right_ready = fixture .. "/scratch-right.ready"
	local left_result = fixture .. "/scratch-left.result"
	local right_result = fixture .. "/scratch-right.result"
	local function spawn(ready, peer_ready, result)
		return vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
			env = {
				REPO_SCRATCH_LOCK_CHILD = "1",
				REPO_SCRATCH_LOCK_ROOT = state,
				REPO_SCRATCH_LOCK_READY = ready,
				REPO_SCRATCH_LOCK_PEER_READY = peer_ready,
				REPO_SCRATCH_LOCK_RESULT = result,
			},
			text = true,
		})
	end
	local left = spawn(left_ready, right_ready, left_result)
	local right = spawn(right_ready, left_ready, right_result)
	local left_done = left:wait(10000)
	local right_done = right:wait(10000)
	assert(left_done.code == 0, left_done.stderr)
	assert(right_done.code == 0, right_done.stderr)
	local results = { vim.fn.readfile(left_result)[1], vim.fn.readfile(right_result)[1] }
	table.sort(results)
	assert(vim.deep_equal({ "leased", "opened" }, results), "unexpected child results: " .. vim.inspect(results))
	assert(vim.uv.fs_lstat(stale_claim) == nil, "simultaneously reclaimed dead claim survived")
	assert(vim.uv.fs_unlink(managed.lease_path), "child lease cleanup failed")
end)

test("arbiter release and dead-claim reclamation preserve replacement claims", function()
	local function replace_ticket(path)
		local encoded, token = vim.fs.basename(path):match("%.ticket%.(%d+)%.([0-9a-f]+)$")
		assert(encoded and token, "test did not intercept a ticket claim")
		local replacement = read_bytes(path)
		assert(vim.uv.fs_unlink(path))
		write_bytes(path, replacement)
		return replacement
	end

	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/arbiter-release-rival", ref = "refs/heads/main" },
	}))
	local release_rival_path
	local release_rival_bytes
	scratch._set_test_hook(function(event, details)
		if
			event == "before_rename"
			and not release_rival_path
			and details.from:find(".lock.ticket.", 1, true)
			and vim.fs.basename(details.to) == "record"
		then
			release_rival_path = details.from
			release_rival_bytes = replace_ticket(details.from)
		end
	end)
	local renewed, renew_err = scratch.renew(handle)
	scratch._set_test_hook(nil)
	assert(renewed == true and tostring(renew_err):find("release", 1, true), "persisted renewal was hidden")
	assert(read_bytes(release_rival_path) == release_rival_bytes, "arbiter release deleted its replacement")
	assert(vim.uv.fs_unlink(release_rival_path))
	assert(scratch.release(handle))

	local managed = assert(scratch.open({
		key = { repo_identity = "/repo/dead-claim-rival", ref = "refs/heads/main" },
	}))
	assert(scratch.release(managed))
	local child = vim.system({ "sh", "-c", "exit 0" })
	local dead_pid = child.pid
	assert(child:wait().code == 0 and type(dead_pid) == "number")
	assert(vim.wait(1000, function()
		local called, result, _, code = pcall(vim.uv.kill, dead_pid, 0)
		return called and result == nil and code == "ESRCH"
	end, 10))
	local token = vim.fn.sha256("dead-claim-replacement")
	local dead_claim = arbiter_claim(managed.path, "ticket", dead_pid, token, 1)
	local reclaim_rival_bytes
	scratch._set_test_hook(function(event, details)
		if event == "before_rename" and details.from == dead_claim and vim.fs.basename(details.to) == "record" then
			reclaim_rival_bytes = replace_ticket(details.from)
		end
	end)
	local opened, open_err = scratch.open({ key = managed.key })
	scratch._set_test_hook(nil)
	assert(opened == nil and open_err ~= nil, "dead-claim replacement was treated as the stale inode")
	assert(read_bytes(dead_claim) == reclaim_rival_bytes, "dead-claim reclaimer deleted its replacement")
	assert(vim.uv.fs_unlink(dead_claim))
	opened = assert(scratch.open({ key = managed.key }))
	assert(scratch.release(opened))
end)

test("a persisted save survives arbiter release replacement without deleting either claim", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/save-release-rival", ref = "refs/heads/main" },
	}))
	handle = assert(scratch.save(handle, "incumbent\n"))
	local record
	local original
	local rival_bytes
	scratch._set_test_hook(function(event, details)
		if
			event == "before_unlink_reserve"
			and not record
			and details.from:find(".lock.ticket.", 1, true)
			and vim.fs.basename(details.from) == "record"
		then
			record = details.from
			original = record .. ".original"
			rival_bytes = read_bytes(record)
			assert(vim.uv.fs_rename(record, original))
			write_bytes(record, rival_bytes)
		end
	end)
	local saved, warning = scratch.save(handle, "persisted despite release race\n")
	scratch._set_test_hook(nil)
	assert(saved and record, "persisted save was hidden by arbiter release cleanup")
	assert(tostring(warning):find("retained recovery state", 1, true), "arbiter release warning was lost")
	assert(saved.revision == vim.fn.sha256("persisted despite release race\n"))
	assert(read_bytes(saved.path) == "persisted despite release race\n", "save did not persist before release failure")
	assert(read_bytes(record) == rival_bytes, "arbiter cleanup deleted the replacement claim")
	assert(read_bytes(original) == rival_bytes, "arbiter cleanup deleted the displaced owned claim")
	assert(vim.uv.fs_unlink(record))
	assert(vim.uv.fs_unlink(original))
	assert(vim.uv.fs_rmdir(vim.fs.dirname(record)))
	assert(scratch.release(saved))
end)

test("unsafe leases fail closed in open, save, and prune", function()
	for _, kind in ipairs(unsafe_lease_kinds) do
		local open_key = { repo_identity = "/repo/unsafe-open-" .. kind, ref = "refs/heads/main" }
		local released = assert(scratch.open({ key = open_key }))
		assert(scratch.release(released))
		local open_fixture = unsafe_lease(released.lease_path, kind)
		local opened, open_err = scratch.open({ key = open_key })
		assert(opened == nil and open_err ~= nil, kind .. " lease was reclaimed by open")
		open_fixture.assert_unchanged()
		open_fixture.cleanup()

		local save_handle = assert(scratch.open({
			key = { repo_identity = "/repo/unsafe-save-" .. kind, ref = "refs/heads/main" },
		}))
		local content_before = read_bytes(save_handle.path)
		local save_fixture = unsafe_lease(save_handle.lease_path, kind)
		local saved, save_err = scratch.save(save_handle, "must not be written\n")
		assert(
			saved == nil and type(save_err) == "table" and save_err.kind == "lease-unsafe",
			kind .. " save did not fail closed"
		)
		assert(read_bytes(save_handle.path) == content_before, kind .. " lease allowed a content write")
		save_fixture.assert_unchanged()
		save_fixture.cleanup()
		-- The hostile fixture intentionally removed the owned lease. release()
		-- still unregisters the process-local handle while correctly returning
		-- false because ownership can no longer be proven.
		scratch.release(save_handle)

		local prune_handle = assert(scratch.open({
			key = { repo_identity = "/repo/unsafe-prune-" .. kind, ref = "refs/heads/main" },
		}))
		assert(scratch.release(prune_handle))
		local stale = now - 31 * 24 * 60 * 60
		vim.uv.fs_utime(prune_handle.path, stale, stale)
		local prune_fixture = unsafe_lease(prune_handle.lease_path, kind)
		local removed, prune_err = scratch.prune()
		assert(removed == nil and tostring(prune_err):find("lease", 1, true), kind .. " lease did not block prune")
		assert(vim.uv.fs_lstat(prune_handle.path) and vim.uv.fs_lstat(prune_handle.meta_path))
		prune_fixture.assert_unchanged()
		prune_fixture.cleanup()
		assert(vim.uv.fs_unlink(prune_handle.path))
		assert(vim.uv.fs_unlink(prune_handle.meta_path))
	end
end)

test("missing and well-formed expired leases are reclaimable", function()
	local open_key = { repo_identity = "/repo/expired-open", ref = "refs/heads/main" }
	local handle = assert(scratch.open({ key = open_key }))
	assert(scratch.release(handle))
	assert(vim.fn.writefile({
		vim.json.encode({
			token = vim.fn.sha256("expired-open"),
			pid = vim.uv.os_getpid(),
			expires_at = now - 1,
		}),
	}, handle.lease_path) == 0)
	local reclaimed = assert(scratch.open({ key = open_key }))
	assert(reclaimed.lease_token ~= vim.fn.sha256("expired-open"))
	assert(scratch.release(reclaimed))

	local prune_handle = assert(scratch.open({
		key = { repo_identity = "/repo/expired-prune", ref = "refs/heads/main" },
	}))
	assert(scratch.release(prune_handle))
	assert(vim.fn.writefile({
		vim.json.encode({
			token = vim.fn.sha256("expired-prune"),
			pid = vim.uv.os_getpid(),
			expires_at = now - 1,
		}),
	}, prune_handle.lease_path) == 0)
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(prune_handle.path, stale, stale)
	local removed = assert(scratch.prune())
	assert(vim.tbl_contains(removed, prune_handle.path))
	assert(vim.uv.fs_lstat(prune_handle.lease_path) == nil)
end)

test("save accepts exactly 1 MiB and rejects one extra byte before renewal", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/size-limit", ref = "refs/heads/main" },
	}))
	local exact = string.rep("x", 1024 * 1024)
	local saved = assert(scratch.save(handle, exact))
	assert(#read_bytes(saved.path) == 1024 * 1024)
	local content_before = assert(vim.uv.fs_lstat(saved.path))
	local lease_before = assert(vim.uv.fs_lstat(saved.lease_path))
	local rejected, reject_err = scratch.save(saved, exact .. "x")
	assert(rejected == nil and tostring(reject_err):find("1 MiB", 1, true), "oversize save was accepted")
	local content_after = assert(vim.uv.fs_lstat(saved.path))
	local lease_after = assert(vim.uv.fs_lstat(saved.lease_path))
	assert(
		content_after.dev == content_before.dev and content_after.ino == content_before.ino,
		"oversize save rewrote content"
	)
	assert(
		lease_after.dev == lease_before.dev and lease_after.ino == lease_before.ino,
		"oversize save renewed its lease"
	)
	assert(scratch.release(saved))
end)

test("hard-linked scratch content is rejected", function()
	local handle = assert(scratch.open({
		key = { repo_identity = "/repo/hardlinked-content", ref = "refs/heads/main" },
	}))
	local alias = fixture .. "/scratch-hardlink-alias"
	assert(vim.uv.fs_link(handle.path, alias))
	local saved, save_err = scratch.save(handle, "must not be written\n")
	assert(saved == nil and tostring(save_err):find("hard%-linked"), "hard-linked scratch was writable")
	assert(vim.uv.fs_unlink(alias))
	assert(scratch.release(handle))
end)

test("active and preserved managed files survive pruning", function()
	local active = assert(scratch.open({ key = { repo_identity = "/repo/active", ref = "refs/heads/a" } }))
	local preserved = assert(scratch.open({ key = { repo_identity = "/repo/preserved", ref = "refs/heads/p" } }))
	assert(scratch.release(preserved))
	local stale = now - 31 * 24 * 60 * 60
	vim.uv.fs_utime(active.path, stale, stale)
	vim.uv.fs_utime(preserved.path, stale, stale)
	local removed = assert(scratch.prune({ preserved.path }))
	assert(not vim.tbl_contains(removed, active.path) and not vim.tbl_contains(removed, preserved.path))
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

test("root and ancestor swaps after validation cannot redirect publication", function()
	for _, mode in ipairs({ "root", "ancestor" }) do
		local base = fixture .. "/publication-swap-" .. mode
		local ancestor = base .. "/anchor"
		local configured = ancestor .. "/state"
		local outside = base .. "/outside"
		local outside_state = outside .. "/state"
		assert(vim.fn.mkdir(outside_state, "p", tonumber("700", 8)) == 1)
		assert(scratch.setup({
			state_root = configured,
			now = function()
				return now
			end,
			lease_seconds = 60,
			max_age_seconds = 30 * 24 * 60 * 60,
		}))
		local handle = assert(scratch.open({
			key = { repo_identity = "/repo/publication-swap-" .. mode, ref = "refs/heads/main" },
		}))
		handle = assert(scratch.save(handle, "incumbent\n"))

		outside_state = assert(vim.uv.fs_realpath(outside_state))
		local rival_path = vim.fs.joinpath(outside_state, vim.fs.basename(handle.path))
		assert(vim.fn.writefile({ "rival" }, rival_path) == 0)
		local swap_path = mode == "root" and configured or ancestor
		local displaced = base .. "/displaced-" .. mode
		local symlink_target = mode == "root" and outside_state or outside
		local swapped = false
		scratch._set_test_hook(function(event, details)
			if
				event == "after_root_validation"
				and not swapped
				and details.kind == "cas"
				and details.path == handle.path
			then
				swapped = true
				assert(vim.uv.fs_rename(swap_path, displaced))
				assert(vim.uv.fs_symlink(symlink_target, swap_path))
			end
		end)
		local called, saved, save_err = xpcall(function()
			return scratch.save(handle, "must not publish\n")
		end, debug.traceback)
		scratch._set_test_hook(nil)
		assert(called, saved)
		assert(
			swapped and saved == nil and tostring(save_err):find("state root", 1, true),
			mode .. " swap was accepted"
		)
		assert(read_bytes(rival_path) == "rival\n", mode .. " swap overwrote the outside rival")
		local outside_entries = vim.fn.readdir(outside_state)
		assert(
			vim.deep_equal(outside_entries, { vim.fs.basename(handle.path) }),
			mode .. " swap created state outside the validated root: " .. vim.inspect(outside_entries)
		)
		local displaced_root = mode == "root" and displaced or vim.fs.joinpath(displaced, "state")
		assert(
			read_bytes(vim.fs.joinpath(displaced_root, vim.fs.basename(handle.path))) == "incumbent\n",
			mode .. " swap changed the pinned incumbent"
		)

		assert(vim.uv.fs_unlink(swap_path))
		assert(vim.uv.fs_rename(displaced, swap_path))
		assert(scratch.setup({
			state_root = configured,
			now = function()
				return now
			end,
			lease_seconds = 60,
			max_age_seconds = 30 * 24 * 60 * 60,
		}))
		assert(scratch.release(handle))
	end
	assert(scratch.setup({
		state_root = state,
		now = function()
			return now
		end,
		lease_seconds = 60,
		max_age_seconds = 30 * 24 * 60 * 60,
	}))
end)

test("state root substitution is rejected after setup", function()
	local parent = fixture .. "/root-substitution"
	local configured = parent .. "/state"
	local displaced = parent .. "/state-original"
	local outside = parent .. "/outside"
	assert(vim.fn.mkdir(parent, "p", tonumber("700", 8)) == 1)
	assert(scratch.setup({
		state_root = configured,
		now = function()
			return now
		end,
		lease_seconds = 60,
		max_age_seconds = 30 * 24 * 60 * 60,
	}))
	assert(vim.uv.fs_rename(configured, displaced))
	assert(vim.fn.mkdir(outside, "p", tonumber("700", 8)) == 1)
	assert(vim.uv.fs_symlink(outside, configured))
	local opened, err = scratch.open({ key = { repo_identity = "/repo/root-swap", ref = "refs/heads/main" } })
	assert(opened == nil and tostring(err):find("symlink", 1, true), "substituted state root was accepted")
	assert(vim.fn.isdirectory(outside) == 1 and #vim.fn.readdir(outside) == 0, "substituted root was modified")
	assert(scratch.setup({
		state_root = state,
		now = function()
			return now
		end,
		lease_seconds = 60,
		max_age_seconds = 30 * 24 * 60 * 60,
	}))
end)

test("repeated setup replaces callbacks and teardown is deterministic", function()
	local events = {}
	assert(scratch.setup({
		state_root = state,
		now = function()
			return now
		end,
		lease_seconds = 60,
		event = function(event)
			events[#events + 1] = vim.deepcopy(event)
			event.kind = "mutated"
		end,
	}))
	local handle = assert(scratch.open({ key = { repo_identity = "/repo/events", ref = "refs/heads/main" } }))
	assert(events[1].kind == "opened", "event callback did not receive an isolated copy")
	assert(scratch.status(handle).owned, "event callback mutated the active handle")
	assert(scratch.release(handle))
	local before = scratch.status()
	local ok = scratch.setup({ state_root = state, unknown = true })
	assert(not ok)
	assert(vim.deep_equal(before, scratch.status()), "invalid repeated setup mutated state")
	assert(scratch.teardown())
	assert(scratch.teardown())
	assert(not scratch.status().configured)
	assert(scratch.effective_config().lease_seconds == 300)
	assert(scratch.setup({ state_root = state, lease_seconds = 60 }))
end)

test("failed state-root reconfiguration preserves the prior anchor and policy", function()
	local prior = scratch.effective_config()
	local target = fixture .. "/reconfigure-target"
	local candidate = fixture .. "/reconfigure-link"
	assert(vim.fn.mkdir(target, "p", tonumber("700", 8)) == 1)
	assert(vim.uv.fs_symlink(target, candidate))
	local configured, err = scratch.setup({ state_root = candidate, lease_seconds = 120 })
	assert(not configured and tostring(err):find("symlink", 1, true), "unsafe candidate root was accepted")
	assert(vim.deep_equal(scratch.effective_config(), prior), "failed setup replaced the effective policy")
	assert(scratch.status().configured, "failed setup closed the prior root")
	local handle = assert(scratch.open({ key = { repo_identity = "/repo/reconfigure", ref = "refs/heads/main" } }))
	assert(handle.path:sub(1, #state + 1) == state .. "/", "failed setup redirected scratch state")
	assert(scratch.release(handle))
	vim.fn.delete(candidate)
end)

test("NUL state roots fail before normalization or filesystem mutation", function()
	local prefix = fixture .. "/nul-root"
	assert(vim.uv.fs_lstat(prefix) == nil)
	local before = scratch.status()
	local configured, err = scratch.setup({ state_root = prefix .. "\0suffix" })
	assert(not configured and tostring(err):find("NUL", 1, true), tostring(err))
	assert(vim.uv.fs_lstat(prefix) == nil, "NUL state root was truncated into a filesystem mutation")
	assert(vim.deep_equal(before, scratch.status()), "NUL state root mutated plugin state")
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("repo_scratch_spec: %d tests passed"):format(count))
