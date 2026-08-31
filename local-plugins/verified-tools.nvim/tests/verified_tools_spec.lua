vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = assert(vim.uv.fs_realpath(vim.fn.getcwd() .. "/local-plugins/verified-tools.nvim"))
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	vim.fn.getcwd() .. "/local-plugins/_shared/lua/?.lua",
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	package.path,
}, ";")

local tools = require("verified_tools")
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
local state = fixture .. "/state"
local pending = {}
local timers = {}
local network = true
local external = {}
local attestation_failure = {}
local cancelled = {}

local function executable(root, name)
	local bin = root .. "/bin"
	assert(vim.fn.mkdir(bin, "p") >= 0)
	local path = bin .. "/" .. name
	assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path) == 0)
	assert(vim.uv.fs_chmod(path, tonumber("700", 8)))
	return path
end

local function backend(name)
	return {
		run = function(plan, done, control)
			pending[plan.identity.name] = done
			control.set_cancel(function()
				cancelled[plan.identity.name] = true
			end)
		end,
		attest = function(plan, done)
			if attestation_failure[plan.identity.name] then
				done(false, "drifted")
				return
			end
			done(true, {
				path = executable(plan.identity.install_root, plan.identity.name),
				digest = plan.identity.digest,
				backend = name,
			})
		end,
	}
end

