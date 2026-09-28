vim.o.shadafile = "NONE"
vim.o.swapfile = false

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
local repo_root = vim.fs.dirname(vim.fs.dirname(plugin_root))
vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({ repo_root .. "/local-plugins/_shared/lua/?.lua", package.path }, ";")

local trusted_workspace = require("trusted_workspace")

if vim.env.TRUSTED_WORKSPACE_STATE_CRASH_CHILD == "1" then
	local root = assert(vim.env.TRUSTED_WORKSPACE_STATE_CRASH_ROOT)
	local ready = assert(vim.env.TRUSTED_WORKSPACE_STATE_CRASH_READY)
	assert(trusted_workspace.setup({ state_root = root }))
	trusted_workspace._set_test_hook(function(phase, details)
		if phase == "state_exchanged" then
			assert(vim.uv.fs_lstat(details.path), "atomic exchange exposed a missing state path")
			assert(vim.fn.writefile({ "ready" }, ready) == 0)
			vim.wait(60_000, function()
				return false
			end, 100)
			error("state exchange crash child was not killed")
		end
	end)
	trusted_workspace.authorize("/crash-exchange", "test")
	error("state exchange crash child unexpectedly completed")
end

if vim.env.TRUSTED_WORKSPACE_CLAIM_CRASH_CHILD == "1" then
	local root = assert(vim.env.TRUSTED_WORKSPACE_CLAIM_CRASH_ROOT)
	local ready = assert(vim.env.TRUSTED_WORKSPACE_CLAIM_CRASH_READY)
	assert(trusted_workspace.setup({ state_root = root }))
	trusted_workspace._set_test_hook(function(phase)
		if phase == "lock_claim_staged" then
			assert(vim.fn.writefile({ "ready" }, ready) == 0)
			vim.wait(60_000, function()
				return false
			end, 100)
			error("claim crash child was not killed")
		end
	end)
	trusted_workspace.authorize("/crash", "test")
	error("claim crash child unexpectedly completed")
end

if vim.env.TRUSTED_WORKSPACE_LOCK_CHILD == "1" then
	local root = assert(vim.env.TRUSTED_WORKSPACE_LOCK_ROOT)
	local ready = assert(vim.env.TRUSTED_WORKSPACE_LOCK_READY)
	local peer_ready = assert(vim.env.TRUSTED_WORKSPACE_LOCK_PEER_READY)
	local result_path = assert(vim.env.TRUSTED_WORKSPACE_LOCK_RESULT)
	local capability = assert(vim.env.TRUSTED_WORKSPACE_LOCK_CAPABILITY)
	assert(trusted_workspace.setup({ state_root = root }))
	assert(vim.fn.writefile({ "ready" }, ready) == 0)
	assert(
		vim.wait(5000, function()
			return vim.uv.fs_lstat(peer_ready) ~= nil
		end, 5),
		"lock child barrier timed out"
	)
	local ok, err = trusted_workspace.authorize("/race", capability)
	assert(vim.fn.writefile({ ok and "ok" or ("error:" .. tostring(err)) }, result_path) == 0)
	vim.cmd("quitall!")
	return
end

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function with_uv_override(name, replacement, callback)
	local original = assert(vim.uv[name], "missing uv function " .. name)
	vim.uv[name] = function(...)
		return replacement(original, ...)
	end
	local ok, first, second, third = xpcall(callback, debug.traceback)
	vim.uv[name] = original
	if not ok then
		error(first)
	end
	return first, second, third
end

local function with_observational_filesystem(callback)
	local names = { "fs_chmod", "fs_fchmod", "fs_fsync", "fs_mkdir", "fs_rename", "fs_unlink", "fs_write" }
	local originals = {}
	for _, name in ipairs(names) do
		originals[name] = assert(vim.uv[name], "missing uv function " .. name)
		vim.uv[name] = function()
			error("observational read called " .. name)
		end
	end
	local ok, first, second, third = xpcall(callback, debug.traceback)
	for _, name in ipairs(names) do
		vim.uv[name] = originals[name]
	end
	if not ok then
		error(first)
	end
	return first, second, third
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p", 448) == 1, "could not create temporary directory")
	return path
end

local function state_root(parent)
	return vim.fs.joinpath(parent, "state")
end

local function setup(root, mode)
	local ok, err = trusted_workspace.setup({ state_root = root, mode = mode or "full", reset = true })
	assert(ok, err)
end

local function find_error(errors, needle)
	for _, message in ipairs(errors) do
		if message:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function lock_claim(root, kind, pid, token, number)
	local base = vim.fs.joinpath(root, "trusted-workspace.lock")
	local path
	local value = { version = 1, kind = kind, pid = pid, token = token }
	if kind == "choosing" then
		path = base .. ".choosing." .. token
	else
		value.number = assert(number)
		path = ("%s.ticket.%020d.%s"):format(base, number, token)
	end
	assert(vim.fn.writefile({ vim.json.encode(value) }, path) == 0)
	assert(vim.uv.fs_chmod(path, 384))
	return path
end

test("sources are deterministic, restricted, provenance-aware, and copy-safe", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.register_source({
		id = "host-z",
		layer = "host",
		priority = 10,
		value = { plugins = { clangd_compile_db = { path = "host-z" } }, theme = { background = "dark" } },
	}))
	assert(trusted_workspace.register_source({
		id = "host-a",
		layer = "host",
		priority = 20,
		value = { plugins = { clangd_compile_db = { path = "host-a", profile = "full" } } },
	}))
	local rejected, rejected_err = trusted_workspace.register_source({
		id = "old-project",
		layer = "project",
		repo = "/repo",
		fingerprint = "old-schema",
		value = { review = { hunk_context = 7 } },
	})
	assert(not rejected and rejected_err:find("unknown option: review", 1, true), "old project schema was not rejected")
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "fingerprint-1",
		value = {
			plugins = {
				clangd_compile_db = { path = "project-clangd", profile = "light" },
				native_review = { hunk_context = 7 },
				log_workbench = { max_lines = 42 },
			},
		},
	}))

	local pending = assert(trusted_workspace.status())
	equal("pending", pending.mode, "unapproved project source was not pending")
	equal(
		"host-a",
		trusted_workspace.snapshot().value.plugins.clangd_compile_db.path,
		"pending project value became effective"
	)
	equal(
		"project-clangd",
		pending.candidate.value.plugins.clangd_compile_db.path,
		"candidate omitted an allowed project field"
	)
	equal(42, pending.candidate.value.plugins.log_workbench.max_lines, "bounded log setting was omitted")
	equal(
		{ id = "project", layer = "project" },
		pending.candidate.validity.provenance["plugins.clangd_compile_db.path"],
		"candidate provenance is incorrect"
	)
	assert(#trusted_workspace.diff() > 0, "pending candidate has no diff")

	assert(trusted_workspace.approve("/repo", "project", "fingerprint-1"))
	local snapshot = trusted_workspace.snapshot()
	equal(
		"project-clangd",
		snapshot.value.plugins.clangd_compile_db.path,
		"approved project path did not override the host"
	)
	equal("dark", snapshot.value.theme.background, "forbidden project theme overrode the host")
	assert(snapshot.value.dap == nil, "forbidden project DAP field became effective")
	assert(snapshot.value.env == nil, "forbidden project environment became effective")

	snapshot.value.plugins.clangd_compile_db.path = "mutated"
	snapshot.validity.provenance["plugins.clangd_compile_db.path"].id = "mutated"
	local independent = trusted_workspace.snapshot()
	equal("project-clangd", independent.value.plugins.clangd_compile_db.path, "snapshot value shares nested state")
	equal(
		"project",
		independent.validity.provenance["plugins.clangd_compile_db.path"].id,
		"snapshot validity shares nested state"
	)

	equal("rwx------", vim.fn.getfperm(root), "state root is not owner-only")
	equal("rw-------", vim.fn.getfperm(vim.fs.joinpath(root, "trusted-workspace.json")), "state file is not owner-only")
	vim.fn.delete(parent, "rf")
end)

