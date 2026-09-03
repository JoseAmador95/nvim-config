vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/project-python.nvim")
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/a/src", "p")
vim.fn.mkdir(fixture .. "/b/src", "p")
vim.fn.mkdir(fixture .. "/a/.venv/bin", "p")
vim.fn.mkdir(fixture .. "/a/.other/bin", "p")
vim.fn.mkdir(fixture .. "/b/.venv/bin", "p")
fixture = vim.uv.fs_realpath(fixture) or fixture
vim.fn.writefile({ "[project]", 'name = "a"' }, fixture .. "/a/pyproject.toml")
vim.fn.writefile({ "[project]", 'name = "b"' }, fixture .. "/b/pyproject.toml")
vim.fn.writefile({ "print('a')" }, fixture .. "/a/src/test_a.py")
vim.fn.writefile({ "print('b')" }, fixture .. "/b/src/test_b.py")

local function interpreter(path, has_pytest)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({
		"#!/bin/sh",
		has_pytest and 'case "$*" in *pytest*) exit 0;; *IPython*) exit 1;; esac' or "exit 1",
		"exit 1",
	}, path)
	vim.uv.fs_chmod(path, tonumber("700", 8))
end

local python_a = fixture .. "/a/.venv/bin/python"
local python_a2 = fixture .. "/a/.other/bin/python"
local python_b = fixture .. "/b/.venv/bin/python"
interpreter(python_a, true)
interpreter(python_a2, false)
interpreter(python_b, false)

local original_selector = package.loaded["venv-selector"]
local original_terminal = package.loaded["config.terminal"]
local original_project_settings = package.loaded["config.project_settings"]
local original_local_config = package.loaded["config.local_config"]
local original_clients = vim.lsp.get_clients
local original_select = vim.ui.select
local original_defer_fn = vim.defer_fn
local original_path = vim.env.PATH
local original_uv_project_environment = vim.env.UV_PROJECT_ENVIRONMENT
local original_virtual_env = vim.env.VIRTUAL_ENV
local original_conda_prefix = vim.env.CONDA_PREFIX
vim.env.UV_PROJECT_ENVIRONMENT = nil
vim.env.VIRTUAL_ENV = nil
vim.env.CONDA_PREFIX = nil

local function with_python_env(values, callback)
	local previous = {}
	for _, name in ipairs({ "UV_PROJECT_ENVIRONMENT", "VIRTUAL_ENV", "CONDA_PREFIX" }) do
		previous[name] = vim.env[name] or false
		vim.env[name] = values[name]
	end
	local ok, err = xpcall(callback, debug.traceback)
	for name, value in pairs(previous) do
		vim.env[name] = value ~= false and value or nil
	end
	assert(ok, err)
end

local active_python
local explicit_project_values = {}
package.loaded["config.project_settings"] = {
	get = function(key, default)
		return vim.deepcopy(explicit_project_values[key] or default)
	end,
}
package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		if name == "clangd_compile_db" then
			return vim.deepcopy(defaults)
		end
		assert(name == "project_python")
		assert(defaults.test_runner == "pytest")
		assert(defaults.repl.readiness_timeout_ms == 5000 and defaults.repl.poll_interval_ms == 50)
		return vim.deepcopy(defaults)
	end,
}
package.loaded["venv-selector"] = {
	python = function()
		return active_python
	end,
}
vim.lsp.get_clients = function()
	return {}
end

