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

test("record FFI ABI selection uses exact Darwin and Linux directory-removal flags", function()
	local darwin = assert(tools._record_ffi_abi_for_tests("Darwin"))
	local linux = assert(tools._record_ffi_abi_for_tests("Linux"))
	assert(darwin.system == "Darwin" and darwin.at_removedir == 0x80 and darwin.eexist == 17)
	assert(linux.system == "Linux" and linux.at_removedir == 0x200 and linux.eexist == 17)

	local active = assert(tools._record_ffi_abi_for_tests())
	assert(active.system == vim.uv.os_uname().sysname)
	assert(active.at_removedir == (active.system == "Darwin" and 0x80 or 0x200))

	darwin.at_removedir = 0
	assert(tools._record_ffi_abi_for_tests("Darwin").at_removedir == 0x80)
	local unsupported, unsupported_err = tools._record_ffi_abi_for_tests("FreeBSD")
	assert(unsupported == nil and unsupported_err == "unsupported record FFI ABI: FreeBSD")
end)

test("pre-setup status and effective defaults are pure and unknown options are transactional", function()
	tools._reset_for_tests()
	local status = tools.status()
	assert(status.configured == false and vim.deep_equal(status.jobs, {}))
	local effective = tools.effective_config()
	assert(effective.lock_retry_ms == 25 and vim.deep_equal(effective.backends, {}))
	effective.backends[1] = "mutated"
	assert(vim.deep_equal(tools.effective_config().backends, {}), "default effective config shares state")
	local ok, err = pcall(tools.setup, { state_root = "/tmp", injected = true })
	assert(not ok and tostring(err):find("unknown option", 1, true))
	assert(vim.deep_equal(status, tools.status()), "rejected setup mutated aggregate status")
end)

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local state
local case_number = 0
local pending
local timers
local network
local external
local cancelled
local attestations
local attestation_failure
local attestation_override
local attested_evidence
local hold_attestation
local pending_attestation
local probe_count
local instance_token
local backend_observer

local function mkdir(path)
	assert(vim.fn.mkdir(path, "p") >= 0)
end

