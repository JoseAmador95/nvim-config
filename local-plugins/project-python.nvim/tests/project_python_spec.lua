vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.getcwd() .. "/local-plugins/project-python.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local project_python = require("project_python")
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))

local function executable(path)
	assert(vim.fn.mkdir(vim.fs.dirname(path), "p") >= 0)
	assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path) == 0)
	assert(vim.uv.fs_chmod(path, tonumber("700", 8)))
	return vim.fs.normalize(path)
end

local repo = fixture .. "/repo"
local service = repo .. "/services/api"
local source = service .. "/src/main.py"
assert(vim.fn.mkdir(service .. "/src", "p") == 1)
assert(vim.fn.writefile({ "[project]" }, service .. "/pyproject.toml") == 0)
assert(vim.fn.writefile({ "pass" }, source) == 0)
local automatic = executable(service .. "/.venv/bin/python")
local manual = executable(service .. "/.manual/bin/python")
local fallback = executable(fixture .. "/host/bin/python3")

local env = {}
local explicit = {}
local terminal_calls = {}
local terminal = {}
for _, action in ipairs({ "open", "toggle", "focus", "restart" }) do
	terminal[action] = function(spec)
		terminal_calls[#terminal_calls + 1] = { action = action, value = vim.deepcopy(spec) }
		return { spec = spec }
	end
end
terminal.status = function(identity)
	terminal_calls[#terminal_calls + 1] = { action = "status", value = vim.deepcopy(identity) }
	return { exists = false, running = false }
end
terminal.send = function(identity, text)
	terminal_calls[#terminal_calls + 1] = { action = "send", value = vim.deepcopy(identity), text = text }
	return true
end

local function configure(overrides)
	overrides = overrides or {}
	project_python._reset_for_tests()
	env = {}
	explicit = {}
	terminal_calls = {}
	project_python.setup({
		environment = overrides.environment or function()
			return env
		end,
		event = overrides.event,
		explicit = overrides.explicit or function(root)
			return explicit[root]
		end,
		fallback = overrides.fallback or function()
			return fallback
		end,
		terminal = terminal,
		test_runner = overrides.test_runner,
		repl = overrides.repl,
	})
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
	local first = project_python.effective_config()
	assert(first.test_runner == "pytest")
	assert(first.repl.readiness_timeout_ms == 5000 and first.repl.poll_interval_ms == 50)
	first.repl.poll_interval_ms = 1
	first.root_markers[1] = "mutated"
	local second = project_python.effective_config()
	assert(second.repl.poll_interval_ms == 50 and second.root_markers[1] == "pyrightconfig.json")
	assert(pcall(vim.json.encode, second))

	local status = project_python.status()
	assert(status.configured == false and vim.tbl_isempty(status.snapshots))
	status.configured = true
	assert(project_python.status().configured == false)
end)

test("root precedence is attached, nearest marker, repository, then directory", function()
	configure()
	assert(project_python.resolve_root({ start = source, attached_root = service, repo_root = repo }) == service)
	assert(project_python.resolve_root({ start = source, repo_root = repo }) == service)
	assert(vim.fn.delete(service .. "/pyproject.toml") == 0)
	assert(project_python.resolve_root({ start = source, repo_root = repo }) == repo)
	assert(project_python.resolve_root({ start = source }) == service .. "/src")
	assert(vim.fn.writefile({ "[project]" }, service .. "/pyproject.toml") == 0)
end)

test("precedence is explicit, manual, project environment, active environment, fallback", function()
	configure()
	local snapshot = project_python.snapshot(service)
	assert(snapshot.source == "local:.venv" and snapshot.value.interpreter == automatic)
	assert(project_python.select(service, manual).source == "manual")
	local chosen = executable(service .. "/.chosen/bin/python")
	explicit[service] = { pythonPath = chosen }
	snapshot = project_python.refresh(service)
	assert(snapshot.source == "explicit" and snapshot.value.interpreter == chosen)
	explicit[service] = nil
	assert(project_python.refresh(service).source == "manual")
	assert(vim.fn.delete(manual) == 0)
	assert(project_python.refresh(service).source == "local:.venv")
	assert(vim.fn.delete(automatic) == 0)
	local active = executable(service .. "/.active/bin/python")
	env.VIRTUAL_ENV = service .. "/.active"
	assert(project_python.refresh(service).value.interpreter == active)
	env.VIRTUAL_ENV = nil
	assert(project_python.refresh(service).source == "fallback")
end)

test("invalid explicit configuration fails without automatic fallback", function()
	configure()
	local local_python = executable(service .. "/.venv/bin/python")
	explicit[service] = { pythonPath = service .. "/missing/python" }
	local snapshot = project_python.snapshot(service)
	assert(snapshot.source == "explicit" and snapshot.validity == "invalid")
	assert(snapshot.value.interpreter == nil)
	assert(local_python ~= nil)
	explicit[service] = { venvPath = service .. "/envs" }
	assert(project_python.refresh(service).validity == "invalid")
end)

test("snapshots are copied, generation-aware, and stale manual choices wait for refresh", function()
	configure()
	local local_python = executable(service .. "/.venv/bin/python")
	local selected_python = executable(service .. "/.selected/bin/python")
	local selected_snapshot = assert(project_python.select(service, selected_python))
	selected_snapshot.value.interpreter = "mutated"
	local copy = project_python.snapshot(service)
	assert(copy.value.interpreter == selected_python)
	assert(copy.generation == selected_snapshot.generation)
	assert(vim.fn.delete(selected_python) == 0)
	local stale = project_python.snapshot(service)
	assert(stale.source == "manual" and stale.value.interpreter == selected_python)
	assert(stale.generation == copy.generation)
	stale = project_python.refresh(service)
	assert(stale.source == "local:.venv" and stale.value.interpreter == local_python)
	assert(stale.generation > copy.generation)
	project_python._reset_for_tests()
	project_python.setup({
		fallback = function()
			return fallback
		end,
	})
	assert(project_python.snapshot(service).source ~= "manual", "manual choice persisted across reset")
end)

test("default snapshot hits bypass canonicalization and discovery", function()
	configure()
	executable(service .. "/.venv/bin/python")
	local first = project_python.snapshot(service)
	local original_realpath = vim.uv.fs_realpath
	local original_stat = vim.uv.fs_stat
	local original_access = vim.uv.fs_access
	vim.uv.fs_realpath = function()
		error("cached snapshot canonicalized its root")
	end
	vim.uv.fs_stat = function()
		error("cached snapshot inspected the filesystem")
	end
	vim.uv.fs_access = function()
		error("cached snapshot inspected executable bits")
	end
	local ok, second = pcall(project_python.snapshot, service)
	vim.uv.fs_realpath = original_realpath
	vim.uv.fs_stat = original_stat
	vim.uv.fs_access = original_access
	assert(ok, second)
	assert(vim.deep_equal(second, first))
end)

test("caller explicit snapshots are ephemeral", function()
	local events = {}
	configure({
		event = function(event)
			events[#events + 1] = event
		end,
	})
	local automatic_python = executable(service .. "/.venv/bin/python")
	local baseline = project_python.snapshot(service)
	assert(baseline.value.interpreter == automatic_python)
	local status = project_python.status()
	local event_count = #events
	local override = executable(service .. "/.ephemeral/bin/python")
	local explicit_snapshot = project_python.snapshot(service, { explicit = { pythonPath = override } })
	assert(explicit_snapshot.source == "explicit" and explicit_snapshot.value.interpreter == override)
	assert(explicit_snapshot.generation == baseline.generation)
	local invalid = project_python.snapshot(service, { explicit = { pythonPath = service .. "/missing/python" } })
	assert(invalid.source == "explicit" and invalid.validity == "invalid")
	assert(invalid.generation == baseline.generation)
	assert(vim.deep_equal(project_python.status(), status), "ephemeral snapshot changed published state")
	assert(#events == event_count, "ephemeral snapshot emitted an event")
	assert(vim.deep_equal(project_python.snapshot(service), baseline))
end)

test("Pyright, Neotest, and DAP consume the same immutable snapshot", function()
	configure()
	local python = executable(service .. "/.venv/bin/python")
	local settings = { pyright = { disableOrganizeImports = true } }
	local config = { root_dir = service, settings = settings }
	local snapshot = project_python.apply_pyright(config, service)
	assert(rawequal(config.settings, settings))
	assert(config.settings.python.pythonPath == python)
	assert(snapshot.value.interpreter == python)
	assert(vim.deep_equal(project_python.neotest_python(service), { python }))
	assert(project_python.neotest_runner() == "pytest")
	local dap, dap_snapshot = project_python.apply_dap({ type = "python", request = "launch" }, service)
	assert(dap.pythonPath == python and dap_snapshot.value.interpreter == python)

	local invalid = { root_dir = service, settings = { python = { pythonPath = "/missing/python" } } }
	snapshot = project_python.apply_pyright(invalid, service)
	assert(snapshot.validity == "invalid" and invalid.settings.python.pythonPath == "/missing/python")
	local explicit_dap, explicit_snapshot =
		project_python.apply_dap({ type = "python", pythonPath = "/missing/python" }, service)
	assert(explicit_snapshot.validity == "invalid" and explicit_dap.pythonPath == "/missing/python")
end)

test("discovery never executes Python and REPL uses only the injected lifecycle", function()
	configure()
	executable(service .. "/.venv/bin/python")
	local original_system = vim.system
	vim.system = function()
		error("project-python executed a process")
	end
	local ok, err = xpcall(function()
		assert(project_python.snapshot(service).validity == "valid")
		local spec = assert(project_python.repl_spec(service))
		assert(vim.deep_equal(spec.launch.argv, { service .. "/.venv/bin/python", "-i" }))
		assert(project_python.repl("open", service))
		assert(project_python.repl("send", service, { text = "print(42)" }))
		assert(terminal_calls[#terminal_calls].text == "print(42)")
	end, debug.traceback)
	vim.system = original_system
	assert(ok, err)
end)

test("defaultInterpreterPath is approved and diagnostics enumerate without executing", function()
	configure()
	local approved = executable(service .. "/.approved/bin/python")
	explicit[service] = { defaultInterpreterPath = approved }
	local snapshot = project_python.snapshot(service)
	assert(snapshot.source == "explicit" and snapshot.value.interpreter == approved)
	local original_system = vim.system
	vim.system = function()
		error("diagnostics executed Python")
	end
	local ok, diagnostics = pcall(project_python.diagnostics, service)
	vim.system = original_system
	assert(ok and diagnostics.root == service and #diagnostics.candidates > 0)
	assert(diagnostics.candidates[1].source == "explicit")
end)

test("setup contracts are transactional and snapshots are immutable", function()
	local events = {}
	configure({
		event = function(event)
			events[#events + 1] = event
		end,
		repl = { readiness_timeout_ms = 5000, poll_interval_ms = 50 },
		test_runner = "pytest",
	})
	local before = assert(project_python.effective_config())
	assert(before.test_runner == "pytest" and before.repl.readiness_timeout_ms == 5000)
	assert(before.environment == nil and before.event == nil and before.terminal == nil)
	assert(pcall(vim.json.encode, before))
	before.repl.poll_interval_ms = 1
	assert(assert(project_python.effective_config()).repl.poll_interval_ms == 50)
	local snapshot = project_python.snapshot(service)
	local first = project_python.status(service)
	first.snapshot.value.interpreter = "mutated"
	assert(project_python.status(service).snapshot.value.interpreter == snapshot.value.interpreter)
	local ok, err = pcall(project_python.setup, { injected = true })
	assert(not ok and tostring(err):find("unknown key", 1, true))
	ok, err = pcall(project_python.setup, false)
	assert(not ok, "false setup options were accepted")
	ok, err = pcall(project_python.setup, { repl = false })
	assert(not ok, "false repl options were accepted")
	ok, err = pcall(project_python.setup, { test_runner = "nose" })
	assert(not ok and tostring(err):find("pytest or unittest", 1, true))
	assert(project_python.effective_config().test_runner == "pytest")
	assert(project_python.status(service).snapshot.value.interpreter == snapshot.value.interpreter)
	local aggregate = project_python.status()
	assert(aggregate.configured == true and aggregate.snapshots[service] ~= nil)
	aggregate.snapshots[service].value.interpreter = "mutated"
	assert(project_python.status().snapshots[service].value.interpreter == snapshot.value.interpreter)
	assert(events[1].kind == "setup" and events[1].config.terminal == nil)
	assert(pcall(vim.json.encode, events[1].config))
	for _, event in ipairs(events) do
		assert(not (event.status and event.status._fingerprint), "private fingerprint escaped in an event")
	end
	assert(project_python.teardown())
	local defaults = project_python.effective_config()
	assert(defaults.test_runner == "pytest" and defaults.repl.poll_interval_ms == 50)
	assert(project_python.status().configured == false)
	assert(project_python.status(service).configured == false)
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("project_python_spec: %d tests passed", count))
vim.cmd("quitall!")
