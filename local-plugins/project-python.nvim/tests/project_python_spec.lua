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

local function configure()
	project_python._reset_for_tests()
	env = {}
	explicit = {}
	terminal_calls = {}
	project_python.setup({
		environment = function()
			return env
		end,
		explicit = function(root)
			return explicit[root]
		end,
		fallback = function()
			return fallback
		end,
		terminal = terminal,
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
	snapshot = project_python.snapshot(service)
	assert(snapshot.source == "explicit" and snapshot.value.interpreter == chosen)
	explicit[service] = nil
	assert(project_python.snapshot(service).source == "manual")
	assert(vim.fn.delete(manual) == 0)
	assert(project_python.snapshot(service).source == "local:.venv")
	assert(vim.fn.delete(automatic) == 0)
	local active = executable(service .. "/.active/bin/python")
	env.VIRTUAL_ENV = service .. "/.active"
	assert(project_python.snapshot(service).value.interpreter == active)
	env.VIRTUAL_ENV = nil
	assert(project_python.snapshot(service).source == "fallback")
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
	assert(project_python.snapshot(service).validity == "invalid")
end)

test("snapshots are copied, generation-aware, and stale manual choices fall through", function()
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

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("project_python_spec: %d tests passed", count))
vim.cmd("quitall!")