test("changed fingerprints retain the last-known-good snapshot until approval", function()
	local parent = temp_dir()
	setup(state_root(parent))
	assert(trusted_workspace.register_source({
		id = "host",
		layer = "host",
		value = { plugins = { clangd_compile_db = { path = "host" } } },
	}))
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "one",
		value = { plugins = { clangd_compile_db = { path = "one" } } },
	}))
	assert(trusted_workspace.approve("/repo", "project", "one"))
	equal("one", trusted_workspace.snapshot().value.plugins.clangd_compile_db.path, "initial approval did not apply")

	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "two",
		value = { plugins = { clangd_compile_db = { path = "two" } } },
	}))
	local pending = trusted_workspace.status()
	equal("pending", pending.mode, "changed fingerprint was not pending")
	equal("two", pending.candidate.value.plugins.clangd_compile_db.path, "changed candidate is stale")
	equal(
		"one",
		trusted_workspace.snapshot().value.plugins.clangd_compile_db.path,
		"pending source displaced last-known-good"
	)
	equal(
		"one",
		pending.last_known_good.value.plugins.clangd_compile_db.path,
		"last-known-good changed before approval"
	)
	assert(trusted_workspace.register_source({
		id = "host",
		layer = "host",
		value = { plugins = { clangd_compile_db = { path = "host-updated", profile = "full" } } },
	}))
	local mixed = trusted_workspace.snapshot()
	equal("one", mixed.value.plugins.clangd_compile_db.path, "pending source lost its previously approved value")
	equal("full", mixed.value.plugins.clangd_compile_db.profile, "approved host update was blocked by a pending source")
	assert(trusted_workspace.approve("/repo", "project", "two"))
	equal(
		"two",
		trusted_workspace.snapshot().value.plugins.clangd_compile_db.path,
		"changed fingerprint approval did not apply"
	)
	vim.fn.delete(parent, "rf")
end)

test("appliers receive effective validity while pending data stays candidate-only", function()
	local parent = temp_dir()
	setup(state_root(parent))
	local applied
	assert(trusted_workspace.register_applier({
		id = "capture",
		prepare = function(next_snapshot)
			return next_snapshot
		end,
		apply = function(token)
			applied = token
			return true
		end,
		rollback = function()
			return true
		end,
	}))
	assert(trusted_workspace.register_source({
		id = "host",
		layer = "host",
		value = { plugins = { native_review = { hunk_context = 1 } } },
	}))
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "pending",
		value = { plugins = { native_review = { hunk_context = 5 } } },
	}))
	local status = trusted_workspace.status()
	assert(not status.candidate.validity.valid, "pending candidate was reported effective")
	assert(#status.candidate.validity.pending == 1, "candidate omitted pending approval")
	equal({}, status.candidate.validity.errors, "valid pending data produced a schema error")
	local before_generation = status.generation
	local rejected, rejected_err = trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "rejected",
		value = { theme = { background = "hostile" } },
	})
	assert(not rejected and rejected_err:find("unknown option: theme", 1, true), "old project root was not rejected")
	equal(before_generation, trusted_workspace.status().generation, "rejected project source mutated its scope")

	applied = nil
	assert(trusted_workspace.register_source({
		id = "host",
		layer = "host",
		value = { plugins = { native_review = { hunk_context = 2 } } },
	}))
	assert(applied, "safe host update did not reach the applier")
	assert(applied.validity.valid, "candidate errors contaminated the effective snapshot")
	equal({}, applied.validity.errors, "effective snapshot retained candidate-only errors")
	equal({}, applied.validity.pending, "effective snapshot retained candidate-only pending state")
	equal(2, applied.value.plugins.native_review.hunk_context, "safe host update did not apply")
	local snapshot = trusted_workspace.snapshot()
	assert(snapshot.validity.valid and #snapshot.validity.errors == 0 and #snapshot.validity.pending == 0)
	vim.fn.delete(parent, "rf")
end)

test("approval is limited to the exact currently registered project candidate", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local missing, missing_err = trusted_workspace.approve("/repo", "project", "fingerprint")
	assert(not missing and missing_err:find("currently registered", 1, true), "missing source was approved")
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "fingerprint",
		value = {},
	}))
	local wrong_repo = trusted_workspace.approve("/other", "project", "fingerprint")
	local wrong_fingerprint = trusted_workspace.approve("/repo", "project", "different")
	assert(not wrong_repo and not wrong_fingerprint, "mismatched candidate was approved")
	assert(trusted_workspace.approve("/repo", "project", "fingerprint"))
	local workspace = { runtime = "host", root = "/repo", repo_identity = "/repo" }
	assert(trusted_workspace.has_approval({
		workspace = workspace,
		source = "project",
		fingerprint = "fingerprint",
	}))
	assert(trusted_workspace.has_approval("/repo", "project", "different") == false)

	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local persistent = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	persistent.approvals["/repo"].project = nil
	assert(vim.fn.writefile({ vim.json.encode(persistent) }, path) == 0)
	assert(trusted_workspace.has_approval("/repo", "project", "fingerprint") == false)
	equal("fingerprint", trusted_workspace.approvals("/repo").project, "durable approval read changed cached state")

	assert(vim.fn.writefile({ "{" }, path) == 0)
	local approved, approval_err = trusted_workspace.has_approval("/repo", "project", "fingerprint")
	assert(approved == nil and tostring(approval_err):find("corrupt", 1, true), tostring(approval_err))
	equal("{", vim.fn.readfile(path)[1], "approval observation replaced corrupt state")
	vim.fn.delete(parent, "rf")
end)

test("capability grants are exact, persistent, copied, and revocable", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	for _, capability in ipairs({ "lint-format", "test", "build", "debug" }) do
		assert(trusted_workspace.authorize("/repo", capability))
		local granted, grant_err = trusted_workspace.has_grant("/repo", capability)
		assert(granted == true, tostring(grant_err))
	end
	local invalid, invalid_err = trusted_workspace.authorize("/repo", "network")
	assert(not invalid and invalid_err:find("lint%-format"), "unknown capability was accepted")
	local invalid_read, invalid_read_err = trusted_workspace.has_grant("/repo", "network")
	assert(not invalid_read and invalid_read_err:find("lint%-format"), "unknown capability was queried")
	local status = trusted_workspace.status("/repo")
	equal(true, status.repo_grants.debug, "grant is missing")
	status.repo_grants.debug = false
	equal(true, trusted_workspace.status("/repo").repo_grants.debug, "grant status shares state")

	setup(root)
	equal(true, trusted_workspace.status("/repo").repo_grants.build, "grant did not survive reload")
	assert(trusted_workspace.revoke("/repo", "build"))
	assert(trusted_workspace.has_grant("/repo", "build") == false)
	assert(trusted_workspace.status("/repo").repo_grants.build == nil, "revoked grant remains active")
	setup(root)
	assert(trusted_workspace.status("/repo").repo_grants.build == nil, "revocation did not survive reload")
	vim.fn.delete(parent, "rf")
end)

test("has_grant rereads durable state without updating cached status", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/repo", "test"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local persistent = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	persistent.grants["/repo"].build = true
	assert(vim.fn.writefile({ vim.json.encode(persistent) }, path) == 0)
	local granted, grant_err = trusted_workspace.has_grant("/repo", "build")
	assert(granted == true, tostring(grant_err))
	assert(trusted_workspace.status("/repo").repo_grants.build == nil, "durable read changed cached status")

	persistent.grants["/repo"].test = nil
	assert(vim.fn.writefile({ vim.json.encode(persistent) }, path) == 0)
	assert(trusted_workspace.has_grant({ repo = "/repo", capability = "test" }) == false)
	equal(true, trusted_workspace.status("/repo").repo_grants.test, "durable read rewrote cached grants")
	vim.fn.delete(parent, "rf")
end)

test("has_grant keeps absent durable state observational", function()
	local parent = temp_dir()
	local root = state_root(parent)
	local events = 0
	assert(trusted_workspace.setup({
		state_root = root,
		reset = true,
		on_state_change = function()
			events = events + 1
		end,
	}))
	local granted, grant_err = with_observational_filesystem(function()
		return trusted_workspace.has_grant("/repo", "test")
	end)
	assert(granted == false and grant_err == nil)
	assert(vim.uv.fs_lstat(root) == nil, "grant observation created the state root")
	equal(0, events, "grant observation emitted an event")
	vim.fn.delete(parent, "rf")
end)

