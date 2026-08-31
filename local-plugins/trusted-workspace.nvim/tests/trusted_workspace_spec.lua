vim.o.shadafile = "NONE"
vim.o.swapfile = false

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
local repo_root = vim.fs.dirname(vim.fs.dirname(plugin_root))
vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({ repo_root .. "/local-plugins/_shared/lua/?.lua", package.path }, ";")

local trusted_workspace = require("trusted_workspace")
local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
	end
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

test("sources are deterministic, restricted, provenance-aware, and copy-safe", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	assert(trusted_workspace.register_source({
		id = "host-z",
		layer = "host",
		priority = 10,
		value = { clangd = { path = "host-z" }, theme = { background = "dark" } },
	}))
	assert(trusted_workspace.register_source({
		id = "host-a",
		layer = "host",
		priority = 20,
		value = { clangd = { path = "host-a", profile = "full" } },
	}))
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "fingerprint-1",
		value = {
			clangd = { path = "project-clangd", profile = "light", extra = "discard" },
			review = { hunk_context = 7 },
			logs = { max_lines = 42 },
			theme = { background = "light" },
			dap = { ui = "dap-view" },
			mason = { auto_install = false },
			path = { "/hostile" },
			env = { HOSTILE = "yes" },
			plugins_dir = { "/hostile" },
			diagram_cache = { max_bytes = 1 },
		},
	}))

	local pending = assert(trusted_workspace.status())
	equal("pending", pending.mode, "unapproved project source was not pending")
	equal("host-a", trusted_workspace.snapshot().value.clangd.path, "pending project value became effective")
	equal("project-clangd", pending.candidate.value.clangd.path, "candidate omitted an allowed project field")
	equal(42, pending.candidate.value.log_watch.max_lines, "logs alias was not normalized")
	equal(
		{ id = "project", layer = "project" },
		pending.candidate.validity.provenance["clangd.path"],
		"candidate provenance is incorrect"
	)
	assert(find_error(pending.candidate.validity.errors, "theme: project field is not allowed"))
	assert(find_error(pending.candidate.validity.errors, "clangd.extra: project field is not allowed"))
	assert(#trusted_workspace.diff() > 0, "pending candidate has no diff")

	assert(trusted_workspace.approve("/repo", "project", "fingerprint-1"))
	local snapshot = trusted_workspace.snapshot()
	equal("project-clangd", snapshot.value.clangd.path, "approved project path did not override the host")
	equal("dark", snapshot.value.theme.background, "forbidden project theme overrode the host")
	assert(snapshot.value.dap == nil, "forbidden project DAP field became effective")
	assert(snapshot.value.env == nil, "forbidden project environment became effective")
	assert(find_error(snapshot.validity.errors, "plugins_dir: project field is not allowed"))

	snapshot.value.clangd.path = "mutated"
	snapshot.validity.provenance["clangd.path"].id = "mutated"
	local independent = trusted_workspace.snapshot()
	equal("project-clangd", independent.value.clangd.path, "snapshot value shares nested state")
	equal("project", independent.validity.provenance["clangd.path"].id, "snapshot validity shares nested state")

	equal("rwx------", vim.fn.getfperm(root), "state root is not owner-only")
	equal("rw-------", vim.fn.getfperm(vim.fs.joinpath(root, "trusted-workspace.json")), "state file is not owner-only")
	vim.fn.delete(parent, "rf")
end)

test("changed fingerprints retain the last-known-good snapshot until approval", function()
	local parent = temp_dir()
	setup(state_root(parent))
	assert(trusted_workspace.register_source({ id = "host", layer = "host", value = { clangd = { path = "host" } } }))
	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "one",
		value = { clangd = { path = "one" } },
	}))
	assert(trusted_workspace.approve("/repo", "project", "one"))
	equal("one", trusted_workspace.snapshot().value.clangd.path, "initial approval did not apply")

	assert(trusted_workspace.register_source({
		id = "project",
		layer = "project",
		repo = "/repo",
		fingerprint = "two",
		value = { clangd = { path = "two" } },
	}))
	local pending = trusted_workspace.status()
	equal("pending", pending.mode, "changed fingerprint was not pending")
	equal("two", pending.candidate.value.clangd.path, "changed candidate is stale")
	equal("one", trusted_workspace.snapshot().value.clangd.path, "pending source displaced last-known-good")
	equal("one", pending.last_known_good.value.clangd.path, "last-known-good changed before approval")
	assert(trusted_workspace.approve("/repo", "project", "two"))
	equal("two", trusted_workspace.snapshot().value.clangd.path, "changed fingerprint approval did not apply")
	vim.fn.delete(parent, "rf")