local function write_file(path, contents, mode)
	mkdir(vim.fs.dirname(path))
	local fd = assert(vim.uv.fs_open(path, "w", mode or tonumber("600", 8)))
	assert(vim.uv.fs_write(fd, contents, 0) == #contents)
	assert(vim.uv.fs_close(fd))
	assert(vim.uv.fs_chmod(path, mode or tonumber("600", 8)))
	return path
end

local function read_file(path)
	local fd = assert(vim.uv.fs_open(path, "r", 0))
	local stat = assert(vim.uv.fs_fstat(fd))
	local contents = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return contents
end

local function executable(install_root, name)
	local bin = install_root .. "/bin"
	mkdir(bin)
	local path = bin .. "/" .. name
	write_file(path, "#!/bin/sh\nexit 0\n", tonumber("700", 8))
	return path
end

local function normalized_executables(value)
	local result = {}
	if #value > 0 then
		for _, command in ipairs(value) do
			result[command] = command
		end
	else
		for command, installed_name in pairs(value) do
			result[command] = installed_name
		end
	end
	return result
end

local function install_release(plan)
	local evidence = {
		kind = "release-install-evidence",
		archive_sha256 = plan.manifest.integrity.archive_sha256,
		artifacts = {},
	}
	local observed = {
		kind = "release-sha256",
		archive_sha256 = plan.manifest.integrity.archive_sha256,
		commands = {},
		artifacts = {},
	}
	for command, relative in pairs(plan.manifest.integrity.commands) do
		local contents = ("#!/bin/sh\n# %s:%s\nexit 0\n"):format(plan.identity.name, command)
		local path = write_file(vim.fs.joinpath(plan.identity.install_root, relative), contents, tonumber("700", 8))
		evidence.artifacts[relative] = vim.fn.sha256(contents)
		observed.commands[command] = path
	end
	for _, relative in ipairs(plan.manifest.integrity.artifacts) do
		local contents = ("artifact:%s:%s\n"):format(plan.identity.name, relative)
		local path = write_file(vim.fs.joinpath(plan.identity.install_root, relative), contents)
		evidence.artifacts[relative] = vim.fn.sha256(contents)
		observed.artifacts[relative] = path
	end
	return evidence, observed
end

local function install_mason(plan, options)
	options = options or {}
	local integrity = plan.manifest.integrity
	local receipt_path = vim.fs.joinpath(plan.identity.install_root, integrity.receipt_path)
	write_file(receipt_path, vim.json.encode(integrity.receipt) .. "\n", options.receipt_mode or tonumber("600", 8))
	local observed = {
		kind = "mason-local-integrity",
		receipt_path = receipt_path,
		commands = {},
	}
	for command, relative in pairs(integrity.commands) do
		local target = vim.fs.joinpath(
			plan.identity.install_root,
			"packages",
			plan.identity.name,
			"bin",
			plan.executables[command]
		)
		write_file(target, ("#!/bin/sh\n# mason:%s\nexit 0\n"):format(command), tonumber("700", 8))
		local command_path = vim.fs.joinpath(plan.identity.install_root, relative)
		mkdir(vim.fs.dirname(command_path))
		assert(vim.uv.fs_symlink(target, command_path))
		observed.commands[command] = command_path
	end
	return nil, observed
end

local function backend(backend_name)
	return {
		run = function(plan, done, control)
			assert(plan.backend == backend_name)
			if backend_observer then
				backend_observer(plan)
			end
			pending[plan.identity.name] = { done = done, plan = plan }
			control.set_cancel(function()
				cancelled[plan.identity.name] = (cancelled[plan.identity.name] or 0) + 1
			end)
		end,
		attest = function(plan, done, install_evidence)
			attestations[plan.identity.name] = (attestations[plan.identity.name] or 0) + 1
			attested_evidence[plan.identity.name] = vim.deepcopy(install_evidence)
			if attestation_failure[plan.identity.name] then
				done(false, "drifted")
				return
			end
			local observed = attestation_override[plan.identity.name]
			if type(observed) == "function" then
				observed = observed(plan, install_evidence)
			end
			if observed then
				if hold_attestation[plan.identity.name] then
					pending_attestation[plan.identity.name] = {
						done = done,
						observed = vim.deepcopy(observed),
					}
					return
				end
				done(true, vim.deepcopy(observed))
				return
			end
			done(false, "fixture omitted attestation observation")
		end,
	}
end

local function configure(options)
	options = options or {}
	tools._reset_for_tests()
	case_number = case_number + 1
	state = options.state or (fixture .. "/state-" .. case_number)
	pending = {}
	timers = {}
	network = true
	external = {}
	cancelled = {}
	attestations = {}
	attestation_failure = {}
	attestation_override = {}
	attested_evidence = {}
	hold_attestation = {}
	pending_attestation = {}
	probe_count = 0
	backend_observer = options.backend_observer
	instance_token = options.instance_token or string.rep("a", 64)
	local setup = {
		state_root = options.state_root or state,
		backends = { release = backend("release"), mason = backend("mason") },
		probe_external = function(identity, value)
			probe_count = probe_count + 1
			local observed = external[identity.name]
			if type(observed) == "function" then
				return observed(identity, value)
			end
			return vim.deepcopy(observed or { outcome = "absent" })
		end,
		network_authorized = function()
			return network
		end,
		defer = options.defer or function(callback)
			timers[#timers + 1] = callback
		end,
		instance_token = instance_token,
		lock_wait_ms = options.lock_wait_ms or 0,
		pid = options.pid,
		fail_persist = options.fail_persist,
		clock = options.clock,
		interleave = options.interleave,
		events = options.events,
		on_state_change = options.on_state_change,
		notify = options.notify,
	}
	if not options.use_default_liveness then
		setup.process_alive = options.process_alive
			or function(owner, token)
				if owner == (options.pid and options.pid() or vim.uv.os_getpid()) then
					return token == instance_token and true or nil
				end
				return false
			end
	end
	tools.setup(setup)
end

local function spec(name, options)
	options = options or {}
	local backend_name = options.backend or "release"
	local version = options.version or "1.0.0"
	local executables = options.executables or { options.command or name }
	local normalized = normalized_executables(executables)
	local archive_sha256 = options.archive_sha256 or vim.fn.sha256("archive:" .. name .. ":" .. version)
	local value = {
		identity = {
			backend = backend_name,
			name = name,
			version = version,
			target = "test-x86_64",
			digest = options.digest or ("sha256:" .. archive_sha256),
			install_root = options.root or (fixture .. "/install-" .. name .. "-" .. version),
		},
		manifest = { timeout_ms = 1000, marker = options.marker },
		executables = executables,
		requires_network = options.requires_network ~= false,
		force_managed = options.force_managed ~= false,
	}
	if not options.omit_integrity then
		local commands = {}
		for command, installed_name in pairs(normalized) do
			commands[command] = options.command_paths and options.command_paths[command]
				or vim.fs.joinpath("bin", installed_name)
		end
		if backend_name == "release" then
			value.manifest.integrity = {
				kind = "release-sha256",
				archive_sha256 = archive_sha256,
				commands = commands,
				artifacts = vim.deepcopy(options.artifacts or {}),
			}
		else
			value.manifest.integrity = {
				kind = "mason-local-integrity",
				receipt_path = options.receipt_path or "receipt.json",
				receipt = {
					package = name,
					version = version,
					source_version = options.source_version or ("mason-" .. version),
				},
				commands = commands,
			}
		end
	end
	return value
end

local function claim(value, mode)
	local plan = assert(tools.plan(value))
	return assert(tools.claim(plan, { mode = mode or "auto" }))
end

local function finish(name, options)
	options = options or {}
	local entry = assert(pending[name], "backend was not started for " .. name)
	pending[name] = nil
	if options.ok == false then
		entry.done(false, options.reason or "fixture backend failure")
		return
	end
	local evidence, observed
	if entry.plan.backend == "release" then
		evidence, observed = install_release(entry.plan)
	else
		evidence, observed = install_mason(entry.plan, options)
	end
	if type(options.evidence) == "function" then
		evidence = options.evidence(vim.deepcopy(evidence), entry.plan)
	elseif options.omit_evidence then
		evidence = nil
	elseif options.evidence ~= nil then
		evidence = vim.deepcopy(options.evidence)
	end
	if type(options.observed) == "function" then
		observed = options.observed(vim.deepcopy(observed), entry.plan)
	elseif options.observed ~= nil then
		observed = vim.deepcopy(options.observed)
	end
	attestation_override[name] = observed
	if entry.plan.backend == "mason" and evidence == nil then
		entry.done(true)
	else
		entry.done(true, evidence)
	end
end

local function complete_attestation(name, ok, value)
	local held = assert(pending_attestation[name], "attestation was not held for " .. name)
	pending_attestation[name] = nil
	held.done(ok ~= false, value or held.observed)
end

local function record_path(plan)
	return state .. "/records/" .. plan.identity_key .. ".json"
end

local function write_private(path, value)
	assert(vim.fn.mkdir(vim.fs.dirname(path), "p") >= 0)
	assert(vim.fn.writefile({ type(value) == "string" and value or vim.json.encode(value) }, path) == 0)
	assert(vim.uv.fs_chmod(path, tonumber("600", 8)))
end

local function schema2(plan, status, owner, token, proof)
	return {
		schema = 2,
		identity = vim.deepcopy(plan.identity),
		identity_key = plan.identity_key,
		status = status,
		generation = 1,
		updated_at = 1,
		pid = owner,
		instance_token = token or string.rep("b", 64),
		attempt = 1,
		plan = vim.deepcopy(plan),
		proof = vim.deepcopy(proof),
	}
end

local function claim_file(base, resource, owner, token, number)
	local path = ("%s.ticket.%020d.%s"):format(base, number or 1, token)
	write_private(path, {
		schema = 1,
		kind = "ticket",
		pid = owner,
		instance_token = string.rep("c", 64),
		token = token,
		resource = resource,
		number = number or 1,
	})
	return path
end

local function with_uv_override(name, replacement, callback)
	local original = assert(vim.uv[name])
	vim.uv[name] = function(...)
		return replacement(original, ...)
	end
	local ok, err = xpcall(callback, debug.traceback)
	vim.uv[name] = original
	if not ok then
		error(err, 0)
	end
end

local function with_uv_overrides(replacements, callback)
	local originals = {}
	for name, replacement in pairs(replacements) do
		originals[name] = assert(vim.uv[name])
		vim.uv[name] = function(...)
			return replacement(originals[name], ...)
		end
	end
	local ok, err = xpcall(callback, debug.traceback)
	for name, original in pairs(originals) do
		vim.uv[name] = original
	end
	if not ok then
		error(err, 0)
	end
end

if vim.env.VERIFIED_TOOLS_RECORD_CRASH_CHILD == "1" then
	local crash_state = assert(vim.env.VERIFIED_TOOLS_RECORD_CRASH_STATE)
	local crash_root = assert(vim.env.VERIFIED_TOOLS_RECORD_CRASH_INSTALL_ROOT)
	local crash_ready = assert(vim.env.VERIFIED_TOOLS_RECORD_CRASH_READY)
	configure({
		state = crash_state,
		instance_token = string.rep("d", 64),
		use_default_liveness = true,
		interleave = function(stage)
			if stage ~= "after-record-exchange" then
				return
			end
			assert(vim.fn.writefile({ "ready" }, crash_ready) == 0)
			vim.wait(60000, function()
				return false
			end, 10)
			error("record exchange crash child was not killed")
		end,
	})
	local crash_plan = assert(tools.plan(spec("record-exchange-crash", { root = crash_root })))
	assert(tools.claim(crash_plan, { mode = "repair" }))
	error("record exchange crash child unexpectedly completed")
end

test("integrity is required and normalized plans reject unknown or mutated fields", function()
	configure()
	local missing = spec("missing-integrity", { omit_integrity = true })
	local missing_plan, missing_err = tools.plan(missing)
	assert(missing_plan == nil and missing_err == "manifest.integrity is required")
	for _, bad in ipairs({ "../escape", "dir/tool", "/absolute", "..", "bad command" }) do
		local value = spec("unsafe-" .. vim.fn.sha256(bad):sub(1, 8), { executables = { bad } })
		assert(tools.plan(value) == nil, "unsafe command was accepted: " .. bad)
	end
	assert(tools.plan(spec("duplicate", { executables = { "same", "same" } })) == nil)
	assert(tools.plan(spec("duplicate-target", { executables = { one = "same", two = "same" } })) == nil)
	local mapped = assert(tools.plan(spec("mapped", {
		executables = { public = "private-bin", helper = "helper-bin" },
	})))
	assert(mapped.executables.public == "private-bin" and mapped.executables.helper == "helper-bin")
	assert(mapped.manifest.integrity.commands.public == "bin/private-bin")
	assert(probe_count == 0, "force_managed unexpectedly probed the host")
	local unknown = vim.deepcopy(mapped)
	unknown.unexpected = true
	local rejected, reason = tools.claim(unknown)
	assert(rejected == nil and reason == "normalized plan contains unknown fields")
	local mutated = vim.deepcopy(mapped)
	mutated.manifest.marker = "changed"
	rejected, reason = tools.claim(mutated)
	assert(rejected == nil and reason == "normalized plan was modified")
end)

test("external probe outcomes are strict and force_managed bypasses probing", function()
	configure()
	external.absent = { outcome = "absent" }
	local absent = assert(tools.plan(spec("absent", { force_managed = false })))
	assert(absent.strategy == "managed" and absent.probe.outcome == "absent")
	external.incompatible = { outcome = "incompatible", version = "0.9.0", detail = "too old" }
	local incompatible = assert(tools.plan(spec("incompatible", { force_managed = false })))
	assert(incompatible.strategy == "managed" and incompatible.probe.outcome == "incompatible")
	local hosted_path = executable(fixture .. "/external-compatible", "hosted-cli")
	external.compatible = {
		outcome = "compatible",
		version = "1.0.0",
		paths = { ["hosted-cli"] = hosted_path },
	}
	local compatible = assert(tools.plan(spec("compatible", {
		command = "hosted-cli",
		force_managed = false,
	})))
	assert(compatible.strategy == "external")
	assert(compatible.probe.paths["hosted-cli"].lexical == hosted_path)
	assert(compatible.probe.paths["hosted-cli"].fingerprint.path == hosted_path)
	assert(assert(tools.claim(compatible)).external == true)
	external.probe_error = { outcome = "error", detail = "registry unavailable\nretry later" }
	local errored, error_reason = tools.plan(spec("probe_error", { force_managed = false }))
	assert(errored == nil and error_reason == "external probe error: registry unavailable retry later")
	external.probe_throw = function()
		error("probe exploded")
	end
	local crashed, crash_reason = tools.plan(spec("probe_throw", { force_managed = false }))
	assert(crashed == nil and crash_reason:find("external probe crashed:", 1, true))
	external.bad_absent = { outcome = "absent", detail = "not allowed" }
	local invalid, invalid_reason = tools.plan(spec("bad_absent", { force_managed = false }))
	assert(invalid == nil and invalid_reason == "absent probe outcome contains unknown fields")
	external.bad_version = {
		outcome = "compatible",
		version = "2.0.0",
		paths = { ["bad-version-cli"] = hosted_path },
	}
	invalid, invalid_reason = tools.plan(spec("bad_version", {
		command = "bad-version-cli",
		force_managed = false,
	}))
	assert(invalid == nil and invalid_reason == "compatible probe outcome is invalid")
	local before_force = probe_count
	external.forced = function()
		error("must not run")
	end
	local forced = assert(tools.plan(spec("forced")))
	assert(forced.strategy == "managed" and forced.force_managed == true)
	assert(probe_count == before_force)
end)

test("identity destination and every shim remain scheduler and cross-process resources", function()
	configure()
	local first = claim(spec("resource-one", { root = fixture .. "/resource-root-a", command = "shared-cli" }))
	local second = claim(spec("resource-one", {
		root = fixture .. "/resource-root-b",
		command = "shared-cli",
		version = "2.0.0",
	}))
	assert(tools.run(first))
	assert(tools.run(second))
	local jobs = tools.jobs()
	assert(#jobs == 2 and jobs[1].status == "queued" and jobs[1].queue_position == 1)
	assert(jobs[2].status == "running" and jobs[2].queue_position == nil)
	assert(type(jobs[1].identity) == "table" and type(jobs[1].resources) == "table")
	jobs[1].resources[1] = "mutated"
	assert(tools.jobs()[1].resources[1] ~= "mutated", "jobs shares resource state")
	local aggregate = tools.status()
	assert(aggregate.configured == true and vim.deep_equal(aggregate.jobs, tools.jobs()))
	local queued, active = tools._queue_size()
	assert(queued == 1 and active == 1, "same shim ran concurrently across install roots")
	local resource_claims = vim.fn.glob(state .. "/locks/resources/*.ticket.*", false, true)
	assert(#resource_claims == #first.plan.resources, "not every resource has a cross-process claim")
	finish("resource-one")
	assert(pending["resource-one"], "shim-conflicting queued job did not resume")
	finish("resource-one")
	local shared_root = fixture .. "/resource-shared-destination"
	mkdir(shared_root)
	local third = claim(spec("resource-three", { root = shared_root, command = "third-cli" }))
	local fourth = claim(spec("resource-four", { root = shared_root, command = "fourth-cli" }))
	assert(tools.run(third))
	assert(tools.run(fourth))
	queued, active = tools._queue_size()
	assert(queued == 1 and active == 1, "same install destination ran concurrently")
	finish("resource-three")
	assert(pending["resource-four"], "destination-conflicting queued job did not resume")
	finish("resource-four")
end)

test("cross-engine lock contention requeues without a terminal failure", function()
	local first_token = string.rep("1", 64)
	local second_token = string.rep("2", 64)
	local function both_instances_alive(owner, token)
		if owner ~= vim.uv.os_getpid() then
			return false
		end
		return (token == first_token or token == second_token) and true or nil
	end
	configure({ instance_token = first_token, process_alive = both_instances_alive })
	local first = claim(spec("cross-engine-tool", {
		command = "cross-engine-cli",
		root = fixture .. "/cross-engine-v1",
		version = "1.0.0",
	}))
	local second_engine = assert(loadfile(plugin .. "/lua/verified_tools/init.lua"))()
	local second_pending = {}
	local second_observed = {}
	local retries = {}
	second_engine.setup({
		state_root = state,
		backends = {
			release = {
				run = function(plan, done, control)
					second_pending[plan.identity.name] = { plan = plan, done = done }
					control.set_cancel(function() end)
				end,
				attest = function(plan, done)
					done(true, assert(second_observed[plan.identity.name]))
				end,
			},
		},
		probe_external = function()
			return { outcome = "absent" }
		end,
		network_authorized = function()
			return true
		end,
		process_alive = both_instances_alive,
		defer = function(callback)
			retries[#retries + 1] = callback
		end,
		instance_token = second_token,
		lock_wait_ms = 0,
	})
	local second_plan = assert(second_engine.plan(spec("cross-engine-tool", {
		command = "cross-engine-cli",
		root = fixture .. "/cross-engine-v2",
		version = "2.0.0",
	})))
	local second = assert(second_engine.claim(second_plan))
	assert(tools.run(first))
	assert(second_engine.run(second))
	local queued, active = second_engine._queue_size()
	assert(queued == 1 and active == 0)
	assert(second_pending["cross-engine-tool"] == nil)
	assert(second_engine.status(second.identity).status == "queued")
	assert(#retries >= 1)
	finish("cross-engine-tool")
	retries[1]()
	local entry = assert(second_pending["cross-engine-tool"], "contended engine was not retried")
	local evidence, observed = install_release(entry.plan)
	second_observed[entry.plan.identity.name] = observed
	entry.done(true, evidence)
	assert(second_engine.status(second.identity).status == "succeeded")
	second_engine._reset_for_tests()
end)

test("release and Mason share exactly two global slots", function()
	configure()
	local first = claim(spec("slot-release", { backend = "release" }))
	local second = claim(spec("slot-mason", { backend = "mason" }))
	local third = claim(spec("slot-waiting", { backend = "release" }))
	assert(tools.run(first) and tools.run(second) and tools.run(third))
	local queued, active = tools._queue_size()
	assert(queued == 1 and active == 2)
	finish("slot-release")
	queued, active = tools._queue_size()
	assert(queued == 0 and active == 2)
	finish("slot-mason")
	finish("slot-waiting")
end)

test("queued jobs reject an install root replaced before backend start", function()
	configure()
	local first = claim(spec("root-guard-slot-one"))
	local second = claim(spec("root-guard-slot-two"))
	local guarded = claim(spec("root-guard-queued"))
	assert(tools.run(first) and tools.run(second) and tools.run(guarded))
	local queued, active = tools._queue_size()
	assert(queued == 1 and active == 2 and pending["root-guard-queued"] == nil)
	local substitute = fixture .. "/queued-root-substitute"
	mkdir(substitute)
	assert(vim.uv.fs_symlink(substitute, guarded.identity.install_root))
	finish("root-guard-slot-one")
	assert(pending["root-guard-queued"] == nil, "unsafe queued job reached its backend")
	local stored, status_err = tools.status(guarded.identity)
	assert(stored, tostring(status_err) .. "\n" .. read_file(record_path(guarded.plan)))
	assert(stored.status == "failed")
	assert(stored.detail == "install destination was replaced by a non-directory or symlink")
	assert(vim.uv.fs_lstat(guarded.identity.install_root).type == "link")
	finish("root-guard-slot-two")
end)

test("attestation rejects an install root substituted after backend acknowledgement", function()
	configure()
	local guarded = claim(spec("root-guard-attesting"))
	hold_attestation["root-guard-attesting"] = true
	assert(tools.run(guarded))
	finish("root-guard-attesting")
	assert(pending_attestation["root-guard-attesting"])
	local displaced = guarded.identity.install_root .. ".displaced"
	assert(vim.uv.fs_rename(guarded.identity.install_root, displaced))
	local substitute = fixture .. "/attesting-root-substitute"
	mkdir(substitute)
	assert(vim.uv.fs_symlink(substitute, guarded.identity.install_root))
	complete_attestation("root-guard-attesting")
	local stored, status_err = tools.status(guarded.identity)
	assert(stored, tostring(status_err) .. "\n" .. read_file(record_path(guarded.plan)))
	assert(stored.status == "failed")
	assert(stored.detail == "install destination was replaced by a non-directory or symlink")
	assert(vim.uv.fs_lstat(guarded.identity.install_root).type == "link")
	assert(vim.uv.fs_lstat(displaced).type == "directory")
end)

test("offline denial does not consume the one-shot attempt", function()
	configure()
	network = false
	local plan = assert(tools.plan(spec("offline")))
	local claimed, reason, blocked = tools.claim(plan)
	assert(claimed == nil and reason == "blocked/offline" and blocked.status == "blocked")
	assert(tools.status(plan.identity) == nil)
	network = true
	assert(tools.claim(plan), "offline denial consumed the automatic attempt")
end)

test("release success requires install evidence and persists exact observed fingerprints", function()
	configure()
	local callback_result
	local managed = claim(spec("release-evidence", {
		executables = { public = "private-bin", helper = "helper-bin" },
		artifacts = { "share/release.json" },
	}))
	assert(tools.run(managed, function(ok, reason, proof)
		callback_result = { ok = ok, reason = reason, proof = proof }
	end))
	finish("release-evidence")
	assert(callback_result.ok == true, tostring(callback_result.reason))
	local proof = assert(callback_result.proof)
	assert(proof.kind == "release-sha256" and proof.version == 1)
	assert(proof.commands.public.path == vim.uv.fs_realpath(managed.identity.install_root .. "/bin/private-bin"))
	assert(proof.artifacts["share/release.json"].path == managed.identity.install_root .. "/share/release.json")
	local evidence = assert(attested_evidence["release-evidence"])
	assert(evidence.kind == "release-install-evidence")
	assert(evidence.artifacts["bin/private-bin"] == proof.commands.public.sha256)
	assert(evidence.artifacts["share/release.json"] == proof.artifacts["share/release.json"].sha256)
	local stored = assert(tools.status(managed.identity))
	assert(stored.status == "succeeded" and vim.deep_equal(stored.proof, proof))
end)

test("release post-commit warnings remain successful and visible", function()
	local notices = {}
	configure({
		notify = function(message, level)
			notices[#notices + 1] = { message = message, level = level }
		end,
	})
	local callback_result
	local managed = claim(spec("release-warning"))
	assert(tools.run(managed, function(ok, reason)
		callback_result = { ok = ok, reason = reason }
	end))
	finish("release-warning", {
		evidence = function(evidence)
			evidence.warnings = { "parent-fsync-failed", "cleanup-retained" }
			return evidence
		end,
	})
	local warning = "parent-fsync-failed; cleanup-retained"
	assert(callback_result.ok == true and callback_result.reason == warning)
	local stored = assert(tools.status(managed.identity))
	assert(stored.status == "succeeded" and stored.detail == warning)
	assert(vim.deep_equal(attested_evidence["release-warning"].warnings, {
		"parent-fsync-failed",
		"cleanup-retained",
	}))
	assert(#notices == 1 and notices[1].message:find(warning, 1, true))
end)

test("release evidence and observation envelopes are exact", function()
	configure()
	local missing = claim(spec("release-missing-evidence"))
	assert(tools.run(missing))
	finish("release-missing-evidence", { omit_evidence = true })
	local status = assert(tools.status(missing.identity))
	assert(status.status == "failed" and status.detail == "release install evidence is missing or invalid")
	local mismatch = claim(spec("release-evidence-mismatch"))
	assert(tools.run(mismatch))
	finish("release-evidence-mismatch", {
		evidence = function(evidence)
			evidence.artifacts["bin/release-evidence-mismatch"] = string.rep("0", 64)
			return evidence
		end,
	})
	status = assert(tools.status(mismatch.identity))
	assert(status.status == "failed" and status.detail == "release command digest differs from install evidence")
	local extra = claim(spec("release-extra-observation"))
	assert(tools.run(extra))
	finish("release-extra-observation", {
		observed = function(observed)
			observed.unexpected = true
			return observed
		end,
	})
	status = assert(tools.status(extra.identity))
	assert(status.status == "failed" and status.detail == "release attestation observation is invalid")
	local inexact = claim(spec("release-inexact-path"))
	assert(tools.run(inexact))
	finish("release-inexact-path", {
		observed = function(observed, plan)
			observed.commands["release-inexact-path"] =
				executable(plan.identity.install_root .. "/alternate", "release-inexact-path")
			return observed
		end,
	})
	status = assert(tools.status(inexact.identity))
	assert(status.status == "failed" and status.detail == "release commands path is not exact for release-inexact-path")
end)

test("Mason requires a private receipt and accepts only canonical-contained command symlinks", function()
	configure()
	local mason = claim(spec("mason-receipt", {
		backend = "mason",
		executables = { mason_cli = "mason-real" },
	}))
	assert(tools.run(mason))
	finish("mason-receipt")
	local stored = assert(tools.status(mason.identity))
	assert(stored.status == "succeeded", tostring(stored.detail))
	assert(stored.proof.kind == "mason-local-integrity")
	local receipt_path = mason.identity.install_root .. "/receipt.json"
	assert(vim.uv.fs_lstat(receipt_path).mode % 512 == tonumber("600", 8))
	local command_path = mason.identity.install_root .. "/bin/mason-real"
	assert(vim.uv.fs_lstat(command_path).type == "link")
	local canonical = assert(vim.uv.fs_realpath(command_path))
	assert(canonical:find(mason.identity.install_root .. "/packages/", 1, true) == 1)
	assert(stored.proof.commands.mason_cli.path == canonical)
	assert(attested_evidence["mason-receipt"] == nil)
	local public_receipt = claim(spec("mason-public-receipt", { backend = "mason" }))
	assert(tools.run(public_receipt))
	finish("mason-public-receipt", { receipt_mode = tonumber("644", 8) })
	stored = assert(tools.status(public_receipt.identity))
	assert(stored.status == "failed" and stored.detail == "Mason receipt is unsafe: unsafe")
end)

test("Mason backend evidence must be absent", function()
	configure()
	local mason = claim(spec("mason-unexpected-evidence", { backend = "mason" }))
	assert(tools.run(mason))
	finish("mason-unexpected-evidence", { evidence = { unexpected = true } })
	local stored = assert(tools.status(mason.identity))
	assert(stored.status == "failed" and stored.detail == "Mason install evidence must be absent")
end)

test("attestation observations require exact lexical command artifact and receipt paths", function()
	configure()
	local command_alias = claim(spec("release-command-alias"))
	assert(tools.run(command_alias))
	finish("release-command-alias", {
		observed = function(observed, plan)
			observed.commands[plan.identity.name] = plan.identity.install_root .. "/bin/../bin/" .. plan.identity.name
			return observed
		end,
	})
	local stored = assert(tools.status(command_alias.identity))
	assert(stored.status == "failed" and stored.detail:find("path is not exact", 1, true), vim.inspect(stored))

	local artifact_alias = claim(spec("release-artifact-alias", { artifacts = { "share/result.json" } }))
	assert(tools.run(artifact_alias))
	finish("release-artifact-alias", {
		observed = function(observed, plan)
			observed.artifacts["share/result.json"] = plan.identity.install_root .. "/share/../share/result.json"
			return observed
		end,
	})
	stored = assert(tools.status(artifact_alias.identity))
	assert(stored.status == "failed" and stored.detail:find("path is not exact", 1, true), vim.inspect(stored))

	local receipt_alias = claim(spec("mason-receipt-alias", { backend = "mason" }))
	assert(tools.run(receipt_alias))
	finish("mason-receipt-alias", {
		observed = function(observed, plan)
			observed.receipt_path = plan.identity.install_root .. "/./receipt.json"
			return observed
		end,
	})
	stored = assert(tools.status(receipt_alias.identity))
	assert(stored.status == "failed" and stored.detail == "Mason receipt path is not exact", vim.inspect(stored))
end)

test("manual release attestation preserves an unchanged baseline and detects tampering", function()
	configure()
	local release = claim(spec("release-manual-attest", { artifacts = { "share/manual.json" } }))
	assert(tools.run(release))
	finish("release-manual-attest")
	local baseline = assert(tools.status(release.identity)).proof
	local unchanged
	assert(tools.attest(release.identity, function(ok, value)
		unchanged = { ok = ok, value = value }
	end))
	assert(unchanged.ok == true and vim.deep_equal(unchanged.value, baseline))
	assert(vim.deep_equal(assert(tools.status(release.identity)).proof, baseline))
	write_file(
		release.identity.install_root .. "/bin/release-manual-attest",
		"#!/bin/sh\n# tampered\nexit 0\n",
		tonumber("700", 8)
	)
	local drifted
	assert(tools.attest({ identity = release.identity }, function(ok, value)
		drifted = { ok = ok, value = value }
	end))
	assert(drifted.ok == false and drifted.value == "release command digest differs from install evidence")
	local stored = assert(tools.status(release.identity))
	assert(stored.status == "drift" and stored.detail == drifted.value)
	assert(vim.deep_equal(stored.proof, baseline), "drift replaced the last verified baseline")
end)

test("manual Mason attestation preserves an unchanged baseline and detects receipt tampering", function()
	configure()
	local mason = claim(spec("mason-manual-attest", { backend = "mason" }))
	assert(tools.run(mason))
	finish("mason-manual-attest")
	local baseline = assert(tools.status(mason.identity)).proof
	local unchanged
	assert(tools.attest(mason.identity, function(ok, value)
		unchanged = { ok = ok, value = value }
	end))
	assert(unchanged.ok == true and vim.deep_equal(unchanged.value, baseline))
	local receipt_path = mason.identity.install_root .. "/receipt.json"
	write_file(receipt_path, vim.json.encode({
		package = mason.identity.name,
		version = mason.identity.version,
		source_version = "tampered",
	}) .. "\n")
	local drifted
	assert(tools.attest(mason.identity, function(ok, value)
		drifted = { ok = ok, value = value }
	end))
	assert(drifted.ok == false and drifted.value == "Mason on-disk receipt is invalid")
	local stored = assert(tools.status(mason.identity))
	assert(stored.status == "drift" and stored.detail == drifted.value)
	assert(vim.deep_equal(stored.proof, baseline), "drift replaced the last verified baseline")
end)

test("legacy import accepts only verified private origins and persists normalized plan proof", function()
	configure()
	local release_spec = spec("legacy-release-accepted")
	local release_plan = assert(tools.plan(release_spec))
	local release_evidence, release_observed = install_release(release_plan)
	attestation_override["legacy-release-accepted"] = release_observed
	local release_result
	assert(tools.import_legacy(release_spec, {
		status = "succeeded",
		origin = "verified-private-install-receipt-v1",
		install_evidence = release_evidence,
	}, function(ok, value)
		release_result = { ok = ok, value = value }
	end))
	assert(release_result.ok == true and release_result.value.kind == "release-sha256")
	local stored = assert(tools.status(release_plan.identity))
	assert(stored.status == "succeeded" and stored.plan and stored.proof)
	assert(stored.plan.plan_digest and vim.deep_equal(stored.proof, release_result.value))
	local rejected_release_spec = spec("legacy-release-rejected")
	local rejected_release = assert(tools.import_legacy(rejected_release_spec, {
		status = "succeeded",
		origin = "unverified-release-origin",
		install_evidence = {},
	}))
	assert(rejected_release.status == "repair-required")
	assert(rejected_release.detail == "legacy-release-evidence-origin-invalid")
	local mason_spec = spec("legacy-mason-accepted", { backend = "mason" })
	local mason_plan = assert(tools.plan(mason_spec))
	local _, mason_observed = install_mason(mason_plan)
	attestation_override["legacy-mason-accepted"] = mason_observed
	local mason_result
	assert(tools.import_legacy(mason_spec, {
		status = "succeeded",
		origin = "verified-private-mason-receipt-v1",
	}, function(ok, value)
		mason_result = { ok = ok, value = value }
	end))
	assert(mason_result.ok == true and mason_result.value.kind == "mason-local-integrity")
	stored = assert(tools.status(mason_plan.identity))
	assert(stored.status == "succeeded" and stored.plan and stored.proof)
	assert(stored.plan.plan_digest and vim.deep_equal(stored.proof, mason_result.value))
	local rejected_mason_spec = spec("legacy-mason-rejected", { backend = "mason" })
	local rejected_mason = assert(tools.import_legacy(rejected_mason_spec, {
		status = "succeeded",
		origin = "unverified-Mason-origin",
	}))
	assert(rejected_mason.status == "repair-required")
	assert(rejected_mason.detail == "legacy-Mason-evidence-origin-invalid")
end)

test("shim ownership rejects theft but allows an explicit same-tool upgrade", function()
	configure()
	local original = claim(spec("owner-tool", { root = fixture .. "/owner-v1", command = "owned-cli" }))
	assert(tools.run(original))
	finish("owner-tool")
	local thief = claim(spec("different-tool", { root = fixture .. "/thief", command = "owned-cli" }))
	assert(tools.run(thief))
	local thief_status = assert(tools.status(thief.identity))
	assert(
		thief_status.status == "repair-required" and thief_status.detail:find("shim-owned-by-different-tool", 1, true)
	)
	local upgrade = claim(spec("owner-tool", {
		root = fixture .. "/owner-v2",
		command = "owned-cli",
		version = "2.0.0",
	}))
	assert(tools.run(upgrade))
	finish("owner-tool")
	assert(vim.uv.fs_realpath(upgrade.plan.shims["owned-cli"]):find("/owner-v2/", 1, true))
end)

test("backend start invalidates the prior PlantUML shim before partial JAR promotion", function()
	local enabled = false
	local observed = false
	local install_root = fixture .. "/plantuml-managed"
	local shim
	local owner
	configure({
		backend_observer = function(plan)
			if not enabled or plan.identity.name ~= "plantuml" then
				return
			end
			observed = true
			assert(vim.uv.fs_lstat(shim) == nil, "prior PlantUML shim remained executable during install")
			assert(vim.uv.fs_lstat(owner) == nil, "prior PlantUML owner proof remained published during install")
			write_file(vim.fs.joinpath(install_root, "plantuml.jar"), "partial-new-jar\n")
		end,
	})
	local original = claim(spec("plantuml", {
		root = install_root,
		command = "plantuml",
		artifacts = { "plantuml.jar" },
	}))
	assert(tools.run(original))
	finish("plantuml")
	shim = original.plan.shims.plantuml
	owner = vim.fs.joinpath(state, "shims", "owners", vim.fn.sha256("plantuml") .. ".json")
	assert(vim.uv.fs_lstat(shim) and vim.uv.fs_lstat(owner))
	enabled = true
	local upgrade = claim(spec("plantuml", {
		root = install_root,
		command = "plantuml",
		version = "2.0.0",
		artifacts = { "plantuml.jar" },
	}))
	assert(tools.run(upgrade))
	assert(observed and vim.uv.fs_lstat(shim) == nil and vim.uv.fs_lstat(owner) == nil)
	local installing = assert(tools.status(upgrade.identity))
	assert(installing.status == "running" and installing.proof == nil)
	assert(read_file(vim.fs.joinpath(install_root, "plantuml.jar")) == "partial-new-jar\n")
	finish("plantuml")
	assert(vim.uv.fs_lstat(shim) and vim.uv.fs_lstat(owner))
end)

test("multi-command shim promotion rolls back partial work and never overwrites an unowned target", function()
	configure()
	local multi = claim(spec("shim-transaction", {
		executables = { alpha = "alpha-real", beta = "beta-real" },
	}))
	assert(tools.run(multi))
	local fired = false
	with_uv_override("fs_symlink", function(original, source, destination)
		if destination == multi.plan.shims.beta then
			fired = true
			return nil, "EIO: injected partial promotion failure"
		end
		return original(source, destination)
	end, function()
		finish("shim-transaction")
	end)
	assert(fired)
	local stored = assert(tools.status(multi.identity))
	assert(stored.status == "failed" and stored.detail:find("shim-promote-failed", 1, true))
	assert(vim.uv.fs_lstat(multi.plan.shims.alpha) == nil)
	assert(vim.uv.fs_lstat(multi.plan.shims.beta) == nil)
	assert(#vim.fn.glob(state .. "/shims/owners/*.json", false, true) == 0)
	local protected_plan = assert(tools.plan(spec("shim-no-overwrite", { command = "protected-cli" })))
	mkdir(vim.fs.dirname(protected_plan.shims["protected-cli"]))
	write_file(protected_plan.shims["protected-cli"], "human-owned\n")
	local protected_claim = assert(tools.claim(protected_plan))
	assert(tools.run(protected_claim))
	stored = assert(tools.status(protected_claim.identity))
	assert(stored.status == "repair-required")
	assert(read_file(protected_plan.shims["protected-cli"]) == "human-owned\n")
	assert(vim.uv.fs_lstat(protected_plan.shims["protected-cli"]).type == "file")
end)

test("schema-1 records project repair-required without rewrite", function()
	configure()
	local plan = assert(tools.plan(spec("schema-one")))
	assert(tools.claim(plan))
	write_private(record_path(plan), {
		schema = 1,
		identity = plan.identity,
		identity_key = plan.identity_key,
		status = "succeeded",
		generation = 7,
		updated_at = 1,
		pid = 12,
	})
	local projected = assert(tools.status(plan.identity))
	assert(projected.status == "repair-required" and projected.original_status == "succeeded")
	assert(vim.json.decode(read_file(record_path(plan))).schema == 1)
	local repaired = assert(tools.claim(plan, { mode = "repair" }))
	assert(repaired.record.schema == 2 and repaired.record.attempt == 1)
end)

test("randomized schema-1 filenames migrate canonically without deleting legacy state", function()
	configure()
	local plan = assert(tools.plan(spec("schema-one-randomized")))
	local legacy_key = string.rep("7", 64)
	assert(legacy_key ~= plan.identity_key)
	local legacy_path = state .. "/records/" .. legacy_key .. ".json"
	write_private(legacy_path, {
		schema = 1,
		identity = plan.identity,
		identity_key = legacy_key,
		status = "succeeded",
		generation = 9,
		updated_at = 2,
		pid = 12,
	})
	local projected = assert(tools.status(plan.identity))
	assert(projected.status == "repair-required" and projected.legacy_record_path == legacy_path)
	assert(vim.uv.fs_lstat(record_path(plan)) == nil)
	local repaired = assert(tools.claim(plan, { mode = "repair" }))
	assert(repaired.record.schema == 2 and repaired.record.identity_key == plan.identity_key)
	assert(vim.uv.fs_lstat(record_path(plan)).type == "file")
	assert(vim.uv.fs_lstat(legacy_path).type == "file", "explicit repair deleted legacy recovery state")
	local listed = assert(tools.records())
	assert(#listed == 1 and listed[1].schema == 2)

	configure()
	plan = assert(tools.plan(spec("schema-one-duplicate")))
	for index, digit in ipairs({ "8", "9" }) do
		local key = string.rep(digit, 64)
		write_private(state .. "/records/" .. key .. ".json", {
			schema = 1,
			identity = plan.identity,
			identity_key = key,
			status = "failed",
			generation = index,
			updated_at = index,
			pid = 12,
		})
	end
	local duplicate, duplicate_err = tools.status(plan.identity)
	assert(duplicate == nil and duplicate_err and duplicate_err:find("duplicate legacy", 1, true))
	local claim, claim_err = tools.claim(plan, { mode = "repair" })
	assert(claim == nil and claim_err and claim_err:find("duplicate legacy", 1, true))
end)

test("schema-2 succeeded records with missing or invalid proof require repair", function()
	configure()
	local missing = assert(tools.plan(spec("schema-two-missing-proof")))
	assert(tools.claim(missing))
	write_private(record_path(missing), schema2(missing, "succeeded", vim.uv.os_getpid(), instance_token))
	local projected = assert(tools.status(missing.identity))
	assert(projected.status == "repair-required")
	assert(projected.original_status == "succeeded" and projected.detail == "invalid-or-missing-proof")
	assert(tools.claim(missing, { mode = "repair" }))
	local invalid = assert(tools.plan(spec("schema-two-invalid-proof")))
	assert(tools.claim(invalid))
	write_private(
		record_path(invalid),
		schema2(invalid, "succeeded", vim.uv.os_getpid(), instance_token, { version = 1 })
	)
	projected = assert(tools.status(invalid.identity))
	assert(projected.status == "repair-required" and projected.detail == "invalid-or-missing-proof")
end)

test("default liveness binds own PID to its token and never guesses another PID owner", function()
	local synthetic_pid = 51001
	configure({
		use_default_liveness = true,
		pid = function()
			return synthetic_pid
		end,
	})
	local own = assert(tools.plan(spec("own-token")))
	write_private(record_path(own), schema2(own, "queued", synthetic_pid, instance_token))
	assert(tools.status(own.identity).status == "queued")
	local wrong = assert(tools.plan(spec("wrong-own-token")))
	write_private(record_path(wrong), schema2(wrong, "running", synthetic_pid, string.rep("b", 64)))
	local wrong_status, wrong_reason = tools.status(wrong.identity)
	assert(wrong_status == nil and wrong_reason == "owner-unverifiable")
	local other = assert(tools.plan(spec("other-process-token")))
	write_private(record_path(other), schema2(other, "claimed", vim.uv.os_getpid(), instance_token))
	local other_status, other_reason = tools.status(other.identity)
	assert(other_status == nil and other_reason == "owner-unverifiable")
end)

test("schema-2 active records distinguish dead live unknown and unsupported owners", function()
	local liveness = { [41001] = false, [41002] = true }
	configure({
		process_alive = function(owner, token)
			if owner == 41002 then
				assert(token == string.rep("d", 64))
			end
			return liveness[owner]
		end,
	})
	local dead_plan = assert(tools.plan(spec("dead-record")))
	write_private(record_path(dead_plan), schema2(dead_plan, "running", 41001, string.rep("c", 64)))
	local dead = assert(tools.status(dead_plan.identity))
	assert(dead.status == "repair-required" and dead.detail == "dead-owner")
	local live_plan = assert(tools.plan(spec("live-record")))
	write_private(record_path(live_plan), schema2(live_plan, "queued", 41002, string.rep("d", 64)))
	assert(tools.status(live_plan.identity).status == "queued")
	local unknown_plan = assert(tools.plan(spec("unknown-record")))
	write_private(record_path(unknown_plan), schema2(unknown_plan, "claimed", 41003, string.rep("e", 64)))
	local unknown, unknown_reason = tools.status(unknown_plan.identity)
	assert(unknown == nil and unknown_reason == "owner-unverifiable")
	local future_plan = assert(tools.plan(spec("future-record")))
	local future = schema2(future_plan, "failed", 41001, string.rep("f", 64))
	future.schema = 99
	write_private(record_path(future_plan), future)
	local future_status, future_reason = tools.status(future_plan.identity)
	assert(future_status == nil and future_reason == "unsupported-schema")
end)

test("running cancel is two-phase and post-cancel success is never attested", function()
	configure()
	local callback_result
	local running_claim = claim(spec("cancel-running"))
	assert(tools.run(running_claim, function(ok, reason)
		callback_result = { ok = ok, reason = reason }
	end))
	assert(tools.cancel(running_claim.identity))
	assert(cancelled["cancel-running"] == 1)
	local queued, active = tools._queue_size()
	assert(queued == 0 and active == 1, "cancel released the slot before backend acknowledgement")
	local cancelling = assert(tools.status(running_claim.identity))
	assert(cancelling.status == "running" and cancelling.detail == "cancelled")
	assert(tools.cancel(running_claim.identity) and cancelled["cancel-running"] == 1)
	finish("cancel-running")
	assert(attestations["cancel-running"] == nil, "post-cancel success was attested")
	assert(callback_result.ok == false and callback_result.reason == "cancelled")
	assert(tools.status(running_claim.identity).status == "cancelled")
	queued, active = tools._queue_size()
	assert(queued == 0 and active == 0)
end)

test("cancel after backend acknowledgement settles once and ignores a late attestation callback", function()
	configure()
	local callback_count = 0
	local callback_result
	local running_claim = claim(spec("cancel-attesting"))
	hold_attestation["cancel-attesting"] = true
	assert(tools.run(running_claim, function(ok, reason)
		callback_count = callback_count + 1
		callback_result = { ok = ok, reason = reason }
	end))
	finish("cancel-attesting")
	assert(pending_attestation["cancel-attesting"] and attestations["cancel-attesting"] == 1)
	assert(tools.status(running_claim.identity).status == "running")
	assert(tools.cancel(running_claim.identity))
	assert(callback_count == 1 and callback_result.ok == false and callback_result.reason == "cancelled")
	assert(tools.status(running_claim.identity).status == "cancelled")
	complete_attestation("cancel-attesting")
	assert(callback_count == 1, "late attestation callback settled the job twice")
	assert(tools.status(running_claim.identity).status == "cancelled")
	local queued, active = tools._queue_size()
	assert(queued == 0 and active == 0)
end)

test("queued and final persistence failures fail closed", function()
	local fail_queued = false
	configure({
		fail_persist = function(status)
			return fail_queued and status == "queued" and "queued-injected" or nil
		end,
	})
	local queued_claim = claim(spec("queued-persist-failure"))
	fail_queued = true
	local started, start_err = tools.run(queued_claim)
	assert(started == nil and start_err == "queued-injected")
	assert(pending["queued-persist-failure"] == nil)
	local queued, active = tools._queue_size()
	assert(queued == 0 and active == 0)
	assert(tools.status(queued_claim.identity).status == "claimed")
	local fail_final = false
	configure({
		fail_persist = function(status)
			return fail_final and status == "succeeded" and "final-injected" or nil
		end,
	})
	local final_result
	local final_claim = claim(spec("final-persist-failure"))
	assert(tools.run(final_claim, function(ok, reason)
		final_result = { ok = ok, reason = reason }
	end))
	fail_final = true
	finish("final-persist-failure")
	assert(final_result.ok == false and final_result.reason == "status-persist-failed: final-injected")
	local status = assert(tools.status(final_claim.identity))
	assert(status.status == "repair-required" and status.detail == final_result.reason)
	assert(vim.uv.fs_lstat(final_claim.plan.shims["final-persist-failure"]) == nil)
	queued, active = tools._queue_size()
	assert(queued == 0 and active == 0)
end)

test("queued cancellation persistence failure keeps the job queued and callback untouched", function()
	local fail_cancel = false
	configure({
		fail_persist = function(status, identity)
			return fail_cancel
					and status == "cancelled"
					and identity.name == "queued-cancel-persist"
					and "cancel-injected"
				or nil
		end,
	})
	local holder = claim(spec("queued-cancel-holder", {
		command = "queued-cancel-cli",
		root = fixture .. "/queued-cancel-holder",
	}))
	local callback_count = 0
	local waiter = claim(spec("queued-cancel-persist", {
		command = "queued-cancel-cli",
		root = fixture .. "/queued-cancel-waiter",
	}))
	assert(tools.run(holder))
	assert(tools.run(waiter, function()
		callback_count = callback_count + 1
	end))
	local queued, active = tools._queue_size()
	assert(queued == 1 and active == 1)
	fail_cancel = true
	local cancelled_ok, cancel_err = tools.cancel(waiter.identity)
	assert(cancelled_ok == nil and cancel_err == "cancel-persist-failed: cancel-injected")
	queued, active = tools._queue_size()
	assert(queued == 1 and active == 1 and callback_count == 0)
	assert(tools.status(waiter.identity).status == "queued")
	fail_cancel = false
	assert(tools.cancel(waiter.identity))
	assert(callback_count == 1 and tools.status(waiter.identity).status == "cancelled")
	finish("queued-cancel-holder")
end)

test("unrecoverable final persistence failure retains the durable running job and locks", function()
	local fail_final = false
	configure({
		fail_persist = function(status)
			if fail_final and (status == "succeeded" or status == "repair-required") then
				return "unrecoverable-final-injected"
			end
		end,
	})
	local callback_count = 0
	local running_claim = claim(spec("unrecoverable-final-persist"))
	assert(tools.run(running_claim, function()
		callback_count = callback_count + 1
	end))
	fail_final = true
	finish("unrecoverable-final-persist")
	assert(callback_count == 0)
	local queued, active = tools._queue_size()
	assert(queued == 0 and active == 1)
	local durable = assert(tools.status(running_claim.identity))
	assert(durable.status == "running" and durable.proof == nil)
	assert(#vim.fn.glob(state .. "/locks/resources/*.ticket.*", false, true) == #running_claim.plan.resources)
	assert(#vim.fn.glob(state .. "/locks/global/*.ticket.*", false, true) == 1)
	assert(vim.uv.fs_lstat(running_claim.plan.shims["unrecoverable-final-persist"]) == nil)
end)

test("watchdog without backend acknowledgement retains the slot and every lock", function()
	configure()
	local callback_count = 0
	local timed = claim(spec("watchdog-held", {
		root = fixture .. "/watchdog-held",
		command = "watchdog-cli",
	}))
	assert(tools.run(timed, function()
		callback_count = callback_count + 1
	end))
	assert(#timers == 1)
	timers[1]()
	timers[1]()
	assert(cancelled["watchdog-held"] == 1 and callback_count == 0)
	local durable = assert(tools.status(timed.identity))
	assert(durable.status == "running" and durable.detail == "watchdog-timeout")
	local conflicting = claim(spec("watchdog-waiter", {
		root = fixture .. "/watchdog-waiter",
		command = "watchdog-cli",
	}))
	assert(tools.run(conflicting))
	local queued, active = tools._queue_size()
	assert(queued == 1 and active == 1 and pending["watchdog-waiter"] == nil)
	assert(#vim.fn.glob(state .. "/locks/resources/*.ticket.*", false, true) == #timed.plan.resources)
	assert(#vim.fn.glob(state .. "/locks/global/*.ticket.*", false, true) == 1)
end)

test("dead bakery claims reclaim while live unknown hardlinked and orphan states fail closed", function()
	local liveness = { [42001] = false, [42002] = true }
	configure({
		process_alive = function(owner, token)
			if owner == vim.uv.os_getpid() then
				return token == instance_token and true or nil
			end
			return liveness[owner]
		end,
	})
	local dead_plan = assert(tools.plan(spec("dead-lock")))
	local resource = "identity:" .. dead_plan.identity_key
	mkdir(state .. "/locks/resources")
	local base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local dead_path = claim_file(base, resource, 42001, string.rep("1", 64))
	assert(tools.claim(dead_plan))
	assert(vim.uv.fs_lstat(dead_path) == nil)
	local live_plan = assert(tools.plan(spec("live-lock")))
	resource = "identity:" .. live_plan.identity_key
	base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local live_path = claim_file(base, resource, 42002, string.rep("2", 64))
	local live_claim, live_reason = tools.claim(live_plan)
	assert(live_claim == nil and live_reason == "locked" and vim.uv.fs_lstat(live_path))
	local unknown_plan = assert(tools.plan(spec("unknown-lock")))
	resource = "identity:" .. unknown_plan.identity_key
	base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local unknown_path = claim_file(base, resource, 42003, string.rep("3", 64))
	local unknown_claim, unknown_reason = tools.claim(unknown_plan)
	assert(unknown_claim == nil and unknown_reason == "lock-owner-unverifiable")
	assert(vim.uv.fs_lstat(unknown_path))
	local hard_plan = assert(tools.plan(spec("hardlink-lock")))
	resource = "identity:" .. hard_plan.identity_key
	base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local hard_path = claim_file(base, resource, 42002, string.rep("4", 64))
	assert(vim.uv.fs_link(hard_path, hard_path .. ".other"))
	local hard_claim, hard_reason = tools.claim(hard_plan)
	assert(hard_claim == nil and hard_reason:find("unsafe-lock-claim", 1, true))
	assert(vim.uv.fs_lstat(hard_path).nlink == 2)
	local orphan_plan = assert(tools.plan(spec("orphan-publish")))
	resource = "identity:" .. orphan_plan.identity_key
	base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local orphan = base .. ".choosing." .. string.rep("5", 64) .. ".publish"
	write_private(orphan, "truncated")
	assert(tools.claim(orphan_plan), "orphan publication incorrectly blocked the lock")
	assert(vim.uv.fs_lstat(orphan), "ignored orphan publication was unexpectedly removed")
end)

test("lock publication uses descriptor-relative rename no-replace and preserves a colliding claimant", function()
	local fired = false
	local rival_path
	configure({
		interleave = function(stage, context)
			if stage ~= "before-lock-claim-publish" or fired then
				return
			end
			fired = true
			rival_path = context.path
			write_private(context.path, "rival")
		end,
	})
	local plan = assert(tools.plan(spec("publish-collision")))
	local claimed, reason = tools.claim(plan)
	assert(claimed == nil and reason == "lock-claim-collision")
	assert(fired and rival_path)
	assert(read_file(rival_path) == "rival\n")
	assert(vim.uv.fs_lstat(rival_path).nlink == 1)
	assert(#vim.fn.glob(rival_path .. ".publish", false, true) == 0)
end)

test("failed lock staging cleanup preserves an interleaved replacement", function()
	configure()
	local plan = assert(tools.plan(spec("lock-staging-replacement")))
	local fired = false
	local staging_path
	local displaced_path
	with_uv_override("fs_fsync", function(original, fd)
		if not fired then
			local candidates = vim.fn.glob(state .. "/locks/resources/*.publish", false, true)
			if #candidates == 1 then
				fired = true
				staging_path = candidates[1]
				displaced_path = staging_path .. ".displaced"
				assert(vim.uv.fs_rename(staging_path, displaced_path))
				write_private(staging_path, "rival")
				return nil, "simulated lock staging fsync failure"
			end
		end
		return original(fd)
	end, function()
		local claimed, reason = tools.claim(plan)
		assert(claimed == nil and reason:find("lock-claim-write-failed", 1, true))
		assert(reason:find("lock-claim-publish-cleanup-failed", 1, true))
	end)
	assert(fired and staging_path and displaced_path)
	assert(read_file(staging_path) == "rival\n")
	assert(vim.uv.fs_lstat(displaced_path).type == "file")
end)

test("a real lock scanner sees each published claim complete and single-linked", function()
	local scanned = 0
	local scan_error
	configure({
		interleave = function(stage, context)
			if stage ~= "after-lock-claim-publish" or scan_error then
				return
			end
			local claims, collect_err = tools._collect_lock_claims_for_tests(context.base, context.resource)
			if not claims then
				scan_error = collect_err
				return
			end
			local observed
			for _, candidate in ipairs(claims) do
				if candidate.path == context.path then
					observed = candidate
					break
				end
			end
			if not observed or observed.handle.stat.nlink ~= 1 then
				scan_error = "published claim was missing, incomplete, or multiply linked"
				return
			end
			scanned = scanned + 1
		end,
	})
	local managed = claim(spec("scanner-visible-claim"))
	assert(tools.run(managed))
	assert(scan_error == nil, tostring(scan_error))
	assert(scanned > 0, "publication hook did not observe a lock claim")
	finish("scanner-visible-claim")
end)

test("a parent fsync failure after lock publication is a warning, not a false rollback", function()
	local published = false
	local injected = false
	local messages = {}
	configure({
		interleave = function(stage)
			if stage == "after-lock-claim-publish" and not injected then
				published = true
			end
		end,
		notify = function(message)
			messages[#messages + 1] = tostring(message)
		end,
	})
	local managed = claim(spec("lock-publish-fsync-warning"))
	published = false
	with_uv_override("fs_fsync", function(original, fd)
		if published and not injected then
			published = false
			injected = true
			return nil, "simulated lock parent fsync failure"
		end
		return original(fd)
	end, function()
		assert(tools.run(managed), "post-commit fsync warning became a lock failure")
	end)
	assert(injected and pending[managed.identity.name])
	local warned = false
	for _, message in ipairs(messages) do
		warned = warned or message:find("lock claim committed with a durability warning", 1, true) ~= nil
	end
	assert(warned, "post-commit lock durability warning was not emitted")
	finish("lock-publish-fsync-warning")
end)

test("lock release quarantines by identity and restores an interleaved replacement", function()
	configure()
	local plan = assert(tools.plan(spec("release-cas")))
	local fired = false
	local rival_path
	local displaced_path
	local claim_reason
	with_uv_override("fs_rename", function(original, source, destination)
		if not fired and source:find(".ticket.", 1, true) and destination:find(".quarantine.", 1, true) then
			fired = true
			rival_path = source
			displaced_path = source .. ".displaced"
			assert(original(source, displaced_path))
			write_private(source, "rival")
		end
		return original(source, destination)
	end, function()
		local claimed, reason = tools.claim(plan)
		assert(claimed == nil and reason:find("lock-claim-identity-changed", 1, true))
	end)
	assert(fired and rival_path and displaced_path)
	assert(read_file(rival_path) == "rival\n")
	assert(vim.uv.fs_lstat(rival_path).nlink == 1)
	assert(vim.uv.fs_lstat(displaced_path).type == "file")
end)

test("dead-claim reclaim preserves an interleaved replacement inode and fails closed", function()
	configure({
		process_alive = function(owner, token)
			if owner == vim.uv.os_getpid() then
				return token == instance_token and true or nil
			end
			if owner == 62001 then
				return false
			end
			return nil
		end,
	})
	local plan = assert(tools.plan(spec("dead-reclaim-cas")))
	local resource = "identity:" .. plan.identity_key
	mkdir(state .. "/locks/resources")
	local base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local dead_path = claim_file(base, resource, 62001, string.rep("6", 64))
	local fired = false
	local displaced_path = dead_path .. ".displaced"
	with_uv_override("fs_rename", function(original, source, destination)
		if not fired and source == dead_path and destination:find(".quarantine.", 1, true) then
			fired = true
			assert(original(source, displaced_path))
			write_private(source, "rival")
		end
		return original(source, destination)
	end, function()
		local claimed, reason = tools.claim(plan)
		assert(
			claimed == nil and reason and reason:find("dead-lock-reclaim-failed", 1, true),
			vim.inspect({ claimed = claimed, reason = reason })
		)
		assert(reason:find("lock-claim-identity-changed", 1, true))
	end)
	assert(fired)
	assert(read_file(dead_path) == "rival\n")
	assert(vim.uv.fs_lstat(dead_path).nlink == 1)
	assert(vim.uv.fs_lstat(displaced_path).type == "file")
end)

test("private record readers accept exactly 256 KiB and reject one byte more", function()
	configure()
	local managed = claim(spec("record-read-boundary"))
	assert(tools.run(managed))
	finish("record-read-boundary", { ok = false, reason = "boundary baseline" })
	local path = record_path(managed.plan)
	local baseline = read_file(path)
	local limit = 256 * 1024
	assert(#baseline < limit)
	write_file(path, baseline .. string.rep(" ", limit - #baseline))
	assert(tools.status(managed.identity).status == "failed", "exact read boundary was rejected")
	write_file(path, baseline .. string.rep(" ", limit + 1 - #baseline))
	local oversized, oversized_err = tools.status(managed.identity)
	assert(oversized == nil and oversized_err == "unsafe", tostring(oversized_err))
end)

test("record writers reject values beyond their readable boundary", function()
	configure()
	local limit = 256 * 1024
	local oversized_plan
	for size = 130000, 100000, -1000 do
		local value = spec(string.rep("n", size), { command = "record-writer-boundary" })
		local plan = tools.plan(value)
		if plan then
			local candidate = schema2(plan, "claimed", vim.uv.os_getpid(), instance_token)
			candidate.attempt_consumed = true
			candidate.mode = "auto"
			local encoded = vim.json.encode(candidate) .. "\n"
			if #encoded > limit then
				oversized_plan = plan
				break
			end
		end
	end
	if not oversized_plan then
		return
	end
	local call_ok, claimed, claim_err = pcall(tools.claim, oversized_plan)
	assert(call_ok, claimed)
	assert(claimed == nil, tostring(claim_err))
	assert(vim.uv.fs_lstat(record_path(oversized_plan)) == nil, "oversized record was published")
end)

test("an absent destination remains anchored after the backend creates it", function()
	configure()
	local anchor = fixture .. "/backend-created-anchor"
	mkdir(anchor)
	local managed = claim(spec("backend-created-anchor", {
		root = anchor .. "/nested/install",
		command = "backend-created-anchor-cli",
	}))
	assert(tools.run(managed))
	local displaced = anchor .. ".displaced"
	assert(vim.uv.fs_rename(anchor, displaced))
	mkdir(anchor)
	finish("backend-created-anchor")
	local stored = assert(tools.status(managed.identity))
	assert(stored.status ~= "succeeded", "replacement ancestor was trusted after backend creation")
	assert(vim.uv.fs_lstat(managed.plan.shims["backend-created-anchor-cli"]) == nil)
	assert(vim.uv.fs_lstat(displaced).type == "directory")
end)

test("lock reclaim detects in-place claim mutation and preserves the changed file", function()
	configure({
		process_alive = function(owner)
			if owner == 63001 then
				return false
			end
			return true
		end,
	})
	local plan = assert(tools.plan(spec("in-place-lock-mutation")))
	local resource = "identity:" .. plan.identity_key
	mkdir(state .. "/locks/resources")
	local base = state .. "/locks/resources/" .. vim.fn.sha256(resource) .. ".lock"
	local token = string.rep("7", 64)
	local path = claim_file(base, resource, 63001, token)
	local original_contents = read_file(path)
	local mutated_contents = assert(original_contents:gsub(token, string.rep("8", 64), 1))
	assert(#mutated_contents == #original_contents and mutated_contents ~= original_contents)
	local before = assert(vim.uv.fs_lstat(path))
	local fired = false
	with_uv_override("fs_rename", function(original, source, destination)
		if not fired and source == path and destination:find(".quarantine.", 1, true) then
			fired = true
			local fd = assert(vim.uv.fs_open(source, "r+", tonumber("600", 8)))
			assert(vim.uv.fs_write(fd, mutated_contents, 0) == #mutated_contents)
			assert(vim.uv.fs_fsync(fd))
			assert(vim.uv.fs_close(fd))
			assert(vim.uv.fs_lstat(source).ino == before.ino)
		end
		return original(source, destination)
	end, function()
		local claimed, reason = tools.claim(plan)
		claim_reason = reason
		assert(claimed == nil and reason, vim.inspect({ claimed = claimed, reason = reason }))
	end)
	assert(fired, tostring(claim_reason))
	assert(read_file(path) == mutated_contents)
	assert(vim.uv.fs_lstat(path).ino == before.ino)
end)

test("claim options, mixed tables, non-finite values, and callbacks fail safely", function()
	configure()
	local invalid_options = {
		42,
		{ mode = "auto", unexpected = true },
		{ mode = "auto", [1] = "retry" },
		{ mode = "unknown" },
	}
	for index, options in ipairs(invalid_options) do
		local plan = assert(tools.plan(spec("claim-options-" .. index)))
		local call_ok, claimed, claim_err = pcall(tools.claim, plan, options)
		assert(call_ok, claimed)
		assert(claimed == nil, tostring(claim_err))
		assert(vim.uv.fs_lstat(record_path(plan)) == nil)
	end
	local mixed = spec("mixed-integrity-list", { artifacts = { "share/one" } })
	mixed.manifest.integrity.artifacts.named = "share/two"
	local call_ok, planned = pcall(tools.plan, mixed)
	assert(call_ok and planned == nil)
	for index, value in ipairs({ math.huge, -math.huge, 0 / 0 }) do
		local nonfinite = spec("nonfinite-" .. index)
		nonfinite.manifest.timeout_ms = value
		call_ok, planned = pcall(tools.plan, nonfinite)
		assert(call_ok and planned == nil, "non-finite manifest value was accepted")
	end
	local completion = claim(spec("throwing-completion"))
	assert(tools.run(completion, function()
		error("completion exploded")
	end))
	call_ok = pcall(finish, "throwing-completion")
	assert(call_ok and tools.status(completion.identity).status == "succeeded")

	configure({
		clock = function()
			error("clock exploded")
		end,
	})
	local clock_plan = assert(tools.plan(spec("throwing-clock")))
	call_ok, planned = pcall(tools.claim, clock_plan)
	assert(call_ok and planned == nil)
end)

test("run status and cancel accept only exact public envelopes", function()
	configure()
	local managed = claim(spec("exact-public-envelopes"))
	local path = record_path(managed.plan)
	local claimed_bytes = read_file(path)
	local invalid_claims = {}
	local extra = vim.deepcopy(managed)
	extra.unexpected = true
	invalid_claims[#invalid_claims + 1] = extra
	local missing_mode = vim.deepcopy(managed)
	missing_mode.mode = nil
	invalid_claims[#invalid_claims + 1] = missing_mode
	local mismatched_mode = vim.deepcopy(managed)
	mismatched_mode.mode = "repair"
	invalid_claims[#invalid_claims + 1] = mismatched_mode
	local record_extra = vim.deepcopy(managed)
	record_extra.record.unexpected = true
	invalid_claims[#invalid_claims + 1] = record_extra
	local record_changed = vim.deepcopy(managed)
	record_changed.record.attempt_consumed = false
	invalid_claims[#invalid_claims + 1] = record_changed
	local record_plan_changed = vim.deepcopy(managed)
	record_plan_changed.record.plan.manifest.marker = "changed-authority"
	invalid_claims[#invalid_claims + 1] = record_plan_changed
	for _, candidate in ipairs(invalid_claims) do
		local call_ok, started, run_err = pcall(tools.run, candidate)
		assert(call_ok and started == nil and run_err, vim.inspect({ started = started, error = run_err }))
		assert(read_file(path) == claimed_bytes, "invalid run envelope changed durable state")
		assert(pending[managed.identity.name] == nil)
	end
	local started, callback_err = tools.run(managed, "not-a-function")
	assert(started == nil and callback_err == "run callback must be a function")
	assert(read_file(path) == claimed_bytes)
	local status_value, status_err = tools.status({ identity = managed.identity, unexpected = true })
	assert(status_value == nil and status_err == "status request must contain only identity")
	local cancelled_value, cancel_err = tools.cancel({ identity = managed.identity, unexpected = true })
	assert(cancelled_value == nil and cancel_err == "cancel request must contain only identity")
	assert(read_file(path) == claimed_bytes)
	assert(tools.status({ identity = managed.identity }).status == "claimed")
	assert(tools.run(managed), "invalid envelopes stranded a lock or claim")
	finish(managed.identity.name, { ok = false })
end)

test("executable maps accept only safe command basenames", function()
	configure()
	local unsafe = {
		{ ["../public"] = "private" },
		{ ["dir/public"] = "private" },
		{ public = "../private" },
		{ public = "dir/private" },
		{ public = "\\private" },
		{ public = "." },
		{ public = ".." },
	}
	for index, executables in ipairs(unsafe) do
		local call_ok, planned = pcall(
			tools.plan,
			spec("unsafe-executable-map-" .. index, {
				executables = executables,
			})
		)
		assert(call_ok and planned == nil, vim.inspect(executables))
	end
	local mismatched = spec("mismatched-installed-basename", {
		executables = { public = "installed" },
		command_paths = { public = "bin/different" },
	})
	local call_ok, planned = pcall(tools.plan, mismatched)
	assert(call_ok and planned == nil, "integrity path ignored the declared installed basename")
end)

test("backend completion accepts only a strict boolean ok value", function()
	for index, invalid_ok in ipairs({ "true", 1, {}, function() end }) do
		configure()
		local name = "backend-ok-" .. index
		local managed = claim(spec(name))
		assert(tools.run(managed))
		local entry = assert(pending[name])
		local evidence, observed = install_release(entry.plan)
		attestation_override[name] = observed
		local call_ok = pcall(entry.done, invalid_ok, evidence)
		assert(call_ok, "backend done escaped an exception")
		local stored = assert(tools.status(managed.identity))
		assert(stored.status ~= "succeeded", "truthy non-boolean backend result was accepted")
		assert(attestations[name] == nil)
		assert(vim.uv.fs_lstat(managed.plan.shims[name]) == nil)
	end
end)

test("schema-2 records require exact keys and exact field types", function()
	configure()
	local managed = claim(spec("schema-two-exact"))
	assert(tools.run(managed))
	finish("schema-two-exact", { ok = false, reason = "fixture failure" })
	local path = record_path(managed.plan)
	local baseline = vim.json.decode(read_file(path))
	assert(tools.status(managed.identity).status == "failed")
	local mutations = {
		function(value)
			value.unexpected = true
		end,
		function(value)
			value.generation = "1"
		end,
		function(value)
			value.updated_at = "1"
		end,
		function(value)
			value.pid = 1.5
		end,
		function(value)
			value.attempt = 1.5
		end,
		function(value)
			value.attempt_consumed = "true"
		end,
		function(value)
			value.detail = {}
		end,
		function(value)
			value.instance_token = string.rep("A", 64)
		end,
	}
	for _, mutate in ipairs(mutations) do
		local candidate = vim.deepcopy(baseline)
		mutate(candidate)
		write_private(path, candidate)
		local raw = read_file(path)
		local call_ok, value, reason = pcall(tools.status, managed.identity)
		assert(call_ok, value)
		assert(value == nil and reason, vim.inspect(value))
		assert(read_file(path) == raw, "record validation rewrote corrupt state")
	end
	write_private(path, baseline)
	assert(tools.status(managed.identity).status == "failed")
end)

test("promotion failure after pre-backend invalidation never restores the prior shim", function()
	configure()
	local original = claim(spec("rollback-remnant", {
		version = "1.0.0",
		root = fixture .. "/rollback-remnant-v1",
		command = "rollback-remnant-cli",
	}))
	assert(tools.run(original))
	finish("rollback-remnant")
	local shim = original.plan.shims["rollback-remnant-cli"]
	assert(vim.uv.fs_realpath(shim))
	local upgrade = claim(spec("rollback-remnant", {
		version = "2.0.0",
		root = fixture .. "/rollback-remnant-v2",
		command = "rollback-remnant-cli",
	}))
	local callback_result
	assert(tools.run(upgrade, function(ok, reason)
		callback_result = { ok = ok, reason = reason }
	end))
	local promotion_failed = false
	with_uv_override("fs_symlink", function(original, source, destination)
		if destination == shim then
			promotion_failed = true
			return nil, "EIO: injected promotion failure"
		end
		return original(source, destination)
	end, function()
		finish("rollback-remnant")
	end)
	assert(promotion_failed)
	local stored = assert(tools.status(upgrade.identity))
	assert(stored.status == "failed", vim.inspect(stored))
	assert(stored.detail and stored.detail:find("shim-promote-failed", 1, true), stored.detail)
	assert(callback_result and callback_result.ok == false)
	assert(vim.uv.fs_lstat(shim) == nil, "promotion failure restored the stale prior shim")
end)

test("an owner-record quarantine remnant blocks later promotion without mutation", function()
	configure()
	local original = claim(spec("owner-remnant", {
		version = "1.0.0",
		root = fixture .. "/owner-remnant-v1",
		command = "owner-remnant-cli",
	}))
	assert(tools.run(original))
	finish("owner-remnant")
	local shim = original.plan.shims["owner-remnant-cli"]
	local original_target = assert(vim.uv.fs_realpath(shim))
	local owners = vim.fn.glob(state .. "/shims/owners/*.json", false, true)
	assert(#owners == 1)
	local owner_path = owners[1]
	local remnant = owner_path .. ".quarantine.RETAINED"
	mkdir(remnant)
	assert(vim.uv.fs_chmod(remnant, tonumber("700", 8)))
	assert(vim.uv.fs_rename(owner_path, remnant .. "/entry"))
	local upgrade = claim(spec("owner-remnant", {
		version = "2.0.0",
		root = fixture .. "/owner-remnant-v2",
		command = "owner-remnant-cli",
	}))
	assert(tools.run(upgrade))
	local stored = assert(tools.status(upgrade.identity))
	assert(stored.status == "repair-required", vim.inspect(stored))
	assert(stored.detail and stored.detail:find("shim-owner-quarantine-remnant", 1, true), stored.detail)
	assert(vim.uv.fs_realpath(shim) == original_target, "owner remnant allowed shim replacement")
	assert(vim.uv.fs_lstat(remnant .. "/entry").type == "file")
end)

test("a shim quarantine remnant blocks drift removal without mutation", function()
	configure()
	local managed = claim(spec("remnant-drift-removal"))
	assert(tools.run(managed))
	finish("remnant-drift-removal")
	local shim = managed.plan.shims[managed.identity.name]
	local original_target = assert(vim.uv.fs_realpath(shim))
	local remnant = shim .. ".quarantine.RETAINED"
	mkdir(remnant)
	assert(vim.uv.fs_chmod(remnant, tonumber("700", 8)))
	attestation_failure[managed.identity.name] = true
	local result
	assert(tools.attest(managed.identity, function(ok, reason)
		result = { ok = ok, reason = reason }
	end))
	local stored = assert(tools.status(managed.identity))
	assert(stored.status == "repair-required", vim.inspect(stored))
	assert(stored.detail and stored.detail:find("owned-shim-quarantine-remnant", 1, true), stored.detail)
	assert(result and result.ok == false)
	assert(vim.uv.fs_realpath(shim) == original_target, "drift cleanup mutated a shim beside retained evidence")
	assert(vim.uv.fs_lstat(remnant).type == "directory")
end)

test("legacy import rejects malformed evidence without throwing and retains canonical repair state", function()
	local malformed = {
		"not-a-table",
		{},
		{ kind = "release-install-evidence" },
		{
			kind = "release-install-evidence",
			archive_sha256 = string.rep("0", 64),
			artifacts = "not-a-table",
		},
		{
			kind = "release-install-evidence",
			archive_sha256 = string.rep("0", 64),
			artifacts = { [1] = string.rep("0", 64) },
		},
	}
	for index, evidence in ipairs(malformed) do
		configure()
		local value = spec("legacy-malformed-" .. index)
		local callback_count = 0
		local call_ok, imported, import_err = pcall(tools.import_legacy, value, {
			status = "succeeded",
			origin = "verified-private-install-receipt-v1",
			install_evidence = evidence,
		}, function(ok)
			callback_count = callback_count + 1
			assert(ok == false)
		end)
		assert(call_ok, imported)
		assert(imported and imported.status == "repair-required", tostring(import_err))
		assert(imported.legacy == true and imported.legacy_status == "succeeded")
		assert(imported.legacy_origin == "verified-private-install-receipt-v1")
		assert(callback_count == 1)
		local before = read_file(record_path(assert(tools.plan(value))))
		local duplicate, duplicate_err = tools.import_legacy(value, {
			status = "succeeded",
			origin = "verified-private-install-receipt-v1",
			install_evidence = evidence,
		})
		assert(duplicate == nil and duplicate_err)
		assert(
			read_file(record_path(assert(tools.plan(value)))) == before,
			"duplicate import rewrote canonical repair state"
		)
	end
end)

test("a pending verified legacy import excludes a concurrent duplicate", function()
	configure()
	local value = spec("legacy-pending-concurrency")
	local plan = assert(tools.plan(value))
	local evidence, observed = install_release(plan)
	attestation_override[plan.identity.name] = observed
	hold_attestation[plan.identity.name] = true
	local callback_count = 0
	assert(tools.import_legacy(value, {
		status = "succeeded",
		origin = "verified-private-install-receipt-v1",
		install_evidence = evidence,
	}, function()
		callback_count = callback_count + 1
	end))
	assert(pending_attestation[plan.identity.name] and tools.status(plan.identity).status == "running")
	local concurrent = assert(tools.plan(spec("legacy-pending-normal-run")))
	local concurrent_claim = assert(tools.claim(concurrent))
	assert(tools.run(concurrent_claim))
	assert(pending[concurrent.identity.name], "normal scheduler did not coexist with pending legacy import")
	finish(concurrent.identity.name)
	assert(tools.status(concurrent.identity).status == "succeeded")
	local duplicate, duplicate_err = tools.import_legacy(value, {
		status = "succeeded",
		origin = "verified-private-install-receipt-v1",
		install_evidence = evidence,
	})
	assert(duplicate == nil and duplicate_err and callback_count == 0)
	assert(attestations[plan.identity.name] == 1)
	complete_attestation(plan.identity.name)
	assert(callback_count == 1 and tools.status(plan.identity).status == "succeeded")
end)

test("record creation is atomic no-clobber under a racing claimant", function()
	local path
	local rival = "rival-record-create\n"
	local fired = false
	configure({
		interleave = function(stage, context)
			if stage == "record-target-checked" and context.target_present == false and not fired then
				fired = true
				write_file(path, rival)
			end
		end,
	})
	local plan = assert(tools.plan(spec("record-create-cas")))
	path = record_path(plan)
	local claimed = tools.claim(plan)
	assert(claimed == nil, "a racing record was overwritten")
	assert(fired, "record publication was not intercepted")
	assert(read_file(path) == rival)
end)

test("record exchange rolls back an interleaved symlink rival", function()
	local enabled = false
	local fired = false
	local path
	local displaced
	local rival_target = fixture .. "/record-rival-target"
	write_file(rival_target, "rival-target\n")
	configure({
		interleave = function(stage, context)
			if stage == "record-target-checked" and context.target_present and enabled and not fired then
				fired = true
				displaced = path .. ".displaced-by-test"
				assert(vim.uv.fs_rename(path, displaced))
				assert(vim.uv.fs_symlink(rival_target, path))
			end
		end,
	})
	local plan = assert(tools.plan(spec("record-replace-cas")))
	local claimed = assert(tools.claim(plan))
	path = record_path(plan)
	enabled = true
	local started, run_err = tools.run(claimed)
	assert(started == nil and run_err and run_err:find("competing record was restored", 1, true), tostring(run_err))
	assert(fired, "record replacement publication was not intercepted")
	assert(vim.uv.fs_lstat(path).type == "link")
	assert(vim.uv.fs_readlink(path) == rival_target)
	assert(vim.uv.fs_lstat(displaced).type == "file")
	assert(pending[plan.identity.name] == nil)
end)

test("record staging byte drift is rejected before publication", function()
	local enabled = false
	local changed = false
	configure({
		interleave = function(stage, context)
			if stage ~= "record-stage-ready" or not enabled or changed then
				return
			end
			changed = true
			local stat = assert(vim.uv.fs_lstat(context.staging_path))
			local fd = assert(vim.uv.fs_open(context.staging_path, "r+", tonumber("600", 8)))
			assert(vim.uv.fs_write(fd, string.rep("x", stat.size), 0) == stat.size)
			assert(vim.uv.fs_fsync(fd))
			assert(vim.uv.fs_close(fd))
		end,
	})
	local plan = assert(tools.plan(spec("record-stage-drift")))
	local claimed = assert(tools.claim(plan))
	local path = record_path(plan)
	local original = read_file(path)
	local before = assert(vim.uv.fs_lstat(path))
	enabled = true
	local started = tools.run(claimed)
	assert(started == nil, "same-size staging drift was published")
	assert(changed and read_file(path) == original)
	local final = assert(vim.uv.fs_lstat(path))
	assert(final.ino == before.ino and final.dev == before.dev and final.nlink == 1)
	assert(pending[plan.identity.name] == nil)
end)

test("committed record cleanup preserves a replacement and reports success", function()
	local enabled = false
	local replaced = false
	local retained_old = fixture .. "/record-cleanup-retained-old"
	local messages = {}
	configure({
		notify = function(message)
			messages[#messages + 1] = message
		end,
		interleave = function(stage, context)
			if stage ~= "before-record-displaced-cleanup" or not enabled or replaced then
				return
			end
			replaced = true
			assert(vim.uv.fs_rename(context.reserved_path, retained_old))
			write_file(context.reserved_path, "unknown-cleanup-replacement\n")
		end,
	})
	local plan = assert(tools.plan(spec("record-cleanup-replacement")))
	local claimed = assert(tools.claim(plan))
	enabled = true
	assert(tools.run(claimed), "post-commit cleanup drift reported a false write failure")
	assert(replaced and vim.uv.fs_lstat(retained_old).type == "file")
	local preserved = false
	for _, candidate in ipairs(vim.fn.glob(state .. "/record-transactions/**", false, true)) do
		if vim.uv.fs_lstat(candidate) and vim.uv.fs_lstat(candidate).type == "file" then
			local ok, bytes = pcall(read_file, candidate)
			preserved = preserved or ok and bytes == "unknown-cleanup-replacement\n"
		end
	end
	assert(preserved, "conditional cleanup deleted the unknown replacement")
	local warned = false
	for _, message in ipairs(messages) do
		warned = warned or message:find("deferred cleanup", 1, true) ~= nil
	end
	assert(warned, "deferred cleanup warning was not emitted")
end)

test("committed record transaction cleanup reports final fsync and close warnings", function()
	local finalizing = false
	local root_fd
	local messages = {}
	configure({
		notify = function(message)
			messages[#messages + 1] = tostring(message)
		end,
		interleave = function(stage)
			if stage == "record-transaction-cleanup-committed" then
				finalizing = true
			end
		end,
	})
	local plan = assert(tools.plan(spec("record-cleanup-final-warning")))
	with_uv_overrides({
		fs_fsync = function(original, fd)
			if finalizing and not root_fd then
				root_fd = fd
				return nil, "simulated final transaction-root fsync failure"
			end
			return original(fd)
		end,
		fs_close = function(original, fd)
			if root_fd == fd then
				local closed, close_err = original(fd)
				assert(closed, close_err)
				return nil, "simulated final transaction-root close failure"
			end
			return original(fd)
		end,
	}, function()
		assert(tools.claim(plan), "post-commit cleanup warning turned claim into a failure")
	end)
	assert(finalizing and root_fd, "final record transaction cleanup was not intercepted")
	local warning
	for _, message in ipairs(messages) do
		if message:find("cleanup committed with a durability warning", 1, true) then
			warning = message
			break
		end
	end
	assert(warning, "final record transaction cleanup warning was not notified")
	assert(warning:find("fsync failure", 1, true), "final root fsync warning was dropped")
	assert(warning:find("close failure", 1, true), "final root close warning was dropped")
end)

test("record exchange remains visible and recovers after process interruption", function()
	configure()
	local install_root = fixture .. "/record-exchange-crash-install"
	local plan = assert(tools.plan(spec("record-exchange-crash", { root = install_root })))
	local claimed = assert(tools.claim(plan))
	assert(tools.run(claimed))
	finish(plan.identity.name, { ok = false, reason = "seed failure" })
	assert(tools.status(plan.identity).status == "failed")
	local path = record_path(plan)
	local old_bytes = read_file(path)
	local ready = fixture .. "/record-exchange-crash.ready"
	local source = assert(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			VERIFIED_TOOLS_RECORD_CRASH_CHILD = "1",
			VERIFIED_TOOLS_RECORD_CRASH_STATE = state,
			VERIFIED_TOOLS_RECORD_CRASH_INSTALL_ROOT = install_root,
			VERIFIED_TOOLS_RECORD_CRASH_READY = ready,
		},
		text = true,
	})
	local reached = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not reached then
		child:kill(9)
		local failed = child:wait(5000)
		error("child did not reach record exchange: " .. tostring(failed.stderr))
	end
	assert(vim.uv.fs_lstat(path), "record target disappeared during exchange")
	local new_bytes = read_file(path)
	assert(new_bytes ~= old_bytes, "record exchange did not publish NEW bytes")
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "record exchange child was not killed")
	configure({ state = state })
	local recovered = assert(tools.status(plan.identity))
	assert(recovered.identity_key == plan.identity_key and recovered.status == "repair-required")
	assert(read_file(path) == new_bytes, "recovery changed exact committed NEW bytes")
	assert(vim.tbl_isempty(vim.fn.glob(state .. "/record-transactions/*", false, true)))
end)

test("record persistence never reports failure after publishing a new state", function()
	configure()
	local plan = assert(tools.plan(spec("record-postcommit")))
	local path = record_path(plan)
	local fired = false
	local claimed, claim_err
	with_uv_override("fs_chmod", function(original, target, mode)
		if target == path then
			fired = true
			return nil, "EIO: injected post-commit chmod failure"
		end
		return original(target, mode)
	end, function()
		claimed, claim_err = tools.claim(plan)
	end)
	local durable = vim.uv.fs_lstat(path)
	if claimed then
		assert(durable and durable.type == "file", tostring(claim_err))
		local decoded = vim.json.decode(read_file(path))
		assert(decoded.status == claimed.record.status and decoded.generation == claimed.record.generation)
	else
		assert(durable == nil, "persistence returned failure after publishing the record")
	end
	assert(not fired or claimed ~= nil or durable == nil)
end)

test("pre-backend destination rejection preserves an existing same-tool shim", function()
	configure()
	local original = claim(spec("prestart-preserve", {
		version = "1.0.0",
		root = fixture .. "/prestart-preserve-v1",
		command = "prestart-preserve-cli",
	}))
	assert(tools.run(original))
	finish("prestart-preserve")
	local original_target = assert(vim.uv.fs_realpath(original.plan.shims["prestart-preserve-cli"]))

	local holder_one = claim(spec("prestart-holder-one"))
	local holder_two = claim(spec("prestart-holder-two"))
	local upgrade = claim(spec("prestart-preserve", {
		version = "2.0.0",
		root = fixture .. "/prestart-preserve-v2",
		command = "prestart-preserve-cli",
	}))
	assert(tools.run(holder_one) and tools.run(holder_two) and tools.run(upgrade))
	local substitute = fixture .. "/prestart-substitute"
	mkdir(substitute)
	assert(vim.uv.fs_symlink(substitute, upgrade.identity.install_root))
	finish("prestart-holder-one")
	assert(pending["prestart-preserve"] == nil, "unsafe job reached its backend")
	local stored = assert(tools.status(upgrade.identity))
	assert(stored.status ~= "succeeded")
	assert(vim.uv.fs_realpath(upgrade.plan.shims["prestart-preserve-cli"]) == original_target)
	finish("prestart-holder-two")
end)

test("fatal partial lock acquisition preserves an existing same-tool shim", function()
	local publications = 0
	local inject = false
	local fired = false
	configure({
		interleave = function(stage, context)
			if
				inject
				and stage == "before-lock-claim-publish"
				and context.path:find(state .. "/locks/resources/", 1, true)
			then
				publications = publications + 1
				if publications == 3 then
					fired = true
					error("injected fatal partial resource lock")
				end
			end
		end,
	})
	local original = claim(spec("partial-lock-preserve", {
		version = "1.0.0",
		root = fixture .. "/partial-lock-preserve-v1",
		command = "partial-lock-preserve-cli",
	}))
	assert(tools.run(original))
	finish("partial-lock-preserve")
	local shim = original.plan.shims["partial-lock-preserve-cli"]
	local original_target = assert(vim.uv.fs_realpath(shim))

	local holder_one = claim(spec("partial-lock-holder-one"))
	local holder_two = claim(spec("partial-lock-holder-two"))
	local upgrade = claim(spec("partial-lock-preserve", {
		version = "2.0.0",
		root = fixture .. "/partial-lock-preserve-v2",
		command = "partial-lock-preserve-cli",
	}))
	assert(tools.run(holder_one) and tools.run(holder_two) and tools.run(upgrade))
	inject = true
	finish("partial-lock-holder-one")
	assert(fired and pending["partial-lock-preserve"] == nil)
	local stored = assert(tools.status(upgrade.identity))
	assert(stored.status ~= "succeeded")
	assert(vim.uv.fs_realpath(shim) == original_target)
	assert(#vim.fn.glob(state .. "/locks/resources/*.ticket.*", false, true) == #holder_two.plan.resources)
	finish("partial-lock-holder-two")
end)

test("identity keys are stable across real fresh Neovim processes", function()
	local child_script = fixture .. "/fresh-identity.lua"
	local child_state = fixture .. "/fresh-identity-state"
	local child_install = fixture .. "/fresh-identity-install"
	local child_spec = spec("fresh-identity", {
		root = child_install,
		command = "fresh-identity-cli",
	})
	write_file(
		child_script,
		([[vim.o.shadafile = "NONE"
local plugin = %q
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ %q, plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")
local tools = require("verified_tools")
tools.setup({ state_root = %q, instance_token = string.rep("a", 64) })
local plan, err = tools.plan(%s)
assert(plan, err)
io.stdout:write(plan.identity_key .. "\n")
]]):format(plugin, vim.fn.getcwd() .. "/local-plugins/_shared/lua/?.lua", child_state, vim.inspect(child_spec))
	)
	local keys = {}
	for index = 1, 2 do
		local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", child_script }, {
			text = true,
		}):wait()
		assert(result.code == 0, result.stderr)
		keys[index] = vim.trim(result.stdout)
		assert(keys[index]:match("^[0-9a-f]+$") and #keys[index] == 64, vim.inspect(result))
	end
	assert(keys[1] == keys[2], vim.inspect(keys))
end)

test("state root callbacks are snapshotted once", function()
	local calls = 0
	local callback_state = fixture .. "/state-callback-once"
	configure({
		state = callback_state,
		state_root = function()
			calls = calls + 1
			return callback_state
		end,
	})
	local plan = assert(tools.plan(spec("state-callback-once")))
	assert(tools.claim(plan))
	assert(tools.status(plan.identity).status == "claimed")
	assert(calls == 1, "state_root callback was evaluated " .. tostring(calls) .. " times")
end)

test("setup failures are transactional and allow a clean retry", function()
	for index, invalid in ipairs({
		{ instance_token = "not-a-token" },
		{
			pid = function()
				return 0
			end,
		},
	}) do
		tools._reset_for_tests()
		local setup_root = fixture .. "/transactional-setup-" .. index
		local options = vim.tbl_extend("force", {
			state_root = setup_root,
			instance_token = string.rep("a", 64),
		}, invalid)
		local setup_ok = pcall(tools.setup, options)
		assert(not setup_ok, "invalid setup was accepted")
		assert(vim.uv.fs_lstat(setup_root) == nil, "failed setup created its state root")
		assert(not pcall(tools.shim_bin), "failed setup exposed a shim root")
		assert(tools.setup({
			state_root = setup_root,
			instance_token = string.rep("b", 64),
			backends = {
				custom = { run = function() end, attest = function() end, backend_option = true },
			},
			pid = function()
				return vim.uv.os_getpid()
			end,
		}))
		assert(tools.shim_bin() == setup_root .. "/shims/bin")
		assert(vim.uv.fs_lstat(setup_root) == nil, "successful setup performed implicit I/O")
	end
end)

test("pinned setup only accepts an exact idempotent candidate", function()
	tools._reset_for_tests()
	local setup_root = fixture .. "/pinned-setup"
	local root_calls = 0
	local root_resolver = function()
		root_calls = root_calls + 1
		return setup_root
	end
	local pid_resolver = function()
		return vim.uv.os_getpid()
	end
	local options = {
		state_root = root_resolver,
		instance_token = string.rep("c", 64),
		pid = pid_resolver,
		lock_wait_ms = 0,
	}
	assert(tools.setup(options))
	local before_config = tools.effective_config()
	local before_status = tools.status()
	assert(tools.setup(options), "exact repeated setup was not idempotent")
	assert(root_calls == 2, "repeated setup did not snapshot its candidate root")

	local changed = vim.tbl_extend("force", {}, options, { lock_wait_ms = 1 })
	local ok, err = pcall(tools.setup, changed)
	assert(not ok and tostring(err):find("teardown", 1, true), tostring(err))
	assert(root_calls == 3, "rejected reconfiguration skipped candidate root resolution")
	assert(vim.deep_equal(before_config, tools.effective_config()), "rejected reconfiguration changed policy")
	assert(vim.deep_equal(before_status, tools.status()), "rejected reconfiguration changed lifecycle state")

	changed = vim.tbl_extend("force", {}, options, {
		pid = function()
			return 0
		end,
	})
	ok = pcall(tools.setup, changed)
	assert(not ok, "invalid repeated PID was accepted")
	assert(root_calls == 4, "PID failure skipped candidate root resolution")
	assert(vim.deep_equal(before_config, tools.effective_config()), "PID failure changed policy")
end)

test("state roots reject symlinked ancestors without escaping", function()
	local outside = fixture .. "/state-ancestor-outside"
	local lexical_parent = fixture .. "/state-ancestor-lexical"
	mkdir(outside)
	mkdir(lexical_parent)
	assert(vim.uv.fs_symlink(outside, lexical_parent .. "/linked"))
	local escaped_state = lexical_parent .. "/linked/nested-state"
	local configured_ok, configure_err = pcall(configure, { state = escaped_state })
	assert(not configured_ok and configure_err, "symlinked state ancestor was accepted")
	assert(vim.uv.fs_lstat(outside .. "/nested-state") == nil, "state setup escaped through a symlink ancestor")
end)

test("an absent state root revalidates its original parent after creation", function()
	local original_parent = fixture .. "/state-parent-swap"
	local moved_parent = original_parent .. ".moved"
	local swap_state = original_parent .. "/state"
	mkdir(original_parent)
	configure({ state = swap_state })
	local plan = assert(tools.plan(spec("state-parent-swap")))
	local fired = false
	with_uv_override("fs_mkdir", function(original, path, mode)
		local made, make_err = original(path, mode)
		if not fired and path == swap_state and made then
			fired = true
			assert(vim.uv.fs_rename(original_parent, moved_parent))
			assert(original(original_parent, tonumber("700", 8)))
			assert(original(swap_state, tonumber("700", 8)))
		end
		return made, make_err
	end, function()
		local claimed, claim_err = tools.claim(plan)
		assert(claimed == nil and claim_err == "state directory identity changed", tostring(claim_err))
	end)
	assert(fired, "state root creation was not intercepted")
	assert(vim.uv.fs_lstat(swap_state .. "/records") == nil)
	assert(vim.uv.fs_lstat(moved_parent .. "/state/records") == nil)
end)

test("hash callbacks are rejected and core digests cannot escape state", function()
	local escaped = fixture .. "/hash-escape.json"
	tools._reset_for_tests()
	local invalid_root = fixture .. "/invalid-hash-setup"
	local configured_ok = pcall(tools.setup, {
		state_root = invalid_root,
		instance_token = string.rep("a", 64),
		hash = function()
			return "../../hash-escape"
		end,
	})
	assert(not configured_ok, "host hash injection was accepted")
	assert(not pcall(tools.shim_bin))
	assert(vim.uv.fs_lstat(invalid_root) == nil)
	configured_ok = pcall(tools.setup, {
		state_root = invalid_root,
		instance_token = string.rep("a", 64),
		file_sha256 = function()
			return string.rep("0", 64)
		end,
	})
	assert(not configured_ok, "host file_sha256 injection was accepted")
	configure()
	local call_ok, planned, plan_err = pcall(tools.plan, spec("invalid-hash"))
	assert(call_ok, planned)
	assert(planned and planned.identity_key:match("^[0-9a-f]+$") and #planned.identity_key == 64, tostring(plan_err))
	assert(tools.claim(planned))
	assert(vim.uv.fs_lstat(escaped) == nil)
end)

test("record and state paths reject symlinks", function()
	local target = fixture .. "/state-target"
	local link = fixture .. "/state-link"
	mkdir(target)
	assert(vim.uv.fs_symlink(target, link))
	local setup_ok, setup_err = pcall(configure, { state = link })
	assert(not setup_ok and setup_err)
	assert(vim.uv.fs_lstat(link).type == "link")
	configure()
	local linked_plan = assert(tools.plan(spec("linked-record")))
	mkdir(state .. "/records")
	local outside_record = fixture .. "/outside-record"
	write_private(outside_record, "{}")
	assert(vim.uv.fs_symlink(outside_record, record_path(linked_plan)))
	local linked_claim, linked_err = tools.claim(linked_plan)
	assert(linked_claim == nil and linked_err == "unsafe")
	assert(vim.uv.fs_lstat(record_path(linked_plan)).type == "link")
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(string.format("verified_tools_spec: %d tests passed", count))
vim.cmd("quitall!")
