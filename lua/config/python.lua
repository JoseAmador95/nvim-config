-- Host adapters for project-python.nvim. Commands, mappings, prompts, LSP
-- restarts, and upstream plugin integration remain configuration policy.
local M = {}
local deferred = require("config.deferred")
local engine_instance
local engine_configured = false
local local_config = require("config.local_config")
local repo = require("config.repo")
local terminal = require("config.terminal")
local project_settings = require("config.project_settings")
local uv = vim.uv
local repl_interpreters = {}
local repl_queues = {}
local repl_drain_attempts = {}
local repl_drain_scheduled = {}
local dap_python_module

local plugin_config = local_config.plugin("project_python", {
	test_runner = "pytest",
	repl = {
		readiness_timeout_ms = 5000,
		poll_interval_ms = 50,
	},
})
local REPL_DRAIN_INTERVAL_MS = plugin_config.repl.poll_interval_ms
local REPL_DRAIN_MAX_ATTEMPTS = math.ceil(plugin_config.repl.readiness_timeout_ms / REPL_DRAIN_INTERVAL_MS)

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Python" })
end

local function canonical(path)
	local value = type(path) == "string" and vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) or nil
	return value and (uv.fs_realpath(value) or value) or nil
end

local function contained(root, path)
	root = canonical(root)
	path = type(path) == "string" and vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) or nil
	return root ~= nil and path ~= nil and (path == root or vim.fs.relpath(root, path) ~= nil)
end