test("has_grant rejects unsafe durable state without repairing it", function()
	local function granted_fixture()
		local parent = temp_dir()
		local root = state_root(parent)
		setup(root)
		assert(trusted_workspace.authorize("/repo", "test"))
		return parent, root, vim.fs.joinpath(root, "trusted-workspace.json")
	end

	do
		local parent, root = granted_fixture()
		assert(vim.uv.fs_chmod(root, 493)) -- 0755
		local granted, err = trusted_workspace.has_grant("/repo", "test")
		assert(granted == nil and tostring(err):find("0700", 1, true), tostring(err))
		equal("rwxr-xr-x", vim.fn.getfperm(root), "grant observation repaired root permissions")
		vim.fn.delete(parent, "rf")
	end

	do
		local parent, _, path = granted_fixture()
		assert(vim.uv.fs_chmod(path, 420)) -- 0644
		local granted, err = trusted_workspace.has_grant("/repo", "test")
		assert(granted == nil and tostring(err):find("0600", 1, true))
		equal("rw-r--r--", vim.fn.getfperm(path), "grant observation repaired file permissions")
		vim.fn.delete(parent, "rf")
	end

	do
		local parent, _, path = granted_fixture()
		assert(vim.fn.writefile({ "{" }, path) == 0)
		local before = table.concat(vim.fn.readfile(path), "\n")
		local granted, err = trusted_workspace.has_grant("/repo", "test")
		assert(granted == nil and tostring(err):find("corrupt", 1, true))
		equal(before, table.concat(vim.fn.readfile(path), "\n"), "grant observation replaced corrupt state")
		vim.fn.delete(parent, "rf")
	end

	do
		local parent, _, path = granted_fixture()
		local target = vim.fs.joinpath(parent, "target.json")
		assert(vim.uv.fs_rename(path, target))
		assert(vim.uv.fs_symlink(target, path))
		local before = table.concat(vim.fn.readfile(target), "\n")
		local granted, err = trusted_workspace.has_grant("/repo", "test")
		assert(granted == nil and tostring(err):find("symlinks are rejected", 1, true))
		equal(target, vim.uv.fs_readlink(path), "grant observation replaced the state symlink")
		equal(before, table.concat(vim.fn.readfile(target), "\n"), "grant observation changed the symlink target")
		vim.fn.delete(parent, "rf")
	end

	do
		local parent, _, path = granted_fixture()
		local alias = vim.fs.joinpath(parent, "state-hardlink.json")
		assert(vim.uv.fs_link(path, alias))
		local granted, err = trusted_workspace.has_grant("/repo", "test")
		assert(granted == nil and tostring(err):find("hard links are rejected", 1, true))
		assert(vim.uv.fs_lstat(path).nlink == 2, "grant observation replaced hard-linked state")
		vim.fn.delete(parent, "rf")
	end
end)

test("pre-commit file fsync and close failures do not create grants", function()
	for _, fixture in ipairs({
		{ name = "fsync", api = "fs_fsync" },
		{ name = "close", api = "fs_close" },
	}) do
		local parent = temp_dir()
		local root = state_root(parent)
		setup(root)
		local failed = false
		local authorized, authorize_err = with_uv_override(fixture.api, function(original, fd, ...)
			local info = vim.uv.fs_fstat(fd)
			if not failed and info and info.type == "file" then
				failed = true
				if fixture.api == "fs_close" then
					assert(original(fd, ...))
				end
				return nil, "simulated pre-commit " .. fixture.name .. " failure"
			end
			return original(fd, ...)
		end, function()
			return trusted_workspace.authorize("/precommit-" .. fixture.name, "test")
		end)
		assert(failed and not authorized, fixture.name .. " failure was reported as a successful mutation")
		assert(
			tostring(authorize_err):find("could not stage lock claim", 1, true),
			fixture.name .. " error was lost: " .. tostring(authorize_err)
		)
		assert(
			trusted_workspace.status("/precommit-" .. fixture.name).repo_grants.test == nil,
			fixture.name .. " failure advanced in-memory grants"
		)
		assert(
			vim.uv.fs_lstat(vim.fs.joinpath(root, "trusted-workspace.json")) == nil,
			fixture.name .. " published state"
		)
		vim.fn.delete(parent, "rf")
	end
end)

