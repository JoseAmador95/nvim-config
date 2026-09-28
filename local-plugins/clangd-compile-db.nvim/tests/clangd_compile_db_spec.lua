vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.getcwd() .. "/local-plugins/clangd-compile-db.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local router = require("clangd_compile_db")
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local root = fixture .. "/project"
assert(vim.fn.mkdir(root, "p") == 1)

local function database(name, data)
	local directory = root .. "/" .. name
	assert(vim.fn.mkdir(directory, "p") == 1)
	assert(vim.fn.writefile({ data or "[]" }, directory .. "/compile_commands.json") == 0)
	return directory
end

local deferred = {}
local clients = {}
local stopped = {}
local starts = {}
local attached = {}
local waits = {}
local initialization_waits = {}
local discarded = {}
local reconciliations = {}
local start_hook
local wait_hook
local initialize_hook
local attach_hook
local reconcile_hook

local function configure(event)
	router._reset_for_tests()
	deferred, clients, stopped, starts, attached, waits, initialization_waits, discarded, reconciliations =
		{}, {}, {}, {}, {}, {}, {}, {}, {}
	start_hook, wait_hook, initialize_hook, attach_hook, reconcile_hook = nil, nil, nil, nil, nil
	router.setup({
		defer = function(callback)
			deferred[#deferred + 1] = callback
		end,
		event = event,
		lsp = {
			clients = function()
				return clients
			end,
			client_root = function(client)
				return client.root
			end,
			stop = function(client)
				stopped[#stopped + 1] = client.id
			end,
			wait_stopped = function(waited, waited_root, timeout_ms)
				waits[#waits + 1] = { clients = vim.deepcopy(waited), root = waited_root, timeout_ms = timeout_ms }
				if wait_hook then
					return wait_hook(waited, waited_root, timeout_ms)
				end
				return true
			end,
			buffer_valid = function()
				return true
			end,
			config = function(config_root, active)
				local config = {
					root_dir = config_root,
					cmd = { "clangd" },
				}
				if active then
					config.cmd[#config.cmd + 1] = "--compile-commands-dir=" .. active.directory
				end
				return config
			end,
			reconcile = function(reconcile_root, timeout_ms)
				reconciliations[#reconciliations + 1] = { root = reconcile_root, timeout_ms = timeout_ms }
				if reconcile_hook then
					return reconcile_hook(reconcile_root, timeout_ms)
				end
				return {}
			end,
			start = function(config)
				starts[#starts + 1] = { config = vim.deepcopy(config) }
				if start_hook then
					return start_hook(config)
				end
				return { owned = true, client_id = 77 }
			end,
			attach = function(bufnr, client_id)
				attached[#attached + 1] = { bufnr = bufnr, client_id = client_id }
				if attach_hook then
					return attach_hook(bufnr, client_id)
				end
				return true
			end,
			wait_initialized = function(client_id, waited_root, timeout_ms)
				initialization_waits[#initialization_waits + 1] = {
					attached = vim.deepcopy(attached),
					client_id = client_id,
					root = waited_root,
					timeout_ms = timeout_ms,
				}
				if initialize_hook then
					return initialize_hook(client_id, waited_root, timeout_ms)
				end
				return true
			end,
			discard = function(client_id, discard_root, timeout_ms)
				discarded[#discarded + 1] = { client_id = client_id, root = discard_root, timeout_ms = timeout_ms }
				return true
			end,
		},
	})
	router.register_provider("cmake", { priority = 10 })
	router.register_provider("meson", { priority = 20 })
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

test("pre-setup public defaults and aggregate status are copied", function()
	local first = router.effective_config()
	assert(first.max_validation_bytes == 256 * 1024 * 1024)
	assert(first.restart_delay_ms == 100 and first.restart_timeout_ms == 5000)
	first.restart_timeout_ms = 1
	assert(router.effective_config().restart_timeout_ms == 5000)
	assert(pcall(vim.json.encode, router.effective_config()))

	local status = router.status()
	assert(status.configured == false and vim.tbl_isempty(status.roots))
	status.configured = true
	assert(router.status().configured == false)
end)

test("validation accepts only a structural JSON array", function()
	configure()
	local valid = database("valid", "[]")
	assert(router.validate(valid).validity == "structural")
	for name, data in pairs({ malformed = "{", future = '{"version":2,"commands":[]}', scalar = "true" }) do
		local result, err = router.validate(database(name, data))
		assert(result == nil and err:find("expected a JSON array", 1, true))
	end
end)

test("hostile compile database entries are rejected exactly", function()
	configure()
	for name, entry in pairs({
		missing_directory = { file = "a.c", command = "cc a.c" },
		bad_file = { directory = "/tmp", file = 7, command = "cc a.c" },
		both_forms = { directory = "/tmp", file = "a.c", command = "cc a.c", arguments = { "cc", "a.c" } },
		neither_form = { directory = "/tmp", file = "a.c" },
		bad_arguments = { directory = "/tmp", file = "a.c", arguments = { "cc", 7 } },
		bad_command = { directory = "/tmp", file = "a.c", command = "" },
	}) do
		local value, err = router.validate(database("hostile-" .. name, vim.json.encode({ entry })))
		assert(value == nil and err:find("entry 1", 1, true), name .. ": " .. tostring(err))
	end
	assert(
		router.validate(
			database(
				"valid-entries",
				'[{"directory":"/tmp","file":"a.c","arguments":["cc","a.c"]},{"directory":"/tmp","file":"b.c","command":"cc b.c"}]'
			)
		)
	)

	local stable = database("stable-active", "[]")
	local hostile = database("hostile-candidate", "[]")
	assert(router.set_provider(root, "meson", stable))
	local active = assert(router.active(root))
	assert(router.candidate(root, "cmake", hostile))
	assert(vim.fn.writefile({ '[{"directory":"/tmp","file":"a.c"}]' }, hostile .. "/compile_commands.json") == 0)
	local applied, apply_err = router.apply(root, { provider = "cmake" })
	assert(applied == nil and apply_err:find("exactly one", 1, true))
	local status = router.status(root)
	assert(status.active.fingerprint == active.fingerprint, "hostile candidate replaced the prior active database")
	assert(status.candidates.cmake == nil, "hostile candidate remained eligible")
end)

test("files over 256 MiB require explicit unchecked candidate and apply", function()
	configure()
	local directory = database("huge", "[]")
	local path = directory .. "/compile_commands.json"
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_ftruncate(fd, router.MAX_BYTES + 1))
	assert(vim.uv.fs_close(fd))
	local value, err = router.validate(directory)
	assert(value == nil and err:find("use bang", 1, true))
	local candidate = assert(router.candidate(root, "cmake", directory, { unchecked = true }))
	assert(candidate.validity == "unchecked")
	value, err = router.apply(root, { provider = "cmake" })
	assert(value == nil and err:find("requires bang", 1, true))
	assert(vim.fn.writefile({ "[]" }, path) == 0)
	local downgraded = assert(router.apply(root, { provider = "cmake" }))
	assert(downgraded.active.validity == "structural")

	local growing = database("growing", "[]")
	local candidate = assert(router.candidate(root, "cmake", growing))
	local growing_path = growing .. "/compile_commands.json"
	fd = assert(vim.uv.fs_open(growing_path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_ftruncate(fd, router.MAX_BYTES + 1))
	assert(vim.uv.fs_close(fd))
	value, err = router.apply(root, { provider = "cmake" })
	assert(value == nil and err:find("use bang", 1, true))
	assert(router.active(root).fingerprint == downgraded.active.fingerprint, "failed growth replaced active state")
	local unchecked = assert(router.apply(root, { provider = "cmake", unchecked = true }))
	assert(unchecked.active.validity == "unchecked" and unchecked.active.fingerprint ~= candidate.fingerprint)
end)

test("apply refreshes a mutated candidate and preserves active on invalid revalidation", function()
	configure()
	local stable = database("mutation-stable", "[]")
	local changing = database("mutation-changing", "[]")
	assert(router.set_provider(root, "meson", stable))
	local previous = assert(router.active(root))
	local candidate = assert(router.candidate(root, "cmake", changing))
	assert(
		vim.fn.writefile(
			{ '[{"directory":"/tmp","file":"probe.c","command":"cc probe.c"}]' },
			changing .. "/compile_commands.json"
		) == 0
	)
	local applied = assert(router.apply(root, { provider = "cmake" }))
	assert(applied.active.fingerprint ~= candidate.fingerprint, "apply published the stale candidate fingerprint")
	assert(applied.active.validity == "structural")

	local invalid = database("mutation-invalid", "[]")
	assert(router.candidate(root, "cmake", invalid))
	assert(vim.fn.writefile({ "{" }, invalid .. "/compile_commands.json") == 0)
	local result, err = router.apply(root, { provider = "cmake" })
	assert(result == nil and err:find("expected a JSON array", 1, true))
	assert(router.active(root).fingerprint == applied.active.fingerprint, "invalid revalidation replaced active state")
	assert(router.active(root).fingerprint ~= previous.fingerprint)
end)

test("candidate and apply are distinct with deterministic providers and RAM override", function()
	configure()
	local cmake = database("cmake")
	local meson = database("meson")
	local manual = database("manual")
	assert(router.candidate(root, "cmake", cmake))
	assert(router.status(root).state == "candidate" and router.active(root) == nil)
	assert(router.candidate(root, "meson", meson))
	local applied = assert(router.apply(root))
	local active = applied.active
	assert(active.provider == "meson" and active.directory == meson)
	assert(applied.state == "active" and applied.candidate == nil and applied.error == nil)
	local invalid, err = router.candidate(root, "cmake", database("provider-error", "{}"))
	assert(invalid == nil and err:find("expected a JSON array", 1, true))
	local error_state = router.status(root)
	assert(error_state.state == "error" and error_state.active.directory == meson)
	assert(router.set_override(root, manual).active.provider == "manual")
	assert(router.set_provider(root, "cmake", cmake).active.provider == "manual")
	assert(router.clear_override(root).active.provider == "meson")
	router._reset_for_tests()
	router.setup({})
	assert(router.active(root) == nil, "manual override survived process-local reset")
end)

test("changed or malformed active databases become stale without replacement", function()
	configure()
	local directory = database("stale")
	assert(router.set_provider(root, "cmake", directory))
	local active = assert(router.active(root))
	assert(vim.fn.writefile({ "not json" }, directory .. "/compile_commands.json") == 0)
	local refreshed, refresh_err, status = router.refresh(root)
	assert(refreshed == nil and refresh_err:find("expected a JSON array", 1, true))
	assert(status.state == "stale" and status.active.directory == active.directory)
	local generation = status.generation
	assert(router.status(root).generation == generation, "stale status republished without a transition")
	assert(router.command_directory(root) == directory)
end)

test("restarts coalesce, build latest cmd first, and create one ordered client per root", function()
	configure()
	local first = database("first")
	local second = database("second")
	clients = {
		{ id = 1, root = root, attached_buffers = { [5] = true, [1] = true } },
		{ id = 2, root = root, attached_buffers = { [3] = true, [2] = true } },
		{ id = 3, root = fixture .. "/other", attached_buffers = { [9] = true } },
	}
	assert(router.set_provider(root, "cmake", first))
	assert(router.set_provider(root, "cmake", second))
	local pending = router.status(root)
	assert(pending.active_revision == 2 and pending.applied_revision == 0 and pending.restart_pending)
	assert(#deferred == 1, "restart was not coalesced")
	deferred[1]()
	assert(vim.deep_equal(stopped, { 1, 2 }))
	assert(#waits == 1 and waits[1].root == root and waits[1].timeout_ms == 5000)
	assert(#waits[1].clients == 2)
	assert(#starts == 1)
	assert(starts[1].config.cmd[2] == "--compile-commands-dir=" .. second)
	assert(vim.deep_equal(attached, {
		{ bufnr = 1, client_id = 77 },
		{ bufnr = 2, client_id = 77 },
		{ bufnr = 3, client_id = 77 },
		{ bufnr = 5, client_id = 77 },
	}))
	assert(#initialization_waits == 1)
	assert(initialization_waits[1].client_id == 77 and initialization_waits[1].root == root)
	assert(initialization_waits[1].timeout_ms == 5000)
	assert(#initialization_waits[1].attached == 4, "initialization was checked before all buffers attached")
	assert(#reconciliations == 1 and reconciliations[1].root == root)
	local applied = router.status(root)
	assert(applied.active_revision == 2 and applied.applied_revision == 2 and not applied.restart_pending)
	assert(router.set_provider(root, "cmake", second))
	assert(#deferred == 1, "unchanged active database scheduled another restart")
end)

test("initialization failure discards replacement and restores an initialized rollback", function()
	configure()
	local first = database("initialize-rollback-first")
	local second = database("initialize-rollback-second")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()
	assert(router.status(root).applied_revision == 1)

	local starts_after_baseline = 0
	start_hook = function()
		starts_after_baseline = starts_after_baseline + 1
		return { owned = true, client_id = starts_after_baseline == 1 and 78 or 79 }
	end
	local waits_after_baseline = 0
	initialize_hook = function()
		waits_after_baseline = waits_after_baseline + 1
		if waits_after_baseline == 1 then
			return nil, "initialize rejected"
		end
		return true
	end
	assert(router.set_provider(root, "cmake", second))
	deferred[2]()

	local status = router.status(root)
	assert(#discarded == 1 and discarded[1].client_id == 78, "failed replacement was not discarded")
	assert(initialization_waits[#initialization_waits - 1].client_id == 78)
	assert(initialization_waits[#initialization_waits].client_id == 79)
	assert(status.active_revision == 2 and status.applied_revision == 1)
	assert(status.active.directory == second and status.applied.directory == first)
	assert(status.error:find("previous clangd configuration restored", 1, true))
end)

test("failed rollback initialization clears applied state", function()
	configure()
	local first = database("initialize-failure-first")
	local second = database("initialize-failure-second")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()

	local next_id = 80
	start_hook = function()
		local client_id = next_id
		next_id = next_id + 1
		return { owned = true, client_id = client_id }
	end
	initialize_hook = function()
		return nil, "initialize timed out"
	end
	assert(router.set_provider(root, "cmake", second))
	deferred[2]()

	local status = router.status(root)
	assert(#discarded == 2 and discarded[1].client_id == 80 and discarded[2].client_id == 81)
	assert(status.applied == nil and status.applied_revision == nil)
	assert(status.error:find("previous clangd configuration could not be restored", 1, true))
end)

test("initialization callback exceptions are contained before publication", function()
	configure()
	local first = database("initialize-exception-first")
	local second = database("initialize-exception-second")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()

	local calls = 0
	initialize_hook = function()
		calls = calls + 1
		if calls == 1 then
			error("wait exploded")
		end
		return true
	end
	assert(router.set_provider(root, "cmake", second))
	local ok, err = pcall(deferred[2])
	assert(ok, "initialization callback exception escaped: " .. tostring(err))
	local status = router.status(root)
	assert(#discarded == 1 and discarded[1].client_id == 77)
	assert(status.applied_revision == 1 and status.active_revision == 2)
	assert(status.error:find("could not confirm clangd initialization", 1, true))
end)

test("reentrant updates schedule one exact follow-up transaction", function()
	configure()
	local first = database("reentrant-first")
	local second = database("reentrant-second")
	local third = database("reentrant-third")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()
	assert(router.status(root).applied_revision == 1)

	assert(router.set_provider(root, "cmake", second))
	local reentered = false
	start_hook = function()
		if not reentered then
			reentered = true
			assert(router.set_provider(root, "cmake", third))
		end
		return { owned = true, client_id = 77 }
	end
	deferred[2]()
	local between = router.status(root)
	assert(between.active_revision == 3 and between.applied_revision == 2)
	assert(#deferred == 3 and between.restart_pending, "reentrant update did not queue one continuation")
	deferred[3]()
	local final = router.status(root)
	assert(final.active_revision == 3 and final.applied_revision == 3 and not final.restart_pending)
	assert(starts[#starts - 1].config.cmd[2] == "--compile-commands-dir=" .. second)
	assert(starts[#starts].config.cmd[2] == "--compile-commands-dir=" .. third)
end)

test("failed replacement restores only the last applied configuration", function()
	configure()
	local first = database("rollback-first")
	local second = database("rollback-second")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()
	local first_status = router.status(root)
	assert(first_status.applied_revision == first_status.active_revision)

	assert(router.set_provider(root, "cmake", second))
	local attempts = 0
	start_hook = function()
		attempts = attempts + 1
		if attempts == 1 then
			return { owned = false, error = "start rejected" }
		end
		return { owned = true, client_id = 88 }
	end
	deferred[2]()
	local failed = router.status(root)
	assert(failed.active_revision == 2 and failed.applied_revision == 1)
	assert(failed.active.directory == second and failed.applied.directory == first)
	assert(failed.error:find("previous clangd configuration restored", 1, true))
	assert(starts[#starts - 1].config.cmd[2] == "--compile-commands-dir=" .. second)
	assert(starts[#starts].config.cmd[2] == "--compile-commands-dir=" .. first)
	assert(not failed.restart_pending, "failed unchanged revision retried forever")
end)

test("unconfirmed stop and failed rollback never claim an applied revision", function()
	configure()
	local first = database("failure-first")
	local second = database("failure-second")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()
	assert(router.set_provider(root, "cmake", second))
	wait_hook = function()
		return false
	end
	deferred[2]()
	local timed_out = router.status(root)
	assert(timed_out.applied_revision == nil and timed_out.error:find("timed out", 1, true))

	configure()
	first = database("rollback-failure-first")
	second = database("rollback-failure-second")
	clients = { { id = 2, root = root, attached_buffers = { [2] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()
	assert(router.set_provider(root, "cmake", second))
	start_hook = function()
		return { owned = false, error = "start rejected" }
	end
	deferred[2]()
	local unrestored = router.status(root)
	assert(unrestored.applied_revision == nil and unrestored.applied == nil)
	assert(unrestored.error:find("could not be restored", 1, true))
end)

test("reconciliation captures autoactivated buffers before one owned start", function()
	configure()
	local directory = database("reconcile-autoactivation")
	clients = { { id = 1, root = root, attached_buffers = { [4] = true } } }
	reconcile_hook = function(reconcile_root, timeout_ms)
		assert(reconcile_root == root and timeout_ms == 5000)
		return { 2, 6 }
	end
	assert(router.set_provider(root, "cmake", directory))
	deferred[1]()
	assert(#starts == 1, "reconciliation created more than one replacement")
	assert(
		vim.deep_equal(attached, {
			{ bufnr = 2, client_id = 77 },
			{ bufnr = 4, client_id = 77 },
			{ bufnr = 6, client_id = 77 },
		}),
		"autoactivated buffers were not merged into the replacement"
	)
	assert(router.status(root).applied_revision == 1)
end)

test("partial attachment discards the owned client before rollback", function()
	configure()
	local first = database("attach-first")
	local second = database("attach-second")
	clients = { { id = 1, root = root, attached_buffers = { [1] = true, [2] = true } } }
	assert(router.set_provider(root, "cmake", first))
	deferred[1]()
	assert(router.set_provider(root, "cmake", second))
	local attempts = 0
	attach_hook = function(bufnr)
		attempts = attempts + 1
		if attempts == 2 then
			return false
		end
		return true
	end
	deferred[2]()
	local state = router.status(root)
	assert(#discarded == 1 and discarded[1].client_id == 77, "partial client was not explicitly discarded")
	assert(state.applied_revision == 1 and state.applied.directory == first)
	assert(state.error:find("previous clangd configuration restored", 1, true))
end)

test("setup contracts reject unknown options without mutating active state", function()
	local events = {}
	configure(function(event)
		events[#events + 1] = event
	end)
	local directory = database("contract-active", "[]")
	assert(router.set_provider(root, "cmake", directory))
	local active = assert(router.active(root))
	local config = assert(router.effective_config())
	assert(config.lsp == nil and config.defer == nil and config.event == nil and config.events == nil)
	assert(pcall(vim.json.encode, config))
	config.restart_timeout_ms = 1
	assert(assert(router.effective_config()).restart_timeout_ms == 5000)
	local first = router.status(root)
	first.active.directory = "mutated"
	assert(router.status(root).active.directory == directory)
	local ok, err = pcall(router.setup, { injected = true })
	assert(not ok and tostring(err):find("unknown key", 1, true))
	assert(router.active(root).fingerprint == active.fingerprint)
	local aggregate = router.status()
	assert(aggregate.configured == true and aggregate.roots[root].active.directory == directory)
	aggregate.roots[root].active.directory = "mutated"
	assert(router.status().roots[root].active.directory == directory)
	assert(events[1].kind == "setup" and events[1].config.lsp == nil)
	assert(pcall(vim.json.encode, events[1].config))
	assert(router.teardown())
	assert(router.effective_config().restart_timeout_ms == 5000)
	assert(router.status().configured == false)
	assert(type(router.status(root)) == "table")
end)

test("clear override coalesces fallback and skips unapplied round trips", function()
	configure()
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	local fallback = database("clear-fallback")
	local manual = database("clear-manual")
	assert(router.set_provider(root, "cmake", fallback))
	assert(router.set_override(root, manual))
	local cleared = assert(router.clear_override(root))
	assert(cleared.active.provider == "cmake" and cleared.active.directory == fallback)
	assert(#deferred == 1, "fallback transitions did not coalesce to one restart")
	deferred[1]()
	assert(#starts == 1 and starts[1].config.cmd[2] == "--compile-commands-dir=" .. fallback)

	configure()
	clients = { { id = 2, root = root, attached_buffers = { [2] = true } } }
	fallback = database("clear-invalid-fallback")
	manual = database("clear-invalid-manual")
	assert(router.set_provider(root, "cmake", fallback))
	assert(router.set_override(root, manual))
	assert(vim.fn.writefile({ "{" }, fallback .. "/compile_commands.json") == 0)
	local failed, clear_err = router.clear_override(root)
	assert(failed == nil and clear_err:find("expected a JSON array", 1, true))
	assert(router.active(root) == nil, "invalid fallback retained the cleared manual database")
	assert(#deferred == 1, "invalid fallback did not coalesce the removal restart")
	deferred[1]()
	assert(#starts == 0, "unapplied override round trip restarted the unchanged base configuration")

	configure()
	clients = { { id = 3, root = root, attached_buffers = { [3] = true } } }
	manual = database("clear-only-manual")
	assert(router.set_override(root, manual))
	cleared = assert(router.clear_override(root))
	assert(cleared.active == nil and cleared.state == "candidate")
	assert(#deferred == 1, "no-database transitions did not coalesce to one restart")
	deferred[1]()
	assert(#starts == 0, "unapplied manual round trip restarted the unchanged base configuration")
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("clangd_compile_db_spec: %d tests passed", count))
vim.cmd("quitall!")