local function configure()
	tools._reset_for_tests()
	pending, timers, cancelled, attestation_failure = {}, {}, {}, {}
	network = true
	external = {}
	tools.setup({
		state_root = state,
		backends = { release = backend("release"), mason = backend("mason") },
		probe_external = function(identity)
			return external[identity.name]
		end,
		network_authorized = function()
			return network
		end,
		process_alive = function(owner)
			return owner == vim.uv.os_getpid()
		end,
		defer = function(callback)
			timers[#timers + 1] = callback
		end,
		hash = function(value)
			return vim.fn.sha256(value)
		end,
	})
end

local function spec(name, backend_name, root, digest)
	return {
		identity = {
			backend = backend_name or "release",
			name = name,
			version = "1.0.0",
			target = "test-x86_64",
			digest = digest or ("sha256:" .. name),
			install_root = root or (fixture .. "/install-" .. name),
		},
		manifest = { timeout_ms = 1000 },
		requires_network = true,
	}
end

local function claim(value, mode)
	local plan = assert(tools.plan(value))
	return assert(tools.claim(plan, { mode = mode or "auto" }))
end

test("ToolIdentity is exact, copied, and persisted owner-only", function()
	configure()
	local value = spec("copy", "release")
	local injected = vim.deepcopy(value.identity)
	injected.injected = true
	assert(not tools.identity(injected))
	local plan = assert(tools.plan(value))
	value.identity.name = "mutated"
	assert(plan.identity.name == "copy")
	local claimed = claim(spec("copy", "release"))
	local status = assert(tools.status(claimed.identity))
	status.identity.name = "changed"
	assert(tools.status(claimed.identity).identity.name == "copy")
	assert(assert(vim.uv.fs_lstat(state)).mode % 512 == tonumber("700", 8))
	local records = state .. "/records"
	for name in vim.fs.dir(records) do
		assert(assert(vim.uv.fs_lstat(records .. "/" .. name)).mode % 512 == tonumber("600", 8))
	end
end)

test("release and Mason share a two-job scheduler and destination exclusion", function()
	configure()
	local first = claim(spec("release-one", "release", fixture .. "/release-root"))
	local second = claim(spec("mason-one", "mason", fixture .. "/mason-root"))
	local third = claim(spec("release-two", "release", fixture .. "/third-root"))
	assert(tools.run(first))
	assert(tools.run(second))
	assert(tools.run(third))
	local queued, active = tools._queue_size()
	assert(queued == 1 and active == 2)
	pending["release-one"](true)
	queued, active = tools._queue_size()
	assert(queued == 0 and active == 2)
	pending["mason-one"](true)
	pending["release-two"](true)

	local shared = fixture .. "/shared-root"
	local one = claim(spec("shared-one", "release", shared))
	local two = claim(spec("shared-two", "mason", shared))
	assert(tools.run(one))
	assert(tools.run(two))
	queued, active = tools._queue_size()
	assert(queued == 1 and active == 1)
	pending["shared-one"](true)
	assert(pending["shared-two"], "destination-conflicting job did not resume")
	pending["shared-two"](true)
end)

test("offline denial does not consume the one-shot attempt", function()
	configure()
	network = false
	local value = spec("offline")
	local plan = assert(tools.plan(value))
	local claimed, reason, blocked = tools.claim(plan)
	assert(claimed == nil and reason == "blocked/offline" and blocked.status == "blocked")
	assert(tools.status(plan.identity) == nil)
	network = true
	assert(tools.claim(plan), "offline denial consumed the automatic attempt")
end)

test("external compatibility is probed and incompatible hosts receive an attested shim", function()
	configure()
	external.hosted = { path = "/host/hosted", compatible = true }
	local hosted = assert(tools.plan(spec("hosted")))
	assert(hosted.strategy == "external" and hosted.executable == "/host/hosted" and hosted.shim_path == nil)
	assert(tools.claim(hosted).external)

	external.managed = { path = "/host/managed", compatible = false, observed = "0.9" }
	local value = spec("managed")
	local plan = assert(tools.plan(value))
	assert(plan.strategy == "managed" and plan.shim_path:find("/shims/bin/managed", 1, true))
	local managed = assert(tools.claim(plan))
	assert(tools.run(managed))
	pending.managed(true)
	local link = assert(vim.uv.fs_lstat(plan.shim_path))
	assert(link.type == "link")
	assert(vim.uv.fs_readlink(plan.shim_path) == fixture .. "/install-managed/bin/managed")
end)

test("watchdog and explicit cancellation settle once and require explicit retry", function()
	configure()
	local timed = claim(spec("timed"))
	assert(tools.run(timed))
	assert(#timers == 1)
	timers[1]()
	assert(cancelled.timed and tools.status(timed.identity).detail == "watchdog-timeout")
	assert(tools.claim(assert(tools.plan(spec("timed")))) == nil, "failed attempt retried automatically")
	assert(tools.retry(spec("timed")))
	assert(tools.cancel(timed.identity))
	assert(cancelled.timed and tools.status(timed.identity).status == "cancelled")
end)

test("cross-process global slots fail closed when both owners are unverifiable", function()
	configure()
	local waiting = claim(spec("global-capacity"))
	local locks = state .. "/locks/global"
	for slot = 1, 2 do
		local path = locks .. "/" .. slot .. ".lock"
		assert(vim.fn.writefile({ "unverifiable owner" }, path) == 0)
		assert(vim.uv.fs_chmod(path, tonumber("600", 8)))
	end
	assert(tools.run(waiting))
	local status = assert(tools.status(waiting.identity))
	assert(status.status == "failed" and status.detail == "global-capacity")
	assert(vim.uv.fs_lstat(locks .. "/1.lock"), "foreign slot lock was deleted")
	assert(vim.uv.fs_unlink(locks .. "/1.lock"))
	assert(vim.uv.fs_unlink(locks .. "/2.lock"))
end)

test("drift permits repair but not retry and legacy failures remain repair-required", function()
	configure()
	local value = spec("drift")
	local installed = claim(value)
	assert(tools.run(installed))
	pending.drift(true)
	attestation_failure.drift = true
	assert(tools.attest(value.identity))
	assert(tools.status(value.identity).status == "drift")
	assert(tools.retry(value) == nil)
	attestation_failure.drift = nil
	assert(tools.repair(value))
	assert(tools.cancel(value.identity))

	local legacy = spec("legacy-failed")
	assert(tools.import_legacy(legacy, { status = "failed" }))
	assert(tools.status(legacy.identity).status == "repair-required")
	assert(tools.repair(legacy))
	assert(tools.cancel(legacy.identity))

	local success = spec("legacy-success")
	assert(tools.import_legacy(success, { status = "succeeded" }))
	assert(tools.status(success.identity).status == "succeeded")

	local missing = spec("legacy-unattested")
	attestation_failure[missing.identity.name] = true
	assert(tools.import_legacy(missing, { status = "succeeded" }))
	assert(tools.status(missing.identity).status == "repair-required")
end)

test("dead locks recover while hostile state and shim targets fail closed", function()
	configure()
	local value = spec("stale")
	local plan = assert(tools.plan(value))
	local lock_dir = state .. "/locks/identity"
	assert(vim.fn.mkdir(lock_dir, "p") >= 0)
	local lock = lock_dir .. "/" .. plan.identity_key .. ".lock"
	assert(vim.fn.writefile({
		vim.json.encode({
			schema = 1,
			pid = 2147483647,
			key = plan.identity_key,
			identity_key = plan.identity_key,
		}),
	}, lock) == 0)
	assert(vim.uv.fs_chmod(lock, tonumber("600", 8)))
	local stale = claim(value)
	assert(tools.run(stale))
	assert(pending.stale)
	pending.stale(true)

	local hostile = spec("hostile")
	local hostile_plan = assert(tools.plan(hostile))
	assert(vim.fn.writefile({ "do not replace" }, hostile_plan.shim_path) == 0)
	local hostile_claim = claim(hostile)
	assert(tools.run(hostile_claim))
	pending.hostile(true)
	assert(tools.status(hostile.identity).detail == "shim-target-unsafe")

	local linked = spec("linked-record")
	local linked_plan = assert(tools.plan(linked))
	local outside = fixture .. "/outside-record"
	assert(vim.fn.writefile({ "{}" }, outside) == 0)
	assert(vim.uv.fs_symlink(outside, state .. "/records/" .. linked_plan.identity_key .. ".json"))
	local linked_claim, linked_err = tools.claim(linked_plan)
	assert(linked_claim == nil and linked_err == "unsafe")
	assert(vim.uv.fs_lstat(state .. "/records/" .. linked_plan.identity_key .. ".json").type == "link")
	for _, record in ipairs(tools.status()) do
		assert(record.identity.name ~= "linked-record", "unsafe record leaked through status list")
	end
end)

test("symlinked state roots are rejected before permissions are changed", function()
	local target = fixture .. "/state-target"
	local link = fixture .. "/state-link"
	assert(vim.fn.mkdir(target, "p") == 1)
	assert(vim.uv.fs_symlink(target, link))
	tools._reset_for_tests()
	tools.setup({
		state_root = link,
		backends = { release = backend("release") },
		network_authorized = function()
			return true
		end,
	})
	local value = spec("unsafe-state")
	local plan = assert(tools.plan(value))
	local claimed, err = tools.claim(plan)
	assert(claimed == nil and err:find("not a real directory", 1, true))
	assert(vim.uv.fs_lstat(link).type == "link")
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("verified_tools_spec: %d tests passed", count))
vim.cmd("quitall!")