test("persistent lock and state mutations cross directory fsync barriers", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local operations = {}
	trusted_workspace._set_test_hook(function(phase, details)
		if phase == "directory_fsync" then
			operations[#operations + 1] = details.operation
		end
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/barriers", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called and authorized, tostring(authorize_err or authorized))
	local function saw(needle)
		for _, operation in ipairs(operations) do
			if operation:find(needle, 1, true) then
				return true
			end
		end
		return false
	end
	assert(saw("state root mkdir"), "state root mkdir omitted its parent-directory fsync")
	assert(saw("private quarantine mkdir"), "lock quarantine mkdir omitted its parent-directory fsync")
	assert(saw("rename trusted-workspace.json.tmp."), "state publication omitted its directory fsync")
	assert(saw("unlink record.quarantine."), "lock claim unlink omitted its directory fsync")
	assert(saw("remove directory"), "quarantine removal omitted its directory fsync")
	vim.fn.delete(parent, "rf")
end)

test("persistent mutations reread under lock and preserve unrelated writers", function()
	local parent = temp_dir()
	local root = state_root(parent)
	local module_path = plugin_root .. "/lua/trusted_workspace/init.lua"
	local function instance()
		return assert(loadfile(module_path))()
	end
	local seed = instance()
	assert(seed.setup({ state_root = root, reset = true }))
	assert(seed.authorize("/repo", "debug"))
	local left = instance()
	local right = instance()
	assert(left.setup({ state_root = root, reset = true }))
	assert(right.setup({ state_root = root, reset = true }))
	assert(left.revoke("/repo", "debug"))
	assert(right.authorize("/repo", "test"))
	local reader = instance()
	assert(reader.setup({ state_root = root, reset = true }))
	local grants = reader.status("/repo").repo_grants
	assert(grants.debug == nil, "stale writer resurrected a revoked grant")
	equal(true, grants.test, "stale writer discarded an unrelated grant")
	vim.fn.delete(parent, "rf")
end)

test("persistent CAS preserves an external writer at the publication boundary", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/repo", "debug"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local external = vim.json.decode(table.concat(vim.fn.readfile(path, "b"), "\n"))
	external.grants["/external"] = { build = true }
	local external_bytes = vim.json.encode(external)
	local injected = false
	trusted_workspace._set_test_hook(function(phase, details)
		if not injected and phase == "state_target_checked" and details.path == path then
			injected = true
			assert(vim.fn.writefile({ external_bytes }, path, "b") == 0)
		end
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(injected and not authorized and tostring(authorize_err):find("changed concurrently", 1, true))
	equal(external_bytes, table.concat(vim.fn.readfile(path, "b"), "\n"), "external state was clobbered")
	assert(trusted_workspace.status("/repo").repo_grants.test == nil, "failed CAS advanced in-memory grants")
	assert(trusted_workspace.status("/external").repo_grants.build == nil, "failed CAS imported external state")

	setup(root)
	equal(true, trusted_workspace.status("/external").repo_grants.build, "preserved external state did not reload")
	assert(trusted_workspace.status("/repo").repo_grants.test == nil, "rejected mutation reached durable state")
	for name in vim.fs.dir(root) do
		assert(not name:find("trusted%-workspace%.json%.cas%."), "CAS quarantine leaked after recovery")
	end
	vim.fn.delete(parent, "rf")
end)

test("persistent CAS restores a symlink introduced at the exchange boundary", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/repo", "debug"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local displaced = vim.fs.joinpath(parent, "trusted-workspace.before-symlink.json")
	local outside = vim.fs.joinpath(parent, "outside.json")
	assert(vim.fn.writefile({ "outside unchanged" }, outside, "b") == 0)
	local injected = false
	trusted_workspace._set_test_hook(function(phase, details)
		if injected or phase ~= "state_target_checked" or details.path ~= path then
			return
		end
		injected = true
		assert(vim.uv.fs_rename(path, displaced))
		assert(vim.uv.fs_symlink(outside, path))
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(injected and not authorized and tostring(authorize_err):find("changed concurrently", 1, true))
	assert(assert(vim.uv.fs_lstat(path)).type == "link", "boundary symlink was not restored")
	equal(outside, vim.uv.fs_readlink(path), "boundary symlink destination changed")
	equal({ "outside unchanged" }, vim.fn.readfile(outside, "b"), "boundary symlink was followed")
	assert(trusted_workspace.status("/repo").repo_grants.test == nil, "failed CAS advanced in-memory grants")
	assert(vim.fn.filereadable(displaced) == 1, "race fixture lost the displaced prior state")
	vim.fn.delete(parent, "rf")
end)

test("successful state exchange publishes the exact staging snapshot and cleans the incumbent", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local original_bytes = table.concat(vim.fn.readfile(path, "b"), "\n")
	local original_identity = assert(vim.uv.fs_lstat(path))
	local exchange
	trusted_workspace._set_test_hook(function(phase, details)
		if phase ~= "state_exchanged" then
			return
		end
		assert(exchange == nil, "state was exchanged more than once")
		exchange = {
			path = details.path,
			recovery_path = details.recovery_path,
			published_bytes = table.concat(vim.fn.readfile(details.path, "b"), "\n"),
			published_identity = assert(vim.uv.fs_lstat(details.path)),
			incumbent_bytes = table.concat(vim.fn.readfile(details.recovery_path, "b"), "\n"),
			incumbent_identity = assert(vim.uv.fs_lstat(details.recovery_path)),
		}
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(authorized, authorize_err)
	assert(exchange, "existing state did not use the exchange publication path")
	equal(path, exchange.path, "exchange published under the wrong state path")
	equal(original_bytes, exchange.incumbent_bytes, "exchange did not preserve the exact incumbent bytes")
	assert(
		exchange.incumbent_identity.dev == original_identity.dev
			and exchange.incumbent_identity.ino == original_identity.ino,
		"exchange did not preserve the incumbent identity"
	)
	local final_identity = assert(vim.uv.fs_lstat(path))
	assert(
		final_identity.dev == exchange.published_identity.dev and final_identity.ino == exchange.published_identity.ino,
		"cleanup replaced the published staging inode"
	)
	equal(
		exchange.published_bytes,
		table.concat(vim.fn.readfile(path, "b"), "\n"),
		"cleanup changed the exact published staging bytes"
	)
	assert(vim.uv.fs_lstat(exchange.recovery_path) == nil, "successful exchange retained its displaced incumbent")
	for name in vim.fs.dir(root) do
		assert(not name:find("trusted%-workspace%.json%.tmp%."), "successful exchange leaked state staging")
	end
	vim.fn.delete(parent, "rf")
end)

test("state exchange fsync failure keeps committed success, warning, and recovery", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local injected = false
	trusted_workspace._set_test_hook(function(phase, details)
		if
			phase == "directory_fsync"
			and details.operation:find("exchange trusted-workspace.json.tmp.", 1, true)
			and not injected
		then
			injected = true
			error("simulated state exchange fsync failure")
		end
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/committed-fsync", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(
		called and injected and authorized,
		"post-commit fsync failure became a false failure: " .. tostring(authorize_err)
	)
	local status = trusted_workspace.status("/committed-fsync")
	assert(status.repo_grants.test, "committed state exchange did not advance memory")
	assert(
		tostring(status.state_error):find("directory fsync hook failed", 1, true),
		"post-commit state fsync warning was not exposed"
	)
	local recovery
	for name in vim.fs.dir(root) do
		if name:find("trusted%-workspace%.json%.tmp%.") == 1 then
			recovery = vim.fs.joinpath(root, name)
			break
		end
	end
	assert(recovery and vim.uv.fs_lstat(recovery), "uncertain state exchange discarded its recovery incumbent")
	local persisted =
		vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(root, "trusted-workspace.json"), "b"), "\n"))
	assert(persisted.grants["/committed-fsync"].test, "committed state bytes were not visible")
	vim.fn.delete(parent, "rf")
end)

test("state CAS rejects changed staging bytes and restores the exact incumbent", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local incumbent_bytes = table.concat(vim.fn.readfile(path, "b"), "\n")
	local incumbent_identity = assert(vim.uv.fs_lstat(path))
	local injected_bytes = vim.json.encode({
		version = 1,
		approvals = {},
		grants = { ["/injected"] = { build = true } },
	})
	local staging_path
	trusted_workspace._set_test_hook(function(phase)
		if staging_path or phase ~= "state_target_checked" then
			return
		end
		for name in vim.fs.dir(root) do
			if name:find("trusted%-workspace%.json%.tmp%.") == 1 then
				staging_path = vim.fs.joinpath(root, name)
				assert(vim.fn.writefile({ injected_bytes }, staging_path, "b") == 0)
				break
			end
		end
		assert(staging_path, "state staging file was not found")
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(
		not authorized and tostring(authorize_err):find("staging changed before exchange", 1, true),
		"changed state staging was published"
	)
	local current = assert(vim.uv.fs_lstat(path))
	assert(
		current.dev == incumbent_identity.dev and current.ino == incumbent_identity.ino,
		"incumbent identity changed after rejected staging"
	)
	equal(incumbent_bytes, table.concat(vim.fn.readfile(path, "b"), "\n"), "incumbent bytes were not restored")
	equal(injected_bytes, table.concat(vim.fn.readfile(staging_path, "b"), "\n"), "changed staging was clobbered")
	assert(trusted_workspace.status("/repo").repo_grants.test == nil, "rejected staging advanced memory")
	vim.fn.delete(parent, "rf")
end)

test("lock claim publication rejects changed staging content without deleting it", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local staging_path
	local final_path
	local changed_bytes
	local staging_identity
	trusted_workspace._set_test_hook(function(phase, details)
		if staging_path or phase ~= "lock_claim_staged" then
			return
		end
		staging_path = details.staging_path
		final_path = details.path
		local intended = table.concat(vim.fn.readfile(staging_path, "b"), "\n")
		changed_bytes = intended:gsub('"choosing"', '"CHOOSING"', 1)
		assert(changed_bytes ~= intended and #changed_bytes == #intended, "claim mutation was not same-sized")
		staging_identity = assert(vim.uv.fs_lstat(staging_path))
		assert(vim.fn.writefile({ changed_bytes }, staging_path, "b") == 0)
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(staging_path, "lock claim staging hook did not run")
	assert(
		not authorized and tostring(authorize_err):find("staged lock claim content changed", 1, true),
		"changed claim staging was published"
	)
	assert(vim.uv.fs_lstat(final_path) == nil, "changed staging became a visible lock claim")
	local current = assert(vim.uv.fs_lstat(staging_path))
	assert(
		current.dev == staging_identity.dev and current.ino == staging_identity.ino,
		"changed claim staging identity was replaced"
	)
	equal(changed_bytes, table.concat(vim.fn.readfile(staging_path, "b"), "\n"), "changed claim staging was deleted")
	vim.fn.delete(parent, "rf")
end)

test("lock release preserves a replacement instead of adopting its inode", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local displaced = vim.fs.joinpath(parent, "original-ticket")
	local replacement_path
	local replacement_bytes
	local replacement_identity
	local original_bytes
	local original_identity
	trusted_workspace._set_test_hook(function(phase)
		if replacement_path or phase ~= "state_target_checked" then
			return
		end
		for name in vim.fs.dir(root) do
			if name:find("trusted%-workspace%.lock%.ticket%.") == 1 then
				local claim = vim.fs.joinpath(root, name)
				original_bytes = table.concat(vim.fn.readfile(claim, "b"), "\n")
				original_identity = assert(vim.uv.fs_lstat(claim))
				assert(vim.uv.fs_rename(claim, displaced))
				replacement_bytes = original_bytes
				assert(vim.fn.writefile({ replacement_bytes }, claim, "b") == 0)
				assert(vim.uv.fs_chmod(claim, 384))
				replacement_path = claim
				replacement_identity = assert(vim.uv.fs_lstat(claim))
				break
			end
		end
		assert(replacement_path, "owned ticket was not found before state publication")
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(authorized, "committed update was reported as failed: " .. tostring(authorize_err))
	assert(
		tostring(trusted_workspace.status().state_error):find("changed before conditional removal", 1, true),
		"release conflict was not exposed as a status warning"
	)
	local current = assert(vim.uv.fs_lstat(replacement_path))
	assert(
		current.dev == replacement_identity.dev and current.ino == replacement_identity.ino,
		"replacement ticket inode changed during release"
	)
	equal(
		replacement_bytes,
		table.concat(vim.fn.readfile(replacement_path, "b"), "\n"),
		"replacement ticket bytes changed during release"
	)
	local displaced_identity = assert(vim.uv.fs_lstat(displaced))
	assert(
		displaced_identity.dev == original_identity.dev and displaced_identity.ino == original_identity.ino,
		"release lost the originally acquired ticket identity"
	)
	equal(original_bytes, table.concat(vim.fn.readfile(displaced, "b"), "\n"), "original ticket bytes changed")
	for name in vim.fs.dir(root) do
		assert(not name:find("%.remove%."), "release conflict leaked a lock quarantine")
	end
	local reader = assert(loadfile(plugin_root .. "/lua/trusted_workspace/init.lua"))()
	assert(reader.setup({ state_root = root, reset = true }))
	equal(true, reader.status("/repo").repo_grants.test, "committed state was lost after release conflict")
	vim.fn.delete(parent, "rf")
end)

test("lock quarantine cleanup preserves unknown entries and reports the retained directory", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local retained_path
	local foreign_bytes = "cleanup-rival"
	trusted_workspace._set_test_hook(function(phase, details)
		if retained_path or phase ~= "directory_reserved_before_remove" then
			return
		end
		if details.label ~= "lock claim quarantine" or not details.path:find("%.ticket%.") then
			return
		end
		retained_path = details.path
		assert(vim.fn.writefile({ foreign_bytes }, vim.fs.joinpath(details.reserved_path, "foreign"), "b") == 0)
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(retained_path, "ticket quarantine cleanup hook did not run")
	assert(authorized, "committed update was reported as failed: " .. tostring(authorize_err))
	assert(
		tostring(trusted_workspace.status().state_error):find("directory changed before removal", 1, true),
		"unsafe quarantine cleanup was not exposed as a status warning"
	)
	local foreign_path = vim.fs.joinpath(retained_path, "foreign")
	equal(foreign_bytes, table.concat(vim.fn.readfile(foreign_path, "b"), "\n"), "cleanup deleted the unknown entry")
	assert(trusted_workspace.status("/repo").repo_grants.test, "successful state write was lost on cleanup failure")
	local reader = assert(loadfile(plugin_root .. "/lua/trusted_workspace/init.lua"))()
	assert(reader.setup({ state_root = root, reset = true }))
	equal(true, reader.status("/repo").repo_grants.test, "cleanup failure lost the durable state mutation")
	vim.fn.delete(parent, "rf")
end)

test("state cleanup preserves a replacement introduced after final validation", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local retained_old = vim.fs.joinpath(parent, "retained-state-incumbent")
	local foreign_bytes = "post-validation-state-rival"
	local replaced = false
	trusted_workspace._set_test_hook(function(phase, details)
		if phase ~= "entry_validated_before_quarantine" or details.label ~= "state CAS incumbent" or replaced then
			return
		end
		replaced = true
		assert(vim.uv.fs_rename(details.reserved_path, retained_old))
		assert(vim.fn.writefile({ foreign_bytes }, details.reserved_path, "b") == 0)
		assert(vim.uv.fs_chmod(details.reserved_path, 384))
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/post-validation", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(
		called and replaced and authorized,
		"cleanup conflict became a false write failure: " .. tostring(authorize_err)
	)
	assert(trusted_workspace.status("/post-validation").repo_grants.test, "committed grant was lost")
	assert(vim.uv.fs_lstat(retained_old), "cleanup lost the displaced exact incumbent")
	local preserved_foreign = false
	for name in vim.fs.dir(root) do
		local candidate = vim.fs.joinpath(root, name)
		local info = vim.uv.fs_lstat(candidate)
		if
			name:find("trusted%-workspace%.json%.tmp%.") == 1
			and info
			and info.type == "file"
			and table.concat(vim.fn.readfile(candidate, "b"), "\n") == foreign_bytes
		then
			preserved_foreign = true
		end
	end
	assert(preserved_foreign, "cleanup deleted the post-validation state replacement")
	assert(
		tostring(trusted_workspace.status().state_error):find("changed after final validation", 1, true),
		"post-validation cleanup conflict was not exposed"
	)
	vim.fn.delete(parent, "rf")
end)

test("directory cleanup preserves an empty replacement introduced after final validation", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local retained_original = vim.fs.joinpath(parent, "retained-lock-quarantine")
	local replacement_path
	trusted_workspace._set_test_hook(function(phase, details)
		if
			phase ~= "directory_validated_before_quarantine"
			or details.label ~= "lock claim quarantine"
			or not details.path:find(".ticket.", 1, true)
			or replacement_path
		then
			return
		end
		replacement_path = details.path
		assert(vim.uv.fs_rename(details.reserved_path, retained_original))
		assert(vim.fn.mkdir(details.reserved_path, "p", 448) == 1)
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/directory-rival", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(
		called and replacement_path and authorized,
		"directory replacement caused false failure: " .. tostring(authorize_err)
	)
	assert(assert(vim.uv.fs_lstat(replacement_path)).type == "directory", "replacement directory was deleted")
	assert(assert(vim.uv.fs_lstat(retained_original)).type == "directory", "original quarantine was lost")
	assert(
		tostring(trusted_workspace.status().state_error):find("changed after final validation", 1, true),
		"directory cleanup conflict was not exposed"
	)
	vim.fn.delete(parent, "rf")
end)

test("initial state no-replace publication preserves a boundary rival", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local rival_bytes = vim.json.encode({
		version = 1,
		approvals = {},
		grants = { ["/rival"] = { debug = true } },
	})
	local rival_identity
	trusted_workspace._set_test_hook(function(phase, details)
		if rival_identity or phase ~= "state_target_checked" or details.target_present then
			return
		end
		assert(vim.fn.writefile({ rival_bytes }, path, "b") == 0)
		assert(vim.uv.fs_chmod(path, 384))
		rival_identity = assert(vim.uv.fs_lstat(path))
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(not authorized and tostring(authorize_err):find("changed concurrently", 1, true))
	local current = assert(vim.uv.fs_lstat(path))
	assert(current.dev == rival_identity.dev and current.ino == rival_identity.ino, "initial rival inode was replaced")
	equal(rival_bytes, table.concat(vim.fn.readfile(path, "b"), "\n"), "initial rival bytes were clobbered")
	vim.fn.delete(parent, "rf")
end)

test("a crash after state exchange never exposes missing durable state", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local incumbent_bytes = table.concat(vim.fn.readfile(path, "b"), "\n")
	local ready = vim.fs.joinpath(parent, "state-exchange.ready")
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			TRUSTED_WORKSPACE_STATE_CRASH_CHILD = "1",
			TRUSTED_WORKSPACE_STATE_CRASH_ROOT = root,
			TRUSTED_WORKSPACE_STATE_CRASH_READY = ready,
		},
		text = true,
	})
	local ready_ok = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not ready_ok then
		child:kill(9)
		local failed = child:wait(5000)
		error("state exchange crash child did not reach exchange barrier: " .. tostring(failed.stderr))
	end
	local visible = assert(vim.uv.fs_lstat(path))
	assert(visible.type == "file", "state path was absent during the exchange crash window")
	local published = vim.json.decode(table.concat(vim.fn.readfile(path, "b"), "\n"))
	equal(true, published.grants["/crash-exchange"].test, "NEW state was not visible after atomic exchange")
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "state exchange crash child was not killed")
	local recovery
	for name in vim.fs.dir(root) do
		if name:find("trusted%-workspace%.json%.tmp%.") == 1 then
			recovery = vim.fs.joinpath(root, name)
			break
		end
	end
	assert(recovery, "atomic exchange did not retain the displaced incumbent")
	equal(incumbent_bytes, table.concat(vim.fn.readfile(recovery, "b"), "\n"), "recovery incumbent changed")
	assert(trusted_workspace.setup({ state_root = root, reset = true }))
	equal(
		true,
		trusted_workspace.status("/crash-exchange").repo_grants.test,
		"valid NEW state did not reload after crash"
	)
	vim.fn.delete(parent, "rf")
end)

test("state locks reject live owners and reclaim only confirmed-dead owners", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(vim.fn.mkdir(root, "p", 448) == 1)
	local live_token = vim.fn.sha256("live")
	local lock = lock_claim(root, "ticket", vim.uv.os_getpid(), live_token, 1)
	local authorized, live_err = trusted_workspace.authorize("/repo", "test")
	assert(not authorized and live_err:find("locked by process", 1, true), "live owner lock was reclaimed")
	assert(vim.uv.fs_lstat(lock), "live owner lock was removed")
	assert(vim.uv.fs_unlink(lock))

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
	local dead_token = vim.fn.sha256("dead")
	lock = lock_claim(root, "ticket", dead_pid, dead_token, 1)
	local reclaimed, dead_err = trusted_workspace.authorize("/repo", "test")
	assert(reclaimed, "dead owner lock was not reclaimed: " .. tostring(dead_err))
	assert(vim.uv.fs_lstat(lock) == nil, "reclaimed lock was not released")
	vim.fn.delete(parent, "rf")
end)

test("lock enumeration remains bound to the pinned root across an ABA swap", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local token = vim.fn.sha256("aba-live-lock")
	local live_claim = lock_claim(root, "ticket", vim.uv.os_getpid(), token, 1)
	local displaced = vim.fs.joinpath(parent, "state-original")
	local outside = vim.fs.joinpath(parent, "outside")
	assert(vim.fn.mkdir(outside, "p", 448) == 1)
	local swapped = false
	local restored = false
	trusted_workspace._set_test_hook(function(phase)
		if phase == "lock_claim_list_before" and not swapped then
			swapped = true
			assert(vim.uv.fs_rename(root, displaced))
			assert(vim.uv.fs_symlink(outside, root))
		elseif phase == "lock_claim_list_after" and swapped and not restored then
			restored = true
			assert(vim.uv.fs_unlink(root))
			assert(vim.uv.fs_rename(displaced, root))
		end
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(swapped and restored, "ABA listing hook did not complete the swap and restoration")
	assert(not authorized and tostring(authorize_err):find("locked by process", 1, true), "live claim was omitted")
	assert(vim.uv.fs_lstat(live_claim), "live claim was removed after descriptor enumeration")
	assert(#vim.fn.readdir(outside) == 0, "ABA listing wrote through the transient pathname")
	vim.fn.delete(parent, "rf")
end)

test("dead-claim reclamation preserves a live replacement before conditional removal", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
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
	local token = vim.fn.sha256("replaced-dead-lock")
	local claim = lock_claim(root, "ticket", dead_pid, token, 1)
	local displaced = vim.fs.joinpath(parent, "dead-claim-original")
	local rival = {
		version = 1,
		kind = "ticket",
		pid = vim.uv.os_getpid(),
		token = token,
		number = 1,
	}
	local replaced = false
	local rival_identity
	trusted_workspace._set_test_hook(function(phase, details)
		if replaced or phase ~= "lock_claim_before_remove" or details.path ~= claim then
			return
		end
		replaced = true
		assert(vim.uv.fs_rename(claim, displaced))
		assert(vim.fn.writefile({ vim.json.encode(rival) }, claim) == 0)
		assert(vim.uv.fs_chmod(claim, 384))
		rival_identity = assert(vim.uv.fs_lstat(claim))
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(replaced, "conditional-removal replacement hook did not run")
	assert(
		not authorized and tostring(authorize_err):find("changed before conditional removal", 1, true),
		"replacement claim was reclaimed"
	)
	local current = assert(vim.uv.fs_lstat(claim))
	assert(
		current.dev == rival_identity.dev and current.ino == rival_identity.ino,
		"replacement claim identity changed"
	)
	equal(rival, vim.json.decode(table.concat(vim.fn.readfile(claim, "b"), "\n")), "replacement claim bytes changed")
	assert(vim.uv.fs_lstat(displaced), "original dead claim was lost")
	for name in vim.fs.dir(root) do
		assert(not name:find("%.remove%."), "conditional removal leaked a quarantine after restoration")
	end
	vim.fn.delete(parent, "rf")
end)

test("a committed state update remains successful when lock release fails", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	trusted_workspace._set_test_hook(function(phase, details)
		if phase == "lock_claim_before_remove" and details.name:find(".ticket.", 1, true) then
			error("simulated lock release failure")
		end
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/committed", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(authorized, "committed grant was reported as failed: " .. tostring(authorize_err))
	local status = assert(trusted_workspace.status("/committed"))
	assert(status.repo_grants.test == true, "committed grant was not reflected in memory")
	assert(
		tostring(status.state_error):find("could not release state lock", 1, true),
		"lock release warning was not exposed through status"
	)
	local persisted =
		vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(root, "trusted-workspace.json"), "b"), "\n"))
	assert(persisted.grants["/committed"].test == true, "committed grant was not durable")
	vim.fn.delete(parent, "rf")
end)

test("lock release fsync warnings survive later successful cleanup and mutations", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local releasing_ticket = false
	local injected = false
	trusted_workspace._set_test_hook(function(phase, details)
		if phase == "lock_claim_before_remove" and details.name:find(".ticket.", 1, true) then
			releasing_ticket = true
		elseif
			phase == "directory_fsync"
			and releasing_ticket
			and details.operation:find("unlink record.quarantine.", 1, true)
			and not injected
		then
			injected = true
			error("simulated lock release directory fsync failure")
		end
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/release-warning", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(
		called and injected and authorized,
		"release fsync warning became a false failure: " .. tostring(authorize_err)
	)
	local first_warning = tostring(trusted_workspace.status().state_error)
	assert(
		first_warning:find("lock release directory fsync failure", 1, true),
		"release fsync warning was not retained"
	)
	assert(trusted_workspace.authorize("/later-success", "build"), "later clean mutation failed")
	local later_warning = tostring(trusted_workspace.status().state_error)
	assert(
		later_warning:find("lock release directory fsync failure", 1, true),
		"later successful cleanup erased the earlier release warning"
	)
	assert(trusted_workspace.status("/later-success").repo_grants.build, "later successful mutation was not applied")
	vim.fn.delete(parent, "rf")
end)

test("post-commit quarantine close failures remain successful state warnings", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local release_started = false
	local injected = false
	local authorized, authorize_err = with_uv_override("fs_close", function(original, fd, ...)
		local info = vim.uv.fs_fstat(fd)
		local closed, close_err = original(fd, ...)
		if release_started and not injected and info and info.type == "directory" then
			injected = true
			return nil, "simulated post-commit quarantine close failure"
		end
		return closed, close_err
	end, function()
		trusted_workspace._set_test_hook(function(phase, details)
			if phase == "lock_claim_before_remove" and details.name:find(".ticket.", 1, true) then
				release_started = true
			end
		end)
		local result, result_err = trusted_workspace.authorize("/close-warning", "test")
		trusted_workspace._set_test_hook(nil)
		return result, result_err
	end)
	assert(injected and authorized, "post-commit close warning became a false failure: " .. tostring(authorize_err))
	assert(trusted_workspace.status("/close-warning").repo_grants.test, "committed close-warning grant was lost")
	assert(
		tostring(trusted_workspace.status().state_error):find("post-commit quarantine close failure", 1, true),
		"post-commit close warning was not exposed"
	)
	vim.fn.delete(parent, "rf")
end)

test("hard-linked state and lock claims fail closed", function()
	local state_parent = temp_dir()
	local root = state_root(state_parent)
	assert(vim.fn.mkdir(root, "p", 448) == 1)
	local outside_state = vim.fs.joinpath(state_parent, "outside-state.json")
	assert(vim.fn.writefile({ vim.json.encode({ version = 1, approvals = {}, grants = {} }) }, outside_state) == 0)
	assert(vim.uv.fs_link(outside_state, vim.fs.joinpath(root, "trusted-workspace.json")))
	local ok, err = trusted_workspace.setup({ state_root = root, reset = true })
	assert(not ok and err:find("hard links are rejected", 1, true), "hard-linked state was accepted")
	local authorized = trusted_workspace.authorize("/repo", "test")
	assert(not authorized, "hard-linked state accepted a mutation")

	local lock_parent = temp_dir()
	root = state_root(lock_parent)
	setup(root)
	assert(trusted_workspace.authorize("/repo", "debug"))
	local token = vim.fn.sha256("hard-linked-lock")
	local claim = lock_claim(root, "ticket", vim.uv.os_getpid(), token, 1)
	local alias = vim.fs.joinpath(lock_parent, "lock-claim-alias")
	assert(vim.uv.fs_link(claim, alias))
	authorized, err = trusted_workspace.authorize("/repo", "test")
	assert(not authorized and tostring(err):find("hard links are rejected", 1, true), "hard-linked lock was accepted")
	assert(vim.uv.fs_lstat(claim), "unsafe lock claim was removed")
	vim.fn.delete(state_parent, "rf")
	vim.fn.delete(lock_parent, "rf")
end)

test("state root substitution is rejected after setup", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/repo", "debug"))
	local displaced = vim.fs.joinpath(parent, "state-original")
	local outside = vim.fs.joinpath(parent, "outside")
	assert(vim.uv.fs_rename(root, displaced))
	assert(vim.fn.mkdir(outside, "p", 448) == 1)
	assert(vim.uv.fs_symlink(outside, root))
	local authorized, err = trusted_workspace.authorize("/repo", "test")
	assert(not authorized and tostring(err):find("state root", 1, true), "substituted state root was accepted")
	assert(#vim.fn.readdir(outside) == 0, "substituted state root was modified")
	vim.fn.delete(parent, "rf")
end)

test("state publication stays pinned when a validated ancestor is swapped", function()
	local container = temp_dir()
	local parent = vim.fs.joinpath(container, "trusted-parent")
	assert(vim.fn.mkdir(parent, "p", 448) == 1)
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/repo", "debug"))
	local path = vim.fs.joinpath(root, "trusted-workspace.json")
	local original_bytes = table.concat(vim.fn.readfile(path, "b"), "\n")
	local displaced = vim.fs.joinpath(container, "trusted-parent-original")
	local outside = vim.fs.joinpath(container, "outside-parent")
	local outside_root = state_root(outside)
	assert(vim.fn.mkdir(outside_root, "p", 448) == 1)
	local rival_path = vim.fs.joinpath(outside_root, "trusted-workspace.json")
	local rival_bytes = vim.json.encode({
		version = 1,
		approvals = {},
		grants = { ["/rival"] = { build = true } },
	})
	assert(vim.fn.writefile({ rival_bytes }, rival_path, "b") == 0)
	local swapped = false
	trusted_workspace._set_test_hook(function(phase, details)
		if swapped or phase ~= "state_target_checked" or details.path ~= path then
			return
		end
		swapped = true
		assert(vim.uv.fs_rename(parent, displaced))
		assert(vim.uv.fs_symlink(outside, parent))
	end)
	local called, authorized, authorize_err = xpcall(function()
		return trusted_workspace.authorize("/repo", "test")
	end, debug.traceback)
	trusted_workspace._set_test_hook(nil)
	assert(called, authorized)
	assert(swapped, "ancestor-swap publication hook did not run")
	assert(not authorized and tostring(authorize_err):find("state root changed", 1, true), "ancestor swap was accepted")
	equal(rival_bytes, table.concat(vim.fn.readfile(rival_path, "b"), "\n"), "outside rival was clobbered")
	equal(
		original_bytes,
		table.concat(vim.fn.readfile(vim.fs.joinpath(displaced, "state", "trusted-workspace.json"), "b"), "\n"),
		"pinned incumbent changed after the ancestor swap"
	)
	assert(trusted_workspace.status("/repo").repo_grants.test == nil, "failed ancestor-swap CAS advanced memory")
	vim.fn.delete(container, "rf")
end)

test("a process crash before claim publication leaves no blocking claim", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.authorize("/seed", "debug"))
	local ready = vim.fs.joinpath(parent, "claim-crash.ready")
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			TRUSTED_WORKSPACE_CLAIM_CRASH_CHILD = "1",
			TRUSTED_WORKSPACE_CLAIM_CRASH_ROOT = root,
			TRUSTED_WORKSPACE_CLAIM_CRASH_READY = ready,
		},
		text = true,
	})
	local ready_ok = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not ready_ok then
		child:kill(9)
		local failed = child:wait(5000)
		error("claim crash child did not reach publication barrier: " .. tostring(failed.stderr))
	end
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "claim crash child was not killed")

	local staged = {}
	for name in vim.fs.dir(root) do
		if name:find("trusted-workspace.lock.", 1, true) == 1 and name:sub(-8) == ".publish" then
			staged[#staged + 1] = vim.fs.joinpath(root, name)
		end
	end
	equal(1, #staged, "crashed publisher did not leave exactly one staging file")
	assert(vim.uv.fs_lstat(staged[1]:sub(1, -9)) == nil, "incomplete claim became visible")

	local dead_token = vim.fn.sha256("post-crash-final-claim")
	local dead_claim = lock_claim(root, "ticket", child.pid, dead_token, 1)
	local authorized, authorize_err = trusted_workspace.authorize("/repo", "test")
	assert(authorized, "orphan staging file blocked lock acquisition: " .. tostring(authorize_err))
	assert(vim.uv.fs_lstat(dead_claim) == nil, "valid final dead claim was not reclaimed")
	assert(vim.uv.fs_lstat(staged[1]), "unrecognized staging orphan was treated as a claim")
	assert(vim.uv.fs_unlink(staged[1]))
	vim.fn.delete(parent, "rf")
end)

test("two processes serialize simultaneous stale-claim reclamation", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(vim.fn.mkdir(root, "p", 448) == 1)
	local child = vim.system({ "sh", "-c", "exit 0" })
	local dead_pid = child.pid
	assert(child:wait().code == 0 and type(dead_pid) == "number")
	assert(vim.wait(1000, function()
		local called, result, _, code = pcall(vim.uv.kill, dead_pid, 0)
		return called and result == nil and code == "ESRCH"
	end, 10))
	local stale = lock_claim(root, "ticket", dead_pid, vim.fn.sha256("simultaneous-stale"), 1)
	local left_ready = vim.fs.joinpath(parent, "left.ready")
	local right_ready = vim.fs.joinpath(parent, "right.ready")
	local left_result = vim.fs.joinpath(parent, "left.result")
	local right_result = vim.fs.joinpath(parent, "right.result")
	local function spawn(capability, ready, peer, result)
		return vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
			env = {
				TRUSTED_WORKSPACE_LOCK_CHILD = "1",
				TRUSTED_WORKSPACE_LOCK_ROOT = root,
				TRUSTED_WORKSPACE_LOCK_READY = ready,
				TRUSTED_WORKSPACE_LOCK_PEER_READY = peer,
				TRUSTED_WORKSPACE_LOCK_RESULT = result,
				TRUSTED_WORKSPACE_LOCK_CAPABILITY = capability,
			},
			text = true,
		})
	end
	local left = spawn("test", left_ready, right_ready, left_result)
	local right = spawn("debug", right_ready, left_ready, right_result)
	local left_done = left:wait(10000)
	local right_done = right:wait(10000)
	assert(left_done.code == 0, left_done.stderr)
	assert(right_done.code == 0, right_done.stderr)
	equal({ "ok" }, vim.fn.readfile(left_result), "left process did not acquire the serialized lock")
	equal({ "ok" }, vim.fn.readfile(right_result), "right process did not acquire the serialized lock")
	assert(vim.uv.fs_lstat(stale) == nil, "simultaneously reclaimed stale claim survived")
	assert(trusted_workspace.setup({ state_root = root, reset = true }))
	local grants = trusted_workspace.status("/race").repo_grants
	assert(grants.test and grants.debug, "serialized writers lost a persistent mutation")
	vim.fn.delete(parent, "rf")
end)

test("appliers prepare first and roll back in reverse without advancing LKG", function()
	local parent = temp_dir()
	setup(state_root(parent))
	local events = {}
	local fail_second = false
	local function applier(id, order)
		return {
			id = id,
			order = order,
			prepare = function(next_snapshot)
				events[#events + 1] = "prepare:" .. id .. ":" .. tostring(next_snapshot.value.version)
				return "token-" .. id
			end,
			apply = function(token)
				events[#events + 1] = "apply:" .. id .. ":" .. token
				if id == "second" and fail_second then
					return false, "simulated failure"
				end
				return true
			end,
			rollback = function(token)
				events[#events + 1] = "rollback:" .. id .. ":" .. token
				return true
			end,
		}
	end
	assert(trusted_workspace.register_applier(applier("second", 20)))
	assert(trusted_workspace.register_applier(applier("first", 10)))
	assert(trusted_workspace.register_source({ id = "host", layer = "host", value = { version = 1 } }))
	events = {}
	fail_second = true
	local applied, err = trusted_workspace.register_source({ id = "host", layer = "host", value = { version = 2 } })
	assert(not applied and err:find("simulated failure", 1, true), "applier failure was not returned")
	equal({
		"prepare:first:2",
		"prepare:second:2",
		"apply:first:token-first",
		"apply:second:token-second",
		"rollback:first:token-first",
	}, events, "transaction order or rollback order is incorrect")
	local status = trusted_workspace.status()
	equal(1, status.applied.value.version, "failed transaction advanced applied state")
	equal(1, status.last_known_good.value.version, "failed transaction advanced last-known-good")
	equal(2, status.candidate.value.version, "failed candidate was discarded")
	assert(status.apply_error:find("simulated failure", 1, true), "status omitted apply failure")
	fail_second = false
	vim.fn.delete(parent, "rf")
end)

test("corrupt and symlink state fail closed without overwriting targets", function()
	local prior_config = trusted_workspace.effective_config()
	local corrupt_parent = temp_dir()
	local corrupt_root = state_root(corrupt_parent)
	assert(vim.fn.mkdir(corrupt_root, "p", 448) == 1)
	local corrupt_path = vim.fs.joinpath(corrupt_root, "trusted-workspace.json")
	assert(vim.fn.writefile({ "{broken" }, corrupt_path) == 0)
	local ok, err = trusted_workspace.setup({ state_root = corrupt_root, reset = true })
	assert(not ok and err:find("corrupt", 1, true), "corrupt JSON did not fail closed")
	equal(prior_config, trusted_workspace.effective_config(), "corrupt candidate replaced the prior registry")
	equal("{broken", vim.fn.readfile(corrupt_path)[1], "corrupt state was overwritten")

	local symlink_parent = temp_dir()
	local symlink_root = state_root(symlink_parent)
	assert(vim.fn.mkdir(symlink_root, "p", 448) == 1)
	local outside = vim.fs.joinpath(symlink_parent, "outside.json")
	assert(vim.fn.writefile({ "outside" }, outside) == 0)
	assert(vim.uv.fs_symlink(outside, vim.fs.joinpath(symlink_root, "trusted-workspace.json")))
	ok, err = trusted_workspace.setup({ state_root = symlink_root, reset = true })
	assert(not ok and err:find("symlinks are rejected", 1, true), "symlink state file was accepted")
	equal(prior_config, trusted_workspace.effective_config(), "symlink candidate replaced the prior registry")
	equal("outside", vim.fn.readfile(outside)[1], "symlink target was overwritten")

	local root_link_parent = temp_dir()
	local outside_root = vim.fs.joinpath(root_link_parent, "outside-root")
	assert(vim.fn.mkdir(outside_root, "p", 448) == 1)
	local root_link = vim.fs.joinpath(root_link_parent, "state-link")
	assert(vim.uv.fs_symlink(outside_root, root_link))
	ok, err = trusted_workspace.setup({ state_root = root_link, reset = true })
	assert(not ok and err:find("real directory", 1, true), "symlink state root was accepted")

	vim.fn.delete(corrupt_parent, "rf")
	vim.fn.delete(symlink_parent, "rf")
	vim.fn.delete(root_link_parent, "rf")
end)

test("host-only mode never enables or waits for project sources", function()
	local parent = temp_dir()
	setup(state_root(parent), "host-only")
	assert(trusted_workspace.register_source({ id = "host", layer = "host", value = { value = "host" } }))
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "fingerprint",
		value = { plugins = { native_review = { hunk_context = 9 } } },
	}))
	local status = trusted_workspace.status()
	equal("host-only", status.profile, "host-only profile was not reported")
	equal("applied", status.mode, "disabled project source made host-only mode pending")
	equal(0, #status.pending, "host-only mode exposed a project approval")
	equal(false, status.sources[2].enabled, "project source was enabled in host-only mode")
	local value = trusted_workspace.snapshot().value
	assert(not value.plugins or value.plugins.native_review == nil, "host-only mode applied a project field")
	vim.fn.delete(parent, "rf")
end)

test("WorkspaceKey scopes isolate sources and project host values into every scope", function()
	local parent = temp_dir()
	setup(state_root(parent))
	local host_workspace = { runtime = "host", root = "/repo", repo_identity = "logical-repo" }
	local container_workspace = {
		runtime = "container",
		root = "/workspaces/repo",
		repo_identity = "logical-repo",
	}
	assert(trusted_workspace.register_source({
		id = "host",
		layer = "host",
		value = {
			plugins = {
				clangd_compile_db = { profile = "full" },
				log_workbench = { max_lines = 1000, max_bytes = 10000 },
			},
		},
	}))
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		workspace = host_workspace,
		fingerprint = "same",
		value = {
			plugins = {
				clangd_compile_db = { path = "/repo/build" },
				log_workbench = { max_lines = 2000, max_bytes = 5000 },
			},
		},
	}))
	local host_pending = assert(trusted_workspace.status(host_workspace))
	local host_generation = host_pending.generation
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		workspace = container_workspace,
		fingerprint = "same",
		value = {
			plugins = {
				clangd_compile_db = { path = "/workspaces/repo/build" },
				log_workbench = { max_lines = 500, max_bytes = 20000 },
			},
		},
	}))
	equal(
		host_generation,
		trusted_workspace.status(host_workspace).generation,
		"another scope advanced this generation"
	)
	assert(trusted_workspace.approve({
		workspace = host_workspace,
		source = "project",
		fingerprint = "same",
	}))
	assert(trusted_workspace.approve({
		workspace = container_workspace,
		source = "project",
		fingerprint = "same",
	}))
	local host_snapshot = assert(trusted_workspace.snapshot(host_workspace))
	local container_snapshot = assert(trusted_workspace.snapshot(container_workspace))
	equal("/repo/build", host_snapshot.value.plugins.clangd_compile_db.path, "host project path crossed scopes")
	equal(
		"/workspaces/repo/build",
		container_snapshot.value.plugins.clangd_compile_db.path,
		"container project path crossed scopes"
	)
	equal("full", host_snapshot.value.plugins.clangd_compile_db.profile, "host source was not projected")
	equal("full", container_snapshot.value.plugins.clangd_compile_db.profile, "host source missed a scope")
	equal(1000, host_snapshot.value.plugins.log_workbench.max_lines, "project expanded a host line limit")
	equal(500, container_snapshot.value.plugins.log_workbench.max_lines, "project reduction did not apply")
	equal(5000, host_snapshot.value.plugins.log_workbench.max_bytes, "project byte reduction did not apply")
	equal(10000, container_snapshot.value.plugins.log_workbench.max_bytes, "project expanded a host byte limit")
	equal(host_workspace, trusted_workspace.status(host_workspace).sources[2].workspace, "source lost its WorkspaceKey")

	host_snapshot.value.plugins.clangd_compile_db.path = "mutated"
	equal(
		"/repo/build",
		trusted_workspace.snapshot(host_workspace).value.plugins.clangd_compile_db.path,
		"workspace snapshot shares state"
	)
	local approvals = assert(trusted_workspace.approvals(host_workspace))
	equal("same", approvals.project, "approval was not reported")
	approvals.project = "mutated"
	equal("same", trusted_workspace.approvals(host_workspace).project, "approval status shares state")
	local ambiguous, ambiguous_err = trusted_workspace.status("logical-repo")
	assert(not ambiguous and ambiguous_err:find("ambiguous", 1, true), "ambiguous legacy selector chose a scope")
	assert(trusted_workspace.revoke_approval(host_workspace, "project"))
	equal("pending", trusted_workspace.status(host_workspace).mode, "revoked host approval stayed active")
	equal("pending", trusted_workspace.status(container_workspace).mode, "shared logical approval stayed active")
	vim.fn.delete(parent, "rf")