local terminal_exists = false
local terminal_running = false
local terminal_accepting_input = false
local terminal_stop_pending = false
local terminal_restart_pending = false
local terminal_dispose_pending = false
local toggled_specs = {}
local restarted_specs = {}
local opened_specs = {}
local focused_specs = {}
local sent = {}
package.loaded["config.terminal"] = {
	status = function()
		return {
			exists = terminal_exists,
			running = terminal_running,
			accepting_input = terminal_running and terminal_accepting_input,
			stop_pending = terminal_stop_pending,
			restart_pending = terminal_restart_pending,
			dispose_pending = terminal_dispose_pending,
			state = terminal_exists and (terminal_running and "running" or "exited-retained") or "disposed",
		}
	end,
	toggle = function(spec)
		terminal_exists = true
		terminal_running = true
		toggled_specs[#toggled_specs + 1] = vim.deepcopy(spec)
		return { spec = spec }
	end,
	open = function(spec)
		terminal_exists = true
		terminal_running = true
		opened_specs[#opened_specs + 1] = vim.deepcopy(spec)
		return { spec = spec }
	end,
	restart = function(spec)
		terminal_exists = true
		terminal_running = true
		restarted_specs[#restarted_specs + 1] = vim.deepcopy(spec)
		return { spec = spec }
	end,
	focus = function(spec)
		focused_specs[#focused_specs + 1] = vim.deepcopy(spec)
		return {}
	end,
	send = function(identity, text)
		sent[#sent + 1] = { identity = vim.deepcopy(identity), text = text }
		return true
	end,
}

local deferred_callbacks = {}
vim.defer_fn = function(callback)
	deferred_callbacks[#deferred_callbacks + 1] = callback
end

local function drain_deferred(limit)
	limit = limit or 200
	for _ = 1, limit do
		local callback = table.remove(deferred_callbacks, 1)
		if not callback then
			return
		end
		callback()
	end
	assert(#deferred_callbacks == 0, "deferred callback queue exceeded its test bound")
end

local python = require("config.python")
assert(package.loaded.project_python == nil, "project-python loaded before the first Python operation")
local buf_a = vim.fn.bufadd(fixture .. "/a/src/test_a.py")
local buf_b = vim.fn.bufadd(fixture .. "/b/src/test_b.py")
vim.fn.bufload(buf_a)
vim.fn.bufload(buf_b)

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

test("automatic environments follow deterministic filesystem-only priority", function()
	local root = fixture .. "/priority"
	local paths = {
		uv = root .. "/.uv/bin/python",
		venv = root .. "/.venv/bin/python",
		pixi = root .. "/.pixi/envs/default/bin/python3",
		plain_venv = root .. "/venv/Scripts/python.exe",
		env = root .. "/env/python.exe",
		conda = root .. "/.conda/bin/python",
		active = root .. "/.active/bin/python",
		conda_prefix = root .. "/.conda-prefix/bin/python",
	}
	for _, path in pairs(paths) do
		interpreter(path, false)
	end

	with_python_env({
		UV_PROJECT_ENVIRONMENT = ".uv",
		VIRTUAL_ENV = root .. "/.active",
		CONDA_PREFIX = root .. "/.conda-prefix",
	}, function()
		for _, candidate in ipairs({
			paths.uv,
			paths.venv,
			paths.pixi,
			paths.plain_venv,
			paths.env,
			paths.conda,
			paths.active,
			paths.conda_prefix,
		}) do
			assert(python.for_root(root) == vim.fs.normalize(candidate))
			local directory = vim.fs.dirname(candidate)
			local leaf = vim.fs.basename(directory)
			local env_root = (leaf == "bin" or leaf == "Scripts") and vim.fs.dirname(directory) or directory
			assert(python.venv_name(root) == vim.fs.basename(env_root))
			assert(vim.fn.delete(candidate) == 0)
			python.refresh(root)
		end
	end)
end)

test("environment probes skip non-executable files and support all layouts", function()
	local root = fixture .. "/layouts"
	local unix_python = root .. "/.venv/bin/python"
	local unix_python3 = root .. "/.venv/bin/python3"
	local windows_scripts = root .. "/.venv/Scripts/python.exe"
	local windows_root = root .. "/.venv/python.exe"
	interpreter(unix_python, false)
	interpreter(unix_python3, false)
	interpreter(windows_scripts, false)
	interpreter(windows_root, false)
	vim.uv.fs_chmod(unix_python, tonumber("600", 8))
	assert(python.for_root(root) == unix_python3)
	assert(vim.fn.delete(unix_python3) == 0)
	python.refresh(root)
	assert(python.for_root(root) == windows_scripts)
	assert(vim.fn.delete(windows_scripts) == 0)
	python.refresh(root)
	assert(python.for_root(root) == windows_root)
end)

test("process environments are considered only when rooted in the project", function()
	local root = fixture .. "/contained"
	local local_python = root .. "/.venv/bin/python"
	local outside = fixture .. "/outside"
	interpreter(local_python, false)
	interpreter(outside .. "/bin/python", false)
	with_python_env({
		UV_PROJECT_ENVIRONMENT = outside,
		VIRTUAL_ENV = outside,
		CONDA_PREFIX = outside,
	}, function()
		assert(python.for_root(root) == local_python)
	end)
end)

test("canonical root keys preserve lexical symlinked venv interpreters", function()
	local root = fixture .. "/symlink-project"
	local target = fixture .. "/symlink-target"
	local alias = fixture .. "/symlink-project-alias"
	interpreter(target .. "/bin/python", false)
	vim.fn.mkdir(root, "p")
	assert(vim.uv.fs_symlink(target, root .. "/.venv", { dir = true }))
	assert(vim.uv.fs_symlink(root, alias, { dir = true }))
	assert(python.for_root(alias) == root .. "/.venv/bin/python")
end)

test("selection is remembered independently per project without mutating vim.env", function()
	vim.api.nvim_set_current_buf(buf_a)
	active_python = python_a
	python.refresh_current()
	vim.api.nvim_set_current_buf(buf_b)
	assert(python.for_root(fixture .. "/b") ~= python_a, "selection from project a leaked into project b")
	active_python = python_b
	python.refresh_current()
	assert(python.for_root(fixture .. "/a") == python_a)
	assert(python.for_root(fixture .. "/b") == python_b)
	assert(vim.env.PATH == original_path)
	assert(vim.env.UV_PROJECT_ENVIRONMENT == nil)
	assert(vim.env.VIRTUAL_ENV == nil)
	assert(vim.env.CONDA_PREFIX == nil)
end)

test("manual selections are root-scoped and stale interpreters are discarded", function()
	local root = fixture .. "/stale"
	local manual = root .. "/.manual/bin/python"
	local automatic = root .. "/.venv/bin/python"
	local path = root .. "/src/stale.py"
	interpreter(manual, false)
	interpreter(automatic, false)
	vim.fn.mkdir(root .. "/src", "p")
	vim.fn.writefile({ "pass" }, path)
	vim.fn.writefile({ "[project]" }, root .. "/pyproject.toml")
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	active_python = manual
	python.refresh_current(buf)
	assert(python.for_root(root) == manual)
	assert(vim.fn.delete(manual) == 0)
	python.refresh(root)
	assert(python.for_root(root) == automatic)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("Pyright, Neotest, and DAP consume the same root selection without interpreter probes", function()
	local config = { root_dir = fixture .. "/a", settings = { pyright = { disableOrganizeImports = true } } }
	python.before_init({}, config)
	assert(config.settings.python.pythonPath == python_a)
	assert(config.settings.pyright.disableOrganizeImports)
	assert(vim.deep_equal(python.neotest_python(fixture .. "/a"), { python_a }))
	assert(python.neotest_runner({ python_a }) == "pytest")
	assert(python.neotest_runner({ python_b }) == "pytest")

	vim.api.nvim_set_current_buf(buf_a)
	local dap = { listeners = { on_config = {} } }
	python.setup_dap(dap)
	local source = { type = "python", request = "launch" }
	local resolved = dap.listeners.on_config.nvim_config_python(source)
	assert(resolved ~= source and resolved.pythonPath == python_a)
	assert(dap.listeners.on_config.nvim_config_python({ type = "cppdbg" }).type == "cppdbg")
end)

test("DAP roots resolve cross-project config fields before the active buffer", function()
	vim.api.nvim_set_current_buf(buf_a)
	local dap = { listeners = { on_config = {} } }
	python.setup_dap(dap)
	local resolve = dap.listeners.on_config.nvim_config_python
	local from_cwd = resolve({
		type = "python",
		request = "launch",
		cwd = fixture .. "/b",
		program = fixture .. "/a/src/test_a.py",
	})
	assert(from_cwd.pythonPath == python_b, "cwd did not take precedence over the active A buffer")
	local from_program = resolve({
		type = "python",
		request = "launch",
		program = function()
			return fixture .. "/b/src/test_b.py"
		end,
	})
	assert(from_program.pythonPath == python_b, "program did not resolve project B")
	local from_workspace = resolve({ type = "python", request = "launch", workspace = fixture .. "/b" })
	assert(from_workspace.pythonPath == python_b, "workspace did not resolve project B")
	local placeholder = resolve({ type = "python", request = "launch", program = "${file}" })
	assert(placeholder.pythonPath == python_a, "unresolved placeholder preempted the active buffer")
end)

test("Pyright automatic configuration preserves explicit interpreter and venv settings", function()
	for _, explicit in ipairs({
		{ defaultInterpreterPath = "/explicit/default-python" },
		{ pythonPath = "/explicit/python" },
		{ venvPath = "/explicit/venvs" },
		{ venv = "chosen" },
	}) do
		local initial = { root_dir = fixture .. "/a", settings = { python = vim.deepcopy(explicit) } }
		local initial_snapshot = python.before_init({}, initial)
		assert(vim.deep_equal(initial.settings.python, explicit))
		assert(initial_snapshot.source == "explicit" and initial_snapshot.validity == "invalid")
		local updated = { root_dir = fixture .. "/a", settings = { python = vim.deepcopy(explicit) } }
		local updated_snapshot = python.on_new_config(updated, fixture .. "/a")
		assert(vim.deep_equal(updated.settings.python, explicit))
		assert(updated_snapshot.source == "explicit" and updated_snapshot.validity == "invalid")
	end

	local automatic = { root_dir = fixture .. "/a", settings = {} }
	python.on_new_config(automatic, fixture .. "/a")
	assert(automatic.settings.python.pythonPath == python.for_root(fixture .. "/a"))
end)

test("host snapshots are copied and explicit project failures never fall back", function()
	local root = fixture .. "/explicit-invalid"
	local automatic = root .. "/.venv/bin/python"
	interpreter(automatic, false)
	explicit_project_values.vscode = { python = { pythonPath = root .. "/missing/python" } }
	local snapshot = python.snapshot(root)
	assert(snapshot.source == "explicit" and snapshot.validity == "invalid")
	assert(python.for_root(root) == nil, "invalid explicit interpreter fell back to .venv")
	snapshot.value.interpreter = "mutated"
	assert(python.snapshot(root).value.interpreter == nil, "snapshot mutation leaked into plugin state")
	explicit_project_values.vscode = nil
end)

test("host discovery and Neotest runner never execute Python", function()
	local original_system = vim.system
	vim.system = function()
		error("Python discovery executed a process")
	end
	local ok, err = xpcall(function()
		assert(type(python.for_root(fixture .. "/a")) == "string")
		assert(python.neotest_runner({ python_a }) == "pytest")
	end, debug.traceback)
	vim.system = original_system
	assert(ok, err)
end)

test("manual activation restarts only Pyright clients for the selected root", function()
	local stopped = {}
	local started = {}
	local clients = {
		{
			name = "pyright",
			config = { root_dir = fixture .. "/a" },
			attached_buffers = { [buf_a] = true },
			stop = function()
				stopped.pyright_a = true
			end,
		},
		{
			name = "pyright",
			config = { root_dir = fixture .. "/b" },
			attached_buffers = { [buf_b] = true },
			stop = function()
				stopped.pyright_b = true
			end,
		},
		{
			name = "ruff",
			config = { root_dir = fixture .. "/a" },
			attached_buffers = { [buf_a] = true },
			stop = function()
				stopped.ruff = true
			end,
		},
	}
	local previous_defer = vim.defer_fn
	local previous_start = vim.lsp.start
	vim.lsp.get_clients = function()
		return clients
	end
	vim.defer_fn = function(callback)
		callback()
	end
	vim.lsp.start = function(config, options)
		started[#started + 1] = { config = config, options = options }
	end
	active_python = python_a2
	python.refresh_current(buf_a)
	vim.lsp.get_clients = function()
		return {}
	end
	vim.defer_fn = previous_defer
	vim.lsp.start = previous_start
	assert(stopped.pyright_a)
	assert(not stopped.pyright_b)
	assert(not stopped.ruff)
	assert(#started == 1 and started[1].options.bufnr == buf_a)
	assert(started[1].config.root_dir == fixture .. "/a")
end)

test("nearest Python marker outranks an enclosing Git root", function()
	local monorepo = fixture .. "/marker-monorepo"
	local service = monorepo .. "/services/api"
	local path = service .. "/src/main.py"
	vim.fn.mkdir(service .. "/src", "p")
	vim.fn.writefile({ "[project]" }, service .. "/pyproject.toml")
	vim.fn.writefile({ "pass" }, path)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	local repo_config = require("config.repo")
	local previous_root = repo_config.root
	local previous_clients = vim.lsp.get_clients
	repo_config.root = function()
		return monorepo
	end
	vim.lsp.get_clients = function()
		return {}
	end
	local ok, err = xpcall(function()
		assert(python.root(buf) == service)
	end, debug.traceback)
	repo_config.root = previous_root
	vim.lsp.get_clients = previous_clients
	vim.api.nvim_buf_delete(buf, { force = true })
	assert(ok, err)
end)

test("sending code opens and focuses the project REPL automatically", function()
	vim.api.nvim_set_current_buf(buf_a)
	vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "answer = 6 * 7" })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	active_python = python_a
	python.refresh_current()
	terminal_exists = false
	terminal_running = false
	terminal_accepting_input = false
	opened_specs = {}
	focused_specs = {}
	sent = {}
	python.send(false)
	assert(#opened_specs == 1 and vim.deep_equal(opened_specs[1].launch.argv, { python_a, "-i" }))
	assert(#sent == 0, "code was sent before the terminal accepted input")
	terminal_accepting_input = true
	drain_deferred()
	assert(#sent == 1 and sent[1].text == 'exec("answer = 6 * 7")')
	python.send(false)
	assert(#opened_specs == 1, "an existing REPL was opened twice")
	assert(#focused_specs == 1, "a hidden live REPL was not focused before sending")
	assert(#sent == 1, "second code send bypassed the deferred FIFO")
	drain_deferred()
	assert(#sent == 2, "the second line was not sent to the live REPL")
end)

test("sending code restarts a retained stopped REPL", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = true
	terminal_running = false
	terminal_accepting_input = false
	restarted_specs = {}
	opened_specs = {}
	sent = {}
	python.send(false)
	assert(#opened_specs == 0, "a stopped retained REPL was duplicated")
	assert(#restarted_specs == 1, "a stopped retained REPL was not restarted")
	assert(#sent == 0, "code was sent while REPL restart was pending")
	terminal_accepting_input = true
	drain_deferred()
	assert(#sent == 1, "code was not sent after restarting the REPL")
end)

test("an exited REPL adopts the newly selected interpreter on explicit restart", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	toggled_specs = {}
	restarted_specs = {}
	active_python = python_a
	python.refresh_current()
	python.open_repl()
	assert(#toggled_specs == 1 and vim.deep_equal(toggled_specs[1].launch.argv, { python_a, "-i" }))
	terminal_running = false
	active_python = python_a2
	python.refresh_current()
	python.open_repl()
	assert(#restarted_specs == 1)
	assert(vim.deep_equal(restarted_specs[1].launch.argv, { python_a2, "-i" }))
end)

test("opening an unchanged live REPL toggles it without restarting", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	toggled_specs = {}
	restarted_specs = {}
	active_python = python_a
	python.refresh_current()
	python.open_repl()
	assert(#toggled_specs == 1 and #restarted_specs == 0)
	python.open_repl()
	assert(#toggled_specs == 2, "second open did not toggle the live REPL")
	assert(#restarted_specs == 0, "second open restarted an unchanged live REPL")
end)

test("queued REPL sends preserve FIFO order while startup is pending", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	terminal_accepting_input = false
	opened_specs = {}
	focused_specs = {}
	sent = {}
	vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "first = 1" })
	python.send(false)
	vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "second = 2" })
	python.send(false)
	assert(#opened_specs == 1 and #focused_specs == 1 and #sent == 0)
	terminal_accepting_input = true
	drain_deferred()
	assert(#sent == 2)
	assert(sent[1].text == 'exec("first = 1")' and sent[2].text == 'exec("second = 2")')
end)

test("sending during a pending restart waits without refocusing the old process", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = true
	terminal_running = true
	terminal_accepting_input = false
	terminal_restart_pending = true
	focused_specs = {}
	sent = {}
	vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "after_restart = true" })
	python.send(false)
	assert(#focused_specs == 0 and #sent == 0, "pending restart reused the old REPL")
	terminal_restart_pending = false
	terminal_accepting_input = true
	drain_deferred()
	assert(#sent == 1 and sent[1].text == 'exec("after_restart = true")')
end)

test("queued REPL sends abort visibly when the process exits before input", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	terminal_accepting_input = false
	sent = {}
	local previous_notify = vim.notify
	local notices = {}
	vim.notify = function(message, level)
		notices[#notices + 1] = { message = message, level = level }
	end
	python.send(false)
	terminal_running = false
	drain_deferred()
	vim.notify = previous_notify
	assert(#sent == 0 and #notices == 1)
	assert(notices[1].message:find("exited before it accepted input", 1, true))
end)

test("queued REPL sends time out instead of retrying forever", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	terminal_accepting_input = false
	sent = {}
	local previous_notify = vim.notify
	local notices = {}
	vim.notify = function(message, level)
		notices[#notices + 1] = { message = message, level = level }
	end
	python.send(false)
	drain_deferred()
	vim.notify = previous_notify
	assert(#sent == 0 and #notices == 1)
	assert(notices[1].message:find("Timed out waiting for Python REPL input", 1, true))
end)

test("a live REPL asks before adopting a changed interpreter", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	toggled_specs = {}
	restarted_specs = {}
	active_python = python_a
	python.refresh_current()
	python.open_repl()
	assert(#toggled_specs == 1 and vim.deep_equal(toggled_specs[1].launch.argv, { python_a, "-i" }))
	local prompt
	vim.ui.select = function(items, opts)
		prompt = { items = items, opts = opts }
	end
	active_python = python_a2
	python.refresh_current()
	assert(prompt and prompt.opts.prompt:find("environment changed", 1, true))
	assert(#restarted_specs == 0, "REPL restarted without confirmation")
end)

local venv_spec = require("plugins.python")
test("venv-selector disables all implicit global activation paths", function()
	assert(venv_spec.commit == "cc4bb3975de8835291f9bb45889e96c6b2795fc4")
	assert(venv_spec.opts.options.cached_venv_automatic_activation == false)
	assert(venv_spec.opts.options.activate_venv_in_terminal == false)
	assert(venv_spec.opts.options.set_environment_variables == false)
	assert(#venv_spec.opts.hooks == 1 and type(venv_spec.opts.hooks[1]) == "function")
	assert(venv_spec.opts.options.on_venv_activate_callback == nil)
end)

test("venv-selector hook keeps the Python origin while its picker has focus", function()
	terminal_running = false
	active_python = python_a
	python.refresh_current(buf_a)
	local picker_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(picker_buf)
	assert(venv_spec.opts.hooks[1](python_a2, "venv", buf_a) == 0)
	assert(python.for_root(fixture .. "/a") == python_a2)
	assert(python.for_root(fixture .. "/b") == python_b)
	vim.api.nvim_set_current_buf(buf_b)
	vim.api.nvim_buf_delete(picker_buf, { force = true })
end)

test("attached Pyright root scopes manual selection and shared consumers", function()
	local monorepo = fixture .. "/lsp-monorepo"
	local service = monorepo .. "/services/api"
	local path = service .. "/src/main.py"
	local manual = service .. "/.manual/bin/python"
	vim.fn.mkdir(service .. "/src", "p")
	vim.fn.writefile({ "pass" }, path)
	interpreter(manual, false)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	local picker_buf = vim.api.nvim_create_buf(false, true)
	local repo_config = require("config.repo")
	local previous_root = repo_config.root
	local previous_clients = vim.lsp.get_clients
	local previous_defer = vim.defer_fn
	local previous_start = vim.lsp.start
	local stopped = false
	local started = {}
	local client = {
		name = "pyright",
		config = { root_dir = service },
		attached_buffers = { [buf] = true },
		stop = function()
			stopped = true
		end,
	}
	repo_config.root = function()
		return monorepo
	end
	vim.lsp.get_clients = function()
		return { client }
	end
	vim.defer_fn = function(callback)
		callback()
	end
	vim.lsp.config("pyright", {
		settings = { pyright = { disableOrganizeImports = true } },
		before_init = python.before_init,
	})
	vim.lsp.start = function(config, options)
		local restarted_client = { settings = config.settings }
		config.before_init({}, config)
		started[#started + 1] = { config = config, options = options, client = restarted_client }
	end
	terminal_running = false
	vim.api.nvim_set_current_buf(picker_buf)
	local ok, err = xpcall(function()
		assert(venv_spec.opts.hooks[1](manual, "venv", buf) == 0)
		assert(python.root(buf) == service)
		assert(python.for_root(service) == manual)
		assert(python.for_root(monorepo) ~= manual)
		assert(stopped)
		assert(#started == 1 and started[1].options.bufnr == buf)
		assert(started[1].config.root_dir == service)
		assert(rawequal(started[1].config.settings, started[1].client.settings))
		assert(started[1].client.settings.python.pythonPath == manual)
		assert(started[1].client.settings.pyright.disableOrganizeImports)
		assert(vim.deep_equal(python.neotest_python(service), { manual }))
		vim.api.nvim_set_current_buf(buf)
		local original_cmake = package.loaded["config.cmake"]
		local original_clangd = package.loaded["config.clangd"]
		local original_review = package.loaded["config.code_review"]
		package.loaded["config.cmake"] = { status = function() end }
		package.loaded["config.clangd"] = {
			profile = function()
				return "full"
			end,
		}
		package.loaded["config.code_review"] = { status = function() end }
		local statusline = require("config.statusline")
		statusline.refresh_buffer(buf)
		assert(statusline.python() == "Py:.manual")
		package.loaded["config.cmake"] = original_cmake
		package.loaded["config.clangd"] = original_clangd
		package.loaded["config.code_review"] = original_review
	end, debug.traceback)
	repo_config.root = previous_root
	vim.lsp.get_clients = previous_clients
	vim.defer_fn = previous_defer
	vim.lsp.start = previous_start
	vim.api.nvim_set_current_buf(buf_b)
	vim.api.nvim_buf_delete(picker_buf, { force = true })
	vim.api.nvim_buf_delete(buf, { force = true })
	assert(ok, err)
end)

test("Python mappings stay outside the review namespace", function()
	python.setup()
	for _, name in ipairs({ "PythonEnvironment", "PythonEnvironmentRefresh", "PythonEnvironmentClear" }) do
		assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
	end
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>pr", "n", false, true)))
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>ps", "n", false, true)))
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>ps", "x", false, true)))
	assert(vim.tbl_isempty(vim.fn.maparg("<leader>rp", "n", false, true)))
	assert(vim.tbl_isempty(vim.fn.maparg("<leader>rs", "x", false, true)))
	vim.keymap.del("n", "<leader>pr")
	vim.keymap.del("n", "<leader>ps")
	vim.keymap.del("x", "<leader>ps")
end)

package.loaded["venv-selector"] = original_selector
package.loaded["config.terminal"] = original_terminal
package.loaded["config.project_settings"] = original_project_settings
package.loaded["config.local_config"] = original_local_config
vim.lsp.get_clients = original_clients
vim.ui.select = original_select
vim.defer_fn = original_defer_fn
vim.env.UV_PROJECT_ENVIRONMENT = original_uv_project_environment
vim.env.VIRTUAL_ENV = original_virtual_env
vim.env.CONDA_PREFIX = original_conda_prefix
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("python_spec: %d tests passed", count))
vim.cmd("quitall!")