local function attached_ty_root(buf, start)
	local best
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "ty" })) do
		local candidate = client.name == "ty" and client.config and client.config.root_dir or nil
		candidate = canonical(candidate)
		if candidate and contained(candidate, start) and (not best or #candidate > #best) then
			best = candidate
		end
	end
	return best
end

local function project_value(key, root)
	local ok, value = pcall(project_settings.get, key, {}, root)
	return ok and type(value) == "table" and value or nil
end

local function direct_ty_environment(settings)
	if type(settings) ~= "table" then
		return nil
	end
	local ty = type(settings.ty) == "table" and settings.ty or nil
	local configuration = ty and type(ty.configuration) == "table" and ty.configuration or nil
	local environment = configuration and type(configuration.environment) == "table" and configuration.environment
		or nil
	return environment and type(environment.python) == "string" and environment.python ~= "" and environment.python
		or nil
end

local function ty_environment(settings)
	local direct = direct_ty_environment(settings)
	if direct then
		return direct
	end
	return type(settings) == "table" and direct_ty_environment(settings.settings) or nil
end

local function legacy_python(settings)
	if type(settings) ~= "table" then
		return nil
	end
	local nested = type(settings.settings) == "table" and settings.settings or nil
	for _, layer in ipairs({ settings, nested }) do
		local python = type(layer.python) == "table" and layer.python or nil
		if python then
			for _, field in ipairs({ "defaultInterpreterPath", "pythonPath", "venvPath", "venv" }) do
				if type(python[field]) == "string" and python[field] ~= "" then
					return vim.deepcopy(python)
				end
			end
		end
	end
	return nil
end

local function explicit_from_project_settings(root)
	local ty_server = project_value("lspconfig.ty", root)
	local vscode = project_value("vscode", root)
	local legacy_server = project_value("lspconfig.pyright", root)
	return ty_environment(ty_server) or ty_environment(vscode) or legacy_python(vscode) or legacy_python(legacy_server)
end

local function fallback_python()
	for _, name in ipairs({ "python3", "python" }) do
		local path = vim.fn.exepath(name)
		if path ~= "" then
			return path
		end
	end
	return nil
end

local terminal_bridge = {
	status = function(identity)
		return terminal.status(identity)
	end,
	open = function(spec)
		return terminal.open(spec)
	end,
	toggle = function(spec)
		return terminal.toggle(spec)
	end,
	focus = function(spec)
		return terminal.focus(spec)
	end,
	restart = function(spec)
		return terminal.restart(spec)
	end,
	send = function(identity, text)
		return terminal.send(identity, text)
	end,
}

local function ensure_engine()
	if engine_configured and engine_instance then
		return engine_instance
	end
	local candidate = engine_instance
	if not candidate then
		local loaded, result = deferred.try("project_python")
		if not loaded then
			return nil, tostring(result)
		end
		candidate = result
	end
	local ok, result = pcall(candidate.setup, {
		explicit = explicit_from_project_settings,
		fallback = fallback_python,
		terminal = terminal_bridge,
		test_runner = plugin_config.test_runner,
		repl = plugin_config.repl,
	})
	if not ok or not result then
		engine_instance = nil
		engine_configured = false
		return nil, tostring(ok and "project-python setup failed" or result)
	end
	engine_instance = candidate
	engine_configured = true
	return engine_instance
end

local engine = setmetatable({}, {
	__index = function(_, key)
		local instance, err = ensure_engine()
		if not instance then
			error(err)
		end
		return instance[key]
	end,
})

local function root_for_start(start, buf)
	if type(start) ~= "string" or start == "" or start:find("%z") then
		return nil
	end
	return engine.resolve_root({
		start = start,
		attached_root = buf and attached_ty_root(buf, start) or nil,
		repo_root = repo.root(start),
	})
end

function M.root(buf)
	buf = buf or 0
	if buf ~= 0 and not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or (uv.cwd() or vim.fn.getcwd())
	return root_for_start(start, buf)
end

function M.snapshot(root)
	return engine.snapshot(root or M.root(0))
end

function M.for_root(root)
	local snapshot = engine.snapshot(root)
	return snapshot.value.interpreter, snapshot
end

function M.current()
	return M.for_root(M.root(0))
end

local function root_matches(client, root)
	return canonical(client.config and client.config.root_dir) == canonical(root)
end

local function restart_ty(root)
	local buffers = {}
	for _, client in ipairs(vim.lsp.get_clients({ name = "ty" })) do
		if client.name == "ty" and root_matches(client, root) then
			for buf in pairs(client.attached_buffers or {}) do
				buffers[buf] = true
			end
			client:stop()
		end
	end
	if not next(buffers) then
		return
	end
	vim.defer_fn(function()
		for buf in pairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				local config = vim.deepcopy(vim.lsp.config.ty or {})
				config.root_dir = root
				vim.lsp.start(config, {
					bufnr = buf,
					reuse_client = function()
						return false
					end,
				})
			end
		end
	end, 100)
end

local function install_dap_resolver()
	if type(dap_python_module) == "table" then
		dap_python_module.resolve_python = M.current
	end
end

local function public_python()
	local selector = package.loaded["venv-selector"]
	if type(selector) ~= "table" or type(selector.python) ~= "function" then
		return nil
	end
	local ok, path = pcall(selector.python)
	return ok and path or nil
end

local function repl_status(root)
	return engine.repl("status", root) or { exists = false, running = false }
end

local function clear_repl_queue(root)
	repl_queues[root] = nil
	repl_drain_attempts[root] = nil
	repl_drain_scheduled[root] = nil
end

local function fail_repl_queue(root, message)
	clear_repl_queue(root)
	notify(message, vim.log.levels.ERROR)
end

local schedule_repl_drain

local function drain_repl_queue(root)
	local queue = repl_queues[root]
	if not queue or #queue == 0 then
		clear_repl_queue(root)
		return
	end
	local status = repl_status(root)
	if status.accepting_input then
		while queue[1] do
			local ok, send_err = engine.repl("send", root, { text = queue[1] })
			if not ok then
				fail_repl_queue(root, "Could not send code to REPL: " .. tostring(send_err))
				return
			end
			table.remove(queue, 1)
		end
		clear_repl_queue(root)
		return
	end
	if status.exists == false or status.state == "disposed" or status.state == "exited-retained" then
		fail_repl_queue(root, "Python REPL exited before it accepted input")
		return
	end
	local attempts = (repl_drain_attempts[root] or 0) + 1
	repl_drain_attempts[root] = attempts
	if attempts >= REPL_DRAIN_MAX_ATTEMPTS then
		fail_repl_queue(root, "Timed out waiting for Python REPL input")
		return
	end
	schedule_repl_drain(root)
end

schedule_repl_drain = function(root)
	if repl_drain_scheduled[root] then
		return
	end
	repl_drain_scheduled[root] = true
	vim.defer_fn(function()
		repl_drain_scheduled[root] = nil
		drain_repl_queue(root)
	end, REPL_DRAIN_INTERVAL_MS)
end

local function queue_repl_text(root, text)
	local queue = repl_queues[root]
	if not queue then
		queue = {}
		repl_queues[root] = queue
		repl_drain_attempts[root] = 0
	end
	queue[#queue + 1] = text
	schedule_repl_drain(root)
end

local function restart_repl(root, python)
	local record, err = engine.repl("restart", root, { interpreter = python })
	if not record then
		notify("Could not restart REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	repl_interpreters[root] = python
end

local function confirm_repl_restart(root, python)
	local status = repl_status(root)
	if not status.running or repl_interpreters[root] == python then
		return
	end
	vim.ui.select({ "Restart REPL", "Keep current REPL" }, {
		prompt = "Python environment changed for a live REPL",
	}, function(choice)
		if choice == "Restart REPL" then
			restart_repl(root, python)
		end
	end)
end

function M.refresh_current(buf, python)
	local root = M.root(buf or 0)
	python = python or public_python()
	if not root or type(python) ~= "string" then
		return nil, "Python selection is unavailable"
	end
	local before = engine.snapshot(root)
	local snapshot, err = engine.select(root, python)
	if not snapshot then
		return nil, err
	end
	if before.value.interpreter ~= snapshot.value.interpreter or before.source ~= snapshot.source then
		install_dap_resolver()
		restart_ty(root)
		confirm_repl_restart(root, snapshot.value.interpreter)
		vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigPythonChanged", modeline = false })
	end
	return snapshot
end

local function refresh_consumers(root, before, snapshot)
	if before.value.interpreter == snapshot.value.interpreter and before.source == snapshot.source then
		return snapshot
	end
	install_dap_resolver()
	restart_ty(root)
	confirm_repl_restart(root, snapshot.value.interpreter)
	vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigPythonChanged", modeline = false })
	return snapshot
end

function M.refresh(root)
	root = root or M.root(0)
	if not root then
		return nil, "Python project root is unavailable"
	end
	local before = engine.snapshot(root)
	local snapshot, err = engine.refresh(root)
	if not snapshot then
		return nil, err
	end
	return refresh_consumers(root, before, snapshot)
end

function M.clear(root)
	root = root or M.root(0)
	if not root then
		return nil, "Python project root is unavailable"
	end
	local before = engine.snapshot(root)
	local snapshot, err = engine.clear(root)
	if not snapshot then
		return nil, err
	end
	return refresh_consumers(root, before, snapshot)
end

function M.environment(root)
	root = root or M.root(0)
	if not root then
		return nil, "Python project root is unavailable"
	end
	local snapshot = engine.snapshot(root)
	local diagnostics = engine.diagnostics(root)
	return {
		root = root,
		snapshot = snapshot,
		candidates = diagnostics.candidates,
	}
end

local function apply_ty_settings(config, root)
	if type(config) ~= "table" then
		return nil, "ty config is invalid"
	end
	root = canonical(root or config.root_dir)
	local settings = type(config.settings) == "table" and config.settings or {}
	config.settings = settings
	local configured_explicit = direct_ty_environment(settings)
	local explicit = configured_explicit or explicit_from_project_settings(root)
	local snapshot, err = engine.sync(root, explicit)
	if not snapshot then
		return nil, err
	end
	if configured_explicit or snapshot.validity ~= "valid" then
		return snapshot
	end
	settings.ty = type(settings.ty) == "table" and settings.ty or {}
	settings.ty.configuration = type(settings.ty.configuration) == "table" and settings.ty.configuration or {}
	local configuration = settings.ty.configuration
	configuration.environment = type(configuration.environment) == "table" and configuration.environment or {}
	configuration.environment.python = snapshot.value.interpreter
	return snapshot
end

function M.lsp_root_dir(buf, on_dir)
	on_dir(M.root(buf))
end

function M.before_init(_, config)
	return apply_ty_settings(config, config and config.root_dir or M.root(0))
end

function M.on_new_config(config, root)
	return apply_ty_settings(config, root or (config and config.root_dir) or M.root(0))
end

function M.neotest_python(root)
	return engine.neotest_python(root)
end

function M.neotest_runner()
	return engine.neotest_runner()
end

function M.setup_dap(dap, dap_python)
	dap_python_module = dap_python or package.loaded["dap-python"]
	install_dap_resolver()
	dap.listeners.on_config.nvim_config_python = function(config)
		local function value(field)
			local candidate = config[field]
			if type(candidate) == "function" then
				local ok, resolved = pcall(candidate)
				candidate = ok and resolved or nil
			end
			return type(candidate) == "string" and candidate ~= "" and not candidate:find("${", 1, true) and candidate
				or nil
		end
		local resolved_root
		for _, field in ipairs({ "cwd", "program", "workspace", "workspaceFolder" }) do
			resolved_root = root_for_start(value(field))
			if resolved_root then
				break
			end
		end
		return engine.apply_dap(config, resolved_root or M.root(0))
	end
end

function M.open_repl()
	local root = M.root(0)
	local python = M.for_root(root)
	if not root or not python then
		notify("Could not open REPL: project Python is unavailable", vim.log.levels.ERROR)
		return
	end
	local status = repl_status(root)
	if status.running and repl_interpreters[root] and repl_interpreters[root] ~= python then
		vim.ui.select({ "Restart REPL", "Keep current REPL" }, {
			prompt = "The selected Python differs from the live REPL",
		}, function(choice)
			if choice == "Restart REPL" then
				restart_repl(root, python)
			elseif choice == "Keep current REPL" then
				engine.repl("focus", root, { interpreter = repl_interpreters[root] })
			end
		end)
		return
	end
	local action = status.running and "toggle" or (status.exists and "restart" or "toggle")
	local record, err = engine.repl(action, root, { interpreter = python })
	if not record then
		notify("Could not open REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	repl_interpreters[root] = python
end

local function visual_text()
	local start = vim.api.nvim_buf_get_mark(0, "<")
	local finish = vim.api.nvim_buf_get_mark(0, ">")
	if start[1] == 0 or finish[1] == 0 then
		return nil
	end
	local lines = vim.api.nvim_buf_get_text(0, start[1] - 1, start[2], finish[1] - 1, finish[2] + 1, {})
	return table.concat(lines, "\n")
end

function M.send(selection)
	local root = M.root(0)
	local text = selection and visual_text() or vim.api.nvim_get_current_line()
	if not root or not text or text == "" then
		return
	end
	local status = repl_status(root)
	local python = status.running and repl_interpreters[root] or M.for_root(root)
	local payload = "exec(" .. vim.json.encode(text) .. ")"
	if status.stop_pending or status.restart_pending or status.dispose_pending then
		queue_repl_text(root, payload)
		return
	end
	local record, err
	if not status.running then
		if status.exists then
			record, err = engine.repl("restart", root, { interpreter = python })
		else
			record, err = engine.repl("open", root, { interpreter = python })
		end
		repl_interpreters[root] = python
	else
		record, err = engine.repl("focus", root, { interpreter = python })
	end
	if not record then
		notify("Could not prepare REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	queue_repl_text(root, payload)
end

function M.venv_name(root)
	return engine.venv_name(root or M.root(0))
end

function M.setup()
	local function show_environment()
		local environment, err = M.environment()
		if not environment then
			notify(err, vim.log.levels.ERROR)
			return
		end
		local snapshot = environment.snapshot
		local lines = {
			("root: %s"):format(environment.root),
			("source: %s (%s)"):format(snapshot.source, snapshot.validity),
			("interpreter: %s"):format(snapshot.value.interpreter or "unavailable"),
			"candidates:",
		}
		for _, candidate in ipairs(environment.candidates) do
			lines[#lines + 1] = ("  %s: %s [%s]"):format(
				candidate.source,
				candidate.interpreter or candidate.path or "unavailable",
				candidate.validity
			)
		end
		notify(table.concat(lines, "\n"))
	end
	local function run_change(callback, label)
		local snapshot, err = callback()
		if not snapshot then
			notify(("Could not %s Python environment: %s"):format(label, tostring(err)), vim.log.levels.ERROR)
			return
		end
		notify(("Python environment %s: %s"):format(label, snapshot.value.interpreter or "unavailable"))
	end
	vim.api.nvim_create_user_command("PythonEnvironment", show_environment, {
		desc = "Show the selected Python environment and discovery candidates",
		force = true,
	})
	vim.api.nvim_create_user_command("PythonEnvironmentRefresh", function()
		run_change(M.refresh, "refreshed")
	end, { desc = "Refresh the current project Python environment", force = true })
	vim.api.nvim_create_user_command("PythonEnvironmentClear", function()
		run_change(M.clear, "cleared")
	end, { desc = "Clear the current project's manual Python environment", force = true })
	vim.keymap.set("n", "<leader>pr", M.open_repl, { desc = "Python REPL" })
	vim.keymap.set("n", "<leader>ps", function()
		M.send(false)
	end, { desc = "Send line to Python REPL" })
	vim.keymap.set("x", "<leader>ps", function()
		M.send(true)
	end, { desc = "Send selection to Python REPL" })
end

M._engine = ensure_engine

return M
