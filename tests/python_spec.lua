vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
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
local original_clients = vim.lsp.get_clients
local original_select = vim.ui.select
local original_path = vim.env.PATH
local original_virtual_env = vim.env.VIRTUAL_ENV
local original_conda_prefix = vim.env.CONDA_PREFIX

local active_python
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
local toggled_specs = {}
local opened_specs = {}
local focused_specs = {}
local sent = {}
package.loaded["config.terminal"] = {
	status = function()
		return { exists = terminal_exists, running = terminal_running }
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
		toggled_specs[#toggled_specs + 1] = vim.deepcopy(spec)
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

local python = require("config.python")
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
	assert(vim.env.VIRTUAL_ENV == original_virtual_env)
	assert(vim.env.CONDA_PREFIX == original_conda_prefix)
end)

test("Pyright, Neotest, and DAP consume the same root selection", function()
	local config = { root_dir = fixture .. "/a", settings = { pyright = { disableOrganizeImports = true } } }
	python.before_init({}, config)
	assert(config.settings.python.pythonPath == python_a)
	assert(config.settings.pyright.disableOrganizeImports)
	assert(vim.deep_equal(python.neotest_python(fixture .. "/a"), { python_a }))
	assert(python.neotest_runner({ python_a }) == "pytest")
	assert(python.neotest_runner({ python_b }) == "unittest")

	vim.api.nvim_set_current_buf(buf_a)
	local dap = { listeners = { on_config = {} } }
	python.setup_dap(dap)
	local source = { type = "python", request = "launch" }
	local resolved = dap.listeners.on_config.nvim_config_python(source)
	assert(resolved ~= source and resolved.pythonPath == python_a)
	assert(dap.listeners.on_config.nvim_config_python({ type = "cppdbg" }).type == "cppdbg")
end)

test("sending code opens and focuses the project REPL automatically", function()
	vim.api.nvim_set_current_buf(buf_a)
	vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "answer = 6 * 7" })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	active_python = python_a
	python.refresh_current()
	terminal_exists = false
	terminal_running = false
	opened_specs = {}
	focused_specs = {}
	sent = {}
	python.send(false)
	assert(#opened_specs == 1 and vim.deep_equal(opened_specs[1].argv, { python_a, "-i" }))
	assert(#sent == 1 and sent[1].text == 'exec("answer = 6 * 7")')
	python.send(false)
	assert(#opened_specs == 1, "an existing REPL was opened twice")
	assert(#focused_specs == 1, "a hidden live REPL was not focused before sending")
	assert(#sent == 2, "the second line was not sent to the live REPL")
end)

test("sending code restarts a retained stopped REPL", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = true
	terminal_running = false
	toggled_specs = {}
	opened_specs = {}
	sent = {}
	python.send(false)
	assert(#opened_specs == 0, "a stopped retained REPL was duplicated")
	assert(#toggled_specs == 1, "a stopped retained REPL was not restarted")
	assert(#sent == 1, "code was not sent after restarting the REPL")
end)

test("a live REPL asks before adopting a changed interpreter", function()
	vim.api.nvim_set_current_buf(buf_a)
	terminal_exists = false
	terminal_running = false
	toggled_specs = {}
	active_python = python_a
	python.refresh_current()
	python.open_repl()
	assert(#toggled_specs == 1 and vim.deep_equal(toggled_specs[1].argv, { python_a, "-i" }))
	local prompt
	vim.ui.select = function(items, opts)
		prompt = { items = items, opts = opts }
	end
	active_python = python_a2
	python.refresh_current()
	assert(prompt and prompt.opts.prompt:find("environment changed", 1, true))
	assert(#toggled_specs == 1, "REPL restarted without confirmation")
end)

local venv_spec = require("plugins.python")
test("venv-selector disables all implicit global activation paths", function()
	assert(venv_spec.commit == "cc4bb3975de8835291f9bb45889e96c6b2795fc4")
	assert(venv_spec.opts.options.cached_venv_automatic_activation == false)
	assert(venv_spec.opts.options.activate_venv_in_terminal == false)
	assert(venv_spec.opts.options.set_environment_variables == false)
	assert(#venv_spec.opts.hooks == 1 and venv_spec.opts.hooks[1]() == 0)
end)

package.loaded["venv-selector"] = original_selector
package.loaded["config.terminal"] = original_terminal
vim.lsp.get_clients = original_clients
vim.ui.select = original_select
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("python_spec: %d tests passed", count))
vim.cmd("quitall!")