end)

test("capability grants are exact, persistent, copied, and revocable", function()
	local parent = temp_dir()
	local root = state_root(parent)
	setup(root)
	for _, capability in ipairs({ "lint-format", "test", "build", "debug" }) do
		assert(trusted_workspace.authorize("/repo", capability))
	end
	local invalid, invalid_err = trusted_workspace.authorize("/repo", "network")
	assert(not invalid and invalid_err:find("lint%-format"), "unknown capability was accepted")
	local status = trusted_workspace.status("/repo")
	equal(true, status.repo_grants.debug, "grant is missing")
	status.repo_grants.debug = false
	equal(true, trusted_workspace.status("/repo").repo_grants.debug, "grant status shares state")

	setup(root)
	equal(true, trusted_workspace.status("/repo").repo_grants.build, "grant did not survive reload")
	assert(trusted_workspace.revoke("/repo", "build"))
	assert(trusted_workspace.status("/repo").repo_grants.build == nil, "revoked grant remains active")
	setup(root)
	assert(trusted_workspace.status("/repo").repo_grants.build == nil, "revocation did not survive reload")
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
	vim.fn.delete(parent, "rf")
end)

test("corrupt and symlink state fail closed without overwriting targets", function()
	local corrupt_parent = temp_dir()
	local corrupt_root = state_root(corrupt_parent)
	assert(vim.fn.mkdir(corrupt_root, "p", 448) == 1)
	local corrupt_path = vim.fs.joinpath(corrupt_root, "trusted-workspace.json")
	assert(vim.fn.writefile({ "{broken" }, corrupt_path) == 0)
	local ok, err = trusted_workspace.setup({ state_root = corrupt_root, reset = true })
	assert(not ok and err:find("corrupt", 1, true), "corrupt JSON did not fail closed")
	local approved, approval_err = trusted_workspace.approve("/repo", "project", "fingerprint")
	assert(not approved and approval_err:find("unavailable", 1, true), "corrupt state accepted an approval")
	equal("{broken", vim.fn.readfile(corrupt_path)[1], "corrupt state was overwritten")

	local symlink_parent = temp_dir()
	local symlink_root = state_root(symlink_parent)
	assert(vim.fn.mkdir(symlink_root, "p", 448) == 1)
	local outside = vim.fs.joinpath(symlink_parent, "outside.json")
	assert(vim.fn.writefile({ "outside" }, outside) == 0)
	assert(vim.uv.fs_symlink(outside, vim.fs.joinpath(symlink_root, "trusted-workspace.json")))
	ok, err = trusted_workspace.setup({ state_root = symlink_root, reset = true })
	assert(not ok and err:find("symlinks are rejected", 1, true), "symlink state file was accepted")
	local authorized = trusted_workspace.authorize("/repo", "test")
	assert(not authorized, "symlink state accepted a grant")
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
		value = { review = { value = "project" } },
	}))
	local status = trusted_workspace.status()
	equal("host-only", status.profile, "host-only profile was not reported")
	equal("applied", status.mode, "disabled project source made host-only mode pending")
	equal(0, #status.pending, "host-only mode exposed a project approval")
	equal(false, status.sources[2].enabled, "project source was enabled in host-only mode")
	assert(trusted_workspace.snapshot().value.review == nil, "host-only mode applied a project field")
	vim.fn.delete(parent, "rf")
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("trusted_workspace plugin spec: %d tests passed"):format(count))