end)

test("multi-scope setup rolls back external effects before restoring prior state", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	local workspace_a = { runtime = "host", root = "/repo/a", repo_identity = "repo-a" }
	local workspace_b = { runtime = "host", root = "/repo/b", repo_identity = "repo-b" }
	local fail_second = false
	local attempts = 0
	local external_effects = 0
	local events = {}
	assert(trusted_workspace.register_applier({
		id = "global-transaction",
		prepare = function()
			return "token"
		end,
		apply = function()
			attempts = attempts + 1
			events[#events + 1] = "apply:" .. attempts
			if fail_second and attempts == 2 then
				return false, "scope two failed"
			end
			external_effects = external_effects + 1
			return true
		end,
		rollback = function()
			events[#events + 1] = "rollback"
			external_effects = external_effects - 1
			return true
		end,
	}))
	for index, workspace in ipairs({ workspace_a, workspace_b }) do
		assert(trusted_workspace.register_source({
			id = "project",
			layer = "project",
			workspace = workspace,
			fingerprint = "fingerprint-" .. index,
			value = { plugins = { native_review = { hunk_context = index + 2 } } },
		}))
		assert(trusted_workspace.approve({
			workspace = workspace,
			source = "project",
			fingerprint = "fingerprint-" .. index,
		}))
	end
	local before_a = trusted_workspace.snapshot(workspace_a)
	local before_b = trusted_workspace.snapshot(workspace_b)
	attempts = 0
	external_effects = 0
	events = {}
	fail_second = true
	local configured, err = trusted_workspace.setup({ state_root = root, mode = "host-only" })
	assert(not configured and tostring(err):find("scope two failed", 1, true), tostring(err))
	equal({ "apply:1", "apply:2", "rollback" }, events, "multi-scope rollback order is incorrect")
	equal(0, external_effects, "failed setup retained an external effect from an earlier scope")
	equal({ state_root = root, mode = "full" }, trusted_workspace.effective_config(), "failed setup published mode")
	equal(before_a, trusted_workspace.snapshot(workspace_a), "failed setup changed scope A")
	equal(before_b, trusted_workspace.snapshot(workspace_b), "failed setup changed scope B")
	vim.fn.delete(parent, "rf")
end)

test("setup contracts are transactional, copied, repeatable, and callback-isolated", function()
	trusted_workspace.teardown()
	equal(false, trusted_workspace.status().configured, "pre-setup status was unavailable")
	equal({ mode = "full" }, trusted_workspace.effective_config(), "pre-setup config defaults are unavailable")
	local parent = temp_dir()
	local root = state_root(parent)
	assert(trusted_workspace.setup({
		state_root = root,
		reset = true,
		on_state_change = function(event)
			event.kind = "mutated"
			error("observer failure")
		end,
	}))
	local config = trusted_workspace.effective_config()
	local generation = trusted_workspace.status().generation
	config.mode = "mutated"
	equal("full", trusted_workspace.effective_config().mode, "effective config shares state")
	local rejected, rejected_err = trusted_workspace.setup({ state_root = root, injected = true })
	assert(not rejected and rejected_err:find("unknown option: injected", 1, true), "unknown setup option was accepted")
	equal(generation, trusted_workspace.status().generation, "rejected setup mutated generation")
	assert(trusted_workspace.setup({ state_root = root }))
	equal(generation, trusted_workspace.status().generation, "repeat setup was not idempotent")
	assert(trusted_workspace.register_source({ id = "host", layer = "host", value = { safe = true } }))
	equal(true, trusted_workspace.snapshot().value.safe, "observer failure escaped into state mutation")
	local corrupt_parent = temp_dir()
	local corrupt_root = state_root(corrupt_parent)
	assert(vim.fn.mkdir(corrupt_root, "p", 448) == 1)
	local corrupt_path = vim.fs.joinpath(corrupt_root, "trusted-workspace.json")
	assert(vim.fn.writefile({ "{broken" }, corrupt_path) == 0)
	local failed, failed_err = trusted_workspace.setup({ state_root = corrupt_root, reset = true, mode = "host-only" })
	assert(not failed and failed_err:find("corrupt", 1, true), "corrupt candidate setup was accepted")
	equal({ state_root = root, mode = "full" }, trusted_workspace.effective_config(), "failed setup replaced config")
	equal(true, trusted_workspace.snapshot().value.safe, "failed setup discarded the prior source")
	equal(true, trusted_workspace.status().configured, "failed setup discarded the prior registry")
	assert(trusted_workspace.teardown())
	assert(trusted_workspace.teardown())
	equal(false, trusted_workspace.status().configured, "teardown did not reset status")
	vim.fn.delete(corrupt_parent, "rf")
	vim.fn.delete(parent, "rf")
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("trusted_workspace plugin spec: %d tests passed"):format(count))
